"""界面偏好接口：全站页面样式设定的读写。

设定按页面分组（结构见 settings.schemas 的 ``UiPreferencesSetting``），
本路由做整体读写透传——纯用户偏好、无敏感字段、无业务校验（结构校验由
Pydantic 完成，未知字段按前向兼容忽略），因此请求/响应体直接复用配置域
模型，不另抄一份 schema。

存储按主体分流（docs/design/member-management.md P2）：
- 超管 → ``ui.preferences`` 全局配置域（升级前的既有数据原地生效）；
- 成员 → ``member.ui_prefs`` JSON 列，各存各的；NULL 回退默认值——
  成员拖外观滑杆不再覆盖全家的界面设定。

前端在应用启动时 GET 一次、Context 全站共享；每次改动 PUT 整体覆盖。
未来新增页面的样式设定：配置域模型加字段 → 前端类型同步 → 无需动本文件。
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from pydantic import Field
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.deps import require_login
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.auth import Principal
from movieclaw_api.settings.schemas import (
    UiPreferencesSetting,
    get_ui_preferences,
    save_ui_preferences,
)
from movieclaw_db.engine import get_session
from movieclaw_db.repositories.member_repo import MemberRepository

router = APIRouter(prefix="/ui", tags=["ui"])


@router.get(
    "/preferences",
    response_model=ApiResponse[UiPreferencesSetting],
    summary="读取界面偏好（按页面分组的样式设定）",
    operation_id="ui.prefs.show",
)
async def get_preferences(
    principal: Principal = Depends(require_login),
) -> ApiResponse[UiPreferencesSetting]:
    """返回当前主体的界面样式偏好；从未配置过的部分返回默认值。"""
    if principal.kind == "member" and principal.member is not None:
        raw = principal.member.ui_prefs
        # 未知字段前向兼容忽略（与配置域读取同语义）
        return ok(UiPreferencesSetting.model_validate(raw) if raw else UiPreferencesSetting())
    return ok(await get_ui_preferences())


@router.put(
    "/preferences",
    response_model=ApiResponse[UiPreferencesSetting],
    summary="保存界面偏好（整体覆盖）",
    operation_id="ui.prefs.update",
)
async def update_preferences(
    payload: UiPreferencesSetting,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[UiPreferencesSetting]:
    """整体覆盖式保存界面偏好，返回保存后的值。成员写自己的列，不碰全局。

    例外：请求里没带 ``nav.hidden`` 时沿用已存的值。已发布的 iPhone App 用生成的模型整体回写，
    旧模型里没有这个字段，保存首页设置时不能把网页上「移出侧边栏」的项冲掉。
    """
    keep_hidden = "hidden" not in payload.nav.model_fields_set
    if principal.kind == "member" and principal.member_id is not None:
        repo = MemberRepository(session)
        member = await repo.get(principal.member_id)
        if member is not None:
            if keep_hidden and member.ui_prefs:
                stored = UiPreferencesSetting.model_validate(member.ui_prefs)
                payload.nav.hidden = stored.nav.hidden
            member.ui_prefs = payload.model_dump(mode="json")
            await repo.save(member)
        return ok(payload, message="界面设置已保存")
    if keep_hidden:
        payload.nav.hidden = (await get_ui_preferences()).nav.hidden
    return ok(await save_ui_preferences(payload), message="界面设置已保存")


class AppEntry(BaseModel):
    label: str = Field(description="侧边栏文字（manifest 的 short_name / name）")
    path: str = Field(description="落点：相对插件网页根目录的子路径，主入口通常为空")
    icon: str | None = Field(default=None, description="图标地址；没有则用默认图标")
    monochrome: bool = Field(
        default=False, description="manifest 标了 purpose: monochrome：按遮罩用当前文字颜色着色"
    )


class AppView(BaseModel):
    id: str = Field(description="插件 id；主程序地址是 /apps/<id>/")
    name: str
    nav: bool = Field(description="用户同意加到侧边栏")
    base: str = Field(description="iframe 加载的地址前缀")
    entries: list[AppEntry] = Field(description="侧边栏项：主入口在前，manifest shortcuts 依次在后")


@router.get(
    "/apps",
    response_model=ApiResponse[list[AppView]],
    summary="当前用户可见的插件网页与侧边栏入口（docs/design/plugin-web-pages.md）",
    operation_id="ui.apps.list",
    openapi_extra={"x-cli-hidden": True},
)
def list_apps(
    request: Request, principal: Principal = Depends(require_login)
) -> ApiResponse[list[AppView]]:
    # 普通 def：要读安装记录与插件目录，放线程池里跑，不占事件循环
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services import plugin_web

    kernel = getattr(request.app.state, "kernel", None)
    apps = plugin_web.visible_apps(get_settings(), principal, kernel)
    return ok([AppView.model_validate(app) for app in apps])


class AppErrorReport(BaseModel):
    message: str = Field(max_length=500, description="报错信息（error.message）")
    detail: str = Field(default="", max_length=4000, description="出处与调用栈")


@router.post(
    "/apps/{entry_id}/errors",
    response_model=ApiResponse[None],
    summary="插件页面里没接住的报错：写进系统日志（按插件 id 可查）",
    operation_id="ui.apps.errors.report",
    openapi_extra={"x-cli-hidden": True},
)
def report_app_error(
    entry_id: str,
    body: AppErrorReport,
    request: Request,
    principal: Principal = Depends(require_login),
) -> ApiResponse[None]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.exceptions import NotFoundException
    from movieclaw_api.services import plugin_web

    found = plugin_web.find(get_settings(), entry_id)
    kernel = getattr(request.app.state, "kernel", None)
    if found is None or not plugin_web.visible_to(found, principal, kernel):
        raise NotFoundException("没有这个插件页面")
    plugin_web.log_page_error(entry_id, principal.name, body.message, body.detail)
    return ok(None)

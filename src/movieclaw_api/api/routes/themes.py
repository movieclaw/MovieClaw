"""网页主题的目录与托管（docs/design/theme-plugins.md §4.6）。

- ``GET /ui/themes``：当前可用的主题（设置 → 外观的选择卡、前端加载器与首帧缓存都只认它），
  要求登录；
- ``GET /ui/themes.css``：聚合样式表，每个主题一行 ``@import``。根布局固定引用它，**免登录**——
  登录页、初始化页也要按所选主题渲染；
- ``GET /ui/themes/<id>/<子路径>``：主题文件。CSS 与资源免登录（同上）；JS（外框组件）只给登录的人，
  只有外壳用得到它。带 ``?v=`` 的地址内容不变（版本号含文件修改戳），长缓存；不带的按 ETag 校验。

处理函数写成普通 ``def``：要读安装记录与包目录，放线程池里跑，盘慢（NAS）时不卡事件循环。
"""

from __future__ import annotations

import hashlib
import mimetypes

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import FileResponse
from pydantic import Field

from movieclaw_api.api.deps import optional_login, require_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import NotFoundException, UnauthorizedException
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services import themes
from movieclaw_api.services.auth import Principal

router = APIRouter(prefix="/ui", tags=["ui"])

_TYPES = {
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".css": "text/css",
    ".svg": "image/svg+xml",
}
_SCRIPTS = {".js", ".mjs"}
#: 带版本号的地址内容不会变：一年强缓存
_IMMUTABLE = "public, max-age=31536000, immutable"


class ThemePreview(BaseModel):
    bg: str = Field(description="选择卡底色")
    accent: str = Field(description="选择卡主色")


class ThemeView(BaseModel):
    id: str = Field(
        description="主题 id（= 插件 id）；偏好的 theme / theme_desktop / theme_mobile 存它"
    )
    label: str = Field(description="设置页展示名")
    description: str
    preview: ThemePreview
    theme_color: str = Field(description="浏览器地址栏 / PWA 状态栏颜色")
    layout: str = Field(description="版式：panel / cinema")
    glass: bool = Field(description="是否用液态玻璃")
    version: str
    source: str = Field(description="bundled（随应用提供）/ package（插件包）")
    status: str = Field(description="ok / incompatible（主题契约不兼容，需要更新插件）")
    reason: str | None = Field(default=None, description="不兼容的原因")
    css: str | None = Field(default=None, description="主题样式地址；不兼容时为空")
    script: str | None = Field(default=None, description="外框组件模块地址；纯换肤与不兼容时为空")


def _kernel(request: Request):
    return getattr(request.app.state, "kernel", None)


@router.get(
    "/themes",
    response_model=ApiResponse[list[ThemeView]],
    summary="可用的网页主题（docs/design/theme-plugins.md）",
    operation_id="ui.themes.list",
    openapi_extra={"x-cli-hidden": True},
)
def list_themes(
    request: Request, principal: Principal = Depends(require_login)
) -> ApiResponse[list[ThemeView]]:
    found = themes.themes(get_settings(), _kernel(request))
    return ok([ThemeView.model_validate(themes.view(t)) for t in found])


def _etag(text: str) -> str:
    return '"' + hashlib.md5(text.encode()).hexdigest() + '"'  # noqa: S324 -- 只做缓存校验


@router.get(
    "/themes.css",
    summary="全部可用主题的聚合样式表（根布局固定引用，免登录）",
    operation_id="ui.themes.stylesheet",
    openapi_extra={"x-cli-hidden": True},
)
def themes_stylesheet(request: Request) -> Response:
    text = themes.stylesheet(get_settings(), _kernel(request))
    etag = _etag(text)
    headers = {"Cache-Control": "no-cache", "ETag": etag}
    if etag in request.headers.get("if-none-match", ""):
        return Response(status_code=304, headers=headers)
    return Response(text, media_type="text/css", headers=headers)


@router.get(
    "/themes/{theme_id}/{path:path}",
    summary="主题文件：样式与资源免登录，外框组件（JS）要求登录",
    operation_id="ui.themes.file",
    openapi_extra={"x-cli-hidden": True},
)
def theme_file(
    theme_id: str,
    path: str,
    request: Request,
    principal: Principal | None = Depends(optional_login),
) -> Response:
    theme = themes.find(get_settings(), _kernel(request), theme_id)
    if theme is None or theme.incompatible is not None:
        raise NotFoundException("没有这个主题")
    target = themes.resolve_file(theme, path)
    if target is None:
        raise NotFoundException("文件不存在")
    suffix = target.suffix.lower()
    if suffix in _SCRIPTS and principal is None:
        raise UnauthorizedException("请先登录")
    stat = target.stat()
    etag = (
        '"'
        + hashlib.md5(  # noqa: S324 -- 只做缓存校验
            f"{target}:{stat.st_mtime_ns}:{stat.st_size}".encode()
        ).hexdigest()
        + '"'
    )
    cache = _IMMUTABLE if request.query_params.get("v") else "no-cache"
    # 脚本按登录区分，别让共享缓存存
    if suffix in _SCRIPTS:
        cache = cache.replace("public", "private")
    headers = {"Cache-Control": cache, "ETag": etag}
    if etag in request.headers.get("if-none-match", ""):
        return Response(status_code=304, headers=headers)
    media_type = (
        _TYPES.get(suffix) or mimetypes.guess_type(target.name)[0] or "application/octet-stream"
    )
    return FileResponse(target, media_type=media_type, headers=headers, stat_result=stat)

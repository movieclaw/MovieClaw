"""功能开关接口（docs/design/plugin-page-tiers.md §6）。

- ``GET /app/features``：成员区。功能目录与开关状态；各端据此决定入口显隐（停用的功能不出入口）。
- ``PUT /app/features/{key}``：管理员。运行中停用 / 开启一个可停用的功能，重启后保持。
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from pydantic import Field

from movieclaw_api.api.deps import require_admin
from movieclaw_api.exceptions import AppException
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.auth import Principal

router = APIRouter(prefix="/app/features", tags=["app"])


class FeatureView(BaseModel):
    key: str
    title: str
    description: str
    entries: list[str] = Field(description="组成这个功能的内置插件条目 id")
    settings_href: str | None = Field(description="去哪里设置它（站内路径）")
    switchable: bool = Field(description="能不能在插件页停用")
    enabled: bool = Field(description="当前是否开启（被停用或被管理员硬覆盖关掉都算关）")
    locked_by: str | None = Field(
        description="被 data/plugins.yaml / 环境变量关掉时的原因：开关锁住，要在那里改回来"
    )
    changed_at: str | None = Field(description="停用时间（ISO 8601 UTC）；开启着为空")
    changed_by: str | None = Field(description="谁停用的；开启着为空")


class FeatureSwitchPayload(BaseModel):
    enabled: bool = Field(description="true 开启，false 停用")


def _views(request: Request) -> list[FeatureView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.plugin_features import feature_views

    kernel = getattr(request.app.state, "kernel", None)
    return [FeatureView.model_validate(v) for v in feature_views(kernel, get_settings())]


@router.get(
    "",
    response_model=ApiResponse[list[FeatureView]],
    summary="功能目录与开关状态（停用的功能各端不出入口）",
    operation_id="app.features.list",
)
async def list_features(request: Request) -> ApiResponse[list[FeatureView]]:
    return ok(_views(request))


@router.put(
    "/{key}",
    response_model=ApiResponse[FeatureView],
    summary="停用 / 开启一个功能：运行中生效，重启后保持",
    operation_id="app.features.set",
)
async def set_feature(
    key: str,
    payload: FeatureSwitchPayload,
    request: Request,
    principal: Principal = Depends(require_admin),
) -> ApiResponse[FeatureView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.plugin_features import FeatureSwitchError, set_enabled

    kernel = getattr(request.app.state, "kernel", None)
    if kernel is None:
        raise AppException(status_code=503, code="KERNEL_NOT_RUNNING", message="插件内核未运行")
    try:
        await set_enabled(kernel, get_settings(), key, payload.enabled, actor=principal.name)
    except FeatureSwitchError as exc:
        raise AppException(status_code=exc.status, code=exc.code, message=exc.message) from exc
    view = next(v for v in _views(request) if v.key == key)
    return ok(view, message=f"「{view.title}」已{'开启' if view.enabled else '停用'}")

from __future__ import annotations

import logging
from pathlib import Path

from fastapi import APIRouter, Depends, File, UploadFile
from fastapi.responses import FileResponse, Response

from movieclaw_api.api.deps import optional_login, require_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.appearance import (
    ActiveBackdropUpdate,
    AppearanceView,
    BackdropItem,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services import appearance as appearance_media
from movieclaw_api.services.auth import Principal

logger = logging.getLogger("movieclaw_api.appearance")

router = APIRouter(prefix="/appearance", tags=["appearance"])


def _item_url(path: Path) -> str:
    """构造一张背景图的带版本号相对地址。

    版本号取文件修改时间的**纳秒**值（st_mtime_ns）：内容变化 → URL 变化，
    浏览器 <img> 与 WebGL 纹理缓存都按 URL 命中，借此强制加载新图。
    """
    version = path.stat().st_mtime_ns
    prefix = get_settings().api_v1_prefix
    return f"{prefix}/appearance/backdrops/{path.stem}?v={version}"


def _member_scope(principal: Principal | None) -> int | None:
    """把请求主体收敛为存储作用域；匿名和管理员都使用既有全局目录。"""
    if principal is not None and principal.kind == "member":
        return principal.member_id
    return None


def _view(member_id: int | None = None) -> AppearanceView:
    """汇总指定主体的图库与生效标记，构造完整外观视图。"""
    items = [
        BackdropItem(id=path.stem, url=_item_url(path))
        for path in appearance_media.list_backdrops(member_id)
    ]
    active_id = appearance_media.get_active_id(member_id)
    active_url = next((item.url for item in items if item.id == active_id), None)
    return AppearanceView(
        active_id=active_id if active_url else None,
        active_url=active_url,
        backdrops=items,
    )


# 读取接口保持公开：登录页使用管理员全局背景；登录成员则按会话读取自己的
# 图库。写接口必须登录，并由 Principal 自动限定到自己的存储作用域。
@router.get(
    "",
    response_model=ApiResponse[AppearanceView],
    summary="读取外观设置（背景图库与当前生效图）",
    operation_id="appearance.show",
)
async def get_appearance(
    principal: Principal | None = Depends(optional_login),
) -> ApiResponse[AppearanceView]:
    """前端启动时调用：拿到图库列表与生效图地址；生效图为空则用内置默认背景。"""
    return ok(_view(_member_scope(principal)))


@router.post(
    "/backdrops",
    response_model=ApiResponse[AppearanceView],
    summary="上传一张新背景图（加入图库并设为生效）",
    operation_id="appearance.backdrops.upload",
)
async def upload_backdrop(
    file: UploadFile = File(...),
    principal: Principal = Depends(require_login),
) -> ApiResponse[AppearanceView]:
    """接收一张图片存入图库并立即启用；已有的图全部保留，供随时切换。

    校验：只接受常见位图格式（拒绝可内嵌脚本的 SVG）、大小与图库张数有上限。
    错误信息为中文，方便非开发者按提示处理。
    """
    if not appearance_media.is_supported_content_type(file.content_type):
        raise BadRequestException(message_key="errors.appearance.imageFormatUnsupported")

    data = await file.read()
    if not data:
        raise BadRequestException(message_key="errors.appearance.imageEmpty")
    if len(data) > appearance_media.MAX_BACKDROP_BYTES:
        limit_mb = appearance_media.MAX_BACKDROP_BYTES // (1024 * 1024)
        raise BadRequestException(
            message_key="errors.appearance.imageTooLarge", params={"limit": limit_mb}
        )
    member_id = _member_scope(principal)
    if len(appearance_media.list_backdrops(member_id)) >= appearance_media.MAX_BACKDROP_COUNT:
        raise BadRequestException(
            message_key="errors.appearance.backgroundLimit",
            params={"limit": appearance_media.MAX_BACKDROP_COUNT},
        )

    # 已在上面校验过 content_type 属于受支持集合，此处必定命中
    appearance_media.save_backdrop(
        data,
        file.content_type,  # type: ignore[arg-type]
        member_id,
    )
    return ok(_view(member_id))


@router.put(
    "/active",
    response_model=ApiResponse[AppearanceView],
    summary="切换当前生效的背景图",
    operation_id="appearance.active.set",
)
async def set_active_backdrop(
    payload: ActiveBackdropUpdate,
    principal: Principal = Depends(require_login),
) -> ApiResponse[AppearanceView]:
    """点选图库中的某张图启用；``backdrop_id`` 传空则切回内置默认背景（不删图）。"""
    member_id = _member_scope(principal)
    if not appearance_media.set_active(payload.backdrop_id, member_id):
        raise NotFoundException(message_key="errors.appearance.backgroundRemovedRefresh")
    return ok(_view(member_id))


@router.delete(
    "/backdrops/{backdrop_id}",
    response_model=ApiResponse[AppearanceView],
    summary="从图库删除一张背景图",
    operation_id="appearance.backdrops.delete",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def delete_backdrop(
    backdrop_id: str,
    principal: Principal = Depends(require_login),
) -> ApiResponse[AppearanceView]:
    """删除指定背景图；若删的是当前生效图，自动回退到内置默认背景。"""
    member_id = _member_scope(principal)
    if not appearance_media.remove_backdrop(backdrop_id, member_id):
        raise NotFoundException(message_key="errors.appearance.backgroundRemoved")
    return ok(_view(member_id))


@router.get(
    "/backdrops/{backdrop_id}",
    summary="读取一张背景图文件",
    response_class=Response,
    operation_id="appearance.backdrops.download",
)
async def read_backdrop(
    backdrop_id: str,
    principal: Principal | None = Depends(optional_login),
) -> FileResponse:
    """直接返回图片文件本身，供 <img> 与 WebGL 着色器加载。

    地址由 ``GET /appearance`` 返回（带版本号）；图不存在时返回 404。
    """
    path = appearance_media.find_backdrop(backdrop_id, _member_scope(principal))
    if path is None:
        raise NotFoundException(message_key="errors.appearance.backgroundRemoved")
    return FileResponse(
        path,
        media_type=appearance_media.content_type_for(path),
        # 成员背景必须经过会话作用域判定，不能进入共享代理缓存。
        headers={"Cache-Control": "private, max-age=31536000"},
    )

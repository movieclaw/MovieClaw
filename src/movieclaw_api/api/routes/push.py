"""App 推送的接口（docs/design/cloud-push.md §7.2–7.4）。

三个路由组，分别挂在三个鉴权分区：

- ``admin_router``（管理区）：推送通道、设备覆盖、自建中继；
- ``member_router``（成员区）：每个人自己的通知开关、设备状态、测试通知、App 登记；
- ``public_router``（公开区）：推送配图。通知扩展拿不到登录令牌，配图地址自带签名
  （services/push/images.py），签名不对一律 404。

全部标 ``x-cli-hidden``：命令行用不上。
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.deps import require_login
from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.schemas.cloud import (
    MyPushView,
    OfficialChannelRequest,
    PushChannelsView,
    PushPreferencesRequest,
    PushRegistrationRequest,
    PushRegistrationView,
    PushTestView,
    RelayCreateRequest,
    RelayProbeRequest,
    RelayProbeView,
    RelayUpdateRequest,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.push import admin, me, preferences
from movieclaw_api.services.push.images import resolve_image
from movieclaw_db.engine import get_session

_HIDDEN = {"x-cli-hidden": True}

admin_router = APIRouter(prefix="/push", tags=["push"])
member_router = APIRouter(prefix="/push/me", tags=["push"])
public_router = APIRouter(prefix="/push/images", tags=["push"])


# ----------------------------------------------------------------------
# 通道（管理员）
# ----------------------------------------------------------------------


@admin_router.get(
    "/channels",
    response_model=ApiResponse[PushChannelsView],
    summary="推送通道与设备覆盖",
    operation_id="push.channels.list",
    openapi_extra=_HIDDEN,
)
async def list_channels() -> ApiResponse[PushChannelsView]:
    return ok(await admin.build_channels_view())


@admin_router.put(
    "/channels/official",
    response_model=ApiResponse[PushChannelsView],
    summary="启用 / 停用官方推送通道",
    operation_id="push.channels.official.set",
    openapi_extra=_HIDDEN,
)
async def set_official(payload: OfficialChannelRequest) -> ApiResponse[PushChannelsView]:
    await admin.set_official_enabled(payload.enabled)
    return ok(await admin.build_channels_view())


@admin_router.post(
    "/relays/probe",
    response_model=ApiResponse[RelayProbeView],
    summary="检测一个自建中继",
    operation_id="push.relays.probe",
    openapi_extra=_HIDDEN,
)
async def probe_relay(payload: RelayProbeRequest) -> ApiResponse[RelayProbeView]:
    return ok(await admin.probe(payload.url))


@admin_router.post(
    "/relays",
    response_model=ApiResponse[PushChannelsView],
    summary="添加自建中继",
    operation_id="push.relays.create",
    openapi_extra=_HIDDEN,
)
async def create_relay(payload: RelayCreateRequest) -> ApiResponse[PushChannelsView]:
    await admin.create_relay(name=payload.name, url=payload.url, token=payload.token)
    return ok(await admin.build_channels_view(), message="已添加自建中继")


@admin_router.patch(
    "/relays/{relay_id}",
    response_model=ApiResponse[PushChannelsView],
    summary="修改自建中继（改地址、换令牌会重新检测）",
    operation_id="push.relays.update",
    openapi_extra=_HIDDEN,
)
async def update_relay(relay_id: str, payload: RelayUpdateRequest) -> ApiResponse[PushChannelsView]:
    await admin.update_relay(
        relay_id,
        name=payload.name,
        url=payload.url,
        token=payload.token,
        enabled=payload.enabled,
    )
    return ok(await admin.build_channels_view())


@admin_router.delete(
    "/relays/{relay_id}",
    response_model=ApiResponse[PushChannelsView],
    summary="删除自建中继",
    operation_id="push.relays.delete",
    openapi_extra={**_HIDDEN, "x-cli-dangerous": "confirm"},
)
async def delete_relay(relay_id: str) -> ApiResponse[PushChannelsView]:
    await admin.delete_relay(relay_id)
    return ok(await admin.build_channels_view(), message="已删除自建中继")


@admin_router.post(
    "/relays/{relay_id}/refresh",
    response_model=ApiResponse[PushChannelsView],
    summary="重新读取中继的能力（/v1/info）",
    operation_id="push.relays.refresh",
    openapi_extra=_HIDDEN,
)
async def refresh_relay(relay_id: str) -> ApiResponse[PushChannelsView]:
    await admin.refresh_relay(relay_id)
    return ok(await admin.build_channels_view())


# ----------------------------------------------------------------------
# 我的通知（所有登录的人）
# ----------------------------------------------------------------------


@member_router.get(
    "",
    response_model=ApiResponse[MyPushView],
    summary="我的通知开关与能收通知的设备",
    operation_id="push.me.show",
    openapi_extra=_HIDDEN,
)
async def my_push(
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[MyPushView]:
    return ok(await me.build_view(session, principal))


@member_router.put(
    "/preferences",
    response_model=ApiResponse[MyPushView],
    summary="改我的通知开关",
    operation_id="push.me.preferences.set",
    openapi_extra=_HIDDEN,
)
async def update_preferences(
    payload: PushPreferencesRequest,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[MyPushView]:
    await preferences.update(
        session,
        principal.owner_id,
        payload.events,
        is_admin=principal.is_admin,
        library_ids=(
            payload.library_ids if "library_ids" in payload.model_fields_set else preferences.KEEP
        ),
    )
    return ok(await me.build_view(session, principal))


@member_router.put(
    "/muted-items/{item_id}",
    response_model=ApiResponse[MyPushView],
    summary="这部片不再提醒（长按通知的快捷操作；只关推送，订阅照常下载）",
    operation_id="push.me.muted.add",
    openapi_extra=_HIDDEN,
)
async def mute_item(
    item_id: int,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[MyPushView]:
    from movieclaw_db.models import MediaItem

    if await session.get(MediaItem, item_id) is None:
        raise NotFoundException("没有这部片")
    await preferences.set_muted(session, principal.owner_id, item_id, True)
    return ok(await me.build_view(session, principal))


@member_router.delete(
    "/muted-items/{item_id}",
    response_model=ApiResponse[MyPushView],
    summary="恢复一部片的推送",
    operation_id="push.me.muted.remove",
    openapi_extra=_HIDDEN,
)
async def unmute_item(
    item_id: int,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[MyPushView]:
    await preferences.set_muted(session, principal.owner_id, item_id, False)
    return ok(await me.build_view(session, principal))


@member_router.post(
    "/test",
    response_model=ApiResponse[PushTestView],
    summary="给我的设备发一条测试通知",
    operation_id="push.me.test",
    openapi_extra=_HIDDEN,
)
async def send_test(principal: Principal = Depends(require_login)) -> ApiResponse[PushTestView]:
    return ok(await me.test(principal))


@member_router.put(
    "/registration",
    response_model=ApiResponse[PushRegistrationView],
    summary="App 登记推送（只接受 App 类设备自己的凭证）",
    operation_id="push.me.registration.set",
    openapi_extra=_HIDDEN,
)
async def register(
    payload: PushRegistrationRequest,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PushRegistrationView]:
    return ok(
        await me.register(
            session,
            principal,
            token=payload.token,
            topic=payload.topic,
            environment=payload.environment,
            types=payload.types,
            key_id=payload.key_id,
            key=payload.key,
            permission=payload.permission,
            client_version=payload.client_version,
        )
    )


@member_router.delete(
    "/registration",
    response_model=ApiResponse[None],
    summary="清掉这台设备的推送登记",
    operation_id="push.me.registration.delete",
    openapi_extra={**_HIDDEN, "x-cli-dangerous": "confirm"},
)
async def unregister(
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[None]:
    await me.unregister(session, principal)
    return ok(None)


# ----------------------------------------------------------------------
# 推送配图（公开，凭签名）
# ----------------------------------------------------------------------


@public_router.get(
    "/{token}",
    response_class=FileResponse,
    summary="推送配图（通知扩展下载，地址自带签名）",
    operation_id="push.images.get",
    openapi_extra=_HIDDEN,
)
async def push_image(token: str) -> FileResponse:
    from movieclaw_api.api.routes.images import sized_file
    from movieclaw_api.services.channel_push import PUSH_IMAGE_WIDTH, local_push_image
    from movieclaw_api.services.image_cache import get_image_cache

    url = await resolve_image(token)
    if url is None:
        raise NotFoundException("图片不存在")
    # 条目图已落本地就用本地母版缩到推送宽度（图床被墙也带得出图），否则回源
    local = await local_push_image(url)
    if local is not None:
        return await sized_file(
            local,
            source_key=f"push:{local}",
            w=PUSH_IMAGE_WIDTH,
            headers={"Cache-Control": "private, max-age=604800"},
        )
    try:
        cached = await get_image_cache().get_or_fetch(url)
    except Exception as exc:  # noqa: BLE001 -- 取不到图对通知扩展来说就是「不带图」
        raise NotFoundException("图片不存在") from exc
    return FileResponse(
        cached.path,
        media_type=cached.content_type,
        headers={"Cache-Control": "private, max-age=604800"},
    )

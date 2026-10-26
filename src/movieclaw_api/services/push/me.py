"""「账号 → 通知」页和 App 登记的后端：每个人只管自己（cloud-push.md §7.3）。"""

from __future__ import annotations

import time

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    ForbiddenException,
    NotFoundException,
)
from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.schemas.cloud import (
    MyPushView,
    PushAttentionView,
    PushEventView,
    PushLibraryView,
    PushMutedItemView,
    PushRegistrationView,
    PushTestResultView,
    PushTestView,
)
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.push import channels as channel_registry
from movieclaw_api.services.push import preferences, registration
from movieclaw_api.services.push.channels import Channel
from movieclaw_api.services.push.notify import alert_devices, send_test
from movieclaw_db.models import LoginDevice

#: 需要本人处理的状态（还没登记的多半是旧版 App，升级后自动登记，不在这里打扰）
ATTENTION_STATUSES = ("unsupported_build", "permission_denied", "no_channel", "bad_token")

#: 测试推送的节流：每人 10 秒一次（防止连点把额度刷光）
_TEST_INTERVAL_S = 10
_last_test: dict[int, float] = {}


def device_status(device: LoginDevice, channels: list[Channel]) -> tuple[str, str, str | None]:
    """一台设备能不能收到：(status, 给人看的说明, 走哪个通道)。"""
    if not device.push_token and device.push_problem == "unsupported_build":
        # 先于权限：安装包本身收不到，叫人去开系统通知也没用
        return (
            "unsupported_build",
            t("auth.devicePush.unsupportedBuild"),
            None,
        )
    if device.push_permission == "denied":
        return "permission_denied", t("auth.devicePush.permissionDenied"), None
    if device.push_stream:
        # 实时通知不经任何通道，服务器自己送（cloud-push.md §4.1）
        return "ok", t("auth.devicePush.ready"), t("auth.devicePush.realtime")
    if not device.push_token or not device.push_topic:
        return "not_registered", t("auth.devicePush.notRegistered"), None
    if device.push_problem == "bad_token":
        return "bad_token", t("auth.devicePush.badToken"), None
    candidates = channel_registry.route(channels, device.push_topic)
    if not candidates:
        return "no_channel", t("auth.devicePush.noChannel"), None
    channel = candidates[0]
    return (
        "ok",
        t("auth.devicePush.ready"),
        (t("push.channels.official") if channel.kind == "official" else channel.name),
    )


async def build_view(session: AsyncSession, principal: Principal) -> MyPushView:
    channels = await channel_registry.load_channels()
    effective = await preferences.effective(session, principal.owner_id)
    events = [
        PushEventView(
            key=e.key,
            title=e.title,
            description=e.description,
            group=e.group,
            group_id=e.group_id,
            enabled=effective[e.key],
            default=e.default,
        )
        for e in preferences.events_for(is_admin=principal.is_admin)
    ]
    rows = await session.execute(
        select(LoginDevice)
        .where(
            LoginDevice.member_id == principal.owner_id,
            LoginDevice.kind.in_(registration.PUSH_KINDS),  # type: ignore[attr-defined]
        )
        .order_by(LoginDevice.id)
    )
    devices = list(rows.scalars())
    ready_tokens = {
        (device.push_token or "").lower()
        for device in await alert_devices(session, devices)
        if device_status(device, channels)[0] == "ok"
        and device.push_key_id
        and registration.decrypt_key(device) is not None
    }
    streams = [d for d in devices if d.push_stream and device_status(d, channels)[0] == "ok"]
    attention: list[PushAttentionView] = []
    for device in devices:
        status, text, _channel = device_status(device, channels)
        if status in ATTENTION_STATUSES:
            attention.append(
                PushAttentionView(
                    device_id=f"ld-{device.id}",
                    device_name=device.name,
                    status=status,
                    status_text=text,
                )
            )
    from movieclaw_api.services.library.access import visible_library_ids
    from movieclaw_api.services.push.arrivals import watchable
    from movieclaw_db.models import Library

    visible = await visible_library_ids(session, principal)
    # 「媒体库有新片」的选项：能看到的、能播放的库（图片库不推），顺序和媒体库页一致
    libraries = [
        PushLibraryView(id=lib.id or 0, name=lib.name, kind=lib.kind)
        for lib in (
            await session.execute(select(Library).order_by(Library.sort_order, Library.id))
        ).scalars()
        if lib.id in visible and watchable(lib)
    ]
    chosen = await preferences.library_selection(session, principal.owner_id)
    from movieclaw_db.models import MediaItem

    muted = []
    for item_id in await preferences.muted_list(session, principal.owner_id):
        item = await session.get(MediaItem, item_id)
        if item is not None:
            muted.append(
                PushMutedItemView(id=item_id, title=item.title, year=item.year, kind=item.kind)
            )
    from movieclaw_api.services.push import im

    return MyPushView(
        muted_items=muted,
        im_accounts=im.count(principal.owner_id),
        instance_ready=any(c.usable for c in channels) or bool(streams),
        is_admin=principal.is_admin,
        events=events,
        ready_devices=len(ready_tokens) + len(streams),
        attention=attention,
        libraries=libraries,
        library_ids=(
            None if chosen is None else [i for i in chosen if i in {lib.id for lib in libraries}]
        ),
    )


async def _current_push_device(session: AsyncSession, principal: Principal) -> LoginDevice:
    """登记只接受 App 类设备自己的凭证。"""
    if principal.device is None:
        raise ForbiddenException(message_key="errors.push.appSignInRequired")
    if principal.device.kind not in registration.PUSH_KINDS:
        raise ForbiddenException(message_key="errors.push.appOnly")
    device = await session.get(LoginDevice, principal.device.id)
    if device is None:
        raise NotFoundException(message_key="errors.push.deviceMissing")
    return device


async def stream_device(session: AsyncSession, principal: Principal) -> LoginDevice:
    """实时通知的长连接和确认只认开了实时通知的 Android 设备自己的凭证。

    网页会话、iOS 本来就没有实时通知：同 ``unregister`` 返回 404。
    """
    if principal.device is None or principal.device.kind not in registration.STREAM_KINDS:
        raise NotFoundException(message_key="errors.push.realtimeUnavailable")
    device = await _current_push_device(session, principal)
    if not device.push_stream:
        raise ConflictException(message_key="errors.push.realtimeNotRegistered")
    return device


async def register(
    session: AsyncSession,
    principal: Principal,
    *,
    token: str | None,
    topic: str | None,
    environment: str | None,
    types: list[str] | None,
    key_id: str | None,
    key: str | None,
    permission: str,
    client_version: str | None = None,
    unsupported_build: bool = False,
    stream: bool | None = None,
) -> PushRegistrationView:
    device = await _current_push_device(session, principal)
    if stream and device.kind not in registration.STREAM_KINDS:
        raise BadRequestException(message_key="errors.push.androidOnly")
    # 版本是登录时记下的，App 升级后不重新登录就一直是旧的；每次启动的登记顺手刷新
    if client_version and client_version.strip():
        device.client_version = client_version.strip()
    reg = registration.validate(
        permission=permission,
        token=token,
        topic=topic,
        environment=environment,
        types=types,
        key_id=key_id,
        key=key,
        unsupported_build=unsupported_build,
        stream=stream,
    )
    device = await registration.save(session, device, reg)
    status, text, channel_name = device_status(device, await channel_registry.load_channels())
    return PushRegistrationView(
        registered=bool(device.push_token) or device.push_stream,
        status=status,
        status_text=text,
        channel_name=channel_name,
    )


async def unregister(session: AsyncSession, principal: Principal) -> None:
    """清掉这台设备的推送登记。不是 App（网页、命令行）本来就没有登记：404。"""
    if principal.device is None or principal.device.kind not in registration.PUSH_KINDS:
        raise NotFoundException(message_key="errors.push.registrationMissing")
    device = await _current_push_device(session, principal)
    await registration.clear(session, device)


async def test(principal: Principal) -> PushTestView:
    owner = principal.owner_id
    now = time.monotonic()
    last = _last_test.get(owner)
    if last is not None and now - last < _TEST_INTERVAL_S:
        raise BadRequestException(message_key="errors.push.testThrottled")
    _last_test[owner] = now
    outcomes = await send_test(owner)
    return PushTestView(
        sent=sum(1 for o in outcomes if o.result in ("ok", "queued")),
        results=[
            PushTestResultView(
                device_id="im" if o.channel_id == "im" else f"ld-{o.device_id}",
                device_name=o.device_name,
                result=o.result,
                message=render_value(o.message_ref or o.message)
                or (t("push.outcome.delivered") if o.result == "ok" else ""),
            )
            for o in outcomes
        ],
    )


def reset_state() -> None:
    """测试用。"""
    _last_test.clear()

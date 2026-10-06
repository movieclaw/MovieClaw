"""「账号 → 通知」页和 App 登记的后端：每个人只管自己（cloud-push.md §7.3）。"""

from __future__ import annotations

import time

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import BadRequestException, ForbiddenException, NotFoundException
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
ATTENTION_STATUSES = ("permission_denied", "no_channel", "bad_token")

#: 测试推送的节流：每人 10 秒一次（防止连点把额度刷光）
_TEST_INTERVAL_S = 10
_last_test: dict[int, float] = {}


def device_status(device: LoginDevice, channels: list[Channel]) -> tuple[str, str, str | None]:
    """一台设备能不能收到：(status, 给人看的说明, 走哪个通道)。"""
    if device.push_permission == "denied":
        return "permission_denied", "系统通知已关闭，在这台设备的设置里打开", None
    if not device.push_token or not device.push_topic:
        return "not_registered", "还没有开启通知，打开最新版 App 后会自动开启", None
    if device.push_problem == "bad_token":
        return "bad_token", "推送令牌无效，重新打开 App 后会自动更新", None
    candidates = channel_registry.route(channels, device.push_topic)
    if not candidates:
        return "no_channel", "没有可用的推送通道", None
    return "ok", "能收到", candidates[0].name


async def build_view(session: AsyncSession, principal: Principal) -> MyPushView:
    channels = await channel_registry.load_channels()
    effective = await preferences.effective(session, principal.owner_id)
    events = [
        PushEventView(
            key=e.key,
            title=e.title,
            description=e.description,
            group=e.group,
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
    return MyPushView(
        muted_items=muted,
        instance_ready=any(c.usable for c in channels),
        is_admin=principal.is_admin,
        events=events,
        ready_devices=len(ready_tokens),
        attention=attention,
        libraries=libraries,
        library_ids=(
            None if chosen is None else [i for i in chosen if i in {lib.id for lib in libraries}]
        ),
    )


async def _current_push_device(session: AsyncSession, principal: Principal) -> LoginDevice:
    """登记只接受 App 类设备自己的凭证。"""
    if principal.device is None:
        raise ForbiddenException("只有 App 能登记推送：请在 MovieClaw App 里登录")
    if principal.device.kind not in registration.PUSH_KINDS:
        raise ForbiddenException("只有 App 能登记推送")
    device = await session.get(LoginDevice, principal.device.id)
    if device is None:
        raise NotFoundException("设备不存在或已被注销")
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
) -> PushRegistrationView:
    device = await _current_push_device(session, principal)
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
    )
    device = await registration.save(session, device, reg)
    status, text, channel_name = device_status(device, await channel_registry.load_channels())
    return PushRegistrationView(
        registered=bool(device.push_token),
        status=status,
        status_text=text,
        channel_name=channel_name,
    )


async def unregister(session: AsyncSession, principal: Principal) -> None:
    """清掉这台设备的推送登记。不是 App（网页、命令行）本来就没有登记：404。"""
    if principal.device is None or principal.device.kind not in registration.PUSH_KINDS:
        raise NotFoundException("这台设备没有推送登记")
    device = await _current_push_device(session, principal)
    await registration.clear(session, device)


async def test(principal: Principal) -> PushTestView:
    owner = principal.owner_id
    now = time.monotonic()
    last = _last_test.get(owner)
    if last is not None and now - last < _TEST_INTERVAL_S:
        raise BadRequestException("刚发过一条测试通知，请稍等几秒再试")
    _last_test[owner] = now
    outcomes = await send_test(owner)
    return PushTestView(
        sent=sum(1 for o in outcomes if o.result in ("ok", "queued")),
        results=[
            PushTestResultView(
                device_id=f"ld-{o.device_id}",
                device_name=o.device_name,
                result=o.result,
                message=o.message or ("已送达苹果推送服务" if o.result == "ok" else ""),
            )
            for o in outcomes
        ],
    )


def reset_state() -> None:
    """测试用。"""
    _last_test.clear()

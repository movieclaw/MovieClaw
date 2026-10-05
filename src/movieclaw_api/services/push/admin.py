"""「设置 → App 推送」页的后端：通道列表、设备覆盖、自建中继的增删改（cloud-push.md §7.2）。"""

from __future__ import annotations

import time
from collections import defaultdict
from datetime import UTC, datetime
from urllib.parse import urlsplit

from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.cloud import (
    PushChannelsView,
    PushChannelView,
    PushQuotaView,
    RelayProbeView,
    UncoveredAppView,
)
from movieclaw_api.services.push import channels as channel_registry
from movieclaw_api.services.push import registration, relay
from movieclaw_api.services.push.channels import OFFICIAL_ID, OFFICIAL_TOPIC, Channel
from movieclaw_api.services.push.relay import RelayError
from movieclaw_api.settings import PushChannelsSetting, get_setting_store
from movieclaw_api.settings.cloud import PushRelay, RelayInfo
from movieclaw_db.engine import get_database
from movieclaw_db.models import utcnow

_AUTH_LABELS = {"issuer": "签发方令牌", "static": "令牌", "none": "无鉴权"}


def _quota_view(channel: Channel, cloud_limits: dict[str, int]) -> PushQuotaView | None:
    quota = channel_registry.runtime(channel.id).quota
    day = quota.get("day") if isinstance(quota, dict) else None
    reset_at = day.get("reset_at") if isinstance(day, dict) else None
    if isinstance(reset_at, int) and reset_at <= time.time():
        day = None  # 过了重置时间的读数是昨天的，不能还显示「已用完」
    if isinstance(day, dict):
        return PushQuotaView(
            limit=day.get("limit") if isinstance(day.get("limit"), int) else None,
            used=day.get("used") if isinstance(day.get("used"), int) else None,
            remaining=day.get("remaining") if isinstance(day.get("remaining"), int) else None,
            reset_at=(
                datetime.fromtimestamp(reset_at, UTC).replace(tzinfo=None)
                if isinstance(reset_at, int)
                else None
            ),
        )
    if channel.kind == "official" and isinstance(cloud_limits.get("day"), int):
        # 还没推送过：先显示云端给的每日限额
        return PushQuotaView(limit=cloud_limits["day"], used=None, remaining=None, reset_at=None)
    return None


async def build_channels_view() -> PushChannelsView:
    from movieclaw_api.services.cloud import get_cloud_service

    service = get_cloud_service()
    cloud = await service.load()
    cloud_state = (
        "connected" if cloud.connected else ("pairing" if service.pairing else "disconnected")
    )
    channels = await channel_registry.load_channels()

    async with get_database().session() as session:
        devices = await registration.registered_devices(session)

    # 每台设备走哪个通道只汇总成数字；没有通道的 App 版本单独列出来（设备明细在「设备」页）
    by_topic: dict[str, int] = defaultdict(int)
    for device in devices:
        by_topic[device.push_topic or ""] += 1
    device_count: dict[str, int] = defaultdict(int)
    uncovered: list[UncoveredAppView] = []
    for topic in sorted(by_topic, key=lambda t: (t != OFFICIAL_TOPIC, t)):
        candidates = channel_registry.route(channels, topic)
        if candidates:
            device_count[candidates[0].id] += by_topic[topic]
        else:
            uncovered.append(UncoveredAppView(topic=topic, device_count=by_topic[topic]))

    health, health_message = service.health(cloud) if cloud.connected else (None, None)
    views = []
    for channel in channels:
        state, text = _channel_state(channel, cloud_state, health, health_message)
        rt = channel_registry.runtime(channel.id)
        views.append(
            PushChannelView(
                id=channel.id,
                kind=channel.kind,
                name=channel.name,
                enabled=channel.enabled,
                state=state,
                status_text=text,
                url=channel.urls[0] if channel.urls else None,
                auth_mode=channel.info.auth_mode if channel.info else None,
                token_hint=channel.token_hint,
                software=channel.info.software if channel.info else None,
                topics=channel.topics,
                quota=_quota_view(channel, cloud.limits),
                last_success_at=rt.last_success_at,
                last_error=rt.last_error,
                device_count=device_count.get(channel.id, 0),
            )
        )
    return PushChannelsView(cloud_state=cloud_state, channels=views, uncovered=uncovered)


def _channel_state(
    channel: Channel, cloud_state: str, health: str | None, health_message: str | None
) -> tuple[str, str]:
    """通道的状态灯和一句话说明。"""
    rt = channel_registry.runtime(channel.id)
    if not channel.enabled:
        return "inactive", "已停用"
    if channel.kind == "official" and cloud_state != "connected":
        return "inactive", channel.problem or "未连接 MovieClaw Cloud"
    if channel.problem:
        return "error", channel.problem
    if rt.blocked():
        return "warning", rt.blocked_message or "今天的推送额度已经用完"
    if rt.consecutive_failures:
        return "error", f"最近一次推送失败：{rt.last_error}"
    if channel.kind == "official" and health == "unreachable":
        return "warning", health_message or "暂时连不上 MovieClaw Cloud"
    return "ok", "正常"


# ----------------------------------------------------------------------
# 官方通道开关
# ----------------------------------------------------------------------


async def set_official_enabled(enabled: bool) -> None:
    store = get_setting_store()
    config = (await store.get(PushChannelsSetting)).model_copy(deep=True)
    config.official_enabled = enabled
    await store.set(config)
    if enabled:
        await channel_registry.refresh_official_info()


# ----------------------------------------------------------------------
# 自建中继
# ----------------------------------------------------------------------


def _warnings(url: str, info: RelayInfo, matched: int) -> list[str]:
    lan = relay.is_lan_url(url)
    notes = []
    if urlsplit(url).scheme == "http" and not lan:
        notes.append("地址是 http:// 而且不在局域网：令牌会明文经过公网，建议在中继前面加 HTTPS")
    if info.auth_mode == "none" and not lan:
        notes.append("这个中继不要令牌、又在公网上：知道地址的人都能用它往你的 App 推送")
    if matched == 0:
        apps = "、".join(info.topics) or "（没有声明）"
        notes.append(f"目前没有设备会用到这个中继，它能推送的 App：{apps}")
    return notes


def _incompatibility(info: RelayInfo) -> str | None:
    if info.protocol != channel_registry.SUPPORTED_PROTOCOL:
        supported = channel_registry.SUPPORTED_PROTOCOL
        return f"中继的协议版本是 {info.protocol}，这个版本只支持 {supported}"
    if info.auth_mode == "issuer":
        return "这个中继要签发方的令牌，这里还不能添加"
    return None


async def _matched_devices(topics: list[str]) -> int:
    async with get_database().session() as session:
        devices = await registration.registered_devices(session)
    return sum(1 for d in devices if d.push_topic in topics)


async def probe(url: str) -> RelayProbeView:
    """检测一个中继：读 /v1/info，给出它能推什么、用什么鉴权，以及要注意的地方。"""
    try:
        normalized = relay.normalize_url(url)
    except ValueError as exc:
        return RelayProbeView(
            url=url.strip(),
            reachable=False,
            error=str(exc),
            software=None,
            protocol=None,
            auth_mode=None,
            topics=[],
            types=[],
            matched_devices=0,
            warnings=[],
        )
    try:
        info = await relay.fetch_info(normalized)
    except RelayError as exc:
        return RelayProbeView(
            url=normalized,
            reachable=False,
            error=exc.message,
            software=None,
            protocol=None,
            auth_mode=None,
            topics=[],
            types=[],
            matched_devices=0,
            warnings=[],
        )
    matched = await _matched_devices(info.topics)
    return RelayProbeView(
        url=normalized,
        reachable=True,
        error=_incompatibility(info),
        software=info.software or None,
        protocol=info.protocol,
        auth_mode=info.auth_mode or None,
        topics=info.topics,
        types=info.types,
        matched_devices=matched,
        warnings=_warnings(normalized, info, matched),
    )


async def _checked_info(url: str, token: str) -> RelayInfo:
    """添加 / 改地址时再检测一次：能连上、协议兼容、需要令牌时令牌对。"""
    try:
        info = await relay.fetch_info(url)
    except RelayError as exc:
        raise BadRequestException(exc.message) from exc
    if problem := _incompatibility(info):
        raise BadRequestException(problem)
    if channel_registry.needs_token(info.auth_mode):
        if not token:
            raise BadRequestException(
                "这个中继需要令牌：在中继上运行 movieclaw-push token create --name 名称 创建"
            )
        if not await _token_accepted(url, token):
            raise BadRequestException("中继不认这个令牌，请检查是否复制完整、是否已被吊销")
    return info


async def _token_accepted(url: str, token: str) -> bool:
    """用一个空批次试探令牌：中继先验凭证再看请求体，401 就是令牌不对，别的都算通过。"""
    try:
        await relay.push(url, [], bearer=token)
    except RelayError as exc:
        return exc.code != "unauthorized"
    return True


async def create_relay(*, name: str, url: str, token: str | None) -> None:
    try:
        normalized = relay.normalize_url(url)
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    store = get_setting_store()
    config = (await store.get(PushChannelsSetting)).model_copy(deep=True)
    if any(r.url == normalized for r in config.relays):
        raise BadRequestException("这个中继已经添加过了")
    token = (token or "").strip()
    info = await _checked_info(normalized, token)
    config.relays.append(
        PushRelay(
            id=channel_registry.new_relay_id(),
            name=name.strip() or (urlsplit(normalized).hostname or normalized),
            url=normalized,
            token=token if info.auth_mode != "none" else "",
            enabled=True,
            info=info,
            created_at=utcnow(),
        )
    )
    await store.set(config)


async def update_relay(
    relay_id: str,
    *,
    name: str | None,
    url: str | None,
    token: str | None,
    enabled: bool | None,
) -> None:
    store = get_setting_store()
    config = (await store.get(PushChannelsSetting)).model_copy(deep=True)
    target = next((r for r in config.relays if r.id == relay_id), None)
    if target is None:
        raise NotFoundException("中继不存在")
    new_token = (token or "").strip() or target.token
    new_url = target.url
    if url is not None and url.strip():
        try:
            new_url = relay.normalize_url(url)
        except ValueError as exc:
            raise BadRequestException(str(exc)) from exc
        if any(r.url == new_url and r.id != relay_id for r in config.relays):
            raise BadRequestException("这个地址已经被另一个中继用了")
    if new_url != target.url or (token or "").strip():
        info = await _checked_info(new_url, new_token)
        target.info = info
        target.url = new_url
        target.token = new_token if info.auth_mode != "none" else ""
        channel_registry.runtime(relay_id).consecutive_failures = 0
    if name is not None:
        target.name = name.strip() or (urlsplit(target.url).hostname or target.url)
    if enabled is not None:
        target.enabled = enabled
    await store.set(config)


async def delete_relay(relay_id: str) -> None:
    store = get_setting_store()
    config = (await store.get(PushChannelsSetting)).model_copy(deep=True)
    remaining = [r for r in config.relays if r.id != relay_id]
    if len(remaining) == len(config.relays):
        raise NotFoundException("中继不存在")
    config.relays = remaining
    await store.set(config)


async def refresh_relay(relay_id: str) -> None:
    if relay_id == OFFICIAL_ID:
        await channel_registry.refresh_official_info()
        return
    try:
        await channel_registry.refresh_relay_info(relay_id)
    except KeyError as exc:
        raise NotFoundException("中继不存在") from exc
    except RelayError as exc:
        raise BadRequestException(exc.message) from exc
    channel_registry.runtime(relay_id).consecutive_failures = 0

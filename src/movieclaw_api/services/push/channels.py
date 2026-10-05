"""推送通道：官方中继 + 管理员加的自建中继（docs/design/cloud-push.md §3）。

- **每个通道一个启用开关**。官方通道的地址和凭证来自 MovieClaw Cloud，连接之后默认启用；
  未连接时显示为「未激活」。
- **按设备的 Bundle ID 自动选通道**：可用通道里按「官方在前、自建按列表顺序」取第一个
  ``topics`` 包含它的；整批失败时分发器换下一个。
- **能力快照落库**：每个通道的 ``GET /v1/info`` 定期刷新并存进配置域，重启时不用等它
  就能路由。官方通道没拉到过时按 ``io.movieclaw.app`` 处理。
- **运行期状态只在内存里**：最近一次成功、最近的错误、当日额度、限额解除时间——重启
  清零无妨，下一次推送就有了。上报给云端的官方中继连通情况例外：续签前例行检查一次，
  结果存进 ``CloudSetting.relay_check``（见 ``check_official``）。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from movieclaw_api.services.push import relay
from movieclaw_api.services.push.relay import RelayError
from movieclaw_api.settings import get_setting_store
from movieclaw_api.settings.cloud import (
    CloudSetting,
    OfficialRelayCheck,
    PushChannelsSetting,
    PushRelay,
    RelayInfo,
)
from movieclaw_db.models import utcnow

logger = logging.getLogger("movieclaw_api.push.channels")

OFFICIAL_ID = "official"
OFFICIAL_NAME = "MovieClaw 官方推送"
#: 官方 App 的 Bundle ID：官方通道没拉到过 /v1/info 时按它路由，设备覆盖里据此认出官方版
OFFICIAL_TOPIC = "io.movieclaw.app"
#: 实例能用的中继协议主版本
SUPPORTED_PROTOCOL = 1
#: /v1/info 多久刷新一次
INFO_TTL = timedelta(hours=6)


@dataclass
class ChannelRuntime:
    """一个通道的运行期状态（只在内存里）。"""

    last_success_at: datetime | None = None
    last_error: str | None = None
    last_error_at: datetime | None = None
    consecutive_failures: int = 0
    #: 最近一次失败是连不上（网络错误）。中继回了 401、503 这类 HTTP 错误不算——
    #: 上报给云端时据此区分「中继出了问题」和「这台服务器出不了网」
    unreachable: bool = False
    quota: dict | None = None
    blocked_until: datetime | None = None
    blocked_message: str | None = None
    #: 单台设备触发的限额（如 ``device_day``）：设备令牌 → (解除时间, 说明)。只挡这台
    #: 设备，不能因为一台手机超限就停掉整个通道；中继按令牌计数，这里也按令牌记
    device_blocks: dict[str, tuple[datetime, str]] = field(default_factory=dict)

    def record_success(self, quota: dict | None) -> None:
        self.last_success_at = utcnow()
        self.consecutive_failures = 0
        self.last_error = None
        self.unreachable = False
        # 不带 quota（不限额、none 模式）就清掉旧读数，免得一直显示过时的额度
        self.quota = quota

    def record_failure(self, message: str, *, unreachable: bool = False) -> None:
        self.consecutive_failures += 1
        self.last_error = message
        self.last_error_at = utcnow()
        self.unreachable = unreachable

    def blocked(self) -> bool:
        return self.blocked_until is not None and self.blocked_until > utcnow()

    def device_block(self, token: str) -> str | None:
        """这台设备在这个通道上还在限额里：返回说明；没有返回 None。"""
        entry = self.device_blocks.get(token)
        if entry is None:
            return None
        if entry[0] <= utcnow():
            del self.device_blocks[token]
            return None
        return entry[1]

    def clear_blocks(self) -> None:
        """限额可能变了（云端调了额度、重新连接）：解除封锁，下一条推送以中继的答复为准。"""
        self.blocked_until = None
        self.blocked_message = None
        self.device_blocks.clear()


_runtime: dict[str, ChannelRuntime] = {}


def runtime(channel_id: str) -> ChannelRuntime:
    return _runtime.setdefault(channel_id, ChannelRuntime())


def reset_runtime(channel_id: str | None = None) -> None:
    """清掉运行期状态。给通道 id 只清它（断开、重新连接 MovieClaw Cloud 时）；
    不给就清全部（测试用）。"""
    if channel_id is None:
        _runtime.clear()
    else:
        _runtime.pop(channel_id, None)


@dataclass
class Channel:
    """一个推送通道此刻的样子（每次推送前现算，配置随改随生效）。"""

    id: str
    kind: str  # official / custom
    name: str
    enabled: bool
    urls: list[str]
    bearer: str | None
    info: RelayInfo | None
    lan_direct: bool
    #: 能不能发：不能发时 ``problem`` 说明原因（给设置页）
    usable: bool
    problem: str | None = None
    #: 打码后的自建中继令牌
    token_hint: str | None = None
    extra: dict = field(default_factory=dict)

    @property
    def topics(self) -> list[str]:
        if self.info and self.info.topics:
            return list(self.info.topics)
        return [OFFICIAL_TOPIC] if self.kind == "official" else []

    def supports(self, topic: str, push_type: str = "alert") -> bool:
        if topic not in self.topics:
            return False
        return not (self.info and self.info.types and push_type not in self.info.types)

    @property
    def max_batch(self) -> int:
        return max(1, min(100, self.info.max_batch if self.info else 100))


def mask_token(token: str) -> str | None:
    """自建中继令牌打码：保留前缀和前 4 位（``mcpush_a1b2…``）。"""
    if not token:
        return None
    head = token.split("_", 2)
    if len(head) == 3 and head[0] == "mcpush":
        return f"mcpush_{head[1][:4]}…"
    return token[:4] + "…"


def needs_token(auth_mode: str) -> bool:
    """自建中继要不要填令牌：``static`` 和不认识的方式都要（照样带上配置的令牌，中继
    协议第 3 节）；``none`` 不要；``issuer`` 这里加不了；没声明的不强求。"""
    return auth_mode not in ("none", "issuer", "")


def _custom_problem(r: PushRelay) -> str | None:
    if r.info is None:
        return "还没连上过这个中继"
    if r.info.protocol != SUPPORTED_PROTOCOL:
        return f"中继的协议版本是 {r.info.protocol}，这个版本只支持 {SUPPORTED_PROTOCOL}"
    if r.info.auth_mode == "issuer":
        return "这个中继要签发方的令牌，这里还不能用"
    if needs_token(r.info.auth_mode) and not r.token:
        return "缺少中继令牌"
    return None


async def load_channels() -> list[Channel]:
    """官方通道 + 自建中继（按列表顺序）。"""
    from movieclaw_api.services.cloud import get_cloud_service

    store = get_setting_store()
    cloud = await store.get(CloudSetting)
    config = await store.get(PushChannelsSetting)
    service = get_cloud_service()

    bearer = service.official_bearer(cloud)
    endpoints = service.push_endpoints(cloud)
    # 官方中继声明不要凭证（运营方停运时的退路，协议第 3 节）：不带令牌直接推，
    # 云端连不上、令牌过期、版本检查都不再挡着
    open_relay = bool(config.official_info and config.official_info.auth_mode == "none")
    if not cloud.connected:
        problem = "正在连接 MovieClaw Cloud" if service.pairing else "未连接 MovieClaw Cloud"
    elif open_relay:
        problem = None if endpoints else "MovieClaw Cloud 没有给出推送中继地址"
    elif cloud.unsupported_message:
        problem = cloud.unsupported_message
    elif "push" not in cloud.scopes:
        problem = "MovieClaw Cloud 没有授予推送权限"
    elif bearer is None:
        problem = "令牌已过期：连不上 MovieClaw Cloud，官方推送暂停"
    elif not endpoints:
        problem = "MovieClaw Cloud 没有给出推送中继地址"
    else:
        problem = None
    official = Channel(
        id=OFFICIAL_ID,
        kind="official",
        name=OFFICIAL_NAME,
        enabled=config.official_enabled,
        urls=endpoints,
        bearer=None if open_relay else bearer,
        info=config.official_info,
        lan_direct=False,
        usable=config.official_enabled and problem is None,
        problem=problem,
    )
    channels = [official]
    for r in config.relays:
        problem = _custom_problem(r)
        channels.append(
            Channel(
                id=r.id,
                kind="custom",
                name=r.name or r.url,
                enabled=r.enabled,
                urls=[r.url],
                bearer=r.token or None if (r.info and r.info.auth_mode != "none") else None,
                info=r.info,
                lan_direct=True,
                usable=r.enabled and problem is None,
                problem=problem,
                token_hint=mask_token(r.token),
            )
        )
    return channels


def route(channels: list[Channel], topic: str, push_type: str = "alert") -> list[Channel]:
    """能推这个 Bundle ID 的可用通道，按优先顺序。"""
    return [c for c in channels if c.usable and c.supports(topic, push_type)]


async def check_official(cloud: CloudSetting) -> OfficialRelayCheck | None:
    """续签前的例行检查：带上令牌调一次官方中继的 ``GET /v1/info``（推送中继协议 §4.1）。

    - 官方中继据此记下「这台服务器最近一次连接」，没有推送的时候官网也知道它在线；
    - 收到任何答复（包括 401、503）都算连得通，只有网络错误算连不上：云端靠它区分
      「中继出了问题」和「这台服务器出不了网」；
    - 顺带刷新能力快照和当日额度。

    返回要存进 ``CloudSetting.relay_check`` 的结果；没连接、官方通道停用、没有地址时
    返回 None（不检查，也不上报）。
    """
    from movieclaw_api.services.cloud import get_cloud_service

    store = get_setting_store()
    config = await store.get(PushChannelsSetting)
    service = get_cloud_service()
    urls = service.push_endpoints(cloud)
    if not cloud.connected or not config.official_enabled or not urls:
        return None
    bearer = service.official_bearer(cloud)
    now = utcnow()
    error: RelayError | None = None
    for url in urls:
        try:
            info, quota = await relay.check_info(url, bearer=bearer, lan_direct=False)
        except RelayError as exc:
            if not exc.network:  # 收到了答复，只是不对：连得通
                error = None
                break
            error = exc
            continue
        error = None
        fresh = config.model_copy(deep=True)
        fresh.official_info = info
        await store.set(fresh)
        if quota is not None:
            runtime(OFFICIAL_ID).quota = quota
        break

    previous = cloud.relay_check
    state = _runtime.get(OFFICIAL_ID)
    successes = [
        t
        for t in (previous and previous.last_success_at, state and state.last_success_at)
        if t is not None
    ]
    check = OfficialRelayCheck(
        reachable=error is None, checked_at=now, last_success_at=max(successes, default=None)
    )
    if error is not None:
        check.error = error.message
        if previous is not None and not previous.reachable and previous.failing_since:
            check.failing_since = previous.failing_since
        elif state is not None and state.unreachable and state.last_error_at:
            check.failing_since = state.last_error_at  # 推送时就已经连不上了
        else:
            check.failing_since = now
        logger.warning("例行检查：连不上官方推送中继（%s）", error.message)
    return check


def relay_report(check: OfficialRelayCheck | None) -> dict | None:
    """把例行检查的结果写成上报里的 ``relay``（云端协议 §6.1）。"""
    if check is None or check.checked_at is None:
        return None

    def iso(t: datetime) -> str:
        return t.replace(microsecond=0).isoformat() + "Z"

    report: dict = {"reachable": check.reachable, "checked_at": iso(check.checked_at)}
    if check.last_success_at is not None:
        report["last_success_at"] = iso(check.last_success_at)
    if not check.reachable:
        report["error"] = check.error
        if check.failing_since is not None:
            report["failing_since"] = iso(check.failing_since)
    return report


# ----------------------------------------------------------------------
# /v1/info 快照
# ----------------------------------------------------------------------


async def _fetch_first(urls: list[str], *, lan_direct: bool) -> RelayInfo:
    error: RelayError | None = None
    for url in urls:
        try:
            return await relay.fetch_info(url, lan_direct=lan_direct)
        except RelayError as exc:
            error = exc
    raise error or RelayError("没有可用的中继地址", retryable=False)


async def refresh_official_info() -> RelayInfo | None:
    """拉官方中继的 /v1/info 存进快照；失败保留旧的。"""
    from movieclaw_api.services.cloud import get_cloud_service

    store = get_setting_store()
    cloud = await store.get(CloudSetting)
    urls = get_cloud_service().push_endpoints(cloud)
    if not cloud.connected or not urls:
        return None
    try:
        info = await _fetch_first(urls, lan_direct=False)
    except RelayError as exc:
        logger.warning("读取官方推送中继的能力失败：%s", exc.message)
        return None
    config = (await store.get(PushChannelsSetting)).model_copy(deep=True)
    config.official_info = info
    await store.set(config)
    return info


async def refresh_relay_info(relay_id: str) -> RelayInfo:
    """重新拉自建中继的 /v1/info；失败抛 RelayError（设置页显示原因）。"""
    store = get_setting_store()
    config = (await store.get(PushChannelsSetting)).model_copy(deep=True)
    target = next((r for r in config.relays if r.id == relay_id), None)
    if target is None:
        raise KeyError(relay_id)
    try:
        info = await relay.fetch_info(target.url)
    except RelayError as exc:
        runtime(relay_id).record_failure(exc.message)
        raise
    target.info = info
    await store.set(config)
    return info


async def refresh_stale_infos() -> None:
    """把超过 6 小时（或从没拉到过）的快照刷新一遍。出错只记日志。"""
    store = get_setting_store()
    config = await store.get(PushChannelsSetting)
    cloud = await store.get(CloudSetting)
    now = utcnow()

    def stale(info: RelayInfo | None) -> bool:
        return info is None or info.fetched_at is None or now - info.fetched_at > INFO_TTL

    if cloud.connected and config.official_enabled and stale(config.official_info):
        await refresh_official_info()
    for r in list(config.relays):
        if r.enabled and stale(r.info):
            with contextlib.suppress(RelayError, KeyError):
                await refresh_relay_info(r.id)


def new_relay_id() -> str:
    return "r_" + secrets.token_hex(6)


_refresh_task: asyncio.Task[None] | None = None


async def _refresh_loop() -> None:
    await asyncio.sleep(20)
    while True:
        try:
            await refresh_stale_infos()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 -- 刷新失败下一轮再来
            logger.exception("刷新推送中继能力时出错")
        await asyncio.sleep(1800)


def start_refresh_loop() -> None:
    """应用启动后起一个后台循环：每半小时检查一次快照是否过期。"""
    global _refresh_task
    if _refresh_task is None or _refresh_task.done():
        _refresh_task = asyncio.get_running_loop().create_task(_refresh_loop())


async def stop_refresh_loop() -> None:
    global _refresh_task
    task, _refresh_task = _refresh_task, None
    if task is not None and not task.done():
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await task

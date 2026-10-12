"""Webhook 投递（docs/design/domain-events.md §6.2）：每个地址是事件总线上的一个订阅方。

- **可靠订阅**：每个启用的地址一个可靠消费者（``webhook.delivery:<地址 id>``），订阅它勾选的事件，
  按产生顺序投递；失败抛错交给可靠事件的重试（退避到半小时）与死信，可在插件页重放；
- **实时订阅**：高频事件（播放进度）走实时，失败不重试；
- 报文就是事件信封（id、type、occurred_at、origin、data）加 ``server``，HMAC-SHA256 签名；
- 每次投递读当前配置（地址、密钥、模板），改了密钥不用重新订阅；勾选的事件变了才 ``sync``。

出站走 ``movieclaw_net.egress_transport``（服务标签 ``webhook``），关闭熔断：熔断器按服务标签
全进程共享，一个宕机的地址会把熔断打开、拖垮其他健康地址；重试由可靠事件负责、有界。
"""

from __future__ import annotations

import hashlib
import hmac
import inspect
import json
import logging
import time
from datetime import UTC, datetime
from typing import Any

import httpx

from movieclaw_api.services.webhook.catalog import event_types, normalize
from movieclaw_api.services.webhook.deliveries import DeliveryRecord, record_delivery
from movieclaw_api.settings import WebhookEndpoint, WebhookSetting, get_setting_store
from movieclaw_kernel import DeliveryInfo, current_delivery
from movieclaw_net import EgressScope, egress_transport

logger = logging.getLogger("movieclaw_api.webhook")

REQUEST_TIMEOUT = 10.0
#: 可靠消费者的条目 id：消费者 id = ``webhook.delivery:<地址 id>``
ENTRY_ID = "webhook.delivery"


class DeliveryFailed(RuntimeError):
    """目标没收下（网络错误、非 2xx）：交给可靠事件重试。"""

    #: 预料之中的失败：可靠事件只记一行日志，不打堆栈（投递记录里已有原因）
    quiet = True


async def server_info() -> dict:
    """服务器上下文：实例 ID/名称/地址复用 Jellyfin 兼容层身份，版本取应用版本，
    用户名取管理员账号（Jellyfin 变量字典的 NotificationUsername）。"""
    from movieclaw_api import __version__
    from movieclaw_api.settings import AdminAccountSetting
    from movieclaw_api.settings.schemas import get_jellyfin_compat

    compat = await get_jellyfin_compat()
    admin = await get_setting_store().get(AdminAccountSetting)
    return {
        "id": compat.server_id,
        "name": compat.server_name,
        "version": __version__,
        "url": compat.published_server_url,
        "username": admin.username,
    }


def envelope(info: DeliveryInfo, version: str, data: dict, server: dict) -> dict:
    """报文：事件信封 + ``server``（id / name / version）。"""
    return {
        "id": info.event_id,
        "type": info.name,
        "version": version,
        "occurred_at": info.occurred_at,
        "origin": {"kind": info.origin.kind, "id": info.origin.id},
        "server": {k: server.get(k, "") for k in ("id", "name", "version")},
        "data": data,
    }


def sign(body: bytes, secret: str) -> str:
    return "sha256=" + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()


def movieclaw_request(message: dict, secret: str, user_agent: str) -> tuple[bytes, dict]:
    body = json.dumps(message, ensure_ascii=False).encode("utf-8")
    headers = {
        "Content-Type": "application/json; charset=utf-8",
        "User-Agent": user_agent,
        "X-MovieClaw-Event": message["type"],
        "X-MovieClaw-Event-Id": message["id"],
    }
    if secret:
        headers["X-MovieClaw-Signature"] = sign(body, secret)
    return body, headers


async def post(endpoint: WebhookEndpoint, body: bytes, headers: dict) -> tuple[int | None, str]:
    """发一次；返回 (状态码, 错误)。"""
    if endpoint.headers:
        headers = {**headers, **endpoint.headers}
    scope = EgressScope.LAN if endpoint.egress_scope == "lan" else EgressScope.WAN
    try:
        transport = egress_transport("webhook", scope=scope, use_breaker=False)
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT, transport=transport) as client:
            response = await client.post(endpoint.url, content=body, headers=headers)
    except Exception as exc:  # noqa: BLE001 -- 网络错误统一进投递记录
        return None, f"请求失败：{exc}"[:200]
    if 200 <= response.status_code < 300:
        return response.status_code, ""
    return response.status_code, f"目标返回 HTTP {response.status_code}"


async def deliver(endpoint: WebhookEndpoint, info: DeliveryInfo, payload: Any) -> DeliveryRecord:
    """把一个事件投给一个地址（一次尝试），写投递记录。"""
    from movieclaw_api.services.webhook import jellyfin_formatter

    started = time.monotonic()
    record = DeliveryRecord(event_id=info.event_id, event=info.name, attempts=info.attempt)
    event = event_types().get(info.name)
    data = payload.model_dump(mode="json") if hasattr(payload, "model_dump") else dict(payload)
    server = await server_info()
    try:
        if endpoint.format == "jellyfin":
            if not endpoint.template.strip():
                record.error = "jellyfin 格式的地址没有配置模板（请粘贴下游文档提供的模板）"
                record_delivery(endpoint.id, record)
                return record
            requests = await jellyfin_formatter.render(info, data, server, endpoint.template)
            if not requests:
                return record  # 这个事件没有 Jellyfin 对应物：不投
        else:
            message = envelope(info, str(event.version) if event else "1.0", data, server)
            agent = f"MovieClaw/{server.get('version', '')}"
            requests = [movieclaw_request(message, endpoint.secret, agent)]
    except ValueError as exc:
        record.error = f"模板渲染失败：{exc}"
        record_delivery(endpoint.id, record)
        logger.warning("Webhook 模板渲染失败：%s → %s（%s）", info.name, endpoint.name, exc)
        return record
    # Jellyfin 格式的「整季标记已看」按集各发一条（同插件）；任何一条没收下就整体重试
    for body, headers in requests:
        record.status_code, record.error = await post(endpoint, body, headers)
        if not record.ok:
            break
    record.failed = not record.ok
    record.duration_ms = int((time.monotonic() - started) * 1000)
    record.at = datetime.now(UTC)
    record_delivery(endpoint.id, record)
    if record.ok:
        logger.info(
            "Webhook 已投递：%s → %s（HTTP %s，第 %d 次）",
            info.name,
            endpoint.name or endpoint.url,
            record.status_code,
            record.attempts,
        )
    else:
        target = endpoint.name or endpoint.url
        logger.warning("Webhook 投递失败：%s → %s（%s）", info.name, target, record.error)
    return record


async def _endpoint(endpoint_id: str) -> WebhookEndpoint | None:
    setting = await get_setting_store().get(WebhookSetting)
    if not setting.enabled:
        return None
    for endpoint in setting.endpoints:
        if endpoint.id == endpoint_id and endpoint.enabled and endpoint.url:
            return endpoint
    return None


async def deliver_test(endpoint: WebhookEndpoint) -> DeliveryRecord:
    """设置页「发送测试」：同步投一条示例事件（一次尝试，立刻反馈）。"""
    from movieclaw_events import new_ulid
    from movieclaw_kernel import Origin
    from movieclaw_sdk.events import ClientRef, MediaRef, PlaybackStopped, UnitRef

    info = DeliveryInfo(
        event_id=new_ulid(),
        name="webhook.test",
        occurred_at=datetime.now(UTC).isoformat(),
        origin=Origin(kind="admin", id="0"),
    )
    sample = PlaybackStopped(
        member_id=0,
        media=MediaRef(id=0, kind="tv", title="示例剧集", original_title="Sample Show", year=2011),
        unit=UnitRef(season=2, episode=4),
        position_ms=3_120_000,
        duration_ms=3_300_000,
        played=True,
        play_count=1,
        client=ClientRef(name="MovieClaw 设置页"),
        completed=True,
    )
    return await deliver(endpoint, info, sample)


class Subscriptions:
    """按 Webhook 配置维护各地址的订阅：配置改了（勾选的事件、开关）就 ``sync``。"""

    def __init__(self, ctx: Any, store: Any) -> None:
        self._ctx = ctx
        self._store = store
        #: 地址 id → (可靠订阅的事件名, 实时订阅的事件名, 取消订阅们)
        self._active: dict[str, tuple[tuple[str, ...], tuple[str, ...], list[Any]]] = {}

    async def sync(self) -> None:
        setting = await get_setting_store().get(WebhookSetting)
        catalog = event_types()
        desired: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {}
        if setting.enabled:
            for endpoint in setting.endpoints:
                if not endpoint.enabled or not endpoint.url:
                    continue
                names = normalize(endpoint.events)
                durable = tuple(sorted(n for n in names if catalog[n].durable))
                live = tuple(sorted(n for n in names if not catalog[n].durable))
                if durable or live:
                    desired[endpoint.id] = (durable, live)
        for endpoint_id in list(self._active):
            current = self._active[endpoint_id]
            wanted = desired.get(endpoint_id)
            if wanted != current[:2]:
                # 不再订阅任何可靠事件了：消费者行一并删
                await self._off(endpoint_id, forget=not (wanted and wanted[0]))
        for endpoint_id, (durable, live) in desired.items():
            if endpoint_id not in self._active:
                self._on(endpoint_id, durable, live, catalog)

    def _on(
        self,
        endpoint_id: str,
        durable: tuple[str, ...],
        live: tuple[str, ...],
        catalog: dict[str, Any],
    ) -> None:
        offs: list[Any] = []
        if durable:
            offs.append(
                self._store.subscribe(
                    tuple(catalog[n] for n in durable),
                    entry_id=ENTRY_ID,
                    listener_id=endpoint_id,
                    handler=self._durable(endpoint_id),
                )
            )
        for name in live:
            offs.append(
                self._ctx.on(catalog[name], self._live(endpoint_id), id=f"{endpoint_id}:{name}")
            )
        self._active[endpoint_id] = (durable, live, offs)

    async def _off(self, endpoint_id: str, *, forget: bool) -> None:
        _, _, offs = self._active.pop(endpoint_id)
        for off in offs:
            result = off()
            if inspect.isawaitable(result):
                await result
        if forget:
            # 地址删了 / 不再订阅任何可靠事件：消费者行一并删，免得业务侧还为它写事件
            await self._store.forget(f"{ENTRY_ID}:{endpoint_id}")

    async def close(self) -> None:
        for endpoint_id in list(self._active):
            await self._off(endpoint_id, forget=False)

    @staticmethod
    def _durable(endpoint_id: str):  # type: ignore[no-untyped-def]
        async def handle(payload: Any) -> None:
            info = current_delivery.get()
            endpoint = await _endpoint(endpoint_id)
            if info is None or endpoint is None:
                return
            record = await deliver(endpoint, info, payload)
            if record.failed:
                raise DeliveryFailed(record.error)

        return handle

    @staticmethod
    def _live(endpoint_id: str):  # type: ignore[no-untyped-def]
        async def handle(payload: Any) -> None:
            info = current_delivery.get()
            endpoint = await _endpoint(endpoint_id)
            if info is None or endpoint is None:
                return
            await deliver(endpoint, info, payload)  # 高频事件：失败不重试

        return handle


_service: Subscriptions | None = None


def bind(service: Subscriptions | None) -> None:
    global _service
    _service = service


async def resync() -> None:
    """配置保存后调：按新的勾选调整订阅（投递插件没在运行时什么都不做）。"""
    if _service is not None:
        await _service.sync()

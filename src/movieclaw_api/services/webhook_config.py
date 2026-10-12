"""事件 Webhook 管理接口的业务实现（docs/design/webhook.md §4.2）。

secret 生命周期（Stripe 惯例）：
- 新建 endpoint 时服务端生成，仅在**那一次**响应里返回明文；
- 之后任何读取都只给打码值（``mcwh_xxxx****``）；
- 用户丢了明文只能轮换（rotate），旧值即刻作废。
"""

from __future__ import annotations

from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.webhook import (
    DeliveryView,
    WebhookConfigPayload,
    WebhookConfigView,
    WebhookEndpointView,
)
from movieclaw_api.services.webhook import catalog_view, deliver_test, recent_deliveries, resync
from movieclaw_api.services.webhook.catalog import (
    LEGACY_NAMES,
    is_jellyfin_mappable,
    is_known_event,
    normalize,
)
from movieclaw_api.settings import (
    WebhookEndpoint,
    WebhookSetting,
    generate_webhook_secret,
    get_setting_store,
    mask_webhook_secret,
)
from movieclaw_events import new_ulid


def _endpoint_view(
    endpoint: WebhookEndpoint, *, reveal_secret: str | None = None
) -> WebhookEndpointView:
    records = recent_deliveries(endpoint.id)
    return WebhookEndpointView(
        id=endpoint.id,
        name=endpoint.name,
        url=endpoint.url,
        format=endpoint.format,
        enabled=endpoint.enabled,
        events=normalize(endpoint.events),
        template=endpoint.template,
        headers=endpoint.headers,
        egress_scope=endpoint.egress_scope,
        secret_masked=mask_webhook_secret(endpoint.secret),
        secret=reveal_secret,
        last_delivery=DeliveryView(**records[0]) if records else None,
    )


def _build_view(
    setting: WebhookSetting, *, reveal: dict[str, str] | None = None
) -> WebhookConfigView:
    reveal = reveal or {}
    return WebhookConfigView(
        enabled=setting.enabled,
        endpoints=[
            _endpoint_view(ep, reveal_secret=reveal.get(ep.id))
            for ep in setting.endpoints
        ],
        catalog=catalog_view(),
    )


async def build_config_view() -> WebhookConfigView:
    setting = await get_setting_store().get(WebhookSetting)
    return _build_view(setting)


async def save_config(payload: WebhookConfigPayload) -> WebhookConfigView:
    """全量覆盖保存。新建 endpoint 的 secret 明文仅在本次响应返回一次。"""
    store = get_setting_store()
    current = await store.get(WebhookSetting)
    existing = {ep.id: ep for ep in current.endpoints}

    endpoints: list[WebhookEndpoint] = []
    reveal: dict[str, str] = {}
    for item in payload.endpoints:
        item.events = [LEGACY_NAMES.get(e, e) for e in item.events]
        unknown = [e for e in item.events if not is_known_event(e)]
        if unknown:
            raise BadRequestException(f"未知的订阅事件：{'、'.join(unknown)}")
        if item.format == "jellyfin":
            # 前端会禁用勾选，这里兜底：无 Jellyfin 对应物的事件投递必失败，
            # 与其每次事件都记一条失败记录，不如保存时就拒绝
            unmappable = [e for e in item.events if not is_jellyfin_mappable(e)]
            if unmappable:
                raise BadRequestException(
                    f"以下事件没有 Jellyfin 对应物，jellyfin 格式 endpoint 不能订阅："
                    f"{'、'.join(unmappable)}"
                )
        if item.id and item.id in existing:
            secret = existing[item.id].secret  # 编辑：secret 不经前端往返
            endpoint_id = item.id
        else:
            endpoint_id = new_ulid()
            secret = ""
        if item.format == "movieclaw" and not secret:
            # 覆盖两种来路：新建 movieclaw endpoint；以及从 jellyfin 切换过来的
            # 存量 endpoint（原本无密钥）——否则会静默发出无签名报文
            secret = generate_webhook_secret()
            reveal[endpoint_id] = secret
        endpoints.append(
            WebhookEndpoint(
                id=endpoint_id,
                name=item.name,
                url=item.url,
                format=item.format,
                enabled=item.enabled,
                events=item.events,
                secret=secret,
                template=item.template,
                headers=item.headers,
                egress_scope=item.egress_scope,
            )
        )

    setting = WebhookSetting(enabled=payload.enabled, endpoints=endpoints)
    await store.set(setting)
    await resync()  # 勾选的事件、开关变了：调整各地址的订阅
    return _build_view(setting, reveal=reveal)


async def _get_endpoint(endpoint_id: str) -> tuple[WebhookSetting, WebhookEndpoint]:
    setting = await get_setting_store().get(WebhookSetting)
    for endpoint in setting.endpoints:
        if endpoint.id == endpoint_id:
            return setting, endpoint
    raise NotFoundException(f"Webhook endpoint 不存在：{endpoint_id}")


async def rotate_secret(endpoint_id: str) -> WebhookEndpointView:
    """轮换签名密钥，新明文仅本次响应返回；旧密钥即刻作废。"""
    setting, endpoint = await _get_endpoint(endpoint_id)
    if endpoint.format != "movieclaw":
        raise BadRequestException("仅自有协议（movieclaw 格式）的 endpoint 有签名密钥")
    endpoint.secret = generate_webhook_secret()
    await get_setting_store().set(setting)
    return _endpoint_view(endpoint, reveal_secret=endpoint.secret)


async def send_test(endpoint_id: str) -> DeliveryView:
    """向指定 endpoint 同步发送一条示例事件，立刻返回投递结果。"""
    _, endpoint = await _get_endpoint(endpoint_id)
    record = await deliver_test(endpoint)
    return DeliveryView(
        event_id=record.event_id,
        event=record.event,
        ok=record.ok,
        status_code=record.status_code,
        duration_ms=record.duration_ms,
        attempts=record.attempts,
        error=record.error,
        at=record.at.isoformat(),
    )


async def list_deliveries(endpoint_id: str) -> list[DeliveryView]:
    await _get_endpoint(endpoint_id)  # 校验存在性
    return [DeliveryView(**r) for r in recent_deliveries(endpoint_id)]

"""Webhook 投递（docs/design/domain-events.md §6.2）：报文、签名、失败交给可靠重试、按配置订阅。

HTTP 走 httpx.MockTransport，不发真实网络请求；server 信息、配置读取打桩。端到端（真实应用 +
可靠事件 + 重启补投）见 test_webhook_end_to_end.py。
"""

from __future__ import annotations

import hashlib
import hmac
import json

import httpx
import pytest

from movieclaw_api.services.webhook import deliveries, delivery
from movieclaw_api.settings.webhook import WebhookEndpoint
from movieclaw_kernel import DeliveryInfo, Origin
from movieclaw_sdk.events import (
    MediaRef,
    PlaybackMarked,
    SubscriptionFulfilled,
    UnitRef,
)

SERVER = {"id": "srv01", "name": "MovieClaw", "version": "0.0.0-test", "username": "admin"}


def _endpoint(**overrides) -> WebhookEndpoint:  # type: ignore[no-untyped-def]
    payload = {
        "id": "ep01",
        "name": "测试端点",
        "url": "http://receiver.lan/hook",
        "format": "movieclaw",
        "enabled": True,
        "events": ["subscription.fulfilled"],
        "secret": "mcwh_testsecret",
    }
    payload.update(overrides)
    return WebhookEndpoint(**payload)


def _info(name: str = "subscription.fulfilled", attempt: int = 1) -> DeliveryInfo:
    return DeliveryInfo(
        event_id="01EVT",
        name=name,
        occurred_at="2026-10-12T08:00:00+00:00",
        origin=Origin(kind="member", id="3"),
        attempt=attempt,
    )


MEDIA = MediaRef(id=7, kind="tv", title="绝命毒师", year=2008, tmdb_id=1396)
FULFILLED = SubscriptionFulfilled(
    subscription_id=5,
    media=MEDIA,
    units=(UnitRef(season=1, episode=1), UnitRef(season=1, episode=2)),
    requested_units=(UnitRef(season=1, episode=1),),
)


@pytest.fixture(autouse=True)
def _clean(monkeypatch):  # type: ignore[no-untyped-def]
    deliveries.clear_deliveries()

    async def _fake_server_info() -> dict:
        return SERVER

    monkeypatch.setattr(delivery, "server_info", _fake_server_info)
    yield
    deliveries.clear_deliveries()


def _mock(monkeypatch, handler):  # type: ignore[no-untyped-def]
    monkeypatch.setattr(
        delivery, "egress_transport", lambda service, **kw: httpx.MockTransport(handler)
    )


async def test_message_is_the_event_envelope_and_signed(monkeypatch) -> None:
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(200)

    _mock(monkeypatch, handler)
    record = await delivery.deliver(_endpoint(), _info(), FULFILLED)
    assert record.ok and not record.failed
    request = captured[0]
    body = json.loads(request.content)
    # 报文就是事件信封：插件、Webhook 看到同一份 data
    assert body["id"] == "01EVT" and body["type"] == "subscription.fulfilled"
    assert body["occurred_at"] == "2026-10-12T08:00:00+00:00"
    assert body["origin"] == {"kind": "member", "id": "3"}
    assert body["server"] == {"id": "srv01", "name": "MovieClaw", "version": "0.0.0-test"}
    assert body["data"] == FULFILLED.model_dump(mode="json")
    assert body["data"]["requested_units"] == [{"season": 1, "episode": 1}]
    assert request.headers["X-MovieClaw-Event"] == "subscription.fulfilled"
    assert request.headers["X-MovieClaw-Event-Id"] == "01EVT"
    expected = hmac.new(b"mcwh_testsecret", request.content, hashlib.sha256).hexdigest()
    assert request.headers["X-MovieClaw-Signature"] == f"sha256={expected}"


async def test_failures_are_marked_for_retry(monkeypatch) -> None:
    _mock(monkeypatch, lambda request: httpx.Response(502))
    record = await delivery.deliver(_endpoint(), _info(attempt=2), FULFILLED)
    assert record.failed and record.status_code == 502 and record.attempts == 2

    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("拒绝连接")

    _mock(monkeypatch, refuse)
    record = await delivery.deliver(_endpoint(), _info(), FULFILLED)
    assert record.failed and record.status_code is None and "请求失败" in record.error


async def test_durable_handler_raises_so_the_store_retries(monkeypatch) -> None:
    from movieclaw_kernel import current_delivery

    _mock(monkeypatch, lambda request: httpx.Response(500))

    async def endpoint(_id: str) -> WebhookEndpoint:
        return _endpoint()

    monkeypatch.setattr(delivery, "_endpoint", endpoint)
    handle = delivery.Subscriptions._durable("ep01")
    token = current_delivery.set(_info())
    try:
        with pytest.raises(delivery.DeliveryFailed):
            await handle(FULFILLED)
        _mock(monkeypatch, lambda request: httpx.Response(204))
        await handle(FULFILLED)  # 收下了：不抛
    finally:
        current_delivery.reset(token)


async def test_transport_has_no_breaker(monkeypatch) -> None:
    """熔断键按服务标签共享：Webhook 必须关掉熔断，免得坏地址连坐健康地址。"""
    seen: list[dict] = []

    def fake(service, **kwargs):  # type: ignore[no-untyped-def]
        seen.append({"service": service, **kwargs})
        return httpx.MockTransport(lambda request: httpx.Response(200))

    monkeypatch.setattr(delivery, "egress_transport", fake)
    assert (await delivery.deliver(_endpoint(), _info(), FULFILLED)).ok
    assert seen[0]["service"] == "webhook" and seen[0]["use_breaker"] is False


async def test_jellyfin_format_without_template_records_error(monkeypatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("没配模板时不应发请求")

    _mock(monkeypatch, handler)
    record = await delivery.deliver(
        _endpoint(format="jellyfin"), _info("playback.marked_played"), FULFILLED
    )
    assert not record.ok and not record.failed and "没有配置模板" in record.error


async def test_jellyfin_cascade_sends_one_request_per_episode(monkeypatch) -> None:
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(200)

    async def lookups(data, wanted, server):  # type: ignore[no-untyped-def]
        return "admin", {(1, 1): "Pilot"}

    from movieclaw_api.services.webhook import jellyfin_formatter

    monkeypatch.setattr(jellyfin_formatter, "_lookups", lookups)
    _mock(monkeypatch, handler)
    marked = PlaybackMarked(
        member_id=0,
        media=MEDIA,
        units=(UnitRef(season=1, episode=1), UnitRef(season=1, episode=2)),
    )
    endpoint = _endpoint(
        format="jellyfin",
        template='{"type": "{{NotificationType}}", "name": "{{Name}}", "ep": {{EpisodeNumber}}}',
        headers={"Authorization": "Bearer xyz"},
    )
    record = await delivery.deliver(endpoint, _info("playback.marked_played"), marked)
    assert record.ok
    bodies = [json.loads(r.content) for r in captured]
    assert bodies == [
        {"type": "UserDataSaved", "name": "Pilot", "ep": 1},
        {"type": "UserDataSaved", "name": "绝命毒师", "ep": 2},
    ]
    assert captured[0].headers["Authorization"] == "Bearer xyz"
    assert "X-MovieClaw-Signature" not in captured[0].headers  # Jellyfin 格式不签名


async def test_jellyfin_skips_events_without_counterpart(monkeypatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("订阅事件没有 Jellyfin 对应物，不应发请求")

    _mock(monkeypatch, handler)
    endpoint = _endpoint(format="jellyfin", template="{}")
    record = await delivery.deliver(endpoint, _info(), FULFILLED)
    assert not record.failed and record.status_code is None


async def test_template_error_is_recorded_not_retried(monkeypatch) -> None:
    async def lookups(data, wanted, server):  # type: ignore[no-untyped-def]
        return "admin", {}

    from movieclaw_api.services.webhook import jellyfin_formatter

    monkeypatch.setattr(jellyfin_formatter, "_lookups", lookups)
    endpoint = _endpoint(format="jellyfin", template="{{#if_equals}}")
    marked = PlaybackMarked(member_id=0, media=MEDIA, units=())
    record = await delivery.deliver(endpoint, _info("playback.marked_played"), marked)
    assert not record.failed and "模板渲染失败" in record.error


async def test_test_delivery_sends_a_sample(monkeypatch) -> None:
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(200)

    _mock(monkeypatch, handler)
    record = await delivery.deliver_test(_endpoint())
    assert record.ok and record.event == "webhook.test"
    body = json.loads(captured[0].content)
    assert body["type"] == "webhook.test" and body["data"]["media"]["title"] == "示例剧集"


# ---------------------------------------------------------------------- 按配置订阅
class FakeStore:
    def __init__(self) -> None:
        self.subscribed: dict[str, tuple[str, ...]] = {}
        self.forgotten: list[str] = []

    def subscribe(self, events, *, entry_id, listener_id, handler):  # type: ignore[no-untyped-def]
        consumer = f"{entry_id}:{listener_id}"
        self.subscribed[consumer] = tuple(e.name for e in events)

        async def off() -> None:
            self.subscribed.pop(consumer, None)

        return off

    async def forget(self, consumer_id: str) -> None:
        self.forgotten.append(consumer_id)


class FakeCtx:
    def __init__(self) -> None:
        self.live: dict[str, str] = {}

    def on(self, event, handler, *, id):  # type: ignore[no-untyped-def]
        self.live[id] = event.name
        return lambda: self.live.pop(id, None)


async def test_subscriptions_follow_the_config(monkeypatch) -> None:
    from movieclaw_api.settings.webhook import WebhookSetting

    setting = WebhookSetting(
        enabled=True,
        endpoints=[
            _endpoint(
                id="a",
                events=["subscription.fulfilled", "playback.progress", "item.favorited", "gone"],
            ),
            _endpoint(id="b", events=["playback.started"], enabled=False),
        ],
    )

    class Store:
        async def get(self, _schema):  # type: ignore[no-untyped-def]
            return setting

    monkeypatch.setattr(delivery, "get_setting_store", lambda: Store())
    store, ctx = FakeStore(), FakeCtx()
    service = delivery.Subscriptions(ctx, store)
    await service.sync()
    # 可靠订阅一个消费者跟一组事件；高频的进度走实时；旧名字换新、认不出的丢掉；停用的地址不订
    assert store.subscribed == {
        "webhook.delivery:a": ("library.item.favorited", "subscription.fulfilled")
    }
    assert ctx.live == {"a:playback.progress": "playback.progress"}

    # 改了勾选：重新订阅（同一个消费者 id，进度保留）
    setting.endpoints[0].events = ["subscription.fulfilled"]
    await service.sync()
    assert store.subscribed == {"webhook.delivery:a": ("subscription.fulfilled",)}
    assert ctx.live == {}
    assert store.forgotten == []

    # 关掉 Webhook：取消订阅，并删掉消费者行（业务侧不再为它写事件）
    setting.enabled = False
    await service.sync()
    assert store.subscribed == {} and store.forgotten == ["webhook.delivery:a"]

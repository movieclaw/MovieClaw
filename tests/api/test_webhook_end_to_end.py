"""Webhook 端到端（docs/design/domain-events.md §6.2）：真实应用、真实可靠事件存储。

用户在设置页配一个地址 → 业务产生事件 → 地址收到信封；对方暂时出错会按可靠事件的退避重试
（事件 id 不变，供对方去重）；投递插件停着时产生的事件，恢复后补投；高频的播放进度走实时、
失败不重试；删掉地址后业务侧不再为它写事件。HTTP 走 MockTransport。
"""

from __future__ import annotations

import json
import time

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events
from movieclaw_api.services.webhook import deliveries, delivery
from movieclaw_db.engine import get_database
from movieclaw_db.models import DomainEvent, EventConsumer
from movieclaw_sdk.events import (
    PLAYBACK_PROGRESS,
    SUBSCRIPTION_FULFILLED,
    MediaRef,
    Playback,
    SubscriptionFulfilled,
    UnitRef,
)

BASE = "/api/v1/webhook"
MEDIA = MediaRef(id=7, kind="tv", title="漫长的季节", year=2023)


class Receiver:
    """假的下游：按顺序给出状态码，记下收到的报文。"""

    def __init__(self) -> None:
        self.codes: list[int] = []
        self.got: list[dict] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        code = self.codes.pop(0) if self.codes else 200
        self.got.append({"code": code, "body": body, "headers": dict(request.headers)})
        return httpx.Response(code)

    def delivered(self) -> list[dict]:
        return [g["body"] for g in self.got if 200 <= g["code"] < 300]


@pytest.fixture
def world(tmp_path, monkeypatch):  # type: ignore[no-untyped-def]
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'hook.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setattr(durable_events, "RETRY_DELAYS", (0.2, 0.2, 0.2))
    monkeypatch.setattr(durable_events, "POLL_INTERVAL", 0.1)
    get_settings.cache_clear()
    deliveries.clear_deliveries()
    durable_events.reset_state()
    receiver = Receiver()
    monkeypatch.setattr(
        delivery, "egress_transport", lambda service, **kw: httpx.MockTransport(receiver)
    )

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app) as client:
        yield client, receiver
    deliveries.clear_deliveries()
    durable_events.reset_state()
    get_settings.cache_clear()


def wait_for(predicate, timeout: float = 10.0) -> None:  # type: ignore[no-untyped-def]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待超时")


def publish(client: TestClient, event, payload) -> None:  # type: ignore[no-untyped-def]
    from movieclaw_api import events

    async def run() -> None:
        await events.publish_now(event, lambda: payload)

    client.portal.call(run)


def fulfilled(episode: int) -> SubscriptionFulfilled:
    unit = (UnitRef(season=1, episode=episode),)
    return SubscriptionFulfilled(subscription_id=3, media=MEDIA, units=unit, requested_units=unit)


def consumers(client: TestClient) -> list[str]:
    async def run() -> list[str]:
        async with get_database().session() as session:
            rows = await session.execute(select(EventConsumer.consumer_id))
            return list(rows.scalars())

    return client.portal.call(run)


def rows(client: TestClient) -> int:
    async def run() -> int:
        async with get_database().session() as session:
            return await session.scalar(select(func.count()).select_from(DomainEvent)) or 0

    return client.portal.call(run)


def configure(client: TestClient, events: list[str], *, enabled: bool = True) -> dict:
    endpoint = {
        "name": "家里的 Home Assistant",
        "url": "http://ha.lan/hook",
        "format": "movieclaw",
        "enabled": True,
        "events": events,
    }
    reply = client.put(BASE, json={"enabled": enabled, "endpoints": [endpoint]})
    assert reply.status_code == 200, reply.text
    return reply.json()["data"]


def test_configured_endpoint_gets_events_retried_and_caught_up(world) -> None:  # type: ignore[no-untyped-def]
    client, receiver = world
    config = configure(client, ["subscription.fulfilled"])
    endpoint_id = config["endpoints"][0]["id"]
    secret = config["endpoints"][0]["secret"]
    wait_for(lambda: f"webhook.delivery:{endpoint_id}" in consumers(client))

    # 对方先 503 一次：可靠事件退避重试，同一个事件 id
    receiver.codes = [503]
    publish(client, SUBSCRIPTION_FULFILLED, fulfilled(1))
    wait_for(lambda: len(receiver.delivered()) == 1)
    assert [g["code"] for g in receiver.got] == [503, 200]
    first, second = receiver.got
    assert first["body"]["id"] == second["body"]["id"]
    body = receiver.delivered()[0]
    assert body["type"] == "subscription.fulfilled"
    assert body["data"]["media"]["title"] == "漫长的季节"
    assert body["data"]["requested_units"] == [{"season": 1, "episode": 1}]
    import hashlib
    import hmac

    raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
    assert second["headers"]["x-movieclaw-signature"] == (
        "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
    )

    # 投递插件停着时产生的事件：写进事件表，恢复后按顺序补投
    kernel = client.app.state.kernel
    client.portal.call(kernel.disable, "webhook.delivery")
    publish(client, SUBSCRIPTION_FULFILLED, fulfilled(2))
    publish(client, SUBSCRIPTION_FULFILLED, fulfilled(3))
    time.sleep(0.5)
    assert len(receiver.delivered()) == 1
    client.portal.call(kernel.enable, "webhook.delivery")
    wait_for(lambda: len(receiver.delivered()) == 3)
    episodes = [b["data"]["units"][0]["episode"] for b in receiver.delivered()]
    assert episodes == [1, 2, 3]

    # 最近投递记录给设置页看
    records = client.get(f"{BASE}/endpoints/{endpoint_id}/deliveries").json()["data"]
    assert records[0]["ok"] is True and records[-1]["ok"] is False


def test_high_frequency_events_are_live_and_not_retried(world) -> None:  # type: ignore[no-untyped-def]
    client, receiver = world
    configure(client, ["playback.progress"])
    # 进度是高频事件：只走实时订阅，不建可靠消费者、不写事件表
    time.sleep(0.3)
    assert consumers(client) == []
    receiver.codes = [500]
    progress = Playback(member_id=0, media=MEDIA, unit=UnitRef(season=1, episode=1))
    publish(client, PLAYBACK_PROGRESS, progress)
    wait_for(lambda: len(receiver.got) == 1)
    publish(client, PLAYBACK_PROGRESS, progress)
    wait_for(lambda: len(receiver.got) == 2)
    time.sleep(0.5)
    assert [g["code"] for g in receiver.got] == [500, 200]  # 失败的那条不重试
    assert rows(client) == 0


def test_turning_webhook_off_stops_writing_events(world) -> None:  # type: ignore[no-untyped-def]
    client, receiver = world
    config = configure(client, ["subscription.fulfilled"])
    endpoint_id = config["endpoints"][0]["id"]
    wait_for(lambda: consumers(client) == [f"webhook.delivery:{endpoint_id}"])
    publish(client, SUBSCRIPTION_FULFILLED, fulfilled(1))
    wait_for(lambda: len(receiver.delivered()) == 1)
    written = rows(client)

    configure(client, ["subscription.fulfilled"], enabled=False)
    wait_for(lambda: consumers(client) == [])
    publish(client, SUBSCRIPTION_FULFILLED, fulfilled(2))
    time.sleep(0.4)
    # 没人订了：业务侧不再写事件表，也不再投递
    assert rows(client) == written
    assert len(receiver.delivered()) == 1

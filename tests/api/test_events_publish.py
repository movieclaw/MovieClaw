"""事件的唯一产生入口 ``movieclaw_api.events``（docs/design/domain-events.md §4、§5）。"""

from __future__ import annotations

import asyncio
from collections.abc import Callable

import pytest_asyncio
from pydantic import BaseModel, ConfigDict
from sqlalchemy import func, select

from movieclaw_api import events
from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.events import durable_events
from movieclaw_api.plugins.keys import DB
from movieclaw_api.services import durable_events as svc
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import DomainEvent, EventConsumer
from movieclaw_kernel import (
    DURABLE_EVENTS,
    Event,
    Mode,
    Origin,
    Stability,
    State,
    current_origin,
    plugin,
)
from movieclaw_kernel.testing import KernelHarness


class Thing(BaseModel):
    model_config = ConfigDict(frozen=True)
    value: int


OPEN = Stability.EXPERIMENTAL
THING = Event("test/pub-thing", Mode.EMIT, payload=Thing, durable=True, stability=OPEN)
OTHER = Event("test/pub-other", Mode.EMIT, payload=Thing, durable=True, stability=OPEN)
FAST = Event("test/pub-fast", Mode.EMIT, payload=Thing, stability=OPEN)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pub.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setattr(svc, "POLL_INTERVAL", 0.05)
    get_settings.cache_clear()
    svc.reset_state()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    svc.reset_state()
    await dispose_db()
    get_settings.cache_clear()


@pytest_asyncio.fixture
async def harness():
    async with KernelHarness() as h:
        events.bind_bus(h.kernel.bus)
        try:
            yield h
        finally:
            events.unbind_bus(h.kernel.bus)


def live(name: str, event: Event, heard: list) -> object:
    @plugin(name, title=name)
    async def apply(ctx) -> None:
        def on_event(payload: Thing) -> None:
            info = ctx.delivery
            heard.append((payload.value, info.event_id, info.origin.kind, info.origin.id))

        ctx.on(event, on_event)

    return apply


async def wait_for(cond: Callable[[], bool], timeout: float = 5.0) -> None:
    async with asyncio.timeout(timeout):
        while not cond():
            await asyncio.sleep(0.02)


async def count_rows(db) -> int:
    async with db.session() as session:
        return await session.scalar(select(func.count()).select_from(DomainEvent)) or 0


# ---------------------------------------------------------------------- 零开销
async def test_nobody_listening_builds_nothing(db, harness) -> None:
    built: list[int] = []

    def build() -> Thing:
        built.append(1)
        return Thing(value=1)

    async with db.session() as session:
        await events.publish(session, THING, build)
        await session.commit()
    await events.publish_now(THING, build)
    assert built == []
    assert await count_rows(db) == 0


# ---------------------------------------------------------------------- 实时：提交才发
async def test_live_events_go_out_on_commit_in_order(db, harness) -> None:
    heard: list[tuple] = []
    await harness.mount(live("acme.live", THING, heard))
    token = current_origin.set(Origin(kind="member", id="3"))
    try:
        async with db.session() as session:
            await events.publish(session, THING, lambda: Thing(value=1))
            await events.publish(session, THING, lambda: Thing(value=2))
            await events.drain()
            await asyncio.sleep(0.05)
            assert heard == []  # 还没提交
            await session.commit()
    finally:
        current_origin.reset(token)
    await events.drain()
    assert [h[0] for h in heard] == [1, 2]
    # 信封：事件 id 各不相同，发起方是产生时的（不是提交时的）
    assert len({h[1] for h in heard}) == 2
    assert {(h[2], h[3]) for h in heard} == {("member", "3")}


async def test_rolled_back_events_are_dropped(db, harness) -> None:
    heard: list[tuple] = []
    await harness.mount(live("acme.live", THING, heard))
    async with db.session() as session:
        await events.publish(session, THING, lambda: Thing(value=1))
        await session.rollback()
        await events.publish(session, THING, lambda: Thing(value=2))
        await session.commit()
    async with db.session() as session:
        await events.publish(session, THING, lambda: Thing(value=3))
        # 会话没提交就关掉：事件作废
    await events.drain()
    assert [h[0] for h in heard] == [2]


async def test_async_build_and_none_skips(db, harness) -> None:
    heard: list[tuple] = []
    await harness.mount(live("acme.live", THING, heard))

    async def build() -> Thing:
        return Thing(value=7)

    async with db.session() as session:
        await events.publish(session, THING, build)
        await events.publish(session, THING, lambda: None)
        await session.commit()
    await events.drain()
    assert [h[0] for h in heard] == [7]


async def test_build_errors_never_reach_business(db, harness) -> None:
    heard: list[tuple] = []
    await harness.mount(live("acme.live", THING, heard))

    def broken() -> Thing:
        raise RuntimeError("boom")

    async with db.session() as session:
        await events.publish(session, THING, broken)
        await events.publish(session, THING, lambda: Thing(value=1))
        await session.commit()
    await events.drain()
    assert [h[0] for h in heard] == [1]


async def test_publish_now_without_transaction(db, harness) -> None:
    heard: list[tuple] = []
    await harness.mount(live("acme.live", FAST, heard))
    await events.publish_now(FAST, lambda: Thing(value=5))
    await events.drain()
    assert [h[0] for h in heard] == [5]


# ---------------------------------------------------------------------- 可靠：同一个事件 id
async def test_durable_and_live_share_the_envelope(db, harness) -> None:
    heard: list[tuple] = []
    stored: list[tuple] = []

    @plugin("acme.durable", title="d", inject=(DURABLE_EVENTS,))
    async def durable(ctx) -> None:
        def on_event(payload: Thing) -> None:
            stored.append((payload.value, ctx.delivery.event_id))

        ctx.on(THING, on_event, id="keep", durable=True)

    harness.provide(DB, db)
    assert (await harness.mount(durable_events)).state is State.ACTIVE
    assert (await harness.mount(durable)).state is State.ACTIVE
    await harness.mount(live("acme.live", THING, heard))
    async with asyncio.timeout(5):
        while True:
            async with db.session() as session:
                if await session.scalar(select(func.count()).select_from(EventConsumer)):
                    break
            await asyncio.sleep(0.02)
    async with db.session() as session:
        await events.publish(session, THING, lambda: Thing(value=1))
        await session.commit()
    await events.drain()
    await wait_for(lambda: len(stored) == 1)
    assert heard[0][0] == stored[0][0] == 1
    assert heard[0][1] == stored[0][1]
    assert await count_rows(db) == 1


async def test_durable_consumer_follows_several_events_in_order(db, harness) -> None:
    seen: list[tuple[str, int]] = []

    harness.provide(DB, db)
    assert (await harness.mount(durable_events)).state is State.ACTIVE
    store = harness.kernel.service(DURABLE_EVENTS)
    store.subscribe(
        (THING, OTHER),
        entry_id="acme.hook",
        listener_id="all",
        handler=lambda p: seen.append((svc.current_delivery.get().name, p.value)),
    )
    async with asyncio.timeout(5):
        while True:
            async with db.session() as session:
                row = await session.get(EventConsumer, "acme.hook:all")
            if row is not None:
                break
            await asyncio.sleep(0.02)
    assert sorted(row.event_names) == ["test/pub-other", "test/pub-thing"]
    async with db.session() as session:
        await events.publish(session, THING, lambda: Thing(value=1))
        await events.publish(session, OTHER, lambda: Thing(value=2))
        await events.publish(session, THING, lambda: Thing(value=3))
        await session.commit()
    await wait_for(lambda: len(seen) == 3)
    assert seen == [("test/pub-thing", 1), ("test/pub-other", 2), ("test/pub-thing", 3)]

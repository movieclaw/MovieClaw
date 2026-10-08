"""可靠事件（docs/design/plugin-phase2a.md §2）：写入、投递、重试、死信、续投、零开销。

用真实迁移出来的 SQLite 与内核测试工具：投递插件 + 一个订阅插件，业务侧用 ``record`` 写事件。
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from datetime import timedelta

import pytest
import pytest_asyncio
from pydantic import BaseModel, ConfigDict
from sqlmodel import func, select

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.events import durable_events
from movieclaw_api.plugins.keys import DB
from movieclaw_api.services import durable_events as svc
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import DomainEvent, EventConsumer, EventDeadLetter, utcnow
from movieclaw_kernel import (
    DURABLE_EVENTS,
    Delivery,
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


THING = Event(
    "test/thing",
    Mode.EMIT,
    payload=Thing,
    delivery=Delivery.DURABLE,
    stability=Stability.EXPERIMENTAL,
)
OTHER = Event(
    "test/other",
    Mode.EMIT,
    payload=Thing,
    delivery=Delivery.DURABLE,
    stability=Stability.EXPERIMENTAL,
)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'events.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setattr(svc, "RETRY_DELAYS", (0.01, 0.01))
    monkeypatch.setattr(svc, "POLL_INTERVAL", 0.05)
    get_settings.cache_clear()
    svc.reset_state()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    svc.reset_state()
    await dispose_db()
    get_settings.cache_clear()


def consumer(name: str, handler: Callable, *, event=THING, listener_id: str = "main"):
    @plugin(name, title=name, inject=(DURABLE_EVENTS,))
    async def apply(ctx) -> None:
        ctx.on(event, lambda payload: handler(ctx, payload), id=listener_id)

    return apply


async def wait_for(cond: Callable[[], bool], timeout: float = 5.0) -> None:
    async with asyncio.timeout(timeout):
        while not cond():
            await asyncio.sleep(0.02)


async def consumers_ready(db, n: int = 1) -> None:
    """等订阅登记落库（消费者协程启动后异步写入 event_consumer）。"""
    async with asyncio.timeout(5):
        while True:
            async with db.session() as session:
                count = await session.scalar(select(func.count()).select_from(EventConsumer))
            if (count or 0) >= n:
                return
            await asyncio.sleep(0.02)


async def record(db, *values: int, event=THING, commit: bool = True) -> list[bool]:
    async with db.session() as session:
        written = [await svc.record(session, event, Thing(value=v)) for v in values]
        if commit:
            await session.commit()
        else:
            await session.rollback()
    return written


async def count_events(db) -> int:
    async with db.session() as session:
        return await session.scalar(select(func.count()).select_from(DomainEvent)) or 0


async def start(h: KernelHarness, db) -> None:
    h.provide(DB, db)
    fiber = await h.mount(durable_events)
    assert fiber.state is State.ACTIVE


# ---------------------------------------------------------------------- 写入
async def test_nothing_is_written_without_consumers(db) -> None:
    # 零开销：没有任何插件订阅时，业务侧的 record 不写库
    assert await record(db, 1, 2) == [False, False]
    assert await count_events(db) == 0


async def test_record_validates_event_and_payload(db) -> None:
    live = Event("test/live", Mode.EMIT, payload=Thing)
    async with db.session() as session:
        with pytest.raises(TypeError, match="不是可靠事件"):
            await svc.record(session, live, Thing(value=1))
        with pytest.raises(TypeError, match="载荷须是"):
            await svc.record(session, THING, 1)


# ---------------------------------------------------------------------- 投递
async def test_delivers_in_order_after_commit_and_skips_rolled_back(db) -> None:
    seen: list[tuple[int, str, str]] = []

    def handler(ctx, payload: Thing) -> None:
        seen.append((payload.value, ctx.delivery.event_id, ctx.delivery.origin.kind))

    async with KernelHarness() as h:
        await start(h, db)
        fiber = await h.mount(consumer("acme.watch", handler))
        await consumers_ready(db)

        assert await record(db, 1, 2, 3) == [True, True, True]
        await record(db, 99, commit=False)  # 回滚：事件不存在
        await record(db, 4)
        await wait_for(lambda: len(seen) == 4)
        await asyncio.sleep(0.1)
        assert [v for v, _, _ in seen] == [1, 2, 3, 4]
        assert len({eid for _, eid, _ in seen}) == 4
        assert all(kind == "system" for _, _, kind in seen)
        await h.unmount(fiber)


async def test_new_consumer_does_not_replay_history(db) -> None:
    seen: list[int] = []
    async with KernelHarness() as h:
        await start(h, db)
        first = await h.mount(consumer("acme.first", lambda ctx, p: None))
        await consumers_ready(db)
        await record(db, 1, 2)
        late = await h.mount(consumer("acme.late", lambda ctx, p: seen.append(p.value)))
        await asyncio.sleep(0.2)
        await record(db, 3)
        await wait_for(lambda: seen == [3])
        await h.unmount(late)
        await h.unmount(first)


async def test_origin_and_cause_chain_are_carried(db) -> None:
    seen: list[tuple[bool, tuple[str, ...]]] = []

    def handler(ctx, payload: Thing) -> None:
        seen.append((ctx.delivery.origin.is_plugin("acme.self"), ctx.origin.chain))

    async with KernelHarness() as h:
        await start(h, db)
        fiber = await h.mount(consumer("acme.self", handler))
        await consumers_ready(db)
        token = current_origin.set(Origin(kind="plugin", id="acme.self", chain=("x/y",)))
        try:
            await record(db, 1)
        finally:
            current_origin.reset(token)
        await wait_for(lambda: len(seen) == 1)
        # 插件能认出自己引起的事件；处理期间的因果链 = 事件当时的链 + 本事件
        assert seen == [(True, ("x/y", "test/thing"))]
        await h.unmount(fiber)


async def test_cause_chain_limit_stops_writing(db) -> None:
    async with KernelHarness() as h:
        await start(h, db)
        fiber = await h.mount(consumer("acme.loop", lambda ctx, p: None))
        await consumers_ready(db)
        token = current_origin.set(Origin(kind="plugin", id="acme.loop", chain=("e",) * 8))
        try:
            assert await record(db, 1) == [False]
        finally:
            current_origin.reset(token)
        await h.unmount(fiber)


# ---------------------------------------------------------------------- 失败与死信
async def test_failure_is_retried_until_success(db) -> None:
    calls: list[int] = []

    def flaky(ctx, payload: Thing) -> None:
        calls.append(ctx.delivery.attempt)
        if len(calls) < 2:
            raise RuntimeError("downstream not ready")

    async with KernelHarness() as h:
        await start(h, db)
        fiber = await h.mount(consumer("acme.flaky", flaky))
        await consumers_ready(db)
        await record(db, 1)
        await wait_for(lambda: calls == [1, 2])
        async with asyncio.timeout(5):
            while True:
                async with db.session() as session:
                    state = await session.get(EventConsumer, "acme.flaky:main")
                if state.cursor > 0:
                    break
                await asyncio.sleep(0.02)
        assert state.attempts == 0 and state.last_error is None
        await h.unmount(fiber)


async def test_exhausted_event_goes_to_dead_letter_and_does_not_block(db) -> None:
    seen: list[int] = []
    broken = {"on": True}

    def handler(ctx, payload: Thing) -> None:
        if payload.value == 1 and broken["on"]:
            raise RuntimeError("cannot handle 1")
        seen.append(payload.value)

    async with KernelHarness() as h:
        await start(h, db)
        store = h.kernel.service(DURABLE_EVENTS)
        fiber = await h.mount(consumer("acme.dead", handler))
        await consumers_ready(db)
        await record(db, 1, 2)
        await wait_for(lambda: seen == [2])
        async with asyncio.timeout(5):
            while True:
                info = await store.describe()
                [state] = [c for c in info["consumers"] if c["consumer_id"] == "acme.dead:main"]
                if state["backlog"] == 0:
                    break
                await asyncio.sleep(0.02)

        [letter] = info["dead_letters"]
        assert letter["consumer_id"] == "acme.dead:main"
        assert letter["attempts"] == 3  # 1 次 + len(RETRY_DELAYS) 次重试
        assert "cannot handle 1" in letter["error"]
        [state] = [c for c in info["consumers"] if c["consumer_id"] == "acme.dead:main"]
        assert state["backlog"] == 0 and state["active"]

        # 修好之后重放：事件再交一次，死信标记已处理
        broken["on"] = False
        await store.replay(letter["id"])
        assert seen == [2, 1]
        assert (await store.describe())["dead_letters"] == []
        with pytest.raises(svc.ReplayError, match="已经处理过"):
            await store.replay(letter["id"])
        await h.unmount(fiber)


async def test_replay_requires_running_consumer_and_dismiss_resolves(db) -> None:
    def always_fail(ctx, payload: Thing) -> None:
        raise RuntimeError("nope")

    async with KernelHarness() as h:
        await start(h, db)
        store = h.kernel.service(DURABLE_EVENTS)
        fiber = await h.mount(consumer("acme.gone", always_fail))
        await consumers_ready(db)
        await record(db, 1)
        async with asyncio.timeout(5):
            while not (await store.describe())["dead_letters"]:
                await asyncio.sleep(0.02)
        [letter] = (await store.describe())["dead_letters"]
        with pytest.raises(svc.ReplayError, match="nope"):
            await store.replay(letter["id"])
        await h.unmount(fiber)
        with pytest.raises(svc.ReplayError, match="没有运行"):
            await store.replay(letter["id"])
        await store.dismiss(letter["id"])
        assert (await store.describe())["dead_letters"] == []
        with pytest.raises(LookupError):
            await store.dismiss(12345)


async def test_payload_that_no_longer_validates_goes_straight_to_dead_letter(db) -> None:
    seen: list[int] = []
    async with KernelHarness() as h:
        await start(h, db)
        store = h.kernel.service(DURABLE_EVENTS)
        fiber = await h.mount(consumer("acme.strict", lambda ctx, p: seen.append(p.value)))
        await consumers_ready(db)
        async with db.session() as session:
            session.add(DomainEvent(id="01BAD", name="test/thing", payload={"value": "x"}))
            await session.commit()
        svc._wake_all()
        async with asyncio.timeout(5):
            while not (await store.describe())["dead_letters"]:
                await asyncio.sleep(0.02)
        [letter] = (await store.describe())["dead_letters"]
        assert letter["attempts"] == 1 and "载荷校验失败" in letter["error"]
        await record(db, 7)
        await wait_for(lambda: seen == [7])
        await h.unmount(fiber)


# ---------------------------------------------------------------------- 跨重启
async def test_events_written_while_stopped_are_delivered_after_restart(db) -> None:
    seen: list[int] = []
    async with KernelHarness() as h:
        await start(h, db)
        fiber = await h.mount(consumer("acme.resume", lambda ctx, p: seen.append(p.value)))
        await consumers_ready(db)
        await record(db, 1)
        await wait_for(lambda: seen == [1])
        await h.unmount(fiber)
        await h.unmount("kernel.durable-events")

    # 「进程重启」：内存名单清空，消费者行还在库里 → 写入照常发生
    svc.reset_state()
    assert await record(db, 2, 3) == [True, True]

    async with KernelHarness() as h:
        await start(h, db)
        fiber = await h.mount(consumer("acme.resume", lambda ctx, p: seen.append(p.value)))
        await wait_for(lambda: seen == [1, 2, 3])
        await h.unmount(fiber)


async def test_consumers_are_independent(db) -> None:
    a: list[int] = []
    b: list[int] = []

    def slow_fail(ctx, payload: Thing) -> None:
        raise RuntimeError("b is broken")

    async with KernelHarness() as h:
        await start(h, db)
        fa = await h.mount(consumer("acme.a", lambda ctx, p: a.append(p.value)))
        fb = await h.mount(consumer("acme.b", slow_fail))
        fo = await h.mount(consumer("acme.o", lambda ctx, p: b.append(p.value), event=OTHER))
        await consumers_ready(db, 3)
        await record(db, 1, 2)
        await record(db, 5, event=OTHER)
        await wait_for(lambda: a == [1, 2] and b == [5])
        for fiber in (fa, fb, fo):
            await h.unmount(fiber)


async def test_duplicate_listener_id_fails_the_plugin(db) -> None:
    @plugin("acme.dup", title="dup", inject=(DURABLE_EVENTS,))
    async def dup(ctx) -> None:
        ctx.on(THING, lambda p: None, id="same")
        ctx.on(OTHER, lambda p: None, id="same")

    async with KernelHarness() as h:
        await start(h, db)
        fiber = await h.mount(dup)
        assert fiber.state is State.FAILED
        assert "重复" in fiber.error


# ---------------------------------------------------------------------- 清理
async def test_housekeeping_keeps_events_referenced_by_open_dead_letters(db) -> None:
    async with KernelHarness() as h:
        await start(h, db)
        store = h.kernel.service(DURABLE_EVENTS)
        old = utcnow() - timedelta(days=30)
        async with db.session() as session:
            session.add(
                DomainEvent(seq=1, id="01OLD1", name="test/thing", payload={}, occurred_at=old)
            )
            session.add(
                DomainEvent(seq=2, id="01OLD2", name="test/thing", payload={}, occurred_at=old)
            )
            session.add(DomainEvent(seq=3, id="01NEW", name="test/thing", payload={}))
            session.add(
                EventDeadLetter(
                    consumer_id="acme.x:main",
                    event_seq=2,
                    event_id="01OLD2",
                    event_name="test/thing",
                    error="e",
                )
            )
            session.add(
                EventConsumer(
                    consumer_id="acme.removed:main",
                    event_name="test/thing",
                    last_seen_at=utcnow() - timedelta(days=60),
                )
            )
            await session.commit()
        await store.housekeeping()
        async with db.session() as session:
            seqs = sorted((await session.execute(select(DomainEvent.seq))).scalars())
            assert seqs == [2, 3]
            assert await session.get(EventConsumer, "acme.removed:main") is None

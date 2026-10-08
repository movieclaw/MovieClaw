"""事件总线（plugin-kernel.md §4.7、§12.1）。

三种模式的语义、隔离、超时、熔断、因果链、可靠事件接口。
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass

import pytest
from pydantic import BaseModel, ConfigDict

from movieclaw_kernel import (
    DURABLE_EVENTS,
    CauseChainTooLong,
    Delivery,
    Event,
    Mode,
    State,
    plugin,
)
from movieclaw_kernel.testing import KernelHarness


@dataclass(frozen=True)
class Item:
    value: int


@dataclass(frozen=True)
class Batch:
    items: tuple[int, ...]


@dataclass
class Mutable:
    value: int


class Stored(BaseModel):
    model_config = ConfigDict(frozen=True)
    value: int


NOTICE = Event("test/notice", Mode.EMIT, payload=Item)
PIPE = Event("test/pipe", Mode.WATERFALL, payload=Batch, result=Batch, timeout=0.2)
DECIDE = Event("test/decide", Mode.BAIL, payload=Item, result=str, timeout=0.2)
DURABLE = Event("test/durable", Mode.EMIT, payload=Stored, delivery=Delivery.DURABLE)


def listener_plugin(name: str, event: Event, handler, **kw):
    @plugin(name, title=name)
    async def apply(ctx) -> None:
        ctx.on(event, handler, **kw)

    return apply


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


# ---------------------------------------------------------------- 定义与模式校验
def test_mutable_payload_rejected() -> None:
    with pytest.raises(TypeError, match="必须不可变"):
        Event("test/bad", Mode.EMIT, payload=Mutable)


def test_durable_only_for_emit() -> None:
    with pytest.raises(TypeError, match="只有 EMIT"):
        Event("test/bad2", Mode.BAIL, payload=Item, delivery=Delivery.DURABLE)


def test_durable_payload_must_be_pydantic() -> None:
    # 可靠事件要落库、重启后还原：冻结 dataclass 不够，须能按 schema 校验还原
    with pytest.raises(TypeError, match="pydantic"):
        Event("test/bad3", Mode.EMIT, payload=Item, delivery=Delivery.DURABLE)


async def test_wrong_dispatch_mode_and_payload_rejected() -> None:
    async with KernelHarness() as h:
        with pytest.raises(TypeError, match="waterfall"):
            h.events.emit(PIPE, Batch(()))
        with pytest.raises(TypeError, match="载荷须是"):
            h.events.emit(NOTICE, Batch(()))
        with pytest.raises(TypeError, match="可靠事件"):
            h.events.emit(DURABLE, Stored(value=1))


# ---------------------------------------------------------------- EMIT
async def test_emit_isolates_failures_and_never_blocks() -> None:
    seen: list[int] = []

    def bad(item: Item) -> None:
        raise RuntimeError("bad listener")

    async def good(item: Item) -> None:
        seen.append(item.value)

    async with KernelHarness() as h:
        bad_fiber = await h.mount(listener_plugin("bad", NOTICE, bad))
        await h.mount(listener_plugin("good", NOTICE, good))
        for i in range(3):
            h.events.emit(NOTICE, Item(i))
        await h.drain()
        assert seen == [0, 1, 2]
        assert bad_fiber.stats.failures == 3


async def test_emit_drops_when_queue_full() -> None:
    small = Event("test/small", Mode.EMIT, payload=Item, queue_size=2)
    gate = asyncio.Event()
    seen: list[int] = []

    async def slow(item: Item) -> None:
        await gate.wait()
        seen.append(item.value)

    async with KernelHarness() as h:
        fiber = await h.mount(listener_plugin("slow", small, slow))
        started = time.perf_counter()
        for i in range(10):
            h.events.emit(small, Item(i))
        assert time.perf_counter() - started < 0.05
        gate.set()
        await h.drain()
        # 第一个在消费中、队列里 2 个，其余丢弃
        assert len(seen) <= 3
        assert fiber.stats.dropped >= 7


async def test_listener_removed_on_unmount() -> None:
    seen: list[int] = []

    async with KernelHarness() as h:
        fiber = await h.mount(listener_plugin("l", NOTICE, lambda item: seen.append(item.value)))
        h.events.emit(NOTICE, Item(1))
        await h.drain()
        await h.unmount(fiber)
        h.events.emit(NOTICE, Item(2))
        await asyncio.sleep(0.01)
        assert seen == [1]


# ---------------------------------------------------------------- WATERFALL
def wf(name: str, fn, priority: int = 0):
    return listener_plugin(name, PIPE, fn, priority=priority)


async def test_waterfall_onion_order_and_rewrite() -> None:
    trace: list[str] = []

    async def outer(batch: Batch, next):
        trace.append("outer-in")
        result = await next(Batch((*batch.items, 1)))
        trace.append("outer-out")
        return Batch((*result.items, 99))

    async def inner(batch: Batch, next):
        trace.append("inner-in")
        return await next(Batch(tuple(i * 10 for i in batch.items)))

    async with KernelHarness() as h:
        await h.mount(wf("inner", inner, priority=0))
        await h.mount(wf("outer", outer, priority=10))
        result = await h.events.waterfall(PIPE, Batch((5,)), terminal=lambda b: b)
    assert trace == ["outer-in", "inner-in", "outer-out"]
    assert result == Batch((50, 10, 99))


async def test_waterfall_short_circuit() -> None:
    async def stop(batch: Batch, next):
        return Batch(())

    async with KernelHarness() as h:
        await h.mount(wf("stop", stop))
        result = await h.events.waterfall(
            PIPE, Batch((1, 2)), terminal=lambda b: pytest.fail("ran")
        )
    assert result == Batch(())


async def test_waterfall_error_before_next_is_skipped() -> None:
    async def broken(batch: Batch, next):
        raise RuntimeError("before next")

    async with KernelHarness() as h:
        fiber = await h.mount(wf("broken", broken))
        result = await h.events.waterfall(
            PIPE, Batch((1,)), terminal=lambda b: Batch((*b.items, 2))
        )
        assert result == Batch((1, 2))
        assert fiber.stats.failures == 1


async def test_waterfall_error_after_next_returns_downstream_result() -> None:
    calls: list[int] = []

    async def broken_after(batch: Batch, next):
        await next()
        raise RuntimeError("after next")

    def terminal(batch: Batch) -> Batch:
        calls.append(1)
        return Batch((7,))

    async with KernelHarness() as h:
        await h.mount(wf("after", broken_after))
        result = await h.events.waterfall(PIPE, Batch(()), terminal=terminal)
    assert result == Batch((7,))
    assert calls == [1], "下游只能执行一次"


async def test_waterfall_bad_return_type_is_isolated() -> None:
    async def wrong(batch: Batch, next):
        await next()
        return "not a batch"

    async with KernelHarness() as h:
        fiber = await h.mount(wf("wrong", wrong))
        result = await h.events.waterfall(PIPE, Batch((3,)), terminal=lambda b: b)
        assert result == Batch((3,))
        assert fiber.stats.failures == 1


async def test_waterfall_bad_next_payload_is_isolated() -> None:
    async def wrong(batch: Batch, next):
        return await next("nope")

    async with KernelHarness() as h:
        await h.mount(wf("wrong-next", wrong))
        result = await h.events.waterfall(PIPE, Batch((3,)), terminal=lambda b: b)
    assert result == Batch((3,))


async def test_waterfall_timeout_skips_listener() -> None:
    async def sleepy(batch: Batch, next):
        await asyncio.sleep(5)
        return await next()

    async with KernelHarness() as h:
        fiber = await h.mount(wf("sleepy", sleepy))
        started = time.perf_counter()
        result = await h.events.waterfall(PIPE, Batch((1,)), terminal=lambda b: b)
        assert time.perf_counter() - started < 1
        assert result == Batch((1,))
        assert fiber.stats.timeouts == 1


async def test_waterfall_timeout_excludes_downstream_time() -> None:
    async def fast_outer(batch: Batch, next):
        return await next()

    async def slow_terminal(batch: Batch) -> Batch:
        await asyncio.sleep(0.4)  # 超过 PIPE 的 0.2 秒单监听器时限
        return Batch((1,))

    async with KernelHarness() as h:
        fiber = await h.mount(wf("outer", fast_outer))
        result = await h.events.waterfall(PIPE, Batch(()), terminal=slow_terminal)
        assert result == Batch((1,))
        assert fiber.stats.timeouts == 0


async def test_waterfall_terminal_error_propagates() -> None:
    async def passthrough(batch: Batch, next):
        return await next()

    def terminal(batch: Batch) -> Batch:
        raise LookupError("core bug")

    async with KernelHarness() as h:
        fiber = await h.mount(wf("pass", passthrough))
        with pytest.raises(LookupError, match="core bug"):
            await h.events.waterfall(PIPE, Batch(()), terminal=terminal)
        assert fiber.stats.failures == 0


async def test_waterfall_budget_skips_remaining_listeners() -> None:
    budgeted = Event("test/budget", Mode.WATERFALL, payload=Batch, budget=0.05)
    trace: list[str] = []

    async def slow(batch: Batch, next):
        trace.append("slow")
        await asyncio.sleep(0.1)
        return await next()

    async def later(batch: Batch, next):
        trace.append("later")
        return await next()

    async with KernelHarness() as h:
        await h.mount(listener_plugin("slow", budgeted, slow, priority=1))
        await h.mount(listener_plugin("later", budgeted, later, priority=0))
        await h.events.waterfall(budgeted, Batch(()), terminal=lambda b: b)
    assert trace == ["slow"]


# ---------------------------------------------------------------- BAIL
async def test_bail_first_answer_wins_and_failures_skipped() -> None:
    def broken(item: Item):
        raise RuntimeError("x")

    async def wrong_type(item: Item):
        return 42

    async def abstain(item: Item):
        return None

    async def answer(item: Item):
        return f"yes-{item.value}"

    def never(item: Item):
        pytest.fail("应在第一个答复处停下")

    async with KernelHarness() as h:
        await h.mount(listener_plugin("broken", DECIDE, broken, priority=5))
        await h.mount(listener_plugin("wrong", DECIDE, wrong_type, priority=4))
        await h.mount(listener_plugin("abstain", DECIDE, abstain, priority=3))
        await h.mount(listener_plugin("answer", DECIDE, answer, priority=2))
        await h.mount(listener_plugin("never", DECIDE, never, priority=1))
        assert await h.events.bail(DECIDE, Item(3)) == "yes-3"


async def test_bail_no_answer_returns_none() -> None:
    async with KernelHarness() as h:
        assert await h.events.bail(DECIDE, Item(1)) is None


# ---------------------------------------------------------------- 熔断
async def test_breaker_opens_cools_down_and_recovers() -> None:
    clock = FakeClock()
    state = {"fail": True, "calls": 0}

    def flaky(item: Item):
        state["calls"] += 1
        if state["fail"]:
            raise RuntimeError("flaky")
        return "ok"

    async with KernelHarness(clock=clock) as h:
        await h.mount(listener_plugin("flaky", DECIDE, flaky))
        for _ in range(5):
            assert await h.events.bail(DECIDE, Item(1)) is None
        assert state["calls"] == 5
        # 熔断中：不再调用
        await h.events.bail(DECIDE, Item(1))
        assert state["calls"] == 5
        listener = h.events.listeners(DECIDE)[0]
        assert listener.breaker.state == "open"
        # 冷却 60 秒后试探一次，仍失败 → 冷却翻倍
        clock.now += 61
        await h.events.bail(DECIDE, Item(1))
        assert state["calls"] == 6
        assert listener.breaker.open_until == pytest.approx(clock.now + 120)
        clock.now += 121
        state["fail"] = False
        assert await h.events.bail(DECIDE, Item(1)) == "ok"
        assert listener.breaker.state == "closed"


# ---------------------------------------------------------------- 发起方与因果链
async def test_origin_propagates_to_listeners_and_tasks() -> None:
    seen: list[tuple] = []

    @plugin("observer", title="observer")
    async def observer(ctx) -> None:
        async def on_item(item: Item) -> None:
            seen.append(("listener", ctx.origin.kind, ctx.origin.id, ctx.origin.chain))

            async def follow_up() -> None:
                seen.append(("task", ctx.origin.kind, ctx.origin.id))

            ctx.task(follow_up(), name="follow")

        ctx.on(NOTICE, on_item)

    async with KernelHarness() as h:
        await h.mount(observer)
        h.events.emit(NOTICE, Item(1))
        await h.drain()
        await asyncio.sleep(0.01)
    assert seen[0] == ("listener", "plugin", "observer", ("test/notice",))
    assert seen[1] == ("task", "plugin", "observer")


async def test_cause_chain_limit_stops_ping_pong() -> None:
    ping = Event("test/ping", Mode.EMIT, payload=Item)
    hits: list[int] = []
    errors: list[str] = []

    @plugin("ponger", title="ponger")
    async def ponger(ctx) -> None:
        def on_ping(item: Item) -> None:
            hits.append(item.value)
            try:
                ctx.events.emit(ping, Item(item.value + 1))
            except CauseChainTooLong as exc:
                errors.append(str(exc))

        ctx.on(ping, on_ping)

    async with KernelHarness() as h:
        await h.mount(ponger)
        h.events.emit(ping, Item(0))
        for _ in range(20):
            await h.drain()
            await asyncio.sleep(0)
    assert hits == list(range(8))
    assert errors and "因果链" in errors[0]


# ---------------------------------------------------------------- 可靠事件接口
async def test_durable_listener_requires_stable_id() -> None:
    async with KernelHarness() as h:
        fiber = await h.mount(listener_plugin("no-id", DURABLE, lambda e: None))
        assert fiber.state is State.FAILED
        assert "稳定 id" in fiber.error


async def test_durable_listener_waits_for_store() -> None:
    subscribed: list[tuple] = []
    unsubscribed: list[str] = []

    class FakeStore:
        def subscribe(self, event, *, entry_id, listener_id, handler):
            subscribed.append((event.name, entry_id, listener_id))
            return lambda: unsubscribed.append(listener_id)

    @plugin("auto", title="auto", inject=(DURABLE_EVENTS,))
    async def auto(ctx) -> None:
        ctx.on(DURABLE, lambda e: None, id="cascade")

    async with KernelHarness() as h:
        fiber = await h.mount(auto)
        assert fiber.state is State.PENDING
        h.provide(DURABLE_EVENTS, FakeStore())
        await h.settle()
        assert fiber.state is State.ACTIVE
        assert subscribed == [("test/durable", "auto", "cascade")]
        await h.unmount(fiber)
        assert unsubscribed == ["cascade"]


async def test_durable_listener_reads_delivery_info() -> None:
    # 存储实现投递时设置 current_delivery；
    # 监听器经 ctx.delivery 读到事件 id 与「事件发生时的发起方」
    from movieclaw_kernel import DeliveryInfo, Origin, current_delivery

    seen: list[tuple] = []
    holder: dict = {}

    class FakeStore:
        def subscribe(self, event, *, entry_id, listener_id, handler):
            holder["handler"] = handler
            return lambda: None

    @plugin("reader", title="r", inject=(DURABLE_EVENTS,))
    async def reader(ctx) -> None:
        def on_event(item: Stored) -> None:
            info = ctx.delivery
            seen.append((item.value, info.event_id, info.origin.is_plugin("reader")))

        ctx.on(DURABLE, on_event, id="read")
        assert ctx.delivery is None

    async with KernelHarness() as h:
        h.provide(DURABLE_EVENTS, FakeStore())
        fiber = await h.mount(reader)
        origin = Origin("plugin", "reader")
        info = DeliveryInfo("01EVT", "test/durable", "2026-10-09T00:00:00Z", origin)
        token = current_delivery.set(info)
        try:
            holder["handler"](Stored(value=7))
        finally:
            current_delivery.reset(token)
        await h.unmount(fiber)
    assert seen == [(7, "01EVT", True)]


async def test_durable_listener_without_inject_fails() -> None:
    async with KernelHarness() as h:
        fiber = await h.mount(listener_plugin("undeclared", DURABLE, lambda e: None, id="x"))
        assert fiber.state is State.FAILED
        assert "inject" in fiber.error


# ---------------------------------------------------------------- 开销
async def test_waterfall_overhead_is_small() -> None:
    async def passthrough(batch: Batch, next):
        return await next()

    async with KernelHarness() as h:
        for i in range(3):
            await h.mount(wf(f"p{i}", passthrough))
        payload = Batch((1,))
        rounds = 2000
        started = time.perf_counter()
        for _ in range(rounds):
            await h.events.waterfall(PIPE, payload, terminal=lambda b: b)
        per_dispatch = (time.perf_counter() - started) / rounds
    # 3 个监听器的一次分发；设计预算微秒级，CI 抖动下放宽到 1 毫秒
    assert per_dispatch < 0.001

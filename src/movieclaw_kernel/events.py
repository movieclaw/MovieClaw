"""事件总线（docs/design/plugin-kernel.md §4.7）。

三种分发模式，模式是契约的一部分，用错分发方法直接抛 ``TypeError``：

- ``EMIT``：只通知。发出方只做 ``put_nowait``，每个监听器一个有界队列、一个串行消费协程，
  满了丢新事件并计数——绝不反压业务；
- ``WATERFALL``：洋葱式中间件 ``handler(payload, next)``；
- ``BAIL``：依次询问，第一个返回非 ``None`` 的说了算。

监听器在隔离里执行：抛错、超时、返回值不合声明，都按「这个监听器不存在」处理；连续失败
自动熔断。载荷必须不可变（冻结 dataclass / 冻结 pydantic 模型 / 基本不可变类型），waterfall
监听器要改输入就构造新对象传给 ``next``。
"""

from __future__ import annotations

import asyncio
import dataclasses
import inspect
import itertools
import logging
import time
from collections.abc import Awaitable, Callable, Coroutine
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, Generic, Protocol, TypeVar

from movieclaw_kernel.contracts import Contract, ServiceKey, Stability
from movieclaw_kernel.observe import (
    MAX_CAUSE_DEPTH,
    Breaker,
    EntryStats,
    Origin,
    current_entry,
    current_origin,
)

P = TypeVar("P")
R = TypeVar("R")

logger = logging.getLogger("movieclaw_kernel.events")

_order = itertools.count()
_UNSET: Any = object()

_IMMUTABLE_BUILTINS = (type(None), str, int, float, bool, bytes, tuple, frozenset)


class Mode(StrEnum):
    EMIT = "emit"
    WATERFALL = "waterfall"
    BAIL = "bail"


class Delivery(StrEnum):
    LIVE = "live"
    """内存队列，至多一次，重启即丢。"""

    DURABLE = "durable"
    """业务事务内写入事件表、提交后投递、至少一次（第二阶段 A 由 ``DURABLE_EVENTS`` 提供）。"""


class CauseChainTooLong(RuntimeError):
    """因果链超过上限：插件之间经事件互相触发成环。"""


def _is_immutable_type(tp: type) -> bool:
    if tp in _IMMUTABLE_BUILTINS:
        return True
    if dataclasses.is_dataclass(tp):
        return bool(tp.__dataclass_params__.frozen)  # type: ignore[attr-defined]
    config = getattr(tp, "model_config", None)
    if isinstance(config, dict):
        return bool(config.get("frozen"))
    return False


class Event(Contract, Generic[P, R]):
    """事件契约。

    ``payload`` 是载荷类型（必须不可变），``result`` 是 waterfall / bail 的结果类型。
    """

    kind = "event"

    def __init__(
        self,
        name: str,
        mode: Mode,
        *,
        payload: type,
        result: type | None = None,
        delivery: Delivery = Delivery.LIVE,
        version: str = "1.0",
        stability: Stability = Stability.INTERNAL,
        doc: str = "",
        timeout: float | None = None,
        budget: float | None = None,
        queue_size: int = 1000,
    ) -> None:
        if not _is_immutable_type(payload):
            raise TypeError(
                f"事件 {name} 的载荷类型 {payload.__name__} 必须不可变（冻结 dataclass 等）"
            )
        if delivery is Delivery.DURABLE and mode is not Mode.EMIT:
            raise TypeError(f"事件 {name}：只有 EMIT 事件可以可靠投递")
        if delivery is Delivery.DURABLE and not callable(getattr(payload, "model_validate", None)):
            # 可靠事件要落库、重启后还原、将来跨进程：载荷须是冻结的 pydantic 模型
            raise TypeError(f"可靠事件 {name} 的载荷 {payload.__name__} 须是冻结的 pydantic 模型")
        super().__init__(name, version=version, stability=stability, doc=doc)
        self.mode = mode
        self.payload = payload
        self.result = result
        self.delivery = delivery
        self.timeout = timeout
        """单个监听器的时限（秒），不含它调用 ``next`` 后下游的耗时。"""
        self.budget = budget
        """整条 waterfall / bail 链的时限：超出后剩余监听器被跳过，直接走默认实现。"""
        self.queue_size = queue_size


class DurableEventStore(Protocol):
    """可靠事件存储（第二阶段 A 实现）：监听器订阅后跨重启续投。"""

    def subscribe(
        self,
        event: Event[Any, Any],
        *,
        entry_id: str,
        listener_id: str,
        handler: Callable[..., Any],
    ) -> Callable[[], Any]: ...


DURABLE_EVENTS: ServiceKey[DurableEventStore] = ServiceKey(
    "kernel/durable-events",
    stability=Stability.EXPERIMENTAL,
    doc="可靠事件的存储与投递：事务内写入、提交后投递、至少一次",
)


@dataclass(eq=False)
class Listener:
    event: Event[Any, Any]
    handler: Callable[..., Any]
    entry_id: str
    listener_id: str | None
    priority: int
    stats: EntryStats
    order: int = field(default_factory=lambda: next(_order))
    breaker: Breaker = field(default_factory=Breaker)
    queue: asyncio.Queue[tuple[Any, Origin]] | None = None
    drop_logged_at: float = float("-inf")

    @property
    def label(self) -> str:
        return f"{self.entry_id}:{self.listener_id or self.order}"


@dataclass
class _NextState:
    called: bool = False
    done: bool = False
    result: Any = None
    downstream_exc: BaseException | None = None
    paused: float = 0.0


Spawn = Callable[[Coroutine[Any, Any, None], str], asyncio.Task[None]]


class EventBus:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._listeners: dict[str, list[Listener]] = {}
        self._loop: asyncio.AbstractEventLoop | None = None

    # ------------------------------------------------------------------ 注册
    def add(
        self,
        event: Event[Any, Any],
        handler: Callable[..., Any],
        *,
        entry_id: str,
        listener_id: str | None,
        priority: int,
        stats: EntryStats,
        spawn: Spawn,
    ) -> Callable[[], None]:
        if event.delivery is Delivery.DURABLE:
            raise TypeError(f"可靠事件 {event.name} 须经 DURABLE_EVENTS 订阅")
        if event.mode is Mode.WATERFALL and not inspect.iscoroutinefunction(handler):
            raise TypeError(f"waterfall 事件 {event.name} 的监听器必须是 async 函数")
        listener = Listener(event, handler, entry_id, listener_id, priority, stats)
        if event.mode is Mode.EMIT:
            listener.queue = asyncio.Queue(maxsize=event.queue_size)
            spawn(
                self._consume(listener),
                f"event:{event.name}:{listener.listener_id or listener.order}",
            )
        self._listeners.setdefault(event.name, []).append(listener)

        def remove() -> None:
            items = self._listeners.get(event.name, [])
            if listener in items:
                items.remove(listener)

        return remove

    def listeners(self, event: Event[Any, Any]) -> list[Listener]:
        items = self._listeners.get(event.name, [])
        return sorted(items, key=lambda item: (-item.priority, item.order))

    def owned_by(self, entry_id: str) -> list[Listener]:
        return [
            item
            for items in self._listeners.values()
            for item in items
            if item.entry_id == entry_id
        ]

    def bind_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop

    # ------------------------------------------------------------------ 公共校验
    def _check(self, event: Event[Any, Any], mode: Mode, payload: Any) -> Origin:
        if event.mode is not mode:
            raise TypeError(
                f"事件 {event.name} 是 {event.mode.value} 模式，不能用 {mode.value} 分发"
            )
        if not isinstance(payload, event.payload):
            raise TypeError(
                f"事件 {event.name} 的载荷须是 {event.payload.__name__}，"
                f"收到 {type(payload).__name__}"
            )
        origin = current_origin.get()
        if len(origin.chain) >= MAX_CAUSE_DEPTH:
            raise CauseChainTooLong(
                f"事件 {event.name} 的因果链已达 {len(origin.chain)} 层：{' → '.join(origin.chain)}"
            )
        return origin

    def _record_failure(self, listener: Listener, exc: BaseException) -> None:
        stats = listener.stats
        if isinstance(exc, TimeoutError):
            stats.timeouts += 1
            stats.last_error = f"{listener.event.name} 超时"
            logger.warning(
                "事件 %s 的监听器 %s 超时（已跳过）", listener.event.name, listener.label
            )
        else:
            stats.failures += 1
            stats.last_error = f"{type(exc).__name__}: {exc}"
            logger.warning(
                "事件 %s 的监听器 %s 出错（已跳过）",
                listener.event.name,
                listener.label,
                exc_info=exc,
            )
        if listener.breaker.failure(self._clock()):
            logger.warning(
                "事件 %s 的监听器 %s 连续出错，熔断至 %.0f 秒后",
                listener.event.name,
                listener.label,
                listener.breaker.open_until - self._clock() if listener.breaker.open_until else 0,
            )

    def _attribute(self, listener: Listener, origin: Origin) -> tuple[Any, Any]:
        return (
            current_entry.set(listener.entry_id),
            current_origin.set(origin.caused_by(listener.event.name, entry_id=listener.entry_id)),
        )

    @staticmethod
    def _release(tokens: tuple[Any, Any]) -> None:
        current_origin.reset(tokens[1])
        current_entry.reset(tokens[0])

    # ------------------------------------------------------------------ EMIT
    def emit(self, event: Event[P, Any], payload: P) -> None:
        if event.delivery is Delivery.DURABLE:
            raise TypeError(f"可靠事件 {event.name} 须在业务事务内经 DURABLE_EVENTS 写入")
        origin = self._check(event, Mode.EMIT, payload)
        for listener in self._listeners.get(event.name, []):
            assert listener.queue is not None
            try:
                listener.queue.put_nowait((payload, origin))
            except asyncio.QueueFull:
                listener.stats.dropped += 1
                now = self._clock()
                # 积压时每分钟只记一条，别让日志反过来拖慢业务
                if now - listener.drop_logged_at >= 60:
                    listener.drop_logged_at = now
                    logger.warning(
                        "事件 %s 的监听器 %s 积压已满（%d），丢弃新事件",
                        event.name,
                        listener.label,
                        event.queue_size,
                    )

    def emit_threadsafe(self, event: Event[P, Any], payload: P) -> None:
        """从非事件循环线程（如 watchdog 观察者线程）发事件。"""
        if self._loop is None:
            raise RuntimeError("事件总线尚未绑定事件循环")
        self._loop.call_soon_threadsafe(self.emit, event, payload)

    async def _consume(self, listener: Listener) -> None:
        assert listener.queue is not None
        while True:
            payload, origin = await listener.queue.get()
            if not listener.breaker.allow(self._clock()):
                listener.stats.dropped += 1
                listener.queue.task_done()
                continue
            tokens = self._attribute(listener, origin)
            started = time.perf_counter()
            try:
                async with asyncio.timeout(listener.event.timeout):
                    result = listener.handler(payload)
                    if inspect.isawaitable(result):
                        await result
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 -- 监听器出错不影响其他监听器与发出方
                self._record_failure(listener, exc)
            else:
                listener.breaker.success()
                listener.stats.record_handler((time.perf_counter() - started) * 1000)
            finally:
                self._release(tokens)
                listener.queue.task_done()

    async def drain(self) -> None:
        """等所有 EMIT 监听器把已入队的事件处理完（测试与有序关闭用）。"""
        queues = [
            item.queue
            for items in self._listeners.values()
            for item in items
            if item.queue is not None
        ]
        for queue in queues:
            await queue.join()

    # ------------------------------------------------------------------ WATERFALL
    async def waterfall(
        self,
        event: Event[P, R],
        payload: P,
        *,
        terminal: Callable[[P], R | Awaitable[R]],
    ) -> R:
        origin = self._check(event, Mode.WATERFALL, payload)
        listeners = self.listeners(event)
        loop = asyncio.get_running_loop()
        deadline = loop.time() + event.budget if event.budget is not None else None

        async def step(index: int, value: Any) -> Any:
            while index < len(listeners):
                if deadline is not None and loop.time() >= deadline:
                    break
                listener = listeners[index]
                if listener.breaker.allow(self._clock()):
                    return await self._run_layer(listener, index, value, step, origin)
                index += 1
            result = terminal(value)
            if inspect.isawaitable(result):
                result = await result
            return result

        return await step(0, payload)

    async def _run_layer(
        self,
        listener: Listener,
        index: int,
        value: Any,
        step: Callable[[int, Any], Awaitable[Any]],
        origin: Origin,
    ) -> Any:
        event = listener.event
        loop = asyncio.get_running_loop()
        state = _NextState()
        holder: dict[str, asyncio.Timeout] = {}

        async def next_(new_value: Any = _UNSET) -> Any:
            if state.called:
                raise RuntimeError("next() 只能调用一次")
            forwarded = value if new_value is _UNSET else new_value
            if not isinstance(forwarded, event.payload):
                raise TypeError(
                    f"传给 next() 的载荷须是 {event.payload.__name__}，"
                    f"收到 {type(forwarded).__name__}"
                )
            state.called = True
            cm = holder["cm"]
            remaining: float | None = None
            # 下游耗时不算本监听器的：进入 next 时暂停计时，出来再续上
            if cm.when() is not None:
                remaining = cm.when() - loop.time()
                cm.reschedule(None)
            entered = time.perf_counter()
            try:
                result = await step(index + 1, forwarded)
            except BaseException as exc:
                state.downstream_exc = exc
                raise
            finally:
                state.paused += time.perf_counter() - entered
                if remaining is not None:
                    cm.reschedule(loop.time() + max(remaining, 0.0))
            state.done = True
            state.result = result
            return result

        tokens = self._attribute(listener, origin)
        started = time.perf_counter()
        try:
            try:
                async with asyncio.timeout(event.timeout) as cm:
                    holder["cm"] = cm
                    result = await listener.handler(value, next_)
            finally:
                self._release(tokens)
            if event.result is not None and not isinstance(result, event.result):
                raise TypeError(
                    f"监听器返回值须是 {event.result.__name__}，收到 {type(result).__name__}"
                )
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            if state.downstream_exc is not None:
                # 下游（含核心默认实现）的错误不是本监听器的，原样抛给调用方
                raise state.downstream_exc from None
            self._record_failure(listener, exc)
            if state.done:
                return state.result
            return await step(index + 1, value)
        listener.breaker.success()
        listener.stats.record_handler((time.perf_counter() - started - state.paused) * 1000)
        return result

    # ------------------------------------------------------------------ BAIL
    async def bail(self, event: Event[P, R], payload: P) -> R | None:
        origin = self._check(event, Mode.BAIL, payload)
        loop = asyncio.get_running_loop()
        deadline = loop.time() + event.budget if event.budget is not None else None
        for listener in self.listeners(event):
            if deadline is not None and loop.time() >= deadline:
                break
            if not listener.breaker.allow(self._clock()):
                continue
            tokens = self._attribute(listener, origin)
            started = time.perf_counter()
            try:
                async with asyncio.timeout(event.timeout):
                    result = listener.handler(payload)
                    if inspect.isawaitable(result):
                        result = await result
                if (
                    result is not None
                    and event.result is not None
                    and not isinstance(result, event.result)
                ):
                    raise TypeError(
                        f"监听器返回值须是 {event.result.__name__}，收到 {type(result).__name__}"
                    )
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                self._record_failure(listener, exc)
                continue
            finally:
                self._release(tokens)
            listener.breaker.success()
            listener.stats.record_handler((time.perf_counter() - started) * 1000)
            if result is not None:
                return result
        return None

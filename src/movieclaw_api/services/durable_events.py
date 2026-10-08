"""可靠事件：写入（outbox）与投递（docs/design/plugin-phase2a.md §2）。

写入方（业务代码）::

    await durable_events.record(session, LIBRARY_ITEM_DELETED, payload)
    await session.commit()          # 事件随这次提交成立；回滚即不存在

订阅方（插件）::

    @plugin("acme.cascade", inject=(DURABLE_EVENTS,))
    async def apply(ctx):
        ctx.on(LIBRARY_ITEM_DELETED, handler, id="cascade")   # 稳定 id 决定跨重启的进度

- **零开销**：某个事件名没有任何消费者（``event_consumer`` 行，含暂时停用的插件）时，``record``
  只做一次内存集合查找就返回，不写库。消费者名单每个进程只从库里读一次，之后随订阅更新。
- **至少一次、按消费者保序**：每个消费者一个协程，按 ``seq`` 顺序处理；失败退避重试，
  超过次数写死信并前进，不让一个坏事件堵死后续。消费方以 ``ctx.delivery.event_id`` 去重。
- **唤醒**：写入时给会话登记一次 ``after_commit`` 钩子，提交后立刻唤醒投递；另有轮询兜底。
"""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import logging
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Any

from pydantic import ValidationError
from sqlalchemy import delete, event, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_db.engine import Database
from movieclaw_db.models import DomainEvent, EventConsumer, EventDeadLetter, utcnow
from movieclaw_events import new_ulid
from movieclaw_kernel import Delivery, DeliveryInfo, Event, Origin, current_delivery, current_origin
from movieclaw_kernel.observe import MAX_CAUSE_DEPTH, current_entry

logger = logging.getLogger("movieclaw_api.durable_events")

#: 第 n 次失败后等多久再试；用完即进死信（共 1 + len 次尝试）
RETRY_DELAYS: tuple[float, ...] = (5.0, 30.0, 120.0, 600.0, 1800.0)
HANDLER_TIMEOUT = 60.0
#: 提交钩子之外的兜底轮询（钩子漏触发、事件由别的进程写入）
POLL_INTERVAL = 5.0
BATCH_SIZE = 50
EVENT_RETENTION = timedelta(days=14)
CONSUMER_RETENTION = timedelta(days=30)
DEAD_LETTER_RETENTION = timedelta(days=30)
HOUSEKEEPING_INTERVAL = 3600.0

# ---------------------------------------------------------------------- 写入

#: 有消费者的事件名；``None`` = 本进程还没从库里读过
_subscribed: set[str] | None = None
_wakers: set[Callable[[], None]] = set()


async def _subscribed_names(session: AsyncSession) -> set[str]:
    global _subscribed
    if _subscribed is None:
        rows = await session.execute(select(EventConsumer.event_name).distinct())
        _subscribed = set(rows.scalars())
    return _subscribed


def _note_subscribed(name: str) -> None:
    if _subscribed is not None:
        _subscribed.add(name)


def reset_subscribed() -> None:
    """丢掉内存名单，下次写入时从库里重读。"""
    global _subscribed
    _subscribed = None


def reset_state() -> None:
    """测试用：清空进程级缓存（换了数据库之后名单要重新读）。"""
    reset_subscribed()
    _wakers.clear()


def _wake_all() -> None:
    for wake in list(_wakers):
        try:
            wake()
        except Exception:  # noqa: BLE001 -- 唤醒失败只会退化成轮询
            logger.debug("唤醒可靠事件投递失败", exc_info=True)


def _arm_wake(session: AsyncSession) -> None:
    sync = session.sync_session
    if sync.info.get("durable_events_armed"):
        return
    sync.info["durable_events_armed"] = True

    def after_commit(s: Any) -> None:
        s.info.pop("durable_events_armed", None)
        _wake_all()

    # 只登记一次：回滚后挂着的钩子会在下一次提交时触发，多唤醒一次无害
    event.listen(sync, "after_commit", after_commit, once=True)


async def record(session: AsyncSession, evt: Event[Any, Any], payload: Any) -> bool:
    """在业务会话里写一条可靠事件（不提交）。返回是否写入（没有消费者时不写）。"""
    if evt.delivery is not Delivery.DURABLE:
        raise TypeError(f"事件 {evt.name} 不是可靠事件")
    if not isinstance(payload, evt.payload):
        raise TypeError(
            f"事件 {evt.name} 的载荷须是 {evt.payload.__name__}，收到 {type(payload).__name__}"
        )
    if evt.name not in await _subscribed_names(session):
        return False
    origin = current_origin.get()
    if len(origin.chain) >= MAX_CAUSE_DEPTH:
        # 插件之间经事件互相触发成环：不再产生新事件，但不能因此让业务操作失败
        logger.warning(
            "事件 %s 的因果链已达 %d 层（%s），不再写入",
            evt.name,
            len(origin.chain),
            " → ".join(origin.chain),
        )
        return False
    session.add(
        DomainEvent(
            id=new_ulid(),
            name=evt.name,
            version=str(evt.version),
            payload=payload.model_dump(mode="json"),
            origin_kind=origin.kind,
            origin_id=origin.id,
            chain=list(origin.chain),
        )
    )
    _arm_wake(session)
    return True


# ---------------------------------------------------------------------- 投递


class ReplayError(Exception):
    """重放失败：消费者不在运行，或监听器再次出错。"""


@dataclass(eq=False)
class _Consumer:
    consumer_id: str
    event: Event[Any, Any]
    entry_id: str
    handler: Callable[..., Any]
    task: asyncio.Task[None] | None = None
    delivering: bool = field(default=False)


class DurableEvents:
    """``DURABLE_EVENTS`` 的实现：订阅登记、每个消费者一个投递协程、死信与诊断。"""

    def __init__(self, db: Database) -> None:
        self._db = db
        self._consumers: dict[str, _Consumer] = {}
        self._signal = asyncio.Event()
        self._tasks: set[asyncio.Task[Any]] = set()
        _wakers.add(self.wake)
        # 名单跟着数据库走：换库（测试、重建）后要重新从库里读
        reset_subscribed()

    # ------------------------------------------------------------------ 生命周期
    def wake(self) -> None:
        signal, self._signal = self._signal, asyncio.Event()
        signal.set()

    def _start(self, coro: Any, name: str) -> asyncio.Task[Any]:
        task = asyncio.get_running_loop().create_task(coro, name=name)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    async def close(self) -> None:
        _wakers.discard(self.wake)
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        self._consumers.clear()

    def start_housekeeping(self) -> None:
        self._start(self._housekeeping_loop(), "durable-events:housekeeping")

    # ------------------------------------------------------------------ 订阅
    def subscribe(
        self,
        event: Event[Any, Any],
        *,
        entry_id: str,
        listener_id: str,
        handler: Callable[..., Any],
    ) -> Callable[[], Any]:
        consumer_id = f"{entry_id}:{listener_id}"
        if consumer_id in self._consumers:
            raise ValueError(f"可靠监听器 id 重复：{consumer_id}")
        consumer = _Consumer(consumer_id, event, entry_id, handler)
        self._consumers[consumer_id] = consumer
        consumer.task = self._start(self._run(consumer), f"durable-events:{consumer_id}")

        async def unsubscribe() -> None:
            self._consumers.pop(consumer_id, None)
            task = consumer.task
            if task is not None and not task.done():
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await task

        return unsubscribe

    async def _register(self, consumer: _Consumer) -> None:
        async with self._db.session() as session:
            row = await session.get(EventConsumer, consumer.consumer_id)
            if row is None:
                # 新消费者从「现在」开始，不回放订阅之前的历史
                latest = await session.scalar(select(func.max(DomainEvent.seq)))
                row = EventConsumer(
                    consumer_id=consumer.consumer_id,
                    event_name=consumer.event.name,
                    cursor=latest or 0,
                )
                session.add(row)
            else:
                row.event_name = consumer.event.name
                row.last_seen_at = utcnow()
            await session.commit()
        _note_subscribed(consumer.event.name)

    async def _run(self, consumer: _Consumer) -> None:
        await self._register(consumer)
        while True:
            signal = self._signal
            progressed = await self._drain(consumer)
            if progressed:
                continue
            with contextlib.suppress(TimeoutError):
                async with asyncio.timeout(POLL_INTERVAL):
                    await signal.wait()

    async def _drain(self, consumer: _Consumer) -> bool:
        """处理一批积压；返回是否有事可做（有就马上再来一轮）。

        读积压、调监听器、写进度分在三段：监听器常常自己写库，读事务若跨过它再写，
        SQLite WAL 会因快照过期拒绝升级为写事务；重试等待也不能占着读事务（拖住检查点）。
        """
        async with self._db.session() as session:
            state = await session.get(EventConsumer, consumer.consumer_id)
            if state is None:
                return False
            attempts, next_at = state.attempts, state.next_attempt_at
            rows = (
                (
                    await session.execute(
                        select(DomainEvent)
                        .where(
                            DomainEvent.name == consumer.event.name,
                            DomainEvent.seq > state.cursor,
                        )
                        .order_by(DomainEvent.seq)
                        .limit(BATCH_SIZE)
                    )
                )
                .scalars()
                .all()
            )
        if not rows:
            return False
        for row in rows:
            if next_at is not None:
                wait = (next_at - utcnow()).total_seconds()
                if wait > 0:
                    await asyncio.sleep(wait)
                next_at = None
            attempt = attempts + 1
            error, permanent = await self._deliver(consumer, row, attempt)
            dead = error is not None and (permanent or attempt > len(RETRY_DELAYS))
            async with self._db.session() as session:
                state = await session.get(EventConsumer, consumer.consumer_id)
                if state is None:
                    return False
                if error is not None and not dead:
                    state.attempts = attempt
                    state.last_error = error
                    state.next_attempt_at = utcnow() + timedelta(seconds=RETRY_DELAYS[attempt - 1])
                    await session.commit()
                    return True
                if dead:
                    session.add(
                        EventDeadLetter(
                            consumer_id=consumer.consumer_id,
                            event_seq=row.seq or 0,
                            event_id=row.id,
                            event_name=row.name,
                            error=error or "",
                            attempts=attempt,
                        )
                    )
                    logger.warning(
                        "可靠事件 %s（%s）投递给 %s 失败 %d 次，已转入死信：%s",
                        row.name,
                        row.id,
                        consumer.consumer_id,
                        attempt,
                        error,
                    )
                state.cursor = row.seq or state.cursor
                state.attempts = 0
                state.next_attempt_at = None
                state.last_error = error if dead else None
                await session.commit()
            attempts = 0
        return True

    async def _deliver(
        self, consumer: _Consumer, row: DomainEvent, attempt: int
    ) -> tuple[str | None, bool]:
        """交给监听器一次；返回 (错误, 是否不必重试)。"""
        try:
            payload = consumer.event.payload.model_validate(row.payload)
        except ValidationError as exc:
            # 载荷与当前契约对不上，重试也不会好：直接进死信
            return f"载荷校验失败：{exc}", True
        origin = Origin(kind=row.origin_kind, id=row.origin_id, chain=tuple(row.chain or ()))
        info = DeliveryInfo(
            event_id=row.id,
            name=row.name,
            occurred_at=row.occurred_at.isoformat() + "+00:00",
            origin=origin,
            attempt=attempt,
        )
        tokens = (
            current_entry.set(consumer.entry_id),
            current_origin.set(origin.caused_by(row.name, entry_id=consumer.entry_id)),
            current_delivery.set(info),
        )
        consumer.delivering = True
        try:
            async with asyncio.timeout(HANDLER_TIMEOUT):
                result = consumer.handler(payload)
                if inspect.isawaitable(result):
                    await result
        except asyncio.CancelledError:
            raise
        except TimeoutError:
            return f"处理超时（{HANDLER_TIMEOUT:.0f} 秒）", False
        except Exception as exc:  # noqa: BLE001 -- 监听器出错只影响它自己的进度
            logger.warning(
                "可靠事件 %s（%s）的监听器 %s 第 %d 次处理出错",
                row.name,
                row.id,
                consumer.consumer_id,
                attempt,
                exc_info=exc,
            )
            return f"{type(exc).__name__}: {exc}"[:2000], False
        finally:
            consumer.delivering = False
            current_delivery.reset(tokens[2])
            current_origin.reset(tokens[1])
            current_entry.reset(tokens[0])
        return None, False

    # ------------------------------------------------------------------ 死信
    async def replay(self, letter_id: int) -> None:
        async with self._db.session() as session:
            letter = await session.get(EventDeadLetter, letter_id)
            if letter is None:
                raise LookupError(f"死信 {letter_id} 不存在")
            if letter.resolved_at is not None:
                raise ReplayError("这条死信已经处理过")
            consumer = self._consumers.get(letter.consumer_id)
            if consumer is None:
                raise ReplayError("对应的插件当前没有运行，启用后再重放")
            row = await session.scalar(
                select(DomainEvent).where(DomainEvent.seq == letter.event_seq)
            )
            if row is None:
                raise ReplayError("事件已过保留期被清理，无法重放")
            attempt = letter.attempts + 1
        error, _ = await self._deliver(consumer, row, attempt)
        async with self._db.session() as session:
            letter = await session.get(EventDeadLetter, letter_id)
            if letter is None:
                raise LookupError(f"死信 {letter_id} 不存在")
            letter.attempts = attempt
            if error is None:
                letter.resolved_at = utcnow()
                letter.resolution = "replayed"
            else:
                letter.error = error
            await session.commit()
        if error is not None:
            raise ReplayError(error)

    async def dismiss(self, letter_id: int) -> None:
        async with self._db.session() as session:
            letter = await session.get(EventDeadLetter, letter_id)
            if letter is None:
                raise LookupError(f"死信 {letter_id} 不存在")
            if letter.resolved_at is None:
                letter.resolved_at = utcnow()
                letter.resolution = "dismissed"
                await session.commit()

    # ------------------------------------------------------------------ 诊断
    async def describe(self) -> dict[str, Any]:
        async with self._db.session() as session:
            consumers = (await session.execute(select(EventConsumer))).scalars().all()
            items = []
            for row in consumers:
                backlog = await session.scalar(
                    select(func.count())
                    .select_from(DomainEvent)
                    .where(DomainEvent.name == row.event_name, DomainEvent.seq > row.cursor)
                )
                items.append(
                    {
                        "consumer_id": row.consumer_id,
                        "event": row.event_name,
                        "active": row.consumer_id in self._consumers,
                        "backlog": backlog or 0,
                        "attempts": row.attempts,
                        "next_attempt_at": row.next_attempt_at,
                        "last_error": row.last_error,
                    }
                )
            letters = (
                (
                    await session.execute(
                        select(EventDeadLetter)
                        .where(EventDeadLetter.resolved_at.is_(None))
                        .order_by(EventDeadLetter.id.desc())
                        .limit(50)
                    )
                )
                .scalars()
                .all()
            )
        return {
            "consumers": items,
            "dead_letters": [
                {
                    "id": letter.id,
                    "consumer_id": letter.consumer_id,
                    "event": letter.event_name,
                    "event_id": letter.event_id,
                    "error": letter.error,
                    "attempts": letter.attempts,
                    "created_at": letter.created_at,
                }
                for letter in letters
            ],
        }

    # ------------------------------------------------------------------ 清理
    async def housekeeping(self) -> None:
        now = utcnow()
        async with self._db.session() as session:
            if self._consumers:
                await session.execute(
                    update(EventConsumer)
                    .where(EventConsumer.consumer_id.in_(list(self._consumers)))
                    .values(last_seen_at=now)
                )
            pending = select(EventDeadLetter.event_seq).where(EventDeadLetter.resolved_at.is_(None))
            await session.execute(
                delete(DomainEvent).where(
                    DomainEvent.occurred_at < now - EVENT_RETENTION,
                    DomainEvent.seq.not_in(pending),
                )
            )
            await session.execute(
                delete(EventConsumer).where(EventConsumer.last_seen_at < now - CONSUMER_RETENTION)
            )
            await session.execute(
                delete(EventDeadLetter).where(
                    EventDeadLetter.resolved_at < now - DEAD_LETTER_RETENTION
                )
            )
            await session.commit()
        reset_subscribed()  # 消费者可能被清掉了，下次写入时重读名单

    async def _housekeeping_loop(self) -> None:
        while True:
            try:
                await self.housekeeping()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 -- 清理失败下一轮再来
                logger.warning("可靠事件清理失败", exc_info=True)
            await asyncio.sleep(HOUSEKEEPING_INTERVAL)

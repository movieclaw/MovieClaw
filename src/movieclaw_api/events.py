"""事件的唯一产生入口（docs/design/domain-events.md §4）。

业务里每件「发生了的事」只在这里发一次，通知、Webhook、插件都是订阅方::

    await events.publish(session, SUBSCRIPTION_FULFILLED, lambda: SubscriptionFulfilled(...))
    await session.commit()          # 随这次提交成立；回滚即作废

    # 没有业务事务时（检测器、定时检查）
    await events.publish_now(SYSTEM_UPDATE_AVAILABLE, lambda: UpdateAvailable(...))

- **没人听就什么都不做**：既没有可靠消费者、也没有实时监听器时直接返回，``build`` 不调用；
- **提交才发**：实时投递挂在会话上，``after_commit`` 时按顺序发出，``after_rollback`` 时丢掉；
  可靠投递随同一次提交写进事件表（``services/durable_events.py``）；
- 同一个事件的可靠投递与实时投递共用一个事件 id、发生时间、发起方；
- **不抛错**：``build`` 出错只记日志、事件丢掉，业务照常提交；
- 放在「记录这件事」的那次提交之前（仓储层会中途提交，``add_activity`` 自己就 commit）。

业务代码拿不到内核总线，由内置插件 ``core.registries`` 启动时 ``bind_bus``；没绑（命令行、单测）
时只有可靠投递。
"""

from __future__ import annotations

import inspect
import logging
from collections.abc import Callable
from datetime import datetime
from typing import Any, TypeVar

from sqlalchemy import event as sa_event
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_events import new_ulid
from movieclaw_kernel import DeliveryInfo, Event, Origin, current_origin
from movieclaw_kernel.events import EventBus

logger = logging.getLogger("movieclaw_api.events")

P = TypeVar("P")

_bus: EventBus | None = None

#: 会话上挂着、等提交才发的实时事件
_PENDING = "movieclaw_events_pending"
_ARMED = "movieclaw_events_armed"


def bind_bus(bus: EventBus) -> None:
    global _bus
    _bus = bus


def unbind_bus(bus: EventBus) -> None:
    global _bus
    if _bus is bus:
        _bus = None


def bus() -> EventBus | None:
    return _bus


def listening(event: Event[Any, Any]) -> bool:
    """有没有实时监听器（零开销判断的一半；另一半是可靠消费者名单）。"""
    return _bus is not None and bool(_bus.listeners(event))


async def wanted(session: AsyncSession, event: Event[Any, Any]) -> bool:
    """有没有人订这个事件（实时或可靠）：产生点要先拍快照（删除前）时用它省掉没人要的查询。"""
    return listening(event) or await _durable_wanted(session, event)


async def _durable_wanted(session: AsyncSession, event: Event[Any, Any]) -> bool:
    if not event.durable:
        return False
    from movieclaw_api.services import durable_events

    return await durable_events.wanted(session, event)


def _utc_text(value: datetime) -> str:
    return value.isoformat() + "+00:00"


async def publish(
    session: AsyncSession,
    event: Event[P, Any],
    build: Callable[[], Any],
    *,
    occurred_at: datetime | None = None,
) -> None:
    """在业务事务里发一个事件，随调用方下一次提交成立。

    ``build`` 可同步可异步，返回 ``None`` 表示不发。``occurred_at``（不带时区的 UTC）
    给补传的事件用：离线观看记录回到服务器时，事件时间是它真正发生的时间。
    """
    try:
        live = listening(event)
        durable = await _durable_wanted(session, event)
        if not live and not durable:
            return
        payload = build()
        if inspect.isawaitable(payload):
            payload = await payload
        if payload is None:
            return
        from movieclaw_db.models import utcnow

        event_id = new_ulid()
        occurred_at = occurred_at or utcnow()
        origin = current_origin.get()
        if durable:
            from movieclaw_api.services import durable_events

            await durable_events.record(
                session, event, payload, event_id=event_id, occurred_at=occurred_at, origin=origin
            )
        if live:
            info = DeliveryInfo(
                event_id=event_id,
                name=event.name,
                occurred_at=_utc_text(occurred_at),
                origin=origin,
            )
            _stage(session, event, payload, origin, info)
    except Exception:  # noqa: BLE001 -- 事件出任何错都不能打断业务
        logger.exception("产生事件 %s 失败（已忽略）", event.name)


async def publish_now(event: Event[P, Any], build: Callable[[], Any]) -> None:
    """发一个不在业务事务里的事件（检测器、定时检查）：有可靠消费者时自己开会话写。"""
    try:
        from movieclaw_api.services import durable_events

        cached = durable_events.cached_names()
        maybe_durable = event.durable and (cached is None or event.name in cached)
        if not maybe_durable and not listening(event):
            return
        from movieclaw_db.engine import get_database

        async with get_database().session() as session:
            await publish(session, event, build)
            await session.commit()
    except Exception:  # noqa: BLE001
        logger.exception("产生事件 %s 失败（已忽略）", event.name)


def _stage(
    session: AsyncSession,
    event: Event[Any, Any],
    payload: Any,
    origin: Origin,
    info: DeliveryInfo,
) -> None:
    sync = session.sync_session
    sync.info.setdefault(_PENDING, []).append((event, payload, origin, info))
    if sync.info.get(_ARMED):
        return
    sync.info[_ARMED] = True

    def after_commit(s: Any) -> None:
        pending = s.info.pop(_PENDING, None) or []
        bus = _bus
        if bus is None:
            return
        for evt, value, from_origin, delivery in pending:
            try:
                bus.emit(evt, value, origin=from_origin, info=delivery)
            except Exception:  # noqa: BLE001
                logger.exception("发出事件 %s 失败（已忽略）", evt.name)

    def after_rollback(s: Any) -> None:
        s.info.pop(_PENDING, None)

    sa_event.listen(sync, "after_commit", after_commit)
    sa_event.listen(sync, "after_rollback", after_rollback)


async def drain() -> None:
    """等已发出的实时事件都被监听器处理完（测试用）。"""
    if _bus is not None:
        await _bus.drain()

"""使用提示状态的写入（docs/design/tips.md）：``/tips`` 接口与服务端代记共用。

写入一律原子 upsert：同一个人在手机和电视上同时上报，计数不丢。
"""

from __future__ import annotations

from sqlalchemy import func
from sqlalchemy.dialects.sqlite import insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models import TipEvent, TipRecord, utcnow


async def load_record(session: AsyncSession, owner: int, tip_id: str) -> TipRecord | None:
    return (
        await session.execute(
            select(TipRecord)
            .where(TipRecord.member_id == owner, TipRecord.tip_id == tip_id)
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()


async def donate(session: AsyncSession, owner: int, event_id: str) -> TipEvent:
    """记一次事件（计数 +1），返回记完的那一行。"""
    now = utcnow()
    await session.execute(
        insert(TipEvent)
        .values(
            member_id=owner,
            event_id=event_id,
            count=1,
            first_at=now,
            last_at=now,
            created_at=now,
            updated_at=now,
        )
        .on_conflict_do_update(
            index_elements=["member_id", "event_id"],
            set_={"count": TipEvent.count + 1, "last_at": now, "updated_at": now},
        )
    )
    await session.commit()
    return (
        await session.execute(
            select(TipEvent)
            .where(TipEvent.member_id == owner, TipEvent.event_id == event_id)
            .execution_options(populate_existing=True)
        )
    ).scalar_one()


async def record_display(session: AsyncSession, owner: int, tip_id: str) -> TipRecord:
    """记一次展示（展示次数 +1）。"""
    now = utcnow()
    await session.execute(
        insert(TipRecord)
        .values(
            member_id=owner,
            tip_id=tip_id,
            display_count=1,
            first_displayed_at=now,
            last_displayed_at=now,
            created_at=now,
            updated_at=now,
        )
        .on_conflict_do_update(
            index_elements=["member_id", "tip_id"],
            set_={
                "display_count": TipRecord.display_count + 1,
                "first_displayed_at": func.coalesce(TipRecord.first_displayed_at, now),
                "last_displayed_at": now,
                "updated_at": now,
            },
        )
    )
    await session.commit()
    record = await load_record(session, owner, tip_id)
    assert record is not None
    return record


async def invalidate(session: AsyncSession, owner: int, tip_id: str, reason: str) -> TipRecord:
    """作废一条提示；已作废的保留第一次的时间与原因。"""
    now = utcnow()
    await session.execute(
        insert(TipRecord)
        .values(
            member_id=owner,
            tip_id=tip_id,
            display_count=0,
            invalidated_at=now,
            invalidated_reason=reason,
            created_at=now,
            updated_at=now,
        )
        .on_conflict_do_update(
            index_elements=["member_id", "tip_id"],
            set_={"invalidated_at": now, "invalidated_reason": reason, "updated_at": now},
            where=TipRecord.invalidated_at.is_(None),
        )
    )
    await session.commit()
    record = await load_record(session, owner, tip_id)
    assert record is not None
    return record

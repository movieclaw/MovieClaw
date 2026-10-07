from __future__ import annotations

import asyncio
import logging
from datetime import timedelta

from pydantic import TypeAdapter
from sqlalchemy import update
from sqlmodel import select

from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    DownloadAttemptStatus,
    MediaItem,
    Subscription,
    SubscriptionDownloadAttempt,
    WantedItem,
    utcnow,
)
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_matcher import RuleVerdict, TorrentCandidate
from movieclaw_scheduler import register_task

logger = logging.getLogger(__name__)
_lock = asyncio.Lock()


async def recover_submissions(session, *, now=None):
    from movieclaw_api.services.subscription.dispatch import dispatch

    now = now or utcnow()
    intents = (
        (
            await session.execute(
                select(SubscriptionDownloadAttempt)
                .where(
                    SubscriptionDownloadAttempt.status == DownloadAttemptStatus.SUBMITTING,
                    SubscriptionDownloadAttempt.updated_at <= now - timedelta(seconds=60),
                )
                .limit(50)
            )
        )
        .scalars()
        .all()
    )
    for intent in intents:
        intent_id = intent.id
        payload = intent.submission
        if not payload:
            continue
        subscription = await session.get(Subscription, intent.subscription_id)
        if subscription is None:
            continue
        rows = (
            (
                await session.execute(
                    select(WantedItem).where(
                        WantedItem.id.in_(payload["wanted_ids"] + payload["upgrade_ids"])
                    )
                )
            )
            .scalars()
            .all()
        )
        if not rows:
            continue
        leased = await session.execute(
            update(SubscriptionDownloadAttempt)
            .where(
                SubscriptionDownloadAttempt.id == intent.id,
                SubscriptionDownloadAttempt.status == DownloadAttemptStatus.SUBMITTING,
                SubscriptionDownloadAttempt.updated_at == intent.updated_at,
            )
            .values(updated_at=now)
        )
        if leased.rowcount != 1:
            await session.rollback()
            return
        await session.commit()
        item = await session.get(MediaItem, subscription.media_item_id)
        candidate = TypeAdapter(TorrentCandidate).validate_python(payload["candidate"])
        try:
            await dispatch(
                session,
                subscription=subscription,
                item=item,
                wanted_rows=[r for r in rows if r.id in payload["wanted_ids"]],
                upgrade_rows=[r for r in rows if r.id in payload["upgrade_ids"]],
                candidate=candidate,
                verdict=RuleVerdict(accepted=True),
                source="智能提交恢复",
                submission_intent=intent,
            )
        except Exception:
            await session.rollback()
            logger.exception("智能提交恢复失败 #%s", intent_id)


async def run_due(session, *, now=None):
    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch

    now = now or utcnow()
    due = (
        await session.execute(
            select(WantedItem.subscription_id)
            .join(Subscription, Subscription.id == WantedItem.subscription_id)
            .where(
                WantedItem.next_selection_at <= now,
                WantedItem.in_scope.is_(True),
                WantedItem.status == "wanted",
                Subscription.selection_mode == "smart",
                Subscription.status == "active",
            )
            .order_by(WantedItem.next_selection_at)
            .limit(100)
        )
    ).all()
    if due:
        # 无站点请求；共享管线从持久化候选恢复并重新核验。
        return await evaluate_and_dispatch(
            session, [], source="智能等待到期", subscription_ids={r[0] for r in due}
        )
    return None


@register_task(
    "smart_selection_due",
    title="智能订阅等待到期",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=30,
    description="恢复智能提交意图，并执行固定截止或观察窗口到期决策",
)
async def smart_selection_due():
    async with _lock, get_database().session() as session:
        await recover_submissions(session)
        await run_due(session)


async def evaluate_requested(subscription_id: int):
    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch

    async with _lock, get_database().session() as session:
        await evaluate_and_dispatch(
            session, [], source="用户请求立即下载", subscription_ids={subscription_id}
        )

from __future__ import annotations

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import AppException, BadRequestException
from movieclaw_db.models import (
    ActivityType,
    SmartProfile,
    Subscription,
    SubscriptionActivity,
    SubscriptionStatus,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_matcher.smart import SmartPolicy, SmartPreferences


def conflict() -> AppException:
    return AppException(
        status_code=409, code="SMART_VERSION_CONFLICT", message="设置或等待状态已改变，请刷新后重试"
    )


async def save_profile(
    session: AsyncSession, kind: str, preferences: SmartPreferences, revision: int
) -> SmartProfile:
    if kind not in {"movie", "tv"}:
        raise BadRequestException("设置类型必须是电影或剧集")
    # SmartPreferences 已限制 0–7 天；保留整小时输入，兼容已有偏好和旧客户端。
    # 不收紧历史策略的解析，已冻结订阅仍按创建时的预算执行。
    if preferences.wait_seconds % 3600:
        raise BadRequestException("等待时长请选择不等待，或不超过 7 天的整数小时")
    if revision == 0:
        row = SmartProfile(kind=kind, preferences=preferences.model_dump(), revision=1)
        session.add(row)
        try:
            await session.flush()
        except IntegrityError as exc:
            await session.rollback()
            raise conflict() from exc
    else:
        result = await session.execute(
            update(SmartProfile)
            .where(SmartProfile.kind == kind, SmartProfile.revision == revision)
            .values(
                preferences=preferences.model_dump(), revision=revision + 1, updated_at=utcnow()
            )
        )
        if result.rowcount != 1:
            await session.rollback()
            raise conflict()
    await _apply_to_subscriptions(session, kind, preferences, revision + 1)
    await session.commit()
    return await session.get(SmartProfile, kind, populate_existing=True)


def _wait_text(seconds: int) -> str:
    return "不等待" if seconds == 0 else f"最多等 {seconds // 3600} 小时"


async def _apply_to_subscriptions(
    session: AsyncSession, kind: str, preferences: SmartPreferences, revision: int
) -> None:
    """已有智能订阅跟随类型设置：同一事务里写入新设置，并让在等的单元立即重新决策。

    订阅上的 ``smart_policy`` 不再是创建时的冻结快照，而是「当前设置」的副本——读取
    路径（read_policy）因此不用改。每次决策的输入另有 smart_decision_record 保存，
    回放审计不依赖订阅上的这一列。在等单元的截止由决策引擎按新预算收紧（只缩短不
    延长、手动延长保留，见 movieclaw_matcher.smart.decide），这里只把它们的下次决策
    提前到现在，让「改成不等待」在下一轮到期扫描就投递。
    """
    policy = SmartPolicy(
        **preferences.model_dump(), kind=kind, profile_revision=revision
    ).model_dump(mode="json")
    rows = (
        await session.execute(
            select(Subscription.id, Subscription.status).where(
                Subscription.selection_mode == "smart", Subscription.kind == kind
            )
        )
    ).all()
    subscription_ids = [row.id for row in rows]
    if not subscription_ids:
        return
    now = utcnow()
    await session.execute(
        update(Subscription)
        .where(Subscription.id.in_(subscription_ids))  # type: ignore[union-attr]
        .values(smart_policy=policy, updated_at=now)
    )
    await session.execute(
        update(WantedItem)
        .where(
            WantedItem.subscription_id.in_(subscription_ids),  # type: ignore[attr-defined]
            WantedItem.status == WantedStatus.WANTED,
            WantedItem.next_selection_at > now,  # type: ignore[operator]
        )
        .values(next_selection_at=now)
    )
    target = f"{preferences.resolution} {preferences.source}"
    message = (
        f"已跟随当前{'剧集' if kind == 'tv' else '电影'}智能设置："
        f"{_wait_text(preferences.wait_seconds)}，目标 {target}"
        f"{'，达标后停止洗版' if preferences.allow_upgrade else '，不洗版'}"
    )
    session.add_all(
        SubscriptionActivity(
            subscription_id=subscription_id,
            type=ActivityType.ADJUSTED,
            message=message,
            payload={"smart_policy": policy},
        )
        for subscription_id, status in rows
        # 已收齐的订阅也换上新设置（恢复/补缺时生效），但不往它们的时间线里刷动态
        if status != SubscriptionStatus.COMPLETED
    )


async def freeze_policy(session: AsyncSession, kind: str, revision: int | None) -> dict:
    row = await session.get(SmartProfile, kind)
    if row is None:
        raise BadRequestException("请先保存该类型的智能设置")
    if revision != row.revision:
        raise conflict()
    return SmartPolicy(**row.preferences, kind=kind, profile_revision=row.revision).model_dump(
        mode="json"
    )


def read_policy(subscription: Subscription) -> SmartPolicy | None:
    if subscription.selection_mode != "smart":
        return None
    try:
        policy = SmartPolicy.model_validate(subscription.smart_policy)
        return policy if policy.kind == subscription.kind else None
    except ValueError:
        return None

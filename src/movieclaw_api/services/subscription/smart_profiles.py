from __future__ import annotations

from sqlalchemy import update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import AppException, BadRequestException
from movieclaw_db.models import (
    SmartProfile,
    Subscription,
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
    from movieclaw_api.services.subscription.smart_memory import apply_to_subscriptions

    await apply_to_subscriptions(session, (kind,))
    await session.commit()
    return await session.get(SmartProfile, kind, populate_existing=True)


async def save_defaults(
    session: AsyncSession,
    shared: SmartPreferences,
    *,
    movie_wait_seconds: int,
    tv_wait_seconds: int,
    movie_revision: int,
    tv_revision: int,
) -> tuple[SmartProfile, SmartProfile]:
    """智能设置只有一套：画质、洗版、最低要求两类共用，等待时间电影和剧集各一个。

    两行在同一事务里按各自的 revision 写入，任一冲突整体回滚。
    """
    rows = []
    for kind, wait, revision in (
        ("movie", movie_wait_seconds, movie_revision),
        ("tv", tv_wait_seconds, tv_revision),
    ):
        preferences = shared.model_copy(update={"wait_seconds": wait})
        if wait % 3600 or not 0 <= wait <= 604800:
            raise BadRequestException("等待时长请选择不等待，或不超过 7 天的整数小时")
        if revision == 0:
            if await session.get(SmartProfile, kind) is not None:
                await session.rollback()
                raise conflict()
            session.add(SmartProfile(kind=kind, preferences=preferences.model_dump(), revision=1))
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
                    preferences=preferences.model_dump(),
                    revision=revision + 1,
                    updated_at=utcnow(),
                )
            )
            if result.rowcount != 1:
                await session.rollback()
                raise conflict()
        rows.append(kind)
    from movieclaw_api.services.subscription.smart_memory import apply_to_subscriptions

    await apply_to_subscriptions(session)
    await session.commit()
    movie = await session.get(SmartProfile, "movie", populate_existing=True)
    tv = await session.get(SmartProfile, "tv", populate_existing=True)
    return movie, tv


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

from __future__ import annotations

from sqlalchemy import update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import AppException, BadRequestException
from movieclaw_db.models import SmartProfile, Subscription
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
            await session.commit()
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
        await session.commit()
    return await session.get(SmartProfile, kind, populate_existing=True)


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

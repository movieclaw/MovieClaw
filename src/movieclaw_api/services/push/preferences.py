"""通知的个人偏好（docs/design/cloud-push.md §5、domain-events.md §6.1）。

推送按人发，每个人自己管收什么：``push_preference`` 每人一行，只记改过的开关，
没改过的用通知规则的默认值。开关就是通知规则表（rules.py）里的一条条，偏好页、App 的设置页
都按它自动渲染；新增通知 = 登记一条规则。
"""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models import PushPreference, utcnow


@dataclass(frozen=True)
class PushEvent:
    key: str
    title: str
    description: str
    group: str
    default: bool
    #: 只有管理员会收到（成员看不到这个开关）
    admin_only: bool = False


#: 旧版偏好键 → 现在的键（老 App 还会发旧键；库里的旧键已由迁移改名）
LEGACY_KEYS = {
    "imported": "subscription.fulfilled",
    "download_started": "subscription.download_started",
    "identity_skipped": "subscription.identity_skipped",
    "upgraded": "subscription.upgraded",
    "library_new": "library.items.arrived",
    "new_device": "account.device.signed_in",
    "system_alert": "system.alert.raised",
    "new_version": "system.update.available",
    "usage_tip": "system.tip.suggested",
}


def push_events() -> list[PushEvent]:
    """偏好开关（按通知规则表，登记顺序）。"""
    from movieclaw_api.services.push import rules

    return [
        PushEvent(
            key=entry.pref_key,
            title=entry.title,
            description=entry.description,
            group=entry.group,
            default=entry.default,
            admin_only=entry.admin_only,
        )
        for entry in rules.entries()
    ]


def spec(key: str) -> PushEvent | None:
    return next((e for e in push_events() if e.key == key), None)


def events_for(*, is_admin: bool) -> list[PushEvent]:
    return [e for e in push_events() if is_admin or not e.admin_only]


async def load_overrides(session: AsyncSession, member_id: int) -> dict[str, bool]:
    row = (
        await session.execute(select(PushPreference).where(PushPreference.member_id == member_id))
    ).scalar_one_or_none()
    if row is None or not isinstance(row.events, dict):
        return {}
    return {str(k): bool(v) for k, v in row.events.items()}


async def effective(session: AsyncSession, member_id: int) -> dict[str, bool]:
    """这个人每个事件的开关（默认值 + 改过的）。"""
    overrides = await load_overrides(session, member_id)
    return {e.key: overrides.get(e.key, e.default) for e in push_events()}


async def wants(session: AsyncSession, member_ids: set[int], event: str) -> set[int]:
    """这些人里打开了这个事件的。"""
    found = spec(event)
    if found is None or not member_ids:
        return set()
    rows = (
        await session.execute(
            select(PushPreference).where(PushPreference.member_id.in_(member_ids))  # type: ignore[attr-defined]
        )
    ).scalars()
    overrides = {row.member_id: row.events for row in rows if isinstance(row.events, dict)}
    return {
        member_id
        for member_id in member_ids
        if bool(overrides.get(member_id, {}).get(event, found.default))
    }


#: ``update`` 的 library_ids 不传时的占位：区分「不改」和「改成全部（None）」
KEEP = object()


async def library_selection(session: AsyncSession, member_id: int) -> list[int] | None:
    """「媒体库有新片」关心的库；None = 能看到的全部（含以后新建的）。"""
    row = (
        await session.execute(select(PushPreference).where(PushPreference.member_id == member_id))
    ).scalar_one_or_none()
    if row is None or row.library_ids is None:
        return None
    return [int(i) for i in row.library_ids if isinstance(i, int)]


async def library_selections(
    session: AsyncSession, member_ids: set[int]
) -> dict[int, list[int] | None]:
    """批量读：成员 → 关心的库（None = 全部）。没有偏好行的成员按全部算。"""
    rows = (
        await session.execute(
            select(PushPreference).where(PushPreference.member_id.in_(member_ids))  # type: ignore[attr-defined]
        )
    ).scalars()
    found = {
        row.member_id: (
            None
            if row.library_ids is None
            else [int(i) for i in row.library_ids if isinstance(i, int)]
        )
        for row in rows
    }
    return {m: found.get(m) for m in member_ids}


async def update(
    session: AsyncSession,
    member_id: int,
    changes: dict[str, bool],
    *,
    is_admin: bool,
    library_ids: object = KEEP,
) -> dict[str, bool]:
    """改开关。不认识的事件、成员改管理员专属事件一律忽略。

    ``library_ids``：不传 = 不改；None = 能看到的全部库；列表 = 只关心这些库。
    """
    allowed = {e.key for e in events_for(is_admin=is_admin)}
    row = (
        await session.execute(select(PushPreference).where(PushPreference.member_id == member_id))
    ).scalar_one_or_none()
    current = dict(row.events) if row is not None and isinstance(row.events, dict) else {}
    for key, value in changes.items():
        key = LEGACY_KEYS.get(key, key)
        if key in allowed:
            current[key] = bool(value)
    if row is None:
        row = PushPreference(member_id=member_id, events=current)
    else:
        row.events = current
        row.updated_at = utcnow()
    if library_ids is not KEEP:
        row.library_ids = (
            None if library_ids is None else sorted({int(i) for i in library_ids})  # type: ignore[union-attr]
        )
    session.add(row)
    await session.commit()
    return await effective(session, member_id)


# ----------------------------------------------------------------------
# 「这部剧不再提醒」
# ----------------------------------------------------------------------


def _muted(row: PushPreference | None) -> list[int]:
    if row is None or not isinstance(row.muted_item_ids, list):
        return []
    return [int(i) for i in row.muted_item_ids if isinstance(i, int)]


async def muted_items(session: AsyncSession, member_ids: set[int]) -> dict[int, set[int]]:
    """批量读：成员 → 静音的条目 id。"""
    if not member_ids:
        return {}
    rows = (
        await session.execute(
            select(PushPreference).where(PushPreference.member_id.in_(member_ids))  # type: ignore[attr-defined]
        )
    ).scalars()
    found = {row.member_id: set(_muted(row)) for row in rows}
    return {m: found.get(m, set()) for m in member_ids}


async def muted_list(session: AsyncSession, member_id: int) -> list[int]:
    """这个人静音的条目，最近静音的在前。"""
    row = (
        await session.execute(select(PushPreference).where(PushPreference.member_id == member_id))
    ).scalar_one_or_none()
    return list(reversed(_muted(row)))


async def set_muted(session: AsyncSession, member_id: int, item_id: int, muted: bool) -> None:
    """静音 / 恢复一部片的推送（只关这一部，订阅照常下载）。重复操作是幂等的。"""
    row = (
        await session.execute(select(PushPreference).where(PushPreference.member_id == member_id))
    ).scalar_one_or_none()
    current = [i for i in _muted(row) if i != item_id]
    if muted:
        current.append(item_id)
    if row is None:
        if not muted:
            return
        row = PushPreference(member_id=member_id, events={}, muted_item_ids=current)
    else:
        row.muted_item_ids = current or None
        row.updated_at = utcnow()
    session.add(row)
    await session.commit()

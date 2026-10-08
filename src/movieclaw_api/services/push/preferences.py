"""App 推送的事件目录与个人偏好（docs/design/cloud-push.md §5）。

推送按人发，每个人自己管收什么：``push_preference`` 每人一行，只记改过的开关，
没改过的用这里的默认值。新增事件 = 在 ``PUSH_EVENTS`` 加一行 + 产生点调一次
``services.push.notify``，偏好页、App 的设置页都按这张表自动渲染。
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


PUSH_EVENTS: tuple[PushEvent, ...] = (
    PushEvent(
        "imported",
        "入库完成",
        "你订阅或手动下载的电影、剧集整理进媒体库时",
        group="我的订阅",
        default=True,
    ),
    PushEvent(
        "download_started",
        "开始下载",
        "你订阅的内容找到资源、交给下载器时",
        group="我的订阅",
        default=False,
    ),
    PushEvent(
        "identity_skipped",
        "已跳过同名资源",
        "订阅发现无法确认身份的同名资源时知会一次，无需处理",
        group="我的订阅",
        default=True,
    ),
    PushEvent(
        "upgraded",
        "洗版完成",
        "你订阅的内容换成了更好的版本时",
        group="我的订阅",
        default=False,
    ),
    PushEvent(
        "library_new",
        "媒体库有新片",
        "你关心的媒体库来了新片或新剧集，不管是谁下载的",
        group="媒体库",
        default=False,
    ),
    PushEvent(
        "new_device",
        "新设备登录",
        "有新的 App、播放器、命令行或转码器登录了你的账号",
        group="账号安全",
        default=True,
    ),
    PushEvent(
        "system_alert",
        "需要处理的问题",
        "下载器、站点、导入出错这类需要管理员处理的问题",
        group="管理员",
        default=True,
        admin_only=True,
    ),
    PushEvent(
        "new_version",
        "有新版本",
        "MovieClaw 发布了新版本时，每个版本只提醒一次",
        group="管理员",
        default=True,
        admin_only=True,
    ),
)

EVENTS_BY_KEY = {event.key: event for event in PUSH_EVENTS}


def events_for(*, is_admin: bool) -> list[PushEvent]:
    return [e for e in PUSH_EVENTS if is_admin or not e.admin_only]


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
    return {e.key: overrides.get(e.key, e.default) for e in PUSH_EVENTS}


async def wants(session: AsyncSession, member_ids: set[int], event: str) -> set[int]:
    """这些人里打开了这个事件的。"""
    spec = EVENTS_BY_KEY[event]
    if not member_ids:
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
        if bool(overrides.get(member_id, {}).get(event, spec.default))
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

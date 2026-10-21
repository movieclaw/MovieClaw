"""按成员交换观看事实，不启动播放、不发布播放事件，不改收藏/轨道；较新已看事实清除续播位置。"""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import and_, or_, tuple_, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.playback_sync import (
    SyncCatalog,
    SyncImportIn,
    SyncMedia,
    SyncOutcome,
    SyncUnit,
    SyncWatch,
)
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import assert_item_visible, visible_library_ids
from movieclaw_api.services.playback_stats import _group_viewings, _targets_for, effective_end
from movieclaw_db.models import (
    FileState,
    LibraryFile,
    MediaItem,
    Member,
    PlaybackLog,
    PlaybackState,
    WatchRecord,
)
from movieclaw_db.models.base import utcnow


def naive(value: datetime) -> datetime:
    return value.astimezone(UTC).replace(tzinfo=None)


async def target(session: AsyncSession, member_id: int) -> Principal:
    if member_id == 0:
        return Principal(kind="admin", name="admin")
    member = await session.get(Member, member_id)
    if member is None or member.status != "active":
        raise NotFoundException("成员不存在或已停用")
    return Principal(
        kind="member", name=member.username, member_id=member_id, is_admin=False, member=member
    )


async def catalog(
    session: AsyncSession, actor: Principal, member_id: int, cursor: str | None, limit: int
) -> SyncCatalog:
    owner = await target(session, member_id)
    visible = await visible_library_ids(session, actor) & await visible_library_ids(session, owner)
    query = (
        select(LibraryFile.media_item_id, LibraryFile.season_number, LibraryFile.episode_number)
        .join(MediaItem, MediaItem.id == LibraryFile.media_item_id)
        .where(
            LibraryFile.state == FileState.IN_PLACE,
            LibraryFile.library_id.in_(visible),
            MediaItem.kind.in_(["movie", "tv"]),
        )
        .distinct()
    )
    cols = (LibraryFile.media_item_id, LibraryFile.season_number, LibraryFile.episode_number)
    if cursor:
        try:
            m, s, e = map(int, cursor.split(":"))
            if min(m, s, e) < 0:
                raise ValueError
        except ValueError as exc:
            raise BadRequestException("游标无效") from exc
        query = query.where(
            or_(
                cols[0] > m,
                and_(cols[0] == m, cols[1] > s),
                and_(cols[0] == m, cols[1] == s, cols[2] > e),
            )
        )
    rows = list((await session.execute(query.order_by(*cols).limit(limit + 1))).all())
    has_more, rows = len(rows) > limit, rows[:limit]
    units = [tuple(int(v or 0) for v in row) for row in rows]
    next_cursor = ":".join(map(str, units[-1])) if has_more and units else None
    if not units:
        return SyncCatalog(items=[], next_cursor=None)
    media = {
        m.id: m
        for m in (
            await session.execute(select(MediaItem).where(MediaItem.id.in_({u[0] for u in units})))
        ).scalars()
    }
    states = {
        (r.media_item_id, r.season_number, r.episode_number): r
        for r in (
            await session.execute(
                select(PlaybackState).where(
                    PlaybackState.member_id == member_id,
                    tuple_(
                        PlaybackState.media_item_id,
                        PlaybackState.season_number,
                        PlaybackState.episode_number,
                    ).in_(units),
                )
            )
        ).scalars()
    }
    logs = list(
        (
            await session.execute(
                select(PlaybackLog).where(
                    PlaybackLog.member_id == member_id,
                    tuple_(
                        PlaybackLog.media_item_id,
                        PlaybackLog.season_number,
                        PlaybackLog.episode_number,
                    ).in_(units),
                )
            )
        ).scalars()
    )
    _, durations = await _targets_for(
        session, logs, browsable_library_ids=visible, fold_hidden=True
    )
    watches: dict[tuple[int, int, int], list[SyncWatch]] = {u: [] for u in units}
    now = utcnow()
    for viewing in _group_viewings(logs, durations):
        if not viewing.finished:
            continue
        last = viewing.segments[-1]
        when = effective_end(last, now)
        if when is None:
            continue
        unit = (last.media_item_id, last.season_number, last.episode_number)
        watches[unit].append(
            SyncWatch(id=f"playback:{viewing.first.id}", watched_at=when, basis="playback")
        )
    imports = (
        await session.execute(
            select(WatchRecord).where(
                WatchRecord.member_id == member_id,
                tuple_(
                    WatchRecord.media_item_id, WatchRecord.season_number, WatchRecord.episode_number
                ).in_(units),
            )
        )
    ).scalars()
    for record in imports:
        unit = (record.media_item_id, record.season_number, record.episode_number)
        if not any(
            abs((w.watched_at - record.watched_at).total_seconds()) < 1 for w in watches[unit]
        ):
            watches[unit].append(
                SyncWatch(id=f"import:{record.id}", watched_at=record.watched_at, basis="import")
            )
    items = []
    for unit in units:
        m = media[unit[0]]
        try:
            await assert_item_visible(session, owner, m.id)
            await assert_item_visible(session, actor, m.id)
        except NotFoundException:
            continue
        state = states.get(unit)
        if state and state.played and not watches[unit]:
            watches[unit].append(
                SyncWatch(
                    id=f"state:{state.id}",
                    watched_at=state.last_played_at or state.updated_at,
                    basis="state",
                )
            )
        items.append(
            SyncUnit(
                media=SyncMedia(
                    id=m.id, kind=m.kind, title=m.title, tmdb_id=m.tmdb_id, imdb_id=m.imdb_id
                ),
                season=unit[1],
                episode=unit[2],
                played=bool(state and state.played),
                position_ms=state.position_ms if state else 0,
                updated_at=state.updated_at if state else None,
                last_played_at=state.last_played_at if state else None,
                watches=watches[unit],
            )
        )
    return SyncCatalog(items=items, next_cursor=next_cursor)


async def import_records(
    session: AsyncSession, actor: Principal, payload: SyncImportIn
) -> list[SyncOutcome]:
    owner = await target(session, payload.member_id)
    visible = await visible_library_ids(session, actor) & await visible_library_ids(session, owner)
    source = f"plugin:{actor.plugin.entry_id}" if actor.plugin else "api"
    outcomes: list[SyncOutcome] = []
    # 同一批的同一单元共用扫描时的版本；第二条重看不能与本批第一条自己产生冲突。
    versions = {}
    for record in payload.records:
        prior = (
            await session.execute(
                select(WatchRecord).where(
                    WatchRecord.member_id == payload.member_id,
                    WatchRecord.source == source,
                    WatchRecord.source_id == record.source_id,
                )
            )
        ).scalar_one_or_none()
        unit = (record.media_item_id, record.season, record.episode)
        when = naive(record.watched_at)
        if prior:
            same = (
                prior.media_item_id,
                prior.season_number,
                prior.episode_number,
            ) == unit and prior.watched_at == when
            outcomes.append(
                SyncOutcome(
                    status="already" if same else "mismatch",
                    state_version=prior.state_version if same else None,
                )
            )
            continue
        media = await session.get(MediaItem, record.media_item_id)
        valid_id = bool(
            (record.tmdb_id and media and media.tmdb_id == record.tmdb_id)
            or (record.imdb_id and media and media.imdb_id == record.imdb_id)
        )
        if (
            not media
            or media.kind != record.kind
            or not valid_id
            or (record.kind == "movie" and (record.season or record.episode))
            or (record.kind == "tv" and record.episode < 1)
        ):
            outcomes.append(SyncOutcome(status="mismatch"))
            continue
        file = (
            await session.execute(
                select(LibraryFile.id)
                .where(
                    LibraryFile.media_item_id == unit[0],
                    LibraryFile.season_number == unit[1],
                    LibraryFile.episode_number == unit[2],
                    LibraryFile.state == FileState.IN_PLACE,
                    LibraryFile.library_id.in_(visible),
                )
                .limit(1)
            )
        ).first()
        try:
            await assert_item_visible(session, owner, media.id)
            await assert_item_visible(session, actor, media.id)
        except NotFoundException:
            file = None
        if not file:
            outcomes.append(SyncOutcome(status="not_found"))
            continue
        state = (
            await session.execute(
                select(PlaybackState).where(
                    PlaybackState.member_id == payload.member_id,
                    PlaybackState.media_item_id == unit[0],
                    PlaybackState.season_number == unit[1],
                    PlaybackState.episode_number == unit[2],
                )
            )
        ).scalar_one_or_none()
        expected = naive(record.expected_updated_at) if record.expected_updated_at else None
        initial = versions.get(unit, state.updated_at if state else None)
        if initial != expected:
            outcomes.append(SyncOutcome(status="conflict"))
            continue
        try:
            async with session.begin_nested():
                stamp = utcnow()
                if state is not None:
                    # 乐观锁；旧历史不抹掉较新的续播，较新/同时的已看事实与手动标记一样清零。
                    result = await session.execute(
                        update(PlaybackState)
                        .where(
                            PlaybackState.id == state.id,
                            PlaybackState.updated_at == state.updated_at,
                        )
                        .values(
                            played=True,
                            updated_at=stamp,
                            last_played_at=max(when, state.last_played_at)
                            if state.last_played_at
                            else when,
                            play_count=max(state.play_count, 1),
                            position_ms=0
                            if state.last_played_at is None or when >= state.last_played_at
                            else state.position_ms,
                        )
                    )
                    if result.rowcount != 1:
                        outcomes.append(SyncOutcome(status="conflict"))
                        continue
                else:
                    state = PlaybackState(
                        member_id=payload.member_id,
                        media_item_id=unit[0],
                        season_number=unit[1],
                        episode_number=unit[2],
                        played=True,
                        play_count=1,
                        last_played_at=when,
                        updated_at=stamp,
                    )
                    session.add(state)
                session.add(
                    WatchRecord(
                        member_id=payload.member_id,
                        media_item_id=unit[0],
                        season_number=unit[1],
                        episode_number=unit[2],
                        watched_at=when,
                        source=source,
                        source_id=record.source_id,
                        state_version=stamp,
                    )
                )
                await session.flush()
            versions.setdefault(unit, initial)
            outcomes.append(SyncOutcome(status="applied", state_version=stamp))
        except IntegrityError:
            # 并发导入/同一源重放：不覆盖新状态；调用方可重新读取并重试。
            outcomes.append(SyncOutcome(status="conflict"))
    await session.commit()
    return outcomes

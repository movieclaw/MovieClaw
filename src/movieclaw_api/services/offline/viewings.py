"""本机播放的观看记录合并（docs/design/offline-download.md §7）。

App 播本机副本时不走实时进度上报，每次播放记一条观看记录（客户端 UUID），先落盘、能连上
就发；离线攒着的回来后一批补传。这里逐条按编号幂等合并：

1. **校时**：手机时间 + （服务器现在 − 手机发送时间），不晚于服务器现在；偏差超过 7 天
   视为手机时钟不可信，整条平移到「刚刚结束」。
2. **定位**：先按 ``file_id`` 找它现在属于哪个条目哪一集（条目转移、重新识别后也对得上），
   找不到再用 ``media_item_id``；都找不到 → rejected。
3. **续播状态**：记录的发生时间比服务器上这个单元的更新时间新才写（按发生时间判新旧，
   不按到达先后）；阈值与实时上报同一个 ``resolve_progress``。
4. **观看日志**：按 ``viewing_id`` upsert 一行；首次插入时 ``play_count`` +1；
   观看时长取大、且不超过「结束 − 开始 + 2 秒」。
5. **事件**：「已看」翻转发 ``playback.completed``（时间用记录时间）；开始 / 进度 / 停止只在
   记录是新鲜的（2 分钟内，即在线时的本机播放）时发，补传的旧记录不发，免得落地后一串推送。
   不碰实时会话（``activity``）与 ``end_session``：前者会造出假的「正在播放」，后者会掐断
   这台设备正在进行的取流。
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.schemas.offline import (
    PlaybackViewingRecordIn,
    PlaybackViewingResultView,
    PlaybackViewingsRequest,
)
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import visible_library_ids
from movieclaw_api.services.playback import events as playback_events
from movieclaw_api.services.playback import plan as playback_plan
from movieclaw_db.models import LibraryFile, MediaItem, PlaybackLog
from movieclaw_db.models.base import utcnow
from movieclaw_playback import state as playback_state
from movieclaw_playback.events import ClientInfo
from movieclaw_playback.progress import resolve_progress
from movieclaw_playback.state import Unit
from movieclaw_sdk.events import (
    PLAYBACK_COMPLETED,
    PLAYBACK_PROGRESS,
    PLAYBACK_STARTED,
    PLAYBACK_STOPPED,
)

#: 手机时钟偏差超过这个就不信它（飞行模式不影响手机时钟，真出现多半是用户手动改过时间）
_MAX_TRUSTED_SKEW = timedelta(days=7)
#: 记录的最后更新时间离服务器现在这么近，算「在线时的本机播放」，照实时播放发事件
_FRESH = timedelta(minutes=2)
_WATCH_SLACK_MS = 2_000


def _naive_utc(value: datetime) -> datetime:
    """库里存不带时区的 UTC；客户端发来的带时区时间先换算。"""
    if value.tzinfo is None:
        return value
    return value.astimezone(UTC).replace(tzinfo=None)


class _Clock:
    def __init__(self, sent_at: datetime, now: datetime) -> None:
        self.now = now
        skew = now - _naive_utc(sent_at)
        self.trusted = abs(skew) <= _MAX_TRUSTED_SKEW
        self.skew = skew

    def times(self, record: PlaybackViewingRecordIn) -> tuple[datetime, datetime]:
        started = _naive_utc(record.started_at)
        updated = _naive_utc(record.updated_at)
        if updated < started:
            started = updated
        if self.trusted:
            started, updated = started + self.skew, updated + self.skew
        else:
            # 时钟不可信：保留时长，整条平移到刚刚结束
            started, updated = self.now - (updated - started), self.now
        return min(started, self.now), min(updated, self.now)


async def _locate(
    session: AsyncSession, principal: Principal, record: PlaybackViewingRecordIn
) -> tuple[Unit, int | None] | None:
    visible = await visible_library_ids(session, principal)
    if record.file_id is not None:
        file = await session.get(LibraryFile, record.file_id)
        if file is not None and file.media_item_id is not None:
            if visible is not None and file.library_id not in visible:
                return None
            return (file.media_item_id, file.season_number or 0, file.episode_number or 0), file.id
    files = await playback_plan.library_files_for_unit(
        session,
        record.media_item_id,
        record.season_number,
        record.episode_number,
        visible_library_ids=visible,
    )
    if not files:
        return None
    return (record.media_item_id, record.season_number, record.episode_number), None


async def apply_viewings(
    session: AsyncSession,
    principal: Principal,
    payload: PlaybackViewingsRequest,
    *,
    client: ClientInfo,
) -> list[PlaybackViewingResultView]:
    member_id = principal.member_id if principal.member_id is not None else 0
    clock = _Clock(payload.sent_at, utcnow())
    results: list[PlaybackViewingResultView] = []
    for record in payload.records:
        located = await _locate(session, principal, record)
        if located is None:
            results.append(PlaybackViewingResultView(viewing_id=record.viewing_id, status="rejected"))
            continue
        unit, file_id = located
        status = await _apply_one(
            session, record, unit, file_id, clock, member_id=member_id, client=client
        )
        results.append(PlaybackViewingResultView(viewing_id=record.viewing_id, status=status))
    await session.commit()
    return results


async def _apply_one(
    session: AsyncSession,
    record: PlaybackViewingRecordIn,
    unit: Unit,
    file_id: int | None,
    clock: _Clock,
    *,
    member_id: int,
    client: ClientInfo,
) -> str:
    started, updated = clock.times(record)
    fresh = clock.now - updated <= _FRESH
    files = await playback_state.unit_files(session, unit)
    played_files = [f for f in files if f.id == file_id] or files
    runtime_ms = await playback_state.unit_runtime_ms(session, unit, files=played_files)
    runtime_ms = runtime_ms or record.duration_ms

    log = (
        await session.execute(select(PlaybackLog).where(PlaybackLog.viewing_id == record.viewing_id))
    ).scalar_one_or_none()
    first_time = log is None
    if log is not None and updated <= log.last_seen_at and (log.ended_at or not record.ended):
        # 同一份快照重发（上次的确认没收到）：已经合并过，什么都不改
        return "applied"

    row = await playback_state.get_or_create_state(session, unit, member_id=member_id)
    # 刚建的行（或只收藏过）的 updated_at 是建行那一刻，不能拿它和发生时间比
    pristine = row.last_played_at is None and not row.played and not row.position_ms
    newer = pristine or row.updated_at is None or updated > row.updated_at
    if first_time:
        # 计数点与实时上报一样放在「开始」：这次播放第一次到达服务器时 +1
        row.play_count = (row.play_count or 0) + 1
    newly_played = False
    if newer:
        was_played = row.played
        outcome = resolve_progress(
            None if record.completed else record.position_ms,
            runtime_ms,
            currently_played=row.played,
        )
        row.position_ms = outcome.position_ms
        row.played = outcome.played
        row.updated_at = updated
        newly_played = outcome.played and not was_played
    if row.last_played_at is None or updated > row.last_played_at:
        row.last_played_at = updated

    watched = min(
        record.watched_ms, int((updated - started).total_seconds() * 1000) + _WATCH_SLACK_MS
    )
    if log is None:
        item = await session.get(MediaItem, unit[0])
        log = PlaybackLog(
            member_id=member_id,
            media_item_id=unit[0],
            kind=item.kind if item else "movie",
            title=item.title if item else "",
            season_number=unit[1],
            episode_number=unit[2],
            device_id=client.device_id,
            client=client.name,
            device_name=client.device_name,
            started_at=started,
            last_seen_at=updated,
            start_position_ms=record.start_position_ms,
            end_position_ms=record.position_ms,
            watched_ms=max(watched, 0),
            viewing_id=record.viewing_id,
        )
        session.add(log)
    else:
        if updated >= log.last_seen_at:
            log.last_seen_at = updated
            log.end_position_ms = record.position_ms
        log.watched_ms = max(log.watched_ms, watched)
        log.updated_at = clock.now
    log.completed = log.completed or newly_played or record.completed
    if record.ended:
        log.ended_at = updated

    events: list = []
    if fresh and first_time:
        events.append(PLAYBACK_STARTED)
    if newly_played:
        events.append(PLAYBACK_COMPLETED)
    if fresh and record.ended:
        events.append(PLAYBACK_STOPPED)
    elif fresh and not first_time and not newly_played:
        events.append(PLAYBACK_PROGRESS)
    for event in events:
        await playback_events.publish_playback(
            session,
            event,
            unit,
            row,
            member_id=member_id,
            client=client,
            duration_ms=runtime_ms,
            file_id=file_id or record.file_id,
            completed=newly_played,
            occurred_at=updated,
        )
    return "applied" if newer else "stale"

"""改锚原语：一组文件从旧条目单元换到新条目单元时的标准动作
（docs/design/library-other-kind.md 4.9）。

四个调用方共用同一套动作，谁都不许各自拼：

- 扫描自动转正：影视库里临时本地身份的文件，TMDB 后来认出来了；
- 人工认领 / 重新识别：用户把文件挂到另一条目；
- 将来的库类型转换。

动作只有三步：改 ``library_file`` 的锚与季集号 → 把观看状态从旧单元
**复制**到新单元（文件行是两代条目之间唯一稳定的桥，进度不能因为换了
身份就丢）→ 旧条目交给孤儿清理（无文件无订阅即删）。清理必须在调用方
提交事务之后做（它自己开会话），所以本模块只返回旧条目 id 集合。
"""

from __future__ import annotations

import logging
from collections.abc import Iterable
from datetime import datetime

from sqlalchemy import func, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models import LibraryFile, PlaybackState, WatchRecord, utcnow
from movieclaw_playback import state as playback_state

logger = logging.getLogger("movieclaw_api.library_reanchor")

Unit = tuple[int, int, int]


async def migrate_watch_state(session: AsyncSession, old_unit: Unit, new_unit: Unit) -> int:
    """把旧单元的观看状态（每个成员一行）复制到新单元；返回处理的行数。

    导入的 WatchRecord 原行随单元迁移，不复制源去重键；原日期和回执版本保留。
    目标单元已有状态时按"更靠后的进度赢"合并：``last_played_at`` 较晚的
    一份决定进度与轨道记忆，已看/收藏取并，播放次数取较大者。旧行不删
    ——旧条目若被孤儿清理删除，外键级联会带走它；若旧条目仍有别的文件
    （同一部作品的另一版本仍挂在旧锚上），旧进度理应保留。

    「接下来继续」隐藏不跟进度走，见 :func:`_merge_dismiss`。复制标记也是"读标记 →
    写标记"，与播放清标记、隐藏的锚点校验走同一把作品级锁：每个成员先拿新旧两部
    作品的锁（``lock_titles`` 内按 id 升序，与批量写回一致），再在锁内读行、合并。
    """
    if old_unit == new_unit:
        return 0
    old_item, old_season, old_episode = old_unit
    new_item, new_season, new_episode = new_unit
    old_rows = select(PlaybackState).where(
        PlaybackState.media_item_id == old_item,
        PlaybackState.season_number == old_season,
        PlaybackState.episode_number == old_episode,
    )
    # 锁要先于下面的任何写，读到的行也要是锁内的。成员事先不知道：读出有哪些成员、逐个
    # 加锁，再读一遍——锁外读到的行先过期，下一遍按锁内的最新值重新装载（本事务自己改过、
    # 尚未 flush 的行不动）；期间新冒出来的成员（并发首播旧单元）补锁，直到都在锁内
    locked: set[int] = set()
    while True:
        rows = (await session.execute(old_rows)).scalars().all()
        pending = sorted({row.member_id for row in rows} - locked)
        if not pending:
            break
        for member_id in pending:
            await playback_state.lock_titles(session, member_id, [old_item, new_item])
        locked.update(pending)
        for row in rows:
            if row not in session.dirty:
                session.expire(row)
    # 观看事实随被更正的文件迁移；保留原行 id、源去重键与原写入回执版本。
    # 即使旧 PlaybackState 已被清理，也不能让导入事实留在待删的旧条目上。
    await session.execute(
        update(WatchRecord)
        .where(
            WatchRecord.media_item_id == old_item,
            WatchRecord.season_number == old_season,
            WatchRecord.episode_number == old_episode,
        )
        .values(
            media_item_id=new_item,
            season_number=new_season,
            episode_number=new_episode,
            updated_at=utcnow(),
        )
    )
    if not rows:
        return 0
    for old in rows:
        # 目标作品里（旧行自己以外）最近一次播放：迁入的隐藏要与它比
        newest = (
            await session.execute(
                select(func.max(PlaybackState.last_played_at)).where(
                    PlaybackState.member_id == old.member_id,
                    PlaybackState.media_item_id == new_item,
                    PlaybackState.id != old.id,
                )
            )
        ).scalar_one()
        target = (
            await session.execute(
                select(PlaybackState).where(
                    PlaybackState.member_id == old.member_id,
                    PlaybackState.media_item_id == new_item,
                    PlaybackState.season_number == new_season,
                    PlaybackState.episode_number == new_episode,
                )
            )
        ).scalar_one_or_none()
        if target is None:
            target = PlaybackState(
                member_id=old.member_id,
                media_item_id=new_item,
                season_number=new_season,
                episode_number=new_episode,
                position_ms=old.position_ms,
                audio_track=old.audio_track,
                subtitle_track=old.subtitle_track,
                played=old.played,
                play_count=old.play_count,
                is_favorite=old.is_favorite,
                favorited_at=old.favorited_at,
                last_played_at=old.last_played_at,
            )
            session.add(target)
            await _merge_dismiss(session, old, target, newest)
            continue
        old_wins = (old.last_played_at or datetime.min) > (target.last_played_at or datetime.min)
        if old_wins:
            target.position_ms = old.position_ms
            target.audio_track = old.audio_track or target.audio_track
            target.subtitle_track = old.subtitle_track or target.subtitle_track
            target.last_played_at = old.last_played_at
        target.played = target.played or old.played
        # 收藏时间取两边**较早**的那个：重新识别只是换了个身份锚点，
        # 用户收藏这部作品的那个动作还是当初那一次，不该看起来像刚收藏
        if old.is_favorite:
            times = [t for t in (target.favorited_at, old.favorited_at) if t is not None]
            if times:
                target.favorited_at = min(times)
        target.is_favorite = target.is_favorite or old.is_favorite
        target.play_count = max(target.play_count, old.play_count)
        target.updated_at = utcnow()
        session.add(target)
        await _merge_dismiss(session, old, target, newest)
    return len(rows)


async def _merge_dismiss(
    session: AsyncSession, old: PlaybackState, target: PlaybackState, newest: datetime | None
) -> None:
    """把旧行带来的「接下来继续」隐藏与播放事实，按发生时间并进目标作品。

    隐藏是作品级的独立事件，不跟着 ``last_played_at`` 较新的那一行走（旧身份播 t1、
    目标播 t2、旧身份 t3 隐藏时，进度跟目标，但隐藏之后谁都没再播，隐藏要带过去）。
    规则与 ``playback_state.note_playback`` 同一条——比隐藏新的播放事实让作品回来：

    - 换了作品时，旧行的播放（``old.last_played_at``）是迁进目标作品的一条播放事实：按它
      清掉目标作品里比它旧的标记（含目标行自己的），比它新的隐藏留着。同一作品内换集
      不必再清：这条播放当初到达时已经按同一规则清过；
    - 旧行的隐藏只在目标作品里（旧行以外）的播放 ``newest`` 都不比它新时才带过去；
      旧作品里比它新的播放早已把它清掉，不必再比。没有隐藏时间的旧标记当作最早；
    - 两边的隐藏都留下时取较新的隐藏时间。
    """
    if old.media_item_id != target.media_item_id and old.last_played_at is not None:
        await playback_state.note_playback(
            session,
            member_id=old.member_id,
            media_item_id=target.media_item_id,
            played_at=old.last_played_at,
        )
    if not old.continue_dismissed:
        return
    dismissed_at = old.continue_dismissed_at
    if newest is not None and (dismissed_at is None or newest > dismissed_at):
        return
    if target.continue_dismissed:
        times = [t for t in (target.continue_dismissed_at, dismissed_at) if t is not None]
        dismissed_at = max(times) if times else None
    target.continue_dismissed = True
    target.continue_dismissed_at = dismissed_at


async def reanchor_rows(
    session: AsyncSession,
    rows: Iterable[LibraryFile],
    new_item_id: int,
    *,
    unit_of,
    identity_source: str | None,
    resolved_version: int | None,
) -> set[int]:
    """把一组文件行改挂到 ``new_item_id``，观看状态随迁；返回被换下的旧条目 id。

    ``unit_of(row) -> (season, episode)`` 给出每行在新条目下的季集号（电影/
    单本 (0,0)；剧集按解析结果）。调用方负责 commit，并在 commit 之后对
    返回的旧条目 id 调 ``cleanup_orphan_items``。
    """
    old_ids: set[int] = set()
    now = utcnow()
    for row in rows:
        season, episode = unit_of(row)
        if row.media_item_id is not None and (
            row.media_item_id,
            row.season_number,
            row.episode_number,
        ) != (new_item_id, season, episode):
            if row.media_item_id != new_item_id:
                old_ids.add(row.media_item_id)
            await migrate_watch_state(
                session,
                (row.media_item_id, row.season_number, row.episode_number),
                (new_item_id, season, episode),
            )
        row.media_item_id = new_item_id
        row.season_number = season
        row.episode_number = episode
        row.unidentified_reason = None
        row.unidentified_message = None
        row.unidentified_code = None
        row.unidentified_candidates = None
        row.identity_source = identity_source
        row.resolved_version = resolved_version
        row.review_suggestion = None
        row.updated_at = now
        session.add(row)
    return old_ids

"""观看状态存取——playback_state 表的领域服务。

键是 (member_id, media_item_id, season, episode)：``member_id`` 是观看者
（0=超管哨兵，见 PlaybackState 模型注释），每人各看各的进度与收藏。
所有入口都要求调用方显式传 ``member_id``——协议层（Web 播放器 / Jellyfin）
从各自的会话/设备凭据解析身份后传入，本层不做身份判定。
所有写入走 upsert：状态行按需创建，缺行即"从未播过"。
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from datetime import datetime

from sqlalchemy import Select, select
from sqlalchemy.exc import IntegrityError
from sqlmodel.ext.asyncio.session import AsyncSession

from movieclaw_db.models import (
    LibraryFile,
    MediaEpisode,
    MediaMetadata,
    PlaybackState,
)
from movieclaw_db.models.base import utcnow
from movieclaw_playback.progress import resolve_mark_played, resolve_progress
from movieclaw_playback.track_policy import (
    NO_CONTEXT,
    TrackContext,
    default_audio,
    default_subtitle_or_off,
)

Unit = tuple[int, int, int]  # (media_item_id, season, episode)


def unit_files_statement(unit: Unit) -> Select:
    """一个播放单元在位文件的查询（:func:`unit_files` 与要连带取别的列的调用方共用）。

    按 id 稳定排序：多版本时「第一个文件」是片长等回退取值的来源，顺序不定会让
    同一部片在不同请求里给出不同的片长；与 Jellyfin 侧 MediaSources 的顺序一致。
    """
    item_id, season, episode = unit
    return (
        select(LibraryFile)
        .where(
            LibraryFile.media_item_id == item_id,
            LibraryFile.season_number == season,
            LibraryFile.episode_number == episode,
            LibraryFile.in_place(),
        )
        .order_by(LibraryFile.id)
    )


async def unit_files(session: AsyncSession, unit: Unit) -> list[LibraryFile]:
    """一个播放单元的在位文件（多版本时不止一个）。"""
    return list((await session.execute(unit_files_statement(unit))).scalars())


async def unit_runtime_ms(
    session: AsyncSession, unit: Unit, *, files: list[LibraryFile] | None = None
) -> int | None:
    """一个播放单元的片长（毫秒），按可信度降序回退：在位文件实测时长 >
    分集刮削时长 > 条目刮削时长；都没有返回 None。

    **必须服务端算，不能听客户端报**——它是 ``resolve_progress`` 的分母，
    直接决定「看到哪算已看」。网页播放器与 Jellyfin 客户端共用同一个来源，
    同一部片才不会在两个入口给出不同的已看结论。

    ``files`` 是调用方已经取过的 :func:`unit_files`：进度上报同一请求里还要拿
    它们判断轨选择（见 :func:`apply_track_selection`），传进来就不再查第二遍。
    """
    item_id, season, episode = unit
    if files is None:
        files = await unit_files(session, unit)
    for file in files:
        if file.duration_seconds:
            return file.duration_seconds * 1000
    ep = (
        await session.execute(
            select(MediaEpisode).where(
                MediaEpisode.media_item_id == item_id,
                MediaEpisode.season_number == season,
                MediaEpisode.episode_number == episode,
            )
        )
    ).scalar_one_or_none()
    if ep and ep.runtime_minutes:
        return ep.runtime_minutes * 60_000
    meta = (
        await session.execute(
            select(MediaMetadata).where(MediaMetadata.media_item_id == item_id)
        )
    ).scalar_one_or_none()
    if meta and meta.runtime_minutes:
        return meta.runtime_minutes * 60_000
    return None


async def get_states(
    session: AsyncSession, media_item_ids: Iterable[int], *, member_id: int
) -> dict[Unit, PlaybackState]:
    """批量取一组条目**该观看者**的全部状态行，按 (item, season, episode) 索引。"""
    ids = list(set(media_item_ids))
    if not ids:
        return {}
    rows = (
        await session.execute(
            select(PlaybackState).where(
                PlaybackState.media_item_id.in_(ids),
                PlaybackState.member_id == member_id,
            )
        )
    ).scalars()
    return {(r.media_item_id, r.season_number, r.episode_number): r for r in rows}


async def _get_or_create(
    session: AsyncSession, unit: Unit, *, member_id: int
) -> PlaybackState:
    statement = select(PlaybackState).where(
        PlaybackState.member_id == member_id,
        PlaybackState.media_item_id == unit[0],
        PlaybackState.season_number == unit[1],
        PlaybackState.episode_number == unit[2],
    )
    row = (await session.execute(statement)).scalar_one_or_none()
    if row is None:
        row = PlaybackState(
            member_id=member_id,
            media_item_id=unit[0],
            season_number=unit[1],
            episode_number=unit[2],
        )
        try:
            # INSERT 圈在 SAVEPOINT 里当场写入（同 library_file_repo.upsert_by_path）：
            # 撞键只回滚保存点，会话照常可用
            async with session.begin_nested():
                session.add(row)
        except IntegrityError:
            # 同一成员的另一台设备同时首次开播这一单元，抢先写入了这一行
            # （两边都查到「没有」再各自插入）。撞键不是错误，用它那一行——
            # 曾经直接 500
            row = (await session.execute(statement)).scalar_one()
    return row


async def record_playback_start(
    session: AsyncSession, unit: Unit, *, member_id: int
) -> PlaybackState:
    """开始播放：play_count +1、刷新最近播放时间（scrobble 语义的计数点）。"""
    row = await _get_or_create(session, unit, member_id=member_id)
    row.play_count += 1
    row.last_played_at = utcnow()
    row.updated_at = utcnow()
    return row


async def record_playback_progress(
    session: AsyncSession,
    unit: Unit,
    *,
    member_id: int,
    position_ms: int | None,
    runtime_ms: int | None,
) -> tuple[PlaybackState, bool]:
    """进度上报（Progress 与 Stopped 同入口）：按阈值三分支落库。

    第二个返回值 ``newly_played`` = played 是否在本次从 False 翻转为 True，
    供协议层判定是否发出 ``playback.completed`` webhook 事件。
    """
    row = await _get_or_create(session, unit, member_id=member_id)
    was_played = row.played
    outcome = resolve_progress(position_ms, runtime_ms, currently_played=row.played)
    row.position_ms = outcome.position_ms
    row.played = outcome.played
    row.last_played_at = utcnow()
    row.updated_at = utcnow()
    return row, (outcome.played and not was_played)


async def mark_played(
    session: AsyncSession,
    units: list[Unit],
    *,
    member_id: int,
    date_played: datetime | None = None,
) -> PlaybackState | None:
    """标记已看（可级联多单元，如整剧/整季）。返回第一个单元的状态行。"""
    first: PlaybackState | None = None
    for unit in units:
        row = await _get_or_create(session, unit, member_id=member_id)
        row.played = True
        row.position_ms = 0
        row.play_count, row.last_played_at = resolve_mark_played(
            play_count=row.play_count,
            date_played=date_played,
            last_played_at=row.last_played_at,
        )
        row.updated_at = utcnow()
        first = first or row
    return first


async def mark_unplayed(
    session: AsyncSession, units: list[Unit], *, member_id: int
) -> PlaybackState | None:
    """取消已看：全部清零（对齐 BaseItem.ResetPlayedState，不是减一）。"""
    first: PlaybackState | None = None
    for unit in units:
        row = await _get_or_create(session, unit, member_id=member_id)
        row.played = False
        row.position_ms = 0
        row.play_count = 0
        row.last_played_at = None
        row.updated_at = utcnow()
        first = first or row
    return first


async def set_favorite(
    session: AsyncSession, unit: Unit, *, member_id: int, favorite: bool
) -> PlaybackState:
    """收藏 / 取消收藏。网页详情页的心与 Jellyfin 客户端的心都落在这里。

    ``favorited_at`` **只在由非收藏变收藏时刷新**：重复点心是幂等的，不该把
    时间改写成今天；取消收藏则留着旧时间不动——它已经不会被读到（列表只看
    ``is_favorite``），而下次真的再收藏时自然会刷新。
    """
    row = await _get_or_create(session, unit, member_id=member_id)
    if favorite and not row.is_favorite:
        row.favorited_at = utcnow()
    row.is_favorite = favorite
    row.updated_at = utcnow()
    return row


def track_report_changes(
    row: PlaybackState, *, audio_track: str | None = None, subtitle_track: str | None = None
) -> bool:
    """这次上报的轨和已记的值有没有不同——相同就什么都不用做，也不必为判断去取文件。"""
    return (audio_track is not None and audio_track != row.audio_track) or (
        subtitle_track is not None and subtitle_track != row.subtitle_track
    )


def _untouched_choice(
    ref: str,
    kind: str,
    files: Iterable[LibraryFile],
    contexts: Mapping[int, TrackContext],
    playing_audio: str | None,
) -> bool:
    """``ref`` 是不是这些文件「没人动过」时本来就会放的那条：默认轨策略挑的音轨、字幕，
    或者策略本来就不开字幕时的「关闭」。默认字幕要看放的是哪条音轨（``playing_audio``，
    没有就按默认音轨算），见 ``movieclaw_playback.track_policy``。

    判断不了的文件跳过：原盘的轨以播放器引擎读到的为准、服务端读不到；还没探测过
    内封轨的旧行也不知道默认是哪条。多版本又不知道放的是哪个时，任一版本对得上就算
    ——绝大多数单元只有一个文件。
    """
    for file in files:
        if file.is_disc():
            continue
        context = contexts.get(file.id or 0, NO_CONTEXT)
        if kind == "audio":
            if not file.audio_streams:
                continue
            default = default_audio(file, context).ref
        else:
            if file.subtitle_streams is None:
                continue
            default = default_subtitle_or_off(file, context, playing_audio)
        if ref == default:
            return True
    return False


def apply_track_selection(
    row: PlaybackState,
    *,
    audio_track: str | None = None,
    subtitle_track: str | None = None,
    files: Iterable[LibraryFile] = (),
    contexts: Mapping[int, TrackContext] | None = None,
) -> None:
    """在已取得的状态行上记忆轨选择（docs/design/jellyfin-subtitle.md §3.3）。

    与 record_playback_start/progress 同一会话内使用（它们已经
    get-or-create 了该单元的行，这里绝不能再建第二行——会撞唯一键）。
    参数值是中性轨引用（movieclaw_playback.subtitles 的
    embedded:<k> / external:<文件名> / 字幕特有 "off"）。None = 本次上报
    没带该轨，**保持原值不动**——播放器的心跳可能只报进度不报轨。

    **只记用户的选择**（2026-09-29）：播放器上报的是「正在放的轨」，多数只是默认挑选的
    结果。照单全收就把默认挑选冻成了「用户选的」：默认策略以后改了（比如按媒体库语言
    选字幕），这些条目跟不上；自动落成「关闭」的，还会被当成用户明确关掉、连带整部剧
    都不再开字幕。所以上报的轨就是这个文件没人动过时本来就会放的那条（见
    :func:`_untouched_choice`），就清空记忆、交回默认策略；和默认不同的才是用户换过的，
    照记。用户在菜单里特意选回默认那条，清空和记住的效果一样。

    ``files`` 是这个单元的在位文件，知道放的是哪个版本时只给那一个；不给（或都判断
    不了）就照上报原样记。``contexts`` 是各文件的默认轨策略上下文（库语言、原始语言，
    按文件 id），与文件同一条 SQL 取出；不给按旧规则判断。只在上报和已记的值不同时才判断
    （纯内存计算，不查库）。
    """
    files = list(files)
    contexts = contexts or {}
    changed = False
    if audio_track is not None and row.audio_track != audio_track:
        untouched = _untouched_choice(audio_track, "audio", files, contexts, None)
        value = None if untouched else audio_track
        if row.audio_track != value:
            row.audio_track = value
            changed = True
    if subtitle_track is not None and row.subtitle_track != subtitle_track:
        # 默认字幕看正在放的音轨：这次报了就是它，没报就是记着的（都没有即默认音轨）
        playing_audio = audio_track if audio_track is not None else row.audio_track
        untouched = _untouched_choice(subtitle_track, "subtitle", files, contexts, playing_audio)
        value = None if untouched else subtitle_track
        if row.subtitle_track != value:
            row.subtitle_track = value
            changed = True
    if changed:
        row.updated_at = utcnow()


async def get_remembered_tracks(
    session: AsyncSession, unit: Unit, *, member_id: int
) -> tuple[str | None, str | None]:
    """读取记忆的 (音轨, 字幕轨) 中性引用；无记录返回 (None, None)。"""
    row = (
        await session.execute(
            select(PlaybackState).where(
                PlaybackState.member_id == member_id,
                PlaybackState.media_item_id == unit[0],
                PlaybackState.season_number == unit[1],
                PlaybackState.episode_number == unit[2],
            )
        )
    ).scalar_one_or_none()
    if row is None:
        return None, None
    return row.audio_track, row.subtitle_track

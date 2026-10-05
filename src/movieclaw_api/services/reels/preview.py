"""大图预告：Apple TV 首页首屏与详情页的大图停留一会儿后原地换成一段片段。

设计见 docs/design/tvos-app.md §3.5。

放哪一段分两种（2026-10-05 用户定）：

- **resume**（首页「接下来继续」）：从这个人上次停下的位置往前倒 30 秒，放到停下的地方——
  等于帮他回忆一下，看过的内容不会剧透。没有续播点（剧集的下一集还没开始看、看得太少）
  就退回 highlight；
- **highlight**（详情页）：与刷片同一个挑点（电影 5%～75% 里挑，剧集固定最早一季第二集），
  算过的直接读缓存。

放法与刷片完全一样（``mode=seek``：自研引擎从原片中间起播），返回同一个 ``ReelItemView``，
App 用同一个播放器放。预告不开字幕：大图左下角压着片名与简介，底部再出一行字幕就乱了。
各种片源都能放：Matroska / MP4 读容器索引，原盘目录与光盘镜像读盘上结构，其余（TS、AVI、
网盘 strm……）按台账片长挑、起点交给引擎定位（segments.index_for）。连片长都没有才返回 None，
App 保持剧照。
"""

from __future__ import annotations

import asyncio
import logging
from bisect import bisect_right
from collections import OrderedDict
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import assert_item_visible
from movieclaw_api.services.reels import segments
from movieclaw_api.services.reels.feed import (
    ReelCandidate,
    _assemble,
    _file_ref,
    _files_of,
    _playable_library_kinds,
    choose_file,
    unit_kind,
)
from movieclaw_api.services.reels.picker import prefetch_for
from movieclaw_api.services.reels.segments import ReelSegment
from movieclaw_db.models import LibraryFile
from movieclaw_playback import state as playback_state
from movieclaw_playback.container_index import ContainerIndex

logger = logging.getLogger("movieclaw_api.reels")

#: 从续播点往前倒多少（毫秒）
RECAP_MS = 30_000
#: 续播点之前至少有这么长才放回忆（毫秒）；更短的退回 highlight——几秒钟的回忆刚淡入就放完了
MIN_RECAP_MS = 10_000
#: 起点往前找关键帧最多找多远（秒）：长 GOP 的片子不为了对齐关键帧多倒十几秒
KEYFRAME_SNAP_S = 6.0
#: 读过的容器索引留几份：首页左右换片会反复要同几部，MP4 的索引一读就是几 MB
INDEX_CACHE_SIZE = 8

_index_cache: OrderedDict[tuple[str, int | None, int | None], ContainerIndex | None] = OrderedDict()


async def build_preview(
    session: AsyncSession,
    principal: Principal,
    media_item_id: int,
    *,
    source: str,
    season: int = 0,
    episode: int = 0,
) -> dict[str, Any] | None:
    """一部片的大图预告；放不了返回 None。"""
    await assert_item_visible(session, principal, media_item_id)
    libraries = await _playable_library_kinds(session, principal)
    files = (await _files_of(session, [media_item_id], list(libraries))).get(media_item_id, [])
    if not files:
        return None
    kind = unit_kind(libraries.get(files[0].library_id, "movie"))
    member_id = principal.member_id if principal.member_id is not None else 0

    candidate = None
    if source == "resume":
        candidate = await _recap(session, member_id, media_item_id, kind, files, season, episode)
    if candidate is None:
        chosen = choose_file(files, kind)
        if chosen is None:
            return None
        segment = await segments.get_segment(_file_ref(chosen, kind))
        if segment is None:
            return None
        candidate = ReelCandidate(media_item_id, kind, chosen, segment)

    items = await _assemble(session, [candidate], member_id)
    if not items:
        return None
    item = items[0]
    item["play"]["subtitle"] = None
    return item


async def _recap(
    session: AsyncSession,
    member_id: int,
    media_item_id: int,
    kind: str,
    files: list[LibraryFile],
    season: int,
    episode: int,
) -> ReelCandidate | None:
    """续播点往前 30 秒到续播点；没有可用的续播点返回 None。"""
    if kind != "episode":
        season, episode = 0, 0
    states = await playback_state.get_states(session, [media_item_id], member_id=member_id)
    state = states.get((media_item_id, season, episode))
    if state is None or state.played or state.position_ms < MIN_RECAP_MS:
        return None
    unit_files = [
        f for f in files if (f.season_number or 0) == season and (f.episode_number or 0) == episode
    ]
    # 多版本时与刷片同一个取法（1080p 及以上里体积最小）：各版本时间轴一致，回忆哪一版都一样
    chosen = choose_file(unit_files, "movie")
    if chosen is None:
        return None
    index = await _index_of(_file_ref(chosen, kind))
    end_ms = state.position_ms
    if index is not None and index.duration_s:
        end_ms = min(end_ms, int(index.duration_s * 1000))
    target_s = max(0.0, (end_ms - RECAP_MS) / 1000)
    # 有关键帧表就往前对齐到关键帧（引擎从关键帧起播不用先解前面的帧）；没有就原样交给引擎定位
    times = [k.time_s for k in index.keyframes] if index is not None else []
    i = bisect_right(times, target_s + 1e-3) - 1
    start_s = times[i] if i >= 0 and target_s - times[i] <= KEYFRAME_SNAP_S else target_s
    start_ms = int(round(start_s * 1000))
    if end_ms - start_ms < MIN_RECAP_MS:
        return None
    segment = ReelSegment(
        file_id=int(chosen.id or 0),
        start_ms=start_ms,
        end_ms=end_ms,
        method="resume",
        score=0.0,
        prefetch=prefetch_for(index, start_s) if index is not None else (),
        cover=None,
    )
    return ReelCandidate(media_item_id, kind, chosen, segment)


async def _index_of(ref: segments.FileRef) -> ContainerIndex | None:
    key = (ref.path, ref.size_bytes, ref.mtime_ns)
    if key in _index_cache:
        _index_cache.move_to_end(key)
        return _index_cache[key]
    try:
        index = await asyncio.to_thread(segments.index_for, ref)
    except Exception:  # noqa: BLE001 —— 读坏了只是起点不对齐关键帧，照样放回忆
        logger.warning("大图预告读索引失败：%s", ref.path, exc_info=True)
        return None
    _index_cache[key] = index
    while len(_index_cache) > INDEX_CACHE_SIZE:
        _index_cache.popitem(last=False)
    return index

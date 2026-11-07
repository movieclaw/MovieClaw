"""存量原盘的主片自愈：选主片的规则改过之后，让台账跟上新选中的主片。

主播放列表选错时，台账里的分辨率、编码、音轨都是错的那段视频的，片长和码率的自愈管不到它们。
受影响的盘很少（2026-11 长度相近时改比字节，NAS 186 张蓝光盘里 3 张），但不能等用户碰巧手动
扫描，也不能为了它们把全部原盘重探一遍：

- **原盘目录**：台账 ``disc_playlist`` 记着探测时选中的清单。版本落后的行重读一次 MPLS（只在
  升级后第一次启动，NAS 137 张 5～20 秒）：主片没换只换版本号，换了才重探。版本已经是最新、
  但清单是旧版部分读取落下的另一条时，同样只在完整重读和台账不一致时重探；一致、读不全或
  盘不在都不改台账。
- **蓝光镜像**：探测时不记清单，但旧规则只比时长，算得出当时选的是哪条
  （``DiscSource.longest_playlist_name``）。与现在选的不同才重探，并把清单记进台账，下次启动
  不再重探；其余镜像的台账一个字节都不动。已经记下的清单和完整重读不一致时同样扶正；任一
  列表没读全时不改。

片库没挂上的行留到下次启动；探测失败的行已退回「未探测」，由定期对账带退避重试。
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from sqlmodel import select

from movieclaw_api.services import media_probe
from movieclaw_api.services.foreground import yield_to_foreground
from movieclaw_api.services.library.bluray import (
    DISC_PLAYLIST_VERSION,
    MplsPlaylist,
    disc_playlist_record,
    disc_playlist_stale,
    read_main_playlist_result,
)
from movieclaw_api.services.library.items import backfill_streams, reset_probed_spec
from movieclaw_api.services.playback.disc_source import DiscSource
from movieclaw_api.services.playback.iso_source import iso_disc_source
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile, utcnow

logger = logging.getLogger("movieclaw_api.disc_main_playlists")


def _image_clips(source: DiscSource) -> list[dict]:
    return [{"id": clip.clip_id, "in": clip.in_time, "out": clip.out_time} for clip in source.clips]


async def _reset_replaced_image(row: LibraryFile) -> bool:
    """蓝光镜像的台账规格是另一条列表的：退回未探测并记下现在的主片，返回是否要重探。"""
    source = await asyncio.to_thread(iso_disc_source, row.file_path)
    # 读不出，或有列表没读全：剩下的候选可能只是花絮，不能拿来改台账
    if source is None or source.playlist_incomplete:
        return False
    record = row.disc_playlist if isinstance(row.disc_playlist, dict) else {}
    fresh_clips = _image_clips(source)
    stored_clips = record.get("clips")
    # 版本已是最新、清单却是另一条（部分读取把花絮落了账）。只比时长选不出的盘，
    # 旧逻辑在 longest == playlist 时直接返回，挂载恢复后也不会再看这条台账。
    clips_differ = bool(stored_clips) and stored_clips != fresh_clips
    selection_differs = (
        source.longest_playlist_name
        not in (
            None,
            source.playlist_name,
        )
        and record.get("name") != source.playlist_name
    )
    if not clips_differ and not selection_differs:
        return False
    if clips_differ:
        logger.info(
            "光盘镜像主片和台账不一致：file_id=%s %s → %s",
            row.id,
            record.get("name"),
            source.playlist_name,
        )
    else:
        logger.info(
            "光盘镜像主片换了：file_id=%s %s → %s",
            row.id,
            source.longest_playlist_name,
            source.playlist_name,
        )
    reset_probed_spec(row)
    row.duration_seconds = None
    row.disc_playlist = {
        "version": DISC_PLAYLIST_VERSION,
        "name": source.playlist_name,
        "clips": fresh_clips,
    }
    row.updated_at = utcnow()
    return True


async def conflicting_disc_playlist(row: LibraryFile) -> MplsPlaylist | None:
    """版本已是最新的原盘目录，完整重读是否选中了另一条主片。

    版本落后的行交给补探自己重读。读不全、盘不在、没有可用主片，或剪辑清单本来就一致：
    返回 None，调用方不得改台账。
    """
    record = row.disc_playlist
    if disc_playlist_stale(record) or not isinstance(record, dict):
        return None
    stored_clips = record.get("clips")
    if not stored_clips:
        return None
    path = Path(row.file_path)
    if not await asyncio.to_thread(Path(path, "BDMV").is_dir):
        return None
    result = await asyncio.to_thread(read_main_playlist_result, path)
    playlist = result.playlist
    if result.retryable or playlist is None or playlist.duration_seconds <= 0:
        return None
    if disc_playlist_record(playlist)["clips"] == stored_clips:
        return None
    logger.info(
        "原盘主片和台账不一致：file_id=%s %s → %s",
        row.id,
        record.get("name"),
        playlist.path.name,
    )
    return playlist


async def heal_disc_main_playlists() -> int:
    """让存量原盘和蓝光镜像跟上主片的选择，返回跑了几次 ffprobe。"""
    if not media_probe.ffprobe_available():
        return 0  # 探不了就别动：退回未探测也补不回来，装好 ffmpeg 后下次启动再来
    async with get_database().session() as session:
        rows = (
            (
                await session.execute(
                    select(LibraryFile)
                    .where(
                        LibraryFile.container.in_(("bluray", "iso")),  # type: ignore[union-attr]
                        LibraryFile.in_place(),
                        LibraryFile.ignored_at.is_(None),  # type: ignore[union-attr]
                        # 只在网盘上的文件走按预算的后台补探（library/cloud_probe.py）
                        LibraryFile.local_bytes.is_(True),  # type: ignore[attr-defined]
                    )
                    .order_by(LibraryFile.id)  # type: ignore[arg-type]
                )
            )
            .scalars()
            .all()
        )
        pending: list[LibraryFile] = []
        replacements: dict[int, MplsPlaylist] = {}
        for row in rows:
            # 每一行都可能读网盘；页面加载时退开。前台空闲时这次让路没有等待。
            await yield_to_foreground()
            if row.container == "iso":
                if await _reset_replaced_image(row):
                    pending.append(row)
                continue
            # 目录不在（片库没挂上）时补探会把读不出当成残缺盘
            if not await asyncio.to_thread(Path(row.file_path, "BDMV").is_dir):
                continue
            if disc_playlist_stale(row.disc_playlist):
                pending.append(row)
                continue
            if row.id is None:
                continue
            replacement = await conflicting_disc_playlist(row)
            if replacement is not None:
                replacements[row.id] = replacement
                pending.append(row)
        if not pending:
            return 0

        async def _yield() -> bool:
            # 每一行都是网络盘上的读取，页面加载时退开
            await yield_to_foreground()
            return True

        probed = await backfill_streams(
            session, pending, on_processed=_yield, disc_replacements=replacements
        )
    logger.info("原盘主片校准：检查 %d 张，重探 %d 张", len(pending), probed)
    return probed

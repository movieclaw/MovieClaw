"""存量原盘的主片自愈：选主片的规则改过之后，让台账跟上新选中的主片。

主播放列表选错时，台账里的分辨率、编码、音轨都是错的那段视频的，片长和码率的自愈管不到它们。
受影响的盘很少（2026-11 长度相近时改比字节，NAS 186 张蓝光盘里 3 张），但不能等用户碰巧手动
扫描，也不能为了它们把全部原盘重探一遍：

- **原盘目录**：台账 ``disc_playlist`` 记着探测时选中的清单。版本落后的行重读一次 MPLS（只在
  升级后第一次启动，NAS 137 张 5～20 秒）：主片没换只换版本号，换了才重探。读不全不盖戳，
  瞬时 I/O 下次继续；稳定坏盘按文件指纹记失败，文件没变不重复审计。已盖最新版本的行不再读盘。
- **蓝光镜像**：探测时不记清单，但旧规则只比时长，算得出当时选的是哪条
  （``DiscSource.longest_playlist_name``）。与现在选的不同才重探，并把清单记进台账，下次启动
  不再重探；主片未变的镜像只盖清单版本，规格不动。已经记下的清单和完整重读不一致时
  同样扶正；任一列表没读全时只记失败指纹，不拿残余候选改清单。

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
    disc_playlist_audit_due,
    disc_playlist_audit_mutex,
    disc_playlist_failure_record,
    disc_playlist_pending_ledger,
    disc_playlist_pending_matches,
    disc_playlist_probe_pending,
    disc_playlist_stale,
)
from movieclaw_api.services.library.items import backfill_streams, reset_probed_spec
from movieclaw_api.services.playback.disc_source import DiscSource
from movieclaw_api.services.playback.iso_source import iso_disc_source_result
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile, utcnow

logger = logging.getLogger("movieclaw_api.disc_main_playlists")


def _image_clips(source: DiscSource) -> list[dict]:
    return [{"id": clip.clip_id, "in": clip.in_time, "out": clip.out_time} for clip in source.clips]


async def audit_disc_image_playlist(row: LibraryFile, *, force: bool = False) -> tuple[bool, bool]:
    """完整审计一张版本落后的 ISO，返回 ``(台账有变, 需重探)``。"""
    if not disc_playlist_stale(row.disc_playlist):
        return False, False
    path = Path(row.file_path)
    was_pending = disc_playlist_probe_pending(row.disc_playlist)
    if was_pending and await asyncio.to_thread(
        disc_playlist_pending_matches, row.disc_playlist, path
    ):
        return False, True
    if not await asyncio.to_thread(disc_playlist_audit_due, row.disc_playlist, path, force=force):
        return False, False
    result = await asyncio.to_thread(iso_disc_source_result, row.file_path)
    if result.retryable:
        # 挂载抖动或短读不改变台账，也不绑失败指纹；同一镜像恢复后下轮继续审计。
        return False, False
    source = result.source
    # 确定性的格式/解析损坏：剩下的候选可能只是花絮。记失败指纹但不盖 v3，
    # 文件没变时启动与手动扫描都不再反复付整盘读取成本。
    if result.audit_failed or source is None or source.playlist_incomplete:
        failed = await asyncio.to_thread(disc_playlist_failure_record, row.disc_playlist, path)
        if failed == row.disc_playlist:
            return False, False
        row.disc_playlist = failed
        row.updated_at = utcnow()
        return True, False
    record = row.disc_playlist if isinstance(row.disc_playlist, dict) else {}
    fresh_clips = _image_clips(source)
    if was_pending:
        # 盘已变化，旧 pending 的规格目标也失效；完整重审后用新指纹重新等待探测。
        row.disc_playlist = disc_playlist_pending_ledger(source.playlist_name, fresh_clips, path)
        reset_probed_spec(row)
        row.duration_seconds = None
        row.updated_at = utcnow()
        return True, True
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
        row.disc_playlist = {
            "version": DISC_PLAYLIST_VERSION,
            "name": source.playlist_name,
            "clips": fresh_clips,
        }
        return True, False
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
    row.disc_playlist = disc_playlist_pending_ledger(source.playlist_name, fresh_clips, path)
    reset_probed_spec(row)
    row.duration_seconds = None
    row.updated_at = utcnow()
    return True, True


async def heal_disc_main_playlists() -> int:
    """让存量原盘和蓝光镜像跟上主片的选择，返回跑了几次 ffprobe。"""
    if not media_probe.ffprobe_available():
        return 0  # 探不了就别动：退回未探测也补不回来，装好 ffmpeg 后下次启动再来
    total_probed = 0
    total_pending = 0
    async with get_database().session() as session:
        library_ids = list(
            (
                await session.execute(
                    select(LibraryFile.library_id)
                    .where(
                        LibraryFile.container.in_(("bluray", "iso")),  # type: ignore[union-attr]
                        LibraryFile.in_place(),
                        LibraryFile.ignored_at.is_(None),  # type: ignore[union-attr]
                        LibraryFile.local_bytes.is_(True),  # type: ignore[attr-defined]
                    )
                    .distinct()
                    .order_by(LibraryFile.library_id)  # type: ignore[arg-type]
                )
            )
            .scalars()
            .all()
        )
        # 只取 id 的盘点事务到此结束；若随后等同库互斥锁，拿到锁后的行查询
        # 必须开启新快照，才能看见先完成那条链路刚提交的 v3/规格。
        await session.commit()
        for library_id in library_ids:
            async with disc_playlist_audit_mutex(library_id):
                # 等锁之后再读：另一条链路可能刚把 pending 探测成功并盖了 v3。
                rows = list(
                    (
                        await session.execute(
                            select(LibraryFile)
                            .where(
                                LibraryFile.library_id == library_id,
                                LibraryFile.container.in_(("bluray", "iso")),  # type: ignore[union-attr]
                                LibraryFile.in_place(),
                                LibraryFile.ignored_at.is_(None),  # type: ignore[union-attr]
                                LibraryFile.local_bytes.is_(True),  # type: ignore[attr-defined]
                            )
                            .order_by(LibraryFile.id)  # type: ignore[arg-type]
                        )
                    )
                    .scalars()
                    .all()
                )
                pending: list[LibraryFile] = []
                changed = False
                for row in rows:
                    await yield_to_foreground()
                    if row.container == "iso":
                        ledger_changed, reprobe = await audit_disc_image_playlist(row)
                        changed |= ledger_changed
                        if reprobe:
                            pending.append(row)
                        continue
                    path = Path(row.file_path)
                    if not await asyncio.to_thread(Path(path, "BDMV").is_dir):
                        continue
                    if disc_playlist_stale(row.disc_playlist) and await asyncio.to_thread(
                        disc_playlist_audit_due, row.disc_playlist, path
                    ):
                        pending.append(row)
                total_pending += len(pending)
                if not pending:
                    if changed:
                        await session.commit()
                    continue

                async def _yield() -> bool:
                    await yield_to_foreground()
                    return True

                total_probed += await backfill_streams(session, pending, on_processed=_yield)
    logger.info("原盘主片校准：检查 %d 张，重探 %d 张", total_pending, total_probed)
    return total_probed

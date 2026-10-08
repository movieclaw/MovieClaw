"""存量杜比视界文件补记 profile（播放决策按 profile 分直通 / 放基础层 / 转码，见 decide.py）。

``library_file.dv_profile`` 是 2026-10 才加的列，之前入库的杜比视界文件都是空的——空的按
「不知道」保守转码，等于没上线。不能让用户整库重扫（网络盘上是小时级的活），这里在启动后于后台
只补这一类：台账标着杜比视界、profile 还空着的行，逐个用 ffprobe 读一次文件头（NAS 实测每个约
0.16 秒，526 个约一分半）。补完之后只剩确实读不出 DOVI 配置记录的个别文件，下次启动再试也就几个。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging

from sqlmodel import select

from movieclaw_api.services.media_probe import video_color_for
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile

logger = logging.getLogger("movieclaw_api.dolby_vision_backfill")

_task: asyncio.Task[None] | None = None


async def backfill_dolby_vision_profiles() -> int:
    """补记还空着的杜比视界 profile，返回补上了几行。"""
    async with get_database().session() as session:
        rows = (
            (
                await session.execute(
                    select(LibraryFile).where(
                        LibraryFile.hdr == "Dolby Vision",
                        LibraryFile.dv_profile.is_(None),  # type: ignore[union-attr]
                        LibraryFile.in_place(),
                    )
                    .order_by(LibraryFile.id)
                )
            )
            .scalars()
            .all()
        )
        filled = 0
        for row in rows:
            color = await asyncio.to_thread(video_color_for, row.file_path, fallback_hdr=row.hdr)
            if color.dv_profile is None:
                continue
            row.dv_profile = color.dv_profile
            row.dv_bl_compatible = color.dv_backward_compatible
            filled += 1
            if filled % 50 == 0:
                await session.commit()
        await session.commit()
    if rows:
        logger.info("杜比视界 profile 补记：%d 个里补上 %d 个", len(rows), filled)
    return filled


def start_dolby_vision_backfill() -> None:
    """排成后台任务（lifespan 启动阶段调用，不等待完成）。"""
    global _task
    _task = asyncio.get_running_loop().create_task(_run())


async def _run() -> None:
    try:
        await backfill_dolby_vision_profiles()
    except asyncio.CancelledError:
        raise
    except Exception:  # noqa: BLE001 -- 补记失败不影响启动，下次启动重试
        logger.warning("杜比视界 profile 补记异常退出（下次启动将重试）", exc_info=True)


async def close_dolby_vision_backfill() -> None:
    global _task
    if _task is not None:
        _task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await _task
        _task = None

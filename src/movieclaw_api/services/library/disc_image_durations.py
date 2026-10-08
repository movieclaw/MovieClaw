"""存量光盘镜像（ISO）的片长自愈：台账片长换成盘内正片的时长。

ffprobe 对整个镜像估的片长常常离谱或干脆为空（NAS 实测 78 个 ISO：一集 DVD 记成 4 秒、
一部蓝光多出一小时、大半蓝光为空）。片长是「看到哪算已看完」的分母，也是继续观看进度卡与
片长显示的来源——记成 4 秒的那集一开播就被判成看完了。

新入库的 ISO 在探测时就写对（``media_probe._with_disc_image_duration``）；存量行由这里在
启动后于后台校准一次：逐个读盘内结构（每个镜像几次小读取，NAS 上 78 个共约 8 秒），与台账
差出一分钟以上或台账为空才改。幂等，校准过的行下次启动只读不写。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging

from sqlmodel import select

from movieclaw_api.services.playback.iso_source import iso_disc_source
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile

logger = logging.getLogger("movieclaw_api.disc_image_durations")

#: 台账与盘内时长差多少秒以内算一致（盘内时长按节目链 / 播放列表算，与探测值有零头出入）
_TOLERANCE_S = 60

_task: asyncio.Task[None] | None = None


async def heal_disc_image_durations() -> int:
    """校准全部在位 ISO 的台账片长，返回改了几行。"""
    async with get_database().session() as session:
        rows = (
            (
                await session.execute(
                    select(LibraryFile).where(
                        LibraryFile.container == "iso",
                        LibraryFile.in_place(),
                    )
                )
            )
            .scalars()
            .all()
        )
        changed = 0
        for row in rows:
            source = await asyncio.to_thread(iso_disc_source, row.file_path)
            if source is None or source.duration_s <= 0:
                continue
            seconds = round(source.duration_s)
            if row.duration_seconds and abs(row.duration_seconds - seconds) <= _TOLERANCE_S:
                continue
            logger.info(
                "光盘镜像片长校准：file_id=%s %s → %s 秒", row.id, row.duration_seconds, seconds
            )
            row.duration_seconds = seconds
            changed += 1
        if changed:
            await session.commit()
    return changed


def start_disc_image_duration_heal() -> None:
    """排成后台任务（lifespan 启动阶段调用，不等待完成）。"""
    global _task
    _task = asyncio.get_running_loop().create_task(_run())


async def _run() -> None:
    try:
        changed = await heal_disc_image_durations()
        if changed:
            logger.info("光盘镜像片长校准完成：改正 %d 个", changed)
    except asyncio.CancelledError:
        raise
    except Exception:  # noqa: BLE001 -- 自愈失败不影响启动，下次启动重试
        logger.warning("光盘镜像片长校准异常退出（下次启动将重试）", exc_info=True)


async def close_disc_image_duration_heal() -> None:
    """停机时取消未完成的校准（没提交的下次启动重来）。"""
    global _task
    if _task is not None:
        _task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await _task
        _task = None

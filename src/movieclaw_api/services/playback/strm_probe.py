"""网盘（strm）条目的按需规格探测（docs/design/strm-playback.md §2）。

扫库不碰网盘（scan.py：strm 入账时规格留空），规格在**第一次播放**时才探：ffprobe 直接读
直链，只读文件头与索引（几百 KB 到几 MB），结论落进台账，之后与本地文件一样——决策按真实
编码选直出 / 换封装 / 转码，详情页有规格，音轨字幕可选。

探测失败（直链失效、服务器连不上网盘）不记进台账：决策见到规格为空，退回乐观直连。
失败后一分钟内不再重探——同一次播放的降档重试不该每次都白等一轮超时。
"""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import PurePosixPath
from typing import Any
from urllib.parse import urlsplit

from sqlalchemy.orm.attributes import set_committed_value

from movieclaw_api.services.media_probe import PROBE_SCHEMA_VERSION, MediaSpec, probe_media
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile
from movieclaw_db.models.base import utcnow
from movieclaw_playback.streaming import is_strm, media_input

logger = logging.getLogger("movieclaw_api.playback.strm_probe")

#: 探测失败后多久内不再重探（秒）
_FAILURE_COOLDOWN_S = 60.0

#: 直链路径能看出容器时以它为准（与本地文件按扩展名记容器同一口径）
_URL_CONTAINERS = frozenset(
    {"mkv", "mp4", "m4v", "mov", "webm", "ts", "m2ts", "avi", "wmv", "flv", "mpg", "mpeg"}
)
#: 看不出时按 ffprobe 的封装格式名（逗号分隔的第一项）
_FORMAT_CONTAINERS = {
    "matroska": "mkv",
    "mov": "mp4",
    "mpegts": "ts",
    "avi": "avi",
    "asf": "wmv",
    "flv": "flv",
    "mpeg": "mpg",
}

_failed_at: dict[str, float] = {}
_inflight: dict[int, asyncio.Task[dict[str, Any] | None]] = {}


def strm_container(url: str, format_name: str | None) -> str | None:
    """网盘直链的容器（与台账 ``container`` 列同一套扩展名口径）。"""
    suffix = PurePosixPath(urlsplit(url).path).suffix.lower().lstrip(".")
    if suffix in _URL_CONTAINERS:
        return suffix
    return _FORMAT_CONTAINERS.get((format_name or "").split(",")[0])


def needs_strm_probe(file: LibraryFile) -> bool:
    """这一行是还没有规格的网盘条目。"""
    return is_strm(file.file_path) and file.video_codec is None


async def ensure_strm_spec(file: LibraryFile) -> bool:
    """没有规格的网盘条目现场探一次并落库；返回这一行现在有没有规格。

    ``file`` 属于调用方的数据库会话：结论在独立的短会话里提交，再以「已提交」的状态
    写回这个对象——调用方会话里不留脏字段，不会再写一遍。同一文件并发的探测合并成一次。
    """
    if not needs_strm_probe(file):
        return file.video_codec is not None
    if file.id is None:
        return False
    failed_at = _failed_at.get(file.file_path)
    if failed_at is not None and time.monotonic() - failed_at < _FAILURE_COOLDOWN_S:
        return False
    task = _inflight.get(file.id)
    if task is None:
        task = asyncio.create_task(_probe_and_store(file.id, file.file_path))
        _inflight[file.id] = task
        task.add_done_callback(lambda _t, key=file.id: _inflight.pop(key, None))
    values = await asyncio.shield(task)
    if values is None:
        return False
    for key, value in values.items():
        set_committed_value(file, key, value)
    return True


async def _probe_and_store(file_id: int, file_path: str) -> dict[str, Any] | None:
    source = media_input(file_path)
    if source is None:
        _failed_at[file_path] = time.monotonic()
        return None
    url, input_args = source
    started = time.perf_counter()
    spec = await asyncio.to_thread(probe_media, url, input_args=input_args)
    elapsed = time.perf_counter() - started
    if spec is None or spec.video_codec is None:
        _failed_at[file_path] = time.monotonic()
        logger.warning("网盘条目探测失败（%.1f 秒），按乐观直连处理：%s", elapsed, file_path)
        return None
    _failed_at.pop(file_path, None)
    values = _spec_values(spec, strm_container(url, spec.format_name))
    async with get_database().session() as session:
        row = await session.get(LibraryFile, file_id)
        if row is None or row.file_path != file_path:
            return None
        for key, value in values.items():
            setattr(row, key, value)
        row.updated_at = utcnow()
        await session.commit()
    logger.info(
        "网盘条目按需探测完成（%.1f 秒）：%s → %s %s %s",
        elapsed,
        file_path,
        values["container"] or "未知容器",
        spec.video_codec,
        spec.resolution or "",
    )
    return values


def _spec_values(spec: MediaSpec, container: str | None) -> dict[str, Any]:
    """探测结论 → 台账列（与扫描入账、补探落的是同一批列）。"""
    return {
        "container": container,
        "resolution": spec.resolution,
        "video_codec": spec.video_codec,
        "hdr": spec.hdr,
        "dv_profile": spec.dv_profile,
        "dv_bl_compatible": spec.dv_bl_compatible,
        "bit_depth": spec.bit_depth,
        "duration_seconds": spec.duration_seconds,
        "bit_rate": spec.bit_rate,
        "frame_rate": spec.frame_rate,
        "color_space": spec.color_space,
        "audio_streams": list(spec.audio_streams),
        "subtitle_streams": list(spec.subtitle_streams),
        "chapters": list(spec.chapters),
        "probe_version": PROBE_SCHEMA_VERSION,
    }

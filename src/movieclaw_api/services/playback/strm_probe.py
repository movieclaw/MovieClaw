"""网盘（strm）条目的规格探测（docs/design/strm-playback.md §2、plugin-strm-prefetch.md §4）。

扫库不碰网盘（scan.py：strm 入账时规格留空），规格在**第一次播放**时探，或由预探插件提前探：
ffprobe 直接读直链，只读文件头与索引（几百 KB 到几 MB），结论落进台账，之后与本地文件一样——
决策按真实编码选直出 / 换封装 / 转码，详情页有规格，音轨字幕可选。

探测结果另记一行 ``StrmProbeState``：失败次数与退避（后台预探遵守，首播不受限）、探测时直链的
主机 + 路径（扫描据此认出 .strm 换了文件）。探测失败不改台账规格：决策见到规格为空，退回
乐观直连。失败后一分钟内不再重探——同一次播放的降档重试不该每次都白等一轮超时。
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING, Any
from urllib.parse import urlsplit

from sqlalchemy.orm.attributes import set_committed_value

from movieclaw_api.services.media_probe import PROBE_SCHEMA_VERSION, MediaSpec, probe_media
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile, StrmProbeState
from movieclaw_db.models.base import utcnow
from movieclaw_playback.streaming import is_strm, media_input, resolve_strm_url

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger("movieclaw_api.playback.strm_probe")

#: 探测失败后多久内不再重探（秒）
_FAILURE_COOLDOWN_S = 60.0

#: 直链路径能看出容器时以它为准（与本地文件按扩展名记容器同一口径）
URL_CONTAINERS = frozenset(
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

#: 连续失败的退避：第 1、2、3 次及以后（封顶）
_BACKOFF = (timedelta(hours=1), timedelta(hours=6), timedelta(days=1), timedelta(days=3))

_failed_at: dict[str, float] = {}
_inflight: dict[int, asyncio.Task[_Outcome]] = {}


@dataclass(frozen=True)
class _Outcome:
    #: 探出的台账列；失败为 None
    values: dict[str, Any] | None
    error: str | None = None
    next_retry_at: datetime | None = None


def backoff_after(failures: int) -> timedelta:
    """连续失败 ``failures`` 次后要等多久再探（后台预探用）。"""
    return _BACKOFF[min(max(failures, 1), len(_BACKOFF)) - 1]


def strm_target(url: str) -> str:
    """直链的主机 + 路径：签名、时效参数在查询串里，换了它们还是同一个文件。"""
    parts = urlsplit(url)
    return f"{parts.netloc.lower()}{parts.path}"


def strm_container(url: str, format_name: str | None) -> str | None:
    """网盘直链的容器（与台账 ``container`` 列同一套扩展名口径）。"""
    suffix = PurePosixPath(urlsplit(url).path).suffix.lower().lstrip(".")
    if suffix in URL_CONTAINERS:
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
    outcome = await _probe_once(file.id, file.file_path)
    if outcome.values is None:
        return False
    for key, value in outcome.values.items():
        set_committed_value(file, key, value)
    return True


@dataclass(frozen=True)
class ProbeResult:
    """一次后台探测的结论（``probe_file``）。"""

    #: probed：这次探出了规格；ready：本来就有；failed：探了没成功；
    #: backoff：还在失败退避期，没探；not_strm：不是网盘条目；missing：没有这个文件
    status: str
    error: str | None = None
    next_retry_at: datetime | None = None


async def probe_file(file_id: int, *, respect_backoff: bool = True) -> ProbeResult:
    """探一个网盘条目的规格（后台预探与宿主操作用）。默认遵守失败退避。"""
    async with get_database().session() as session:
        row = await session.get(LibraryFile, file_id)
        if row is None:
            return ProbeResult("missing")
        if not is_strm(row.file_path):
            return ProbeResult("not_strm")
        if row.video_codec is not None:
            return ProbeResult("ready")
        state = await session.get(StrmProbeState, file_id)
        file_path = row.file_path
    if (
        respect_backoff
        and state is not None
        and state.next_retry_at is not None
        and state.next_retry_at > utcnow()
    ):
        return ProbeResult("backoff", state.last_error, state.next_retry_at)
    outcome = await _probe_once(file_id, file_path)
    if outcome.values is None:
        return ProbeResult("failed", outcome.error, outcome.next_retry_at)
    return ProbeResult("probed")


async def _probe_once(file_id: int, file_path: str) -> _Outcome:
    """同一文件并发的探测合并成一次（首播与后台预探可能撞在一起）。"""
    task = _inflight.get(file_id)
    if task is None:
        task = asyncio.create_task(_probe_and_store(file_id, file_path))
        _inflight[file_id] = task
        task.add_done_callback(lambda _t, key=file_id: _inflight.pop(key, None))
    return await asyncio.shield(task)


async def _probe_and_store(file_id: int, file_path: str) -> _Outcome:
    source = media_input(file_path)
    if source is None:
        _failed_at[file_path] = time.monotonic()
        return await _record_failure(file_id, file_path, None, "strm 文件里没有可用的直链")
    url, input_args = source
    started = time.perf_counter()
    spec = await asyncio.to_thread(probe_media, url, input_args=input_args)
    elapsed = time.perf_counter() - started
    if spec is None or spec.video_codec is None:
        _failed_at[file_path] = time.monotonic()
        logger.warning("网盘条目探测失败（%.1f 秒），按乐观直连处理：%s", elapsed, file_path)
        reason = (
            "读不出媒体信息（直链失效、网盘连不上或格式不支持）" if spec is None else "没有视频流"
        )
        return await _record_failure(file_id, file_path, url, reason)
    _failed_at.pop(file_path, None)
    values = _spec_values(spec, strm_container(url, spec.format_name))
    async with get_database().session() as session:
        row = await session.get(LibraryFile, file_id)
        if row is None or row.file_path != file_path:
            return _Outcome(None, "文件已不在台账里")
        for key, value in values.items():
            setattr(row, key, value)
        row.updated_at = utcnow()
        state = await session.get(StrmProbeState, file_id) or StrmProbeState(file_id=file_id)
        state.target = strm_target(url)
        state.failures = 0
        state.last_error = None
        state.last_attempt_at = utcnow()
        state.next_retry_at = None
        state.updated_at = utcnow()
        session.add(state)
        await session.commit()
    logger.info(
        "网盘条目探测完成（%.1f 秒）：%s → %s %s %s",
        elapsed,
        file_path,
        values["container"] or "未知容器",
        spec.video_codec,
        spec.resolution or "",
    )
    return _Outcome(values)


async def _record_failure(file_id: int, file_path: str, url: str | None, reason: str) -> _Outcome:
    """记一次失败并排下次可重试的时间；文件已不在台账里就不记。"""
    now = utcnow()
    async with get_database().session() as session:
        row = await session.get(LibraryFile, file_id)
        if row is None or row.file_path != file_path:
            return _Outcome(None, reason)
        state = await session.get(StrmProbeState, file_id) or StrmProbeState(file_id=file_id)
        target = strm_target(url) if url else None
        # 直链换了文件：之前的失败不算在新链头上
        failures = (state.failures or 0) if state.target == target else 0
        state.failures = failures + 1
        state.target = target
        state.last_error = reason
        state.last_attempt_at = now
        state.next_retry_at = now + backoff_after(state.failures)
        state.updated_at = now
        session.add(state)
        await session.commit()
        return _Outcome(None, reason, state.next_retry_at)


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


#: 台账规格列（清空即回到「待探」）
SPEC_COLUMNS = (
    "container",
    "resolution",
    "video_codec",
    "hdr",
    "dv_profile",
    "dv_bl_compatible",
    "bit_depth",
    "duration_seconds",
    "bit_rate",
    "frame_rate",
    "color_space",
    "audio_streams",
    "subtitle_streams",
    "chapters",
    "probe_version",
)


async def refresh_rewritten_strm(session: AsyncSession, row: LibraryFile, file: Path) -> bool:
    """扫描遇到 .strm 的大小或修改时间变了：重读直链，换了文件就清空规格回到待探。

    只换了签名 / 时效参数（主机与路径不变）的不动规格。没有探测记录的旧行无从比对，
    按换了文件处理——重探一次的代价很小。返回是否改动了行（调用方提交）。
    """
    try:
        st = await asyncio.to_thread(file.stat)
    except OSError:
        return False
    if (st.st_size, st.st_mtime_ns) == (row.size_bytes, row.file_mtime_ns):
        return False
    row.size_bytes = st.st_size
    row.file_mtime_ns = st.st_mtime_ns
    row.updated_at = utcnow()
    url = resolve_strm_url(file)
    state = await session.get(StrmProbeState, row.id) if row.id is not None else None
    if url is not None and state is not None and state.target == strm_target(url):
        return True
    if row.video_codec is not None:
        for column in SPEC_COLUMNS:
            setattr(row, column, None)
        row.chapter_images = None
        logger.info("网盘条目的直链换了文件，规格已清空待重探：%s", file)
    if state is not None:
        await session.delete(state)
    _failed_at.pop(str(file), None)
    return True

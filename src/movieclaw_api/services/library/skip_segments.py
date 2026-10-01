"""跳过片头 / 片尾：指纹、整季识别、后台作业与播放下发（docs/design/skip-intro.md）。

服务端算好、客户端只管用：播放会话随响应下发本集的片头 / 片尾区间，Jellyfin
``/MediaSegments`` 输出同一份数据，App 与网页播放器据此显示「跳过片头」与提前的
「即将播放下一集」。客户端不做任何计算。

三件事，各在合适的时候做：

1. **指纹**（读媒体文件，贵）：每集片头窗（前 10 分钟）+ 片尾窗（后 7 分钟）的
   chromaprint 音频指纹，ffmpeg 一次一个、低优先级，算完存成缓存文件
   （``settings.audio_fingerprint_dir``），状态记在 ``media_segment`` 表。每个文件
   只算一次：片源大小变了（洗版原地替换）才重算。
2. **整季识别**（只比指纹，便宜）：一季里任何一集的指纹新算出来，就把整季重新比一遍，
   结果写回这一季每个文件的 ``media_segment.segments``。比对是纯 Python 的 CPU 活，
   放在**独立子进程**里跑（``python -m movieclaw_playback.skip_segments``）——放在服务
   进程里会抢 GIL、拖慢同时在跑的接口与取流（2026-09-30 实测：同进程纯 Python 计算让
   查库慢几百倍，独立进程零影响）。
3. **什么时候做**（每个入口都先查「有没有待办」，没有就什么都不排）：
   - 入库（``enqueue_ingested_item``）：新集落位后排一份条目作业，读的是刚下载完的本地文件。
     不让路，但一次最多读 ``PRIORITY_BATCH`` 个文件，整季积压留给整库回填；
   - 扫描作业收尾、监听触发的增量扫描、暂缓文件的补扫、打开开关
     （都走 ``enqueue_after_library_change``）：整库补缺，低优先级，**有人在看片就暂停**
     （``playback_active``）——它连续读片库所在的磁盘，和正在播的片子抢同一份 IO；
   - 开播（``schedule_playback_bump``）：播到的这一集没有片段 → 20 秒后排一份条目作业，
     先算离正在看的这一集最近的几集。这一集多半赶不上，下一集就有了。**不做边播边算**：
     ffmpeg 的 chromaprint 要读完整段才出结果，分块办法实测边界偏 2.6 秒、短段会丢
     （设计文档 §2.5）。

不在范围内的：电影、「其他」库、第 0 季（特别篇）、原盘与 strm（没有可读的本地字节）。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import shutil
import sys
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from sqlalchemy import func, or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import col, select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import foreground, jobs
from movieclaw_api.services.library.layout import STRM_EXT
from movieclaw_api.services.playback.session import get_session_manager
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    Library,
    LibraryFile,
    MediaItem,
    MediaMetadata,
    MediaSeason,
    MediaSegmentState,
    utcnow,
)
from movieclaw_db.models.library_file import DISC_CONTAINERS
from movieclaw_db.models.playback_state import PlaybackState
from movieclaw_playback import activity
from movieclaw_playback.skip_segments import (
    ALGO_VERSION,
    FINGERPRINT_VERSION,
    encode_fingerprint,
    window_bounds,
)

logger = logging.getLogger("movieclaw_api.library.skip_segments")

LIBRARY_JOB_TYPE = "library.skip_segments"
ITEM_JOB_TYPE = "media.skip_segments"

#: 比这短的文件不算：片头窗只有时长的 1/4，两分钟的短片里认不出什么
MIN_DURATION_S = 120
#: 单个窗口的 ffmpeg 超时：600 秒的 4K 片源经 NFS 读要二三十秒，留足余量
_FFMPEG_TIMEOUT_S = 600.0
#: 一季识别子进程的超时 = 基础 + 每集（78 集的长剧本机约 10 秒，NAS 慢几倍；365 集的日更剧约 70 秒）
_DETECT_BASE_TIMEOUT_S = 120.0
_DETECT_TIMEOUT_PER_EPISODE_S = 6.0
#: 开播后等多久再排作业：让开起播的关键窗口
_BUMP_DELAY_S = 20.0
#: 整库回填遇到有人在看片时，每隔多久再看一眼人走了没有（也是取消请求的响应间隔）
_QUIET_POLL_S = 3.0
#: 播放会话 / 转码会话多久没有动静就不再算「有人在看」：播放器每 10 秒左右上报一次进度或心跳，
#: 45 秒 = 连丢三个周期。浏览器被直接杀掉、App 崩了不会发「停止」，不设这个窗口会让回填白等好几分钟
_FRESH_S = 45.0
#: 开播提队 / 入库触发的条目作业一次最多读几个文件（其余留给整库回填，它会为在看的人让路）。
#: 这类作业本身不让路——入库读的是刚下载好的本地文件、开播提队本来就是因为有人开播——
#: 但整季可能有一大堆没算的旧集，不设上限就会为一集新片把整个积压从 NAS 上读一遍
PRIORITY_BATCH = 6
#: 第一段片头离文件开头不超过这么多毫秒时，下发给播放器的起点贴到 0（见 ``segments_for_file``）
_HEAD_SNAP_MS = 15_000
#: 多少天内看过的季算「正在追」，整库回填优先做（见 ``seasons_needing_work``）
_WATCHING_WINDOW = timedelta(days=30)

# ---------------------------------------------------------------------------
# 能力探测与并发槽
# ---------------------------------------------------------------------------

_chromaprint: bool | None = None


async def fingerprint_supported() -> bool:
    """当前 ffmpeg 能不能出 chromaprint 指纹（进程内只探一次）。

    Docker 镜像里的 jellyfin-ffmpeg 自带；源码部署时系统 ffmpeg 常常没编进这个
    封装器（Homebrew 的就没有），那就整个功能静默不做，日志说清楚一次。
    """
    global _chromaprint
    if _chromaprint is not None:
        return _chromaprint
    try:
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg",
            "-hide_banner",
            "-muxers",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=20)
        _chromaprint = any(
            line.split()[1:2] == [b"chromaprint"] for line in out.splitlines() if line.strip()
        )
    except (OSError, TimeoutError):
        _chromaprint = False
    if not _chromaprint:
        logger.warning(
            "当前 ffmpeg 不支持 chromaprint 音频指纹，片头片尾识别不会运行；"
            "Docker 镜像自带的 jellyfin-ffmpeg 支持，源码部署请换用 jellyfin-ffmpeg"
        )
    return _chromaprint


_slots: dict[str, tuple[asyncio.AbstractEventLoop, asyncio.Semaphore]] = {}


def _slot(name: str) -> asyncio.Semaphore:
    """全进程一次只跑一个 ffmpeg 指纹 / 一个识别子进程：护住 NAS 的读盘与 CPU。

    信号量绑定事件循环，按循环惰性创建（测试里每个用例一个新循环）。
    """
    loop = asyncio.get_running_loop()
    current = _slots.get(name)
    if current is None or current[0] is not loop:
        current = (loop, asyncio.Semaphore(1))
        _slots[name] = current
    return current[1]


def _niced(args: list[str]) -> list[str]:
    """给命令加上 ``nice -n 10`` 前缀：指纹读盘与解码不该抢播放与转码的 CPU / IO。

    不用 ``preexec_fn``：多线程进程里 fork 之后在子进程跑 Python 代码有死锁风险；
    没有 nice 命令的平台（Windows）原样运行。
    """
    nice = shutil.which("nice")
    return [nice, "-n", "10", *args] if nice else args


def playback_active() -> bool:
    """现在有没有人在看片：有未暂停且近期有动静的播放会话、有仍在服务的取流、或有近期有心跳的转码会话。

    数据来自进程内的播放活动注册表（播放器进度上报 + 取流字节计量，Web / iOS / Jellyfin
    客户端都汇到这里）。整库回填据此让路——它连续几个小时顺序读片库所在的磁盘 / 网络，
    和正在播的片子抢的是同一份 IO，而「播放不被打扰」比「识别早一小时完成」重要得多。
    """
    now = time.monotonic()
    sessions, meters = activity.snapshot()
    if any(m.kind == activity.STREAM_KIND_PLAY for m in meters):
        return True  # 正在往外发字节，一定在看
    if any(not s.paused and now - s.last_activity_mono <= _FRESH_S for s in sessions):
        return True
    return any(now - t.last_ping <= _FRESH_S for t in get_session_manager().active())


async def _wait_until_quiet(context: jobs.JobContext) -> None:
    """整库回填专用：有人在看片就暂停，片放完（或暂停播放）后自动继续。

    在处理器里直接等是安全的：调度器的心跳会一直续租约，取消也随时能打断（每轮都查）。
    入库时的条目作业与开播提队的作业**不等**——前者只读一集刚下载好的本地文件，
    后者本来就是因为有人开播才排的。
    """
    announced = False
    while playback_active():
        await context.raise_if_cancelled()
        if not announced:
            announced = True
            logger.info("有人正在看片，片头片尾识别先暂停，看完后自动继续")
            await context.update_progress(
                mode="indeterminate",
                phase="analyzing",
                message="有人正在看片，片头片尾识别先暂停，看完后自动继续",
            )
        await asyncio.sleep(_QUIET_POLL_S)
    if announced:
        # 进度平时只在一季做完时刷新，一季可能要读好几分钟；不在这里改掉「暂停」字样，
        # 任务中心会在已经恢复读盘后继续显示暂停，直到这一季做完
        logger.info("没人在看片了，片头片尾识别继续")
        await context.update_progress(
            mode="indeterminate",
            phase="analyzing",
            message="没人在看片了，继续识别片头片尾",
        )


# ---------------------------------------------------------------------------
# 哪些文件参与
# ---------------------------------------------------------------------------


def eligible_conditions() -> list:
    """参与识别的文件：开了开关的剧集库里、在位、有季号集号（第 0 季除外）、
    不是原盘与 strm、时长够。"""
    return [
        Library.kind == "tv",
        col(Library.detect_media_segments).is_(True),
        LibraryFile.in_place(),
        col(LibraryFile.media_item_id).is_not(None),
        col(LibraryFile.season_number) >= 1,
        col(LibraryFile.episode_number) >= 1,
        col(LibraryFile.duration_seconds) >= MIN_DURATION_S,
        or_(
            col(LibraryFile.container).is_(None),
            col(LibraryFile.container).not_in(sorted(DISC_CONTAINERS)),
        ),
        ~func.lower(LibraryFile.file_path).endswith(STRM_EXT),
    ]


def _needs_work_condition():
    """这个文件还有活要干：没记录、指纹没算、片源变了、或者整季识别过期。"""
    state = MediaSegmentState
    return or_(
        col(state.library_file_id).is_(None),
        state.fingerprint_status == "pending",
        col(state.source_size) != col(LibraryFile.size_bytes),
        (state.fingerprint_status == "ok")
        & (
            col(state.analyzed_at).is_(None)
            | (col(state.algo_version) != ALGO_VERSION)
            | col(state.algo_version).is_(None)
        ),
    )


async def seasons_needing_work(
    session: AsyncSession,
    *,
    library_id: int | None = None,
    media_item_id: int | None = None,
    season_number: int | None = None,
) -> list[tuple[int, int]]:
    """有活要干的季 (media_item_id, season_number)，按「用户最可能先看到」排好序。

    整库回填要跑好几个小时，顺序决定用户多久能在想看的剧里用上「跳过片头」
    （docs/design/skip-intro.md §3.1）。分五档，档内从新到旧：

    1. 正在追的季：``_WATCHING_WINDOW`` 内看过、还没看完——按最后观看时间；
    2. 追剧的下一季：上一档那部剧最近在看的那季的下一季——看完这季马上要用；
    3. 没看过的剧的第一季（库里最小的季号）：没看过的剧几乎都从头看起，
       先让每部剧的开头都有片头，比把一部剧的所有季做完更有用——按首播日期；
    4. 其余还没看完的季——按首播日期；
    5. 已看完的季、很久没碰过的剧——最后做。

    首播日期优先用季的首播日期，缺了用剧的首播日期。不用入库时间：重建库、批量拷入时
    入库时间全挤在一起，排不出先后。观看记录不分成员，任何人在看都算。
    作业每做完一季重新调用一次，新开始追的剧会被立刻提前。
    """
    query = (
        select(LibraryFile.media_item_id, LibraryFile.season_number)
        .join(Library, col(Library.id) == col(LibraryFile.library_id))
        .outerjoin(
            MediaSegmentState,
            col(MediaSegmentState.library_file_id) == col(LibraryFile.id),
        )
        .where(*eligible_conditions(), _needs_work_condition())
        .group_by(LibraryFile.media_item_id, LibraryFile.season_number)
    )
    if library_id is not None:
        query = query.where(LibraryFile.library_id == library_id)
    if media_item_id is not None:
        query = query.where(LibraryFile.media_item_id == media_item_id)
    if season_number is not None:
        query = query.where(LibraryFile.season_number == season_number)
    keys = [(int(i), int(s)) for i, s in (await session.execute(query)).all()]
    if not keys:
        return []

    item_ids = sorted({i for i, _ in keys})
    season_eps: dict[tuple[int, int], set[int]] = {}  # 库里这一季有哪些集
    played_eps: dict[tuple[int, int], set[int]] = {}  # 其中被看完的集
    season_seen: dict[tuple[int, int], datetime] = {}  # 这一季最后一次被看的时间
    item_seen: dict[int, tuple[datetime, int]] = {}  # 这部剧最后一次被看的时间与季号
    season_air: dict[tuple[int, int], date] = {}
    show_air: dict[int, date] = {}
    for chunk in (item_ids[i : i + 500] for i in range(0, len(item_ids), 500)):
        files = await session.execute(
            select(LibraryFile.media_item_id, LibraryFile.season_number, LibraryFile.episode_number)
            .where(col(LibraryFile.media_item_id).in_(chunk), col(LibraryFile.season_number) > 0)
            .distinct()
        )
        for i, s, e in files.all():
            if e is not None:
                season_eps.setdefault((int(i), int(s)), set()).add(int(e))
        states = await session.execute(
            select(
                PlaybackState.media_item_id,
                PlaybackState.season_number,
                PlaybackState.episode_number,
                PlaybackState.played,
                PlaybackState.last_played_at,
            ).where(
                col(PlaybackState.media_item_id).in_(chunk),
                col(PlaybackState.season_number) > 0,
            )
        )
        for i, s, e, played, at in states.all():
            key = (int(i), int(s))
            if played:
                played_eps.setdefault(key, set()).add(int(e))
            if at is not None:
                if key not in season_seen or at > season_seen[key]:
                    season_seen[key] = at
                if int(i) not in item_seen or at > item_seen[int(i)][0]:
                    item_seen[int(i)] = (at, int(s))
        seasons = await session.execute(
            select(MediaSeason.media_item_id, MediaSeason.season_number, MediaSeason.air_date)
            .where(col(MediaSeason.media_item_id).in_(chunk))
            .where(col(MediaSeason.air_date).is_not(None))
        )
        season_air.update({(int(i), int(s)): d for i, s, d in seasons.all()})
        shows = await session.execute(
            select(MediaMetadata.media_item_id, MediaMetadata.release_date)
            .where(col(MediaMetadata.media_item_id).in_(chunk))
            .where(col(MediaMetadata.release_date).is_not(None))
        )
        show_air.update({int(i): d for i, d in shows.all()})

    first_season: dict[int, int] = {}
    for i, s in season_eps:
        first_season[i] = min(s, first_season.get(i, s))
    cutoff = utcnow() - _WATCHING_WINDOW

    def rank(key: tuple[int, int]) -> tuple[int, float, int, int]:
        item, season = key
        aired = season_air.get(key) or show_air.get(item)
        air_score = float(aired.toordinal()) if aired else 0.0
        eps = season_eps.get(key, set())
        if eps and eps <= played_eps.get(key, set()):
            tier = 5  # 这季看完了
        elif item not in item_seen:
            tier = 3 if season == first_season.get(item, season) else 4
        elif item_seen[item][0] < cutoff:
            tier = 5  # 看过但很久没碰，多半弃了
        elif key in season_seen and season_seen[key] >= cutoff:
            return (1, -season_seen[key].timestamp(), item, season)
        elif season == item_seen[item][1] + 1:
            return (2, -item_seen[item][0].timestamp(), item, season)
        else:
            tier = 4
        return (tier, -air_score, item, season)

    return sorted(keys, key=rank)


# ---------------------------------------------------------------------------
# 指纹
# ---------------------------------------------------------------------------


def fingerprint_path(file_id: int) -> Path:
    return Path(get_settings().audio_fingerprint_dir) / f"{file_id}.fp"


class FingerprintError(Exception):
    """算不了指纹（中文原因直接给用户看）。"""


async def _chromaprint_window(path: str, start: float, length: float) -> bytes:
    """ffmpeg 读一个窗口的第一条音轨，输出原始哈希字节。"""
    args = ["ffmpeg", "-nostdin", "-v", "error"]
    if start > 0:
        args += ["-ss", f"{start:.3f}"]
    args += ["-i", path, "-t", f"{length:.3f}", "-map", "0:a:0", "-ac", "2"]
    args += ["-f", "chromaprint", "-fp_format", "raw", "-"]
    proc = await asyncio.create_subprocess_exec(
        *_niced(args), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=_FFMPEG_TIMEOUT_S)
    except TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        await proc.wait()
        raise FingerprintError("读取超时（片源所在的磁盘或网络太慢）") from None
    except asyncio.CancelledError:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        raise
    if proc.returncode == 0 and not out:
        raise FingerprintError("音轨太短，算不出指纹")
    if proc.returncode != 0 or not out:
        text = err.decode("utf-8", "replace").strip()
        if "matches no streams" in text or "does not contain any stream" in text:
            raise FingerprintError("文件没有音轨")
        if "No such file" in text:
            raise FingerprintError("文件读不到（可能已被移走）")
        if "Invalid data found" in text or "moov atom not found" in text:
            raise FingerprintError("文件已损坏或不是可识别的视频")
        tail = text.splitlines()[-1] if text else f"ffmpeg 退出码 {proc.returncode}"
        raise FingerprintError(f"音频解码失败：{tail[:200]}")
    return out


async def compute_fingerprint(file: LibraryFile) -> None:
    """算一个文件的片头窗 + 片尾窗指纹，原子写入缓存文件。失败抛 ``FingerprintError``。

    **调用方要持有 ffmpeg 槽**（``_slot("ffmpeg")``）：全进程一次只读一个文件，护住 NAS 的读盘。
    """
    assert file.id is not None
    duration = float(file.duration_seconds or 0)
    bounds = window_bounds(duration)
    windows: dict[str, bytes] = {}
    for name, (start, length) in bounds.items():
        windows[name] = await _chromaprint_window(file.file_path, start, length)
    meta = {
        "file_id": file.id,
        "size": file.size_bytes,
        "duration": duration,
        "windows": {name: {"start": s, "length": n} for name, (s, n) in bounds.items()},
    }
    path = fingerprint_path(file.id)

    def _write() -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        staging = path.with_name(f".{path.name}.part")
        staging.write_bytes(encode_fingerprint(meta, windows))
        os.replace(staging, path)

    await asyncio.to_thread(_write)


def _fingerprint_readable(file_id: int) -> bool:
    """缓存文件还在且是当前格式（用户可能在缓存管理里清空过）。"""
    path = fingerprint_path(file_id)
    try:
        with path.open("rb") as f:
            head = f.readline(4096)
        meta = json.loads(head)
    except (OSError, ValueError):
        return False
    return isinstance(meta, dict) and meta.get("v") == FINGERPRINT_VERSION


# ---------------------------------------------------------------------------
# 一季
# ---------------------------------------------------------------------------


@dataclass
class SeasonOutcome:
    """一季跑完的统计（作业进度与日志用）。"""

    files: int = 0
    fingerprinted: int = 0
    failed: int = 0
    analyzed: bool = False
    with_intro: int = 0
    with_outro: int = 0


async def _season_files(
    session: AsyncSession, media_item_id: int, season_number: int
) -> list[tuple[LibraryFile, MediaSegmentState | None]]:
    query = (
        select(LibraryFile, MediaSegmentState)
        .join(Library, col(Library.id) == col(LibraryFile.library_id))
        .outerjoin(
            MediaSegmentState,
            col(MediaSegmentState.library_file_id) == col(LibraryFile.id),
        )
        .where(
            *eligible_conditions(),
            LibraryFile.media_item_id == media_item_id,
            LibraryFile.season_number == season_number,
        )
        .order_by(col(LibraryFile.episode_number), col(LibraryFile.id))
    )
    return list((await session.execute(query)).all())


def _fingerprint_due(file: LibraryFile, state: MediaSegmentState | None) -> bool:
    if state is None or state.fingerprint_status == "pending":
        return True
    if state.source_size != file.size_bytes:
        return True  # 片源变了（洗版原地替换），失败的也重试一次
    return state.fingerprint_status == "ok" and not _fingerprint_readable(int(file.id or 0))


async def _run_detection(episodes: list[dict[str, Any]]) -> dict[str, Any]:
    """在独立子进程里跑整季比对（见模块说明：不在服务进程里抢 GIL）。

    子进程入口自己调低优先级（``movieclaw_playback.skip_segments._main``）。超时随季的
    集数放大：两两比对的次数与集数成正比，几百集的日更剧在 NAS 上要几分钟。
    """
    timeout = _DETECT_BASE_TIMEOUT_S + _DETECT_TIMEOUT_PER_EPISODE_S * len(episodes)
    # 子进程继承当前的模块搜索路径：应用内更新的 overlay 是父进程启动时才加进 sys.path 的，
    # 不显式传下去，子进程只看得到镜像里那份旧代码（甚至找不到本模块）。
    # 与 video_cues 的 worker 同款写法
    env = dict(os.environ, PYTHONPATH=os.pathsep.join(p for p in sys.path if p))
    async with _slot("detect"):
        proc = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "movieclaw_playback.skip_segments",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        try:
            out, err = await asyncio.wait_for(
                proc.communicate(json.dumps({"episodes": episodes}).encode()),
                timeout=timeout,
            )
        except (TimeoutError, asyncio.CancelledError):
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
            await proc.wait()
            raise
    if proc.returncode != 0:
        detail = err.decode("utf-8", "replace").strip().splitlines()
        raise RuntimeError(f"片头片尾识别进程出错：{detail[-1] if detail else proc.returncode}")
    return json.loads(out)


async def _fingerprint_one(file: LibraryFile) -> str:
    """算一个文件的指纹并把状态写进台账，返回 ``ok`` / ``failed`` / ``skipped``。

    排到 ffmpeg 槽之后**先复查还要不要算**，复查和写状态都在槽里做：同一季有两个作业并行时
    （入库的条目作业 + 整库回填），前一个可能刚把这个文件算完，后一个手里的清单已经过时了。
    """
    assert file.id is not None
    db = get_database()
    async with _slot("ffmpeg"):
        async with db.session() as session:
            fresh = await session.get(MediaSegmentState, file.id)
        if not _fingerprint_due(file, fresh):
            return "skipped"
        error: str | None = None
        try:
            await compute_fingerprint(file)
        except FingerprintError as exc:
            error = str(exc)
            logger.warning("文件 #%s 算不了片头片尾指纹：%s（%s）", file.id, error, file.file_path)
        async with db.session() as session:
            row = await session.get(MediaSegmentState, file.id)
            if row is None:
                row = MediaSegmentState(library_file_id=file.id)
            row.fingerprint_status = "failed" if error else "ok"
            row.error = error
            row.source_size = file.size_bytes
            row.fingerprinted_at = None if error else utcnow()
            # 新指纹进来，这一季要整季重比：先把自己的识别时间清掉
            row.analyzed_at = None
            row.updated_at = utcnow()
            session.add(row)
            await session.commit()
    return "failed" if error else "ok"


async def analyze_season(
    media_item_id: int,
    season_number: int,
    *,
    context: jobs.JobContext | None = None,
    polite: bool = False,
    max_new: int | None = None,
    prefer_episode: int | None = None,
) -> SeasonOutcome:
    """把一季做完：补齐缺的指纹，再整季识别一遍（有新指纹或结果过期时）。

    每个文件的指纹单独提交——作业中途被取消、服务重启，已经算好的不会白算。
    ``polite``：每个文件开读前，有人在看片就先等（整库回填用，见 ``_wait_until_quiet``）。
    ``max_new``：这次最多新算几个指纹（``PRIORITY_BATCH``），多出来的留给整库回填；挑哪几个：
    给了 ``prefer_episode`` 就先挑离它最近的集（开播提队：在看第 N 集，先把 N 附近的算出来），
    否则先挑最新入库的（入库触发）。识别照样用已有的全部指纹做，只是积压的旧集要等回填。
    """
    db = get_database()
    outcome = SeasonOutcome()
    async with db.session() as session:
        rows = await _season_files(session, media_item_id, season_number)
    outcome.files = len(rows)
    due = [(file, state) for file, state in rows if _fingerprint_due(file, state)]
    if max_new is not None and len(due) > max_new:
        if prefer_episode is not None:
            due.sort(key=lambda fs: abs(int(fs[0].episode_number or 0) - prefer_episode))
        else:
            due.sort(key=lambda fs: fs[0].created_at, reverse=True)
        due = due[: max(max_new, 0)]
    for file, _ in due:
        if context is not None:
            await context.raise_if_cancelled()
            if polite:
                await _wait_until_quiet(context)
        # 前台有请求在等响应就让一步（services/foreground.py）：页面加载的那一两秒里别抢数据库
        await foreground.yield_to_foreground()
        result = await _fingerprint_one(file)
        if result == "failed":
            outcome.failed += 1
        elif result == "ok":
            outcome.fingerprinted += 1

    async with db.session() as session:
        rows = await _season_files(session, media_item_id, season_number)
        ready = [(f, s) for f, s in rows if s is not None and s.fingerprint_status == "ok"]
        stale = any(
            s.analyzed_at is None or s.algo_version != ALGO_VERSION or s.segments is None
            for _, s in ready
        )
    if not ready or not stale:
        return outcome
    if context is not None:
        await context.raise_if_cancelled()
    episodes = [
        {
            "file_id": int(f.id),  # type: ignore[arg-type]
            "episode": int(f.episode_number or 0),
            "duration": float(f.duration_seconds or 0),
            "path": str(fingerprint_path(int(f.id))),  # type: ignore[arg-type]
        }
        for f, _ in ready
    ]
    response = await _run_detection(episodes)
    results: dict[str, list[dict[str, Any]]] = response.get("results", {})
    unreadable = {int(i) for i in response.get("unreadable", [])}
    now = utcnow()
    async with db.session() as session:
        for f, _ in ready:
            row = await session.get(MediaSegmentState, f.id)
            if row is None:
                continue
            if int(f.id or 0) in unreadable:
                # 指纹文件在比对前被清掉 / 读不了（缓存管理里清空过，本次又没轮到重算它）：
                # 不动它现有的结果——播放照常给原来的片头；它在下次这一季重算指纹时补回
                continue
            segments = results.get(str(f.id), [])
            row.segments = segments
            row.algo_version = int(response.get("algo_version") or ALGO_VERSION)
            row.analyzed_at = now
            outcome.with_intro += any(s.get("type") == "intro" for s in segments)
            outcome.with_outro += any(s.get("type") == "outro" for s in segments)
            row.updated_at = now
            session.add(row)
        await session.commit()
    outcome.analyzed = True
    logger.info(
        "片头片尾识别：条目 #%s 第 %s 季 %s 个文件，认出片头 %s 个、片尾 %s 个",
        media_item_id,
        season_number,
        len(ready),
        outcome.with_intro,
        outcome.with_outro,
    )
    return outcome


# ---------------------------------------------------------------------------
# 播放下发
# ---------------------------------------------------------------------------


async def segments_for_file(session: AsyncSession, file: LibraryFile) -> list[dict[str, Any]]:
    """播放器要的片段（毫秒）：库开着开关、识别过才有，否则空表。两次主键查询。"""
    if file.id is None or file.library_id is None:
        return []
    state = await session.get(MediaSegmentState, file.id)
    if state is None or not state.segments or state.fingerprint_status != "ok":
        return []
    library = await session.get(Library, file.library_id)
    if library is None or library.kind != "tv" or not library.detect_media_segments:
        return []
    segments = [dict(s) for s in state.segments]
    # 片头前那几秒多是平台台标、片名卡，不值得单独看：第一段离开头不到 _HEAD_SNAP_MS 就从 0 算起，
    # 开播就给「跳过」，不必等到冠名广告真正响起才冒出来（用户反馈 2026-10-01）。
    # 只改下发的区间，库里存的仍是识别原值；跳到的终点不变
    first = min(segments, key=lambda seg: seg["start_ms"], default=None)
    if first is not None and 0 < first["start_ms"] <= _HEAD_SNAP_MS:
        first["start_ms"] = 0
    return segments


_bump_pending: set[tuple[int, int]] = set()
_bump_tasks: set[asyncio.Task] = set()


def schedule_playback_bump(file: LibraryFile) -> None:
    """开播时顺手看一眼：这一季还没算过，就排一份优先的条目作业（后台、延迟、去重）。

    不在起播路径上做任何查询：延迟 ``_BUMP_DELAY_S`` 后用自己的数据库会话判断。
    """
    if file.media_item_id is None or not file.season_number or not file.episode_number:
        return
    key = (int(file.media_item_id), int(file.season_number))
    if key in _bump_pending:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    _bump_pending.add(key)
    task = loop.create_task(_bump(*key, int(file.episode_number)))
    _bump_tasks.add(task)
    task.add_done_callback(_bump_tasks.discard)


async def _bump(media_item_id: int, season_number: int, episode_number: int) -> None:
    try:
        await asyncio.sleep(_BUMP_DELAY_S)
        if not await fingerprint_supported():
            return
        async with get_database().session() as session:
            seasons = await seasons_needing_work(
                session, media_item_id=media_item_id, season_number=season_number
            )
            if not seasons:
                return
            item = await session.get(MediaItem, media_item_id)
            title = item.title if item is not None else f"条目 #{media_item_id}"
            await enqueue_item_job(
                session,
                media_item_id,
                title,
                season_number=season_number,
                episode_number=episode_number,
                priority=0,
            )
    except Exception:  # noqa: BLE001 —— 锦上添花，绝不影响播放
        logger.warning("开播时排片头片尾识别失败（条目 #%s）", media_item_id, exc_info=True)
    finally:
        _bump_pending.discard((media_item_id, season_number))


# ---------------------------------------------------------------------------
# 作业
# ---------------------------------------------------------------------------


async def enqueue_library_job(
    session: AsyncSession,
    library_id: int,
    library_name: str,
    *,
    origin: str = "system",
) -> jobs.CreateJobResult:
    """整库补缺：同库同时只跑一份，低优先级。

    库资源挂 ``context`` 不占 ``library:{id}`` 租约（与章节同一考虑）：首轮回填可能
    跑好几个小时，占着租约会把扫描、监听入库都挡在外面；它只读媒体文件、只写自己的表。
    """
    return await jobs.create_job(
        session,
        job_type=LIBRARY_JOB_TYPE,
        subject=library_name,
        input_data={"library_id": library_id},
        resources=[jobs.ResourceRef("library", library_id, "context")],
        dedupe_key=f"{LIBRARY_JOB_TYPE}:{library_id}",
        conflict_policy="return_existing",
        handler_revision=f"{LIBRARY_JOB_TYPE}.v1",
        max_attempts=2,
        priority=-10,
        origin=origin,
        progress=jobs.default_progress("等待识别片头片尾"),
    )


async def enqueue_item_job(
    session: AsyncSession,
    media_item_id: int,
    title: str,
    *,
    season_number: int | None = None,
    episode_number: int | None = None,
    priority: int = -5,
    origin: str = "system",
) -> jobs.CreateJobResult:
    """单条目（可限定一季）：入库与开播用。同条目同时只跑一份。

    入库传 -5（比整库回填 -10 先跑，又不挤占用户等着看结果的作业），开播传 0。
    """
    return await jobs.create_job(
        session,
        job_type=ITEM_JOB_TYPE,
        subject=title,
        input_data={
            "media_item_id": media_item_id,
            "season_number": season_number,
            "episode_number": episode_number,
        },
        resources=[jobs.ResourceRef("media_item", media_item_id)],
        dedupe_key=f"{ITEM_JOB_TYPE}:{media_item_id}",
        conflict_policy="return_existing",
        handler_revision=f"{ITEM_JOB_TYPE}.v1",
        max_attempts=2,
        priority=priority,
        origin=origin,
        progress=jobs.default_progress(f"等待识别《{title}》的片头片尾"),
    )


async def enqueue_after_library_change(library_id: int, *, origin: str = "system") -> bool:
    """库里的文件有变动之后，有活才排一份整库补缺，返回是否入队。

    三个扫描入口共用：扫描作业收尾（含定期对账）、监听触发的增量扫描、暂缓文件的补扫——
    后两者直接调 ``scan_library`` 不经过扫描作业，手工把文件拷进库目录的用户不该等到下一轮
    对账才有片头。库没开开关 / 不是剧集库 / ffmpeg 不支持 / 没有待办的季时什么都不做：
    没活就不排，免得任务中心每次扫描后多一条「处理 0 季」的空记录。
    """
    async with get_database().session() as session:
        library = await session.get(Library, library_id)
        if library is None or library.kind != "tv" or not library.detect_media_segments:
            return False
        if not await fingerprint_supported():
            return False
        if not await seasons_needing_work(session, library_id=library_id):
            return False
        await enqueue_library_job(session, library_id, library.name, origin=origin)
    return True


async def enqueue_after_scan(library_id: int, summary: object) -> bool:
    """直接调 ``scan_library`` 的两条路径（监听触发的增量扫描、暂缓文件的补扫）扫完之后调用。

    这一轮真有新文件入账（或待识别的行这轮认出来了）才去查有没有待办：没入账任何东西的扫描
    （事件抖动、只是某个文件被改过）不该为此多一次数据库查询——监听去抖之后每批都会走到这里。
    原地换掉片源这类不增加文件的变动，由下一次扫描作业收尾的挂钩接住。
    ``summary`` 不是真正的扫描结果（测试替身返回 None）时按「没入账」处理，安全。
    """
    if not (getattr(summary, "scanned", 0) or getattr(summary, "retried", 0)):
        return False
    return await enqueue_after_library_change(library_id)


async def enqueue_ingested_item(
    session: AsyncSession, library: Library | None, media_item_id: int, title: str
) -> bool:
    """入库落账后给这一部排识别（库关了开关、不是剧集库就什么都不做）。"""
    if library is None or library.kind != "tv" or not library.detect_media_segments:
        return False
    if not await fingerprint_supported():
        return False
    await enqueue_item_job(session, media_item_id, title, priority=-5)
    return True


async def apply_library_switch(
    session: AsyncSession,
    library: Library,
    *,
    was_enabled: bool,
    rescan_queued: bool = False,
    origin: str = "system",
) -> None:
    """编辑库保存后按开关变化收放作业：关 → 取消本库进行中的整库识别；开 → 立即补缺。

    这次保存改了根路径会重扫，扫描收尾自己会排，不重复。
    """
    if library.id is None or library.kind != "tv":
        return
    if was_enabled == library.detect_media_segments:
        return
    if not library.detect_media_segments:
        for job in await jobs.list_jobs(
            session,
            active_only=True,
            job_type=LIBRARY_JOB_TYPE,
            resource_type="library",
            resource_id=library.id,
        ):
            await jobs.request_cancel(
                session,
                job.id,
                requested_by="媒体库配置变更",
                reason=f"「{library.name}」已关闭「识别片头片尾」，未完成的识别随之取消",
            )
        return
    if rescan_queued:
        return
    # 有待办的季才排（打开开关后库里没有要补的就不留一条空记录）
    await enqueue_after_library_change(library.id, origin=origin)


#: 同一季在一个作业里最多做几次：防止某个季反复出新活（或怎么做都还剩活）时作业永远收不了尾
_MAX_ROUNDS = 5


async def _run_seasons(
    context: jobs.JobContext,
    find: Callable[[AsyncSession], Awaitable[list[tuple[int, int]]]],
    *,
    subject: str,
    polite: bool = False,
    budget: int | None = None,
    prefer_episode: int | None = None,
) -> dict[str, Any]:
    """逐季处理的公共循环（整库与条目作业共用）。断点天然：做完的季不再是「有活要干」。

    ``budget``：整个作业最多新算几个指纹（条目作业传 ``PRIORITY_BATCH``，整库回填不限）。

    **每做完一季重新取一次清单**、做排在最前的那季：整库回填要跑几个小时，只在开头排一次序的话，
    作业期间刚开始追的剧要等到最后（排序见 ``seasons_needing_work``）。这一查只读数据库，
    比读一季的文件快几个数量级。同样也接住了运行期间新落位的集：同库 / 同条目已有作业在跑时，
    后来的排队请求会被 ``return_existing`` 并进这一个作业。
    同一季最多做 ``_MAX_ROUNDS`` 次（做完仍有活，比如期间又落了新集），出错的季本作业不再重试——
    都是为了不原地打转。
    """
    stats = {"seasons": 0, "fingerprinted": 0, "failed": 0, "errors": 0}
    attempts: dict[tuple[int, int], int] = {}
    done = 0
    while True:
        await context.raise_if_cancelled()
        left = None if budget is None else budget - stats["fingerprinted"] - stats["failed"]
        if left is not None and left <= 0:
            break
        async with get_database().session() as session:
            todo = [key for key in await find(session) if attempts.get(key, 0) < _MAX_ROUNDS]
        if not todo:
            break
        item_id, season = todo[0]
        attempts[(item_id, season)] = attempts.get((item_id, season), 0) + 1
        try:
            outcome = await analyze_season(
                item_id,
                season,
                context=context,
                polite=polite,
                max_new=left,
                prefer_episode=prefer_episode,
            )
        except (jobs.JobCancelled, asyncio.CancelledError):
            raise
        except Exception:  # noqa: BLE001 —— 一季出错不打断整批
            stats["errors"] += 1
            attempts[(item_id, season)] = _MAX_ROUNDS
            logger.exception("条目 #%s 第 %s 季的片头片尾识别出错", item_id, season)
        else:
            stats["seasons"] += 1
            stats["fingerprinted"] += outcome.fingerprinted
            stats["failed"] += outcome.failed
        done += 1
        total = done + len(todo) - 1
        if total == done or context.progress_due():
            await context.update_progress(
                mode="determinate",
                phase="analyzing",
                message=f"正在识别片头片尾：第 {done}/{total} 季",
                current=done,
                total=total,
                percent=round(done * 100 / total, 1) if total else 100.0,
                details=dict(stats),
            )
    logger.info("%s的片头片尾识别完成：%s", subject, stats)
    return stats


def _summary(stats: dict[str, Any]) -> str:
    message = f"片头片尾识别完成：处理 {stats['seasons']} 季，新算指纹 {stats['fingerprinted']} 集"
    if stats["failed"]:
        message += f"，{stats['failed']} 集算不了（多为没有音轨或文件读不到）"
    if stats["errors"]:
        message += f"，{stats['errors']} 季出错（详见日志）"
    return message


_UNSUPPORTED = (
    "当前 ffmpeg 不支持音频指纹（chromaprint），片头片尾识别已跳过。"
    "Docker 镜像自带的 jellyfin-ffmpeg 支持；源码部署请换用 jellyfin-ffmpeg"
)


@jobs.register_job_handler(LIBRARY_JOB_TYPE)
async def _run_library_job(context: jobs.JobContext, input_data: dict[str, Any]) -> dict[str, Any]:
    from movieclaw_api.services.library.organize import is_organizing
    from movieclaw_api.services.library.transfer import is_transferring

    library_id = int(input_data["library_id"])
    # 与整理 / 转移互斥：它们正在批量改文件路径（不占库租约，所以自己检查）
    if is_organizing(library_id) or is_transferring(library_id):
        raise jobs.JobRetry("媒体库正在变更文件路径，片头片尾识别稍后自动继续", delay_seconds=30)
    async with get_database().session() as session:
        library = await session.get(Library, library_id)
        if library is None:
            raise jobs.JobFailed("媒体库已不存在，无法识别片头片尾", code="LIBRARY_NOT_FOUND")
        if library.kind != "tv" or not library.detect_media_segments:
            return {"message": f"「{library.name}」没有打开片头片尾识别，本次未处理"}
        if not await fingerprint_supported():
            return {"message": _UNSUPPORTED}

    async def find(session: AsyncSession) -> list[tuple[int, int]]:
        return await seasons_needing_work(session, library_id=library_id)

    stats = await _run_seasons(context, find, subject=f"媒体库 #{library_id}", polite=True)
    return {"message": _summary(stats), **stats}


@jobs.register_job_handler(ITEM_JOB_TYPE)
async def _run_item_job(context: jobs.JobContext, input_data: dict[str, Any]) -> dict[str, Any]:
    media_item_id = int(input_data["media_item_id"])
    season = input_data.get("season_number")
    episode = input_data.get("episode_number")
    if not await fingerprint_supported():
        return {"message": _UNSUPPORTED}

    async def find(session: AsyncSession) -> list[tuple[int, int]]:
        return await seasons_needing_work(
            session,
            media_item_id=media_item_id,
            season_number=int(season) if season is not None else None,
        )

    stats = await _run_seasons(
        context,
        find,
        subject=f"条目 #{media_item_id}",
        budget=PRIORITY_BATCH,
        prefer_episode=int(episode) if episode is not None else None,
    )
    # 积压没做完的交给整库回填（它会为在看片的人让路）：按条目所在的库各排一份
    async with get_database().session() as session:
        left = await seasons_needing_work(session, media_item_id=media_item_id)
        library_ids = (
            sorted(
                {
                    int(i)
                    for i in (
                        await session.execute(
                            select(LibraryFile.library_id).where(
                                LibraryFile.media_item_id == media_item_id
                            )
                        )
                    )
                    .scalars()
                    .all()
                }
            )
            if left
            else []
        )
    for library_id in library_ids:
        await enqueue_after_library_change(library_id)
    return {"message": _summary(stats), **stats}

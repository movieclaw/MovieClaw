"""预切片段：把每部片挑好的那一段离线切成 1080p 小文件，预告与刷片放它（docs/design/reels.md §8）。

**为什么离线**：NAS 没有核显，实时转码撑不起「停留 2 秒就开播、几台同时开」；原画直推又要从片库
读几百 MB、电视上开完整引擎解 4K HDR。切一次之后，每次预告只读本地一个十几 MB 的文件。

**规格**（§8.3，VMAF 实测定的）：宽不超过 1920、帧率超过 30 的减半；H.264 High，CRF 23 封顶 5 Mbps，
关键帧 2 秒；HDR / 杜比视界与封面抓帧同一套色彩决策（``build_filter_chains``）；AAC 立体声；
MP4 + faststart。

**存储**：``<reels_clips_dir>/<文件 id>/<起点毫秒>-v<CLIP_VERSION>.mp4``，旁边同名
``.json`` 记来源文件的大小与修改时间（洗版换了文件就不认）。切不了的（片源坏、P5 映射不了）
也记一份，同一份片源不再重试。进程内有一张「条目 → 切好的片段」登记表（``_Registry``），
刷片过滤、预告查询都只查它，不碰数据库。

**先切谁**（§8.5）：单路串行，四档——0 眼前（请求到了还没切的，后到先切、只留 3 部）>
1 首页会出现的（近期看过、最近入库）> 2 其余电影与剧集（按刷片的评分权重）> 3 「其他」库。
档 0 来了会停掉正在切的低档那一部、放回原档。让路复用片头识别的 ``playback_load``：
本机在转码全停（正在切的也停）；有人在看只切档 0；空闲全切。

**开关**：设置 → 播放「片段预切」（``PlaybackPolicySetting.reel_clips_enabled``，默认关）。
关掉即停，已切的留着（设置页问删不删）。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import shutil
import tempfile
import time
from collections import deque
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Any

from sqlalchemy import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library import skip_segments
from movieclaw_api.services.library.thumbs import build_filter_chains
from movieclaw_api.services.media_probe import VideoColor, video_color_for
from movieclaw_api.services.reels.segments import ReelSegment
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile, MediaItem, PlaybackState, utcnow
from movieclaw_playback.streaming import is_strm

logger = logging.getLogger("movieclaw_api.reels.clips")

#: 规格变了就 +1：旧片段全部作废重切
CLIP_VERSION = 1
MAX_WIDTH = 1920
MAX_FPS = 30.0
CRF = 23
MAXRATE_KBPS = 5000
BUFSIZE_KBPS = 10000
PRESET = "faster"
AUDIO_KBPS = 128
GOP_SECONDS = 2
#: 一段最多切多久：4K 源软解约 1～2 倍实时，45 秒一段正常一分钟内，卡死的进程到点就杀
FFMPEG_TIMEOUT_S = 15 * 60
#: 档 0 最多留几部：用户扫过一排卡片，只有最后停住的几张要紧
NOW_KEEP = 3
#: 档 1 收哪些：多少天内有观看记录的、最近入库的多少部
HOME_RECENT_DAYS = 30
HOME_RECENT_ADDED = 40
#: 整库排队多久重排一轮：扫描新入库的片不经过入库钩子，靠它补上（只排没切过的，很便宜）
REPLAN_S = 3600.0
#: 等让路时多久重看一次播放状态；切的过程中多久看一次要不要停
_YIELD_POLL_S = 10.0
_RUN_POLL_S = 5.0

TIER_NOW, TIER_HOME, TIER_LIBRARY, TIER_OTHER = 0, 1, 2, 3
_TIERS = 4


# --- 规格：一段怎么切 ------------------------------------------------------------


def output_fps(frame_rate: float | None) -> float | None:
    """输出帧率：超过 30 的减半（60→30、50→25），其余不动（返回 None = 不加 fps 滤镜）。"""
    if frame_rate and frame_rate > MAX_FPS + 1:
        return round(frame_rate / 2, 3)
    return None


def build_command(
    *,
    input_args: Sequence[str],
    duration_s: float,
    chain: Sequence[str],
    fps: float | None,
    source_fps: float | None,
    audio_map: str | None,
    dest: Path,
) -> list[str]:
    """一段的 ffmpeg 命令。

    ``input_args`` 已含定位（``-ss``）与输入；``chain`` 是色彩滤镜链候选之一。
    """
    vf = [f for f in chain if f != "null"]
    if fps:
        vf.append(f"fps={fps:g}")
    gop = str(max(1, round((fps or source_fps or 24.0) * GOP_SECONDS)))
    args = [
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-y",
        *input_args,
        "-t",
        f"{duration_s:.3f}",
        "-map",
        "0:v:0",
    ]
    if audio_map:
        args += ["-map", audio_map]
    args += [
        "-vf",
        ",".join(vf),
        "-c:v",
        "libx264",
        "-preset",
        PRESET,
        "-crf",
        str(CRF),
        "-maxrate",
        f"{MAXRATE_KBPS}k",
        "-bufsize",
        f"{BUFSIZE_KBPS}k",
        "-profile:v",
        "high",
        "-pix_fmt",
        "yuv420p",
        "-g",
        gop,
        "-keyint_min",
        gop,
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
    ]
    if audio_map:
        args += ["-c:a", "aac", "-b:a", f"{AUDIO_KBPS}k", "-ac", "2"]
    args += ["-sn", "-dn", "-map_metadata", "-1", "-movflags", "+faststart", "-f", "mp4", str(dest)]
    return args


def scale_filter() -> str:
    """宽不超过 1920、不放大、高按比例取偶数。"""
    return f"scale='min({MAX_WIDTH},iw)':-2:flags=lanczos"


# --- 登记表：哪些条目有切好的片段 ------------------------------------------------


@dataclass(frozen=True)
class ClipInfo:
    media_item_id: int
    file_id: int
    start_ms: int
    end_ms: int
    size_bytes: int
    src_size: int | None
    src_mtime_ns: int | None

    @property
    def name(self) -> str:
        return f"{self.start_ms}-v{CLIP_VERSION}.mp4"

    @property
    def path(self) -> Path:
        return clips_root() / str(self.file_id) / self.name

    @property
    def url_path(self) -> str:
        return f"/api/v1/reels/clips/{self.file_id}/{self.start_ms}.mp4"


def clips_root() -> Path:
    return Path(get_settings().reels_clips_dir)


class _Registry:
    """条目 → 切好的片段；文件 id → 切不了的那份片源（大小, 修改时间）。

    第一次用时扫一遍片段目录的 ``.json`` 建起来（一千来个小文件，几十毫秒），之后随切随删更新。
    """

    def __init__(self) -> None:
        self.loaded = False
        self.by_item: dict[int, ClipInfo] = {}
        self.failed: dict[int, tuple[int | None, int | None]] = {}

    def ensure(self) -> None:
        if self.loaded:
            return
        self.loaded = True
        root = clips_root()
        if not root.is_dir():
            return
        for sidecar in root.glob("*/*.json"):
            try:
                record = json.loads(sidecar.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if record.get("v") != CLIP_VERSION:
                continue
            if record.get("failed"):
                self.failed[int(record["file_id"])] = (
                    record.get("src_size"),
                    record.get("src_mtime_ns"),
                )
                continue
            info = _info_from(record)
            if info is not None and info.path.is_file():
                self.by_item[info.media_item_id] = info

    def put(self, info: ClipInfo) -> None:
        self.ensure()
        self.by_item[info.media_item_id] = info
        self.failed.pop(info.file_id, None)


def _info_from(record: dict[str, Any]) -> ClipInfo | None:
    try:
        return ClipInfo(
            media_item_id=int(record["media_item_id"]),
            file_id=int(record["file_id"]),
            start_ms=int(record["start_ms"]),
            end_ms=int(record["end_ms"]),
            size_bytes=int(record["size"]),
            src_size=record.get("src_size"),
            src_mtime_ns=record.get("src_mtime_ns"),
        )
    except (KeyError, TypeError, ValueError):
        return None


_registry = _Registry()


def ready_clip(file: LibraryFile, segment: ReelSegment) -> ClipInfo | None:
    """这个文件、这一段有没有切好的（来源文件没换过、起点没变、文件还在）。"""
    _registry.ensure()
    info = _registry.by_item.get(int(file.media_item_id or 0))
    if (
        info is None
        or info.file_id != int(file.id or 0)
        or info.start_ms != segment.start_ms
        or info.src_size != file.size_bytes
        or info.src_mtime_ns != file.file_mtime_ns
    ):
        return None
    return info if info.path.is_file() else None


def ready_item_ids() -> set[int]:
    """切好的条目。顺手剔除文件已经不在的（存储页清空过缓存、手动删过目录）：
    一千来次 stat，毫秒级。"""
    _registry.ensure()
    gone = [item for item, info in _registry.by_item.items() if not info.path.is_file()]
    for item in gone:
        del _registry.by_item[item]
    return set(_registry.by_item)


def clip_for_file(file_id: int, start_ms: int) -> ClipInfo | None:
    """取流路由用：按文件 id + 起点找片段。"""
    _registry.ensure()
    for info in _registry.by_item.values():
        if info.file_id == file_id and info.start_ms == start_ms:
            return info if info.path.is_file() else None
    return None


def _failed_before(file: LibraryFile) -> bool:
    _registry.ensure()
    return _registry.failed.get(int(file.id or 0)) == (file.size_bytes, file.file_mtime_ns)


def stats() -> dict[str, int]:
    """已切片段的数量与总大小（关开关前问删不删用）。"""
    _registry.ensure()
    return {
        "count": len(_registry.by_item),
        "bytes": sum(info.size_bytes for info in _registry.by_item.values()),
    }


async def delete_all() -> dict[str, int]:
    """清空全部片段（先停队列）。返回删掉前的统计。"""
    before = stats()
    await stop()
    await asyncio.to_thread(shutil.rmtree, clips_root(), True)
    _registry.by_item.clear()
    _registry.failed.clear()
    return before


# --- 切一段 ------------------------------------------------------------------------


class ClipError(Exception):
    """这份片源切不了（记下来不再重试）。"""


async def _input_args(file: LibraryFile, start_s: float) -> tuple[list[str], Path | None]:
    """ffmpeg 的定位 + 输入参数；光盘写一份 concat 清单（返回它的路径，切完删）。"""
    from movieclaw_api.services.playback.iso_source import transcode_disc_source

    if file.is_disc():
        disc = await asyncio.to_thread(transcode_disc_source, file)
        if disc is None:
            raise ClipError("读不出光盘的主播放列表")
        fd, name = tempfile.mkstemp(prefix="reel-clip-", suffix=".ffconcat")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(disc.concat_list())
        listing = Path(name)
        args = ["-f", "concat", "-safe", "0", "-protocol_whitelist", "file,subfile,concat"]
        return [*args, "-ss", f"{start_s:.3f}", "-i", str(listing)], listing
    return ["-ss", f"{start_s:.3f}", "-i", file.file_path], None


def _audio_map(file: LibraryFile) -> str | None:
    from movieclaw_api.services.reels.tracks import choose_audio

    if not file.audio_streams:
        return None
    if file.is_disc():
        return "0:a:0?"
    ordinal = choose_audio(file.audio_streams)
    return f"0:a:{ordinal}?" if ordinal is not None else None


def _niced(args: list[str]) -> list[str]:
    nice = shutil.which("nice")
    return [nice, "-n", "19", *args] if nice else args


class _Stopped(Exception):
    """切到一半被叫停（插队、转码让路、关开关）。"""


async def generate(
    file: LibraryFile, segment: ReelSegment, *, should_stop=lambda: False
) -> ClipInfo:
    """切一段，原子落盘并登记。

    ``should_stop`` 每几秒问一次，为真就杀掉 ffmpeg、抛 ``_Stopped``（临时文件随之删掉）。
    """
    if is_strm(file.file_path):
        raise ClipError("网盘 strm 没有本机字节可读")
    color = (
        VideoColor(hdr=file.hdr)
        if file.is_disc()
        else await asyncio.to_thread(video_color_for, file.file_path, fallback_hdr=file.hdr)
    )
    folder = clips_root() / str(file.id)
    await asyncio.to_thread(folder.mkdir, parents=True, exist_ok=True)
    part = folder / f".{segment.start_ms}-v{CLIP_VERSION}.mp4.part"
    input_args, listing = await _input_args(file, segment.start_ms / 1000)
    try:
        errors = []
        for chain in build_filter_chains(color, scale_filter(), thumbnail="null"):
            cmd = build_command(
                input_args=input_args,
                duration_s=(segment.end_ms - segment.start_ms) / 1000,
                chain=chain,
                fps=output_fps(file.frame_rate),
                source_fps=file.frame_rate,
                audio_map=_audio_map(file),
                dest=part,
            )
            code, stderr = await _run(cmd, should_stop)
            if code == 0 and part.is_file() and part.stat().st_size > 0:
                break
            errors.append(stderr.strip()[-300:])
        else:
            raise ClipError("；".join(errors) or "ffmpeg 没有产出")
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    finally:
        if listing is not None:
            listing.unlink(missing_ok=True)
    return await install(file, segment, part)


async def install(file: LibraryFile, segment: ReelSegment, part: Path) -> ClipInfo:
    """把切好的临时文件原子换成正式片段，写记录、删同一文件的旧片段、登记。"""
    _registry.ensure()
    folder = clips_root() / str(file.id)
    name = f"{segment.start_ms}-v{CLIP_VERSION}.mp4"
    dest = folder / name
    os.replace(part, dest)
    info = ClipInfo(
        media_item_id=int(file.media_item_id or 0),
        file_id=int(file.id or 0),
        start_ms=segment.start_ms,
        end_ms=segment.end_ms,
        size_bytes=dest.stat().st_size,
        src_size=file.size_bytes,
        src_mtime_ns=file.file_mtime_ns,
    )
    _write_sidecar(folder, name, _record(info))
    # 同一个文件以前切的（起点变了、旧规格）一并删掉
    for old in folder.iterdir():
        if old.name not in (name, f"{name}.json"):
            old.unlink(missing_ok=True)
    previous = _registry.by_item.get(info.media_item_id)
    if previous is not None and previous.file_id != info.file_id:
        await asyncio.to_thread(shutil.rmtree, previous.path.parent, True)
    _registry.put(info)
    return info


def _record(info: ClipInfo) -> dict[str, Any]:
    return {
        "v": CLIP_VERSION,
        "media_item_id": info.media_item_id,
        "file_id": info.file_id,
        "start_ms": info.start_ms,
        "end_ms": info.end_ms,
        "size": info.size_bytes,
        "src_size": info.src_size,
        "src_mtime_ns": info.src_mtime_ns,
    }


def _write_sidecar(folder: Path, name: str, record: dict[str, Any]) -> None:
    tmp = folder / f".{name}.json.part"
    tmp.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, folder / f"{name}.json")


def _mark_failed(file: LibraryFile, reason: str) -> None:
    folder = clips_root() / str(file.id)
    try:
        folder.mkdir(parents=True, exist_ok=True)
        _write_sidecar(
            folder,
            f"failed-v{CLIP_VERSION}",
            {
                "v": CLIP_VERSION,
                "failed": reason[:500],
                "file_id": int(file.id or 0),
                "src_size": file.size_bytes,
                "src_mtime_ns": file.file_mtime_ns,
            },
        )
    except OSError:
        logger.warning("片段预切：记录失败结果写不进去（%s）", folder, exc_info=True)
    _registry.ensure()
    _registry.failed[int(file.id or 0)] = (file.size_bytes, file.file_mtime_ns)


async def _run(cmd: list[str], should_stop) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        *_niced(cmd), stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE
    )
    stderr_task = asyncio.ensure_future(proc.stderr.read())  # type: ignore[union-attr]
    deadline = time.monotonic() + FFMPEG_TIMEOUT_S
    try:
        while True:
            try:
                await asyncio.wait_for(proc.wait(), _RUN_POLL_S)
                break
            except TimeoutError:
                if should_stop():
                    raise _Stopped from None
                if time.monotonic() > deadline:
                    raise ClipError("ffmpeg 超时") from None
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        with contextlib.suppress(Exception):
            await proc.wait()
        stderr_task.cancel()
        raise
    stderr = (await stderr_task).decode("utf-8", "replace")
    return proc.returncode or 0, stderr


# --- 队列 --------------------------------------------------------------------------


def allowed_tier(load: str) -> int:
    """此刻最多切到第几档：转码全停（-1）；有人在看只切档 0；空闲全切。"""
    if load == skip_segments.TRANSCODING:
        return -1
    if load == skip_segments.PLAYING:
        return TIER_NOW
    return _TIERS - 1


class ClipQueue:
    """四档队列 + 单个工作协程。按事件循环各建一个（测试里每个用例一个新循环）。"""

    def __init__(self) -> None:
        self.tiers: list[deque[int]] = [deque() for _ in range(_TIERS)]
        self.queued: dict[int, int] = {}
        self.current: tuple[int, int] | None = None
        self.preempt = False
        self.paused: str | None = None
        self.wake = asyncio.Event()
        self.worker: asyncio.Task[None] | None = None
        #: 排过整库的池子（"film" / "video"）→ 排的时刻；第一轮排完后 ``planned`` 才为真
        self.planned_pools: dict[str, float] = {}
        self.planned = False

    def put(self, item_id: int, tier: int) -> None:
        old = self.queued.get(item_id)
        if old is not None and old <= tier and tier != TIER_NOW:
            return
        if self.current is not None and self.current[0] == item_id:
            return
        if old is not None:
            self.tiers[old].remove(item_id)
        if tier == TIER_NOW:
            self.tiers[TIER_NOW].appendleft(item_id)
            while len(self.tiers[TIER_NOW]) > NOW_KEEP:
                demoted = self.tiers[TIER_NOW].pop()
                self.tiers[TIER_HOME].appendleft(demoted)
                self.queued[demoted] = TIER_HOME
            if self.current is not None and self.current[1] > TIER_NOW:
                self.preempt = True
        else:
            self.tiers[tier].append(item_id)
        self.queued[item_id] = tier
        self.wake.set()

    def pop(self, max_tier: int) -> tuple[int, int] | None:
        for tier in range(0, max_tier + 1):
            if self.tiers[tier]:
                item_id = self.tiers[tier].popleft()
                del self.queued[item_id]
                return item_id, tier
        return None

    def requeue_front(self, item_id: int, tier: int) -> None:
        if item_id in self.queued:
            return
        self.tiers[tier].appendleft(item_id)
        self.queued[item_id] = tier

    @property
    def pending(self) -> int:
        return len(self.queued) + (1 if self.current else 0)

    def state(self) -> str:
        if self.paused and self.pending:
            return "paused"
        return "running" if self.pending or not self.planned else "done"

    def clear(self) -> None:
        for tier in self.tiers:
            tier.clear()
        self.queued.clear()


_queues: dict[asyncio.AbstractEventLoop, ClipQueue] = {}


def get_queue() -> ClipQueue:
    loop = asyncio.get_running_loop()
    queue = _queues.get(loop)
    if queue is None:
        for stale in [lp for lp in _queues if lp.is_closed()]:
            del _queues[stale]
        queue = _queues[loop] = ClipQueue()
    return queue


def _start_worker(queue: ClipQueue) -> None:
    if queue.worker is None or queue.worker.done():
        queue.worker = asyncio.create_task(_work(queue))


async def _work(queue: ClipQueue) -> None:
    while True:
        load = skip_segments.playback_load()
        job = queue.pop(allowed_tier(load))
        if job is None:
            if queue.queued:
                queue.paused = "正在转码播放" if load == skip_segments.TRANSCODING else "有人在观看"
            queue.wake.clear()
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(queue.wake.wait(), _YIELD_POLL_S)
            continue
        queue.paused = None
        queue.current, queue.preempt = job, False
        try:
            await _process(queue, *job)
        except _Stopped:
            queue.requeue_front(*job)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 —— 一部切坏了不能拖垮队列
            logger.exception("片段预切失败：条目 %s", job[0])
        finally:
            queue.current = None


def _should_stop(queue: ClipQueue, tier: int):
    def check() -> bool:
        if queue.preempt and tier > TIER_NOW:
            return True
        return skip_segments.playback_load() == skip_segments.TRANSCODING

    return check


async def _process(queue: ClipQueue, item_id: int, tier: int) -> None:
    from movieclaw_api.services.reels import feed, segments

    async with get_database().session() as session:
        libraries = await _clip_libraries(session)
        files = (await feed._files_of(session, [item_id], list(libraries))).get(item_id, [])
    if not files:
        return
    kind = feed.unit_kind(libraries.get(files[0].library_id, "movie"))
    chosen = feed.choose_file(files, kind)
    if chosen is None or _failed_before(chosen) or is_strm(chosen.file_path):
        return
    segment = await segments.get_segment(feed._file_ref(chosen, kind))
    if segment is None or ready_clip(chosen, segment) is not None:
        return
    started = time.monotonic()
    try:
        info = await generate(chosen, segment, should_stop=_should_stop(queue, tier))
    except ClipError as exc:
        logger.warning("片段预切：条目 %s 文件 %s 切不了（%s）", item_id, chosen.id, exc)
        _mark_failed(chosen, str(exc))
        return
    logger.info(
        "片段预切：条目 %s（档 %s）%.1f 秒，%.1f MB",
        item_id,
        tier,
        time.monotonic() - started,
        info.size_bytes / 1e6,
    )


async def _clip_libraries(session) -> dict[int, str]:
    from movieclaw_db.models import Library

    rows = await session.execute(select(Library.id, Library.kind))
    return {int(lid): str(kind) for lid, kind in rows.all()}


# --- 对外：开关、排队、进度 ----------------------------------------------------------


async def enabled() -> bool:
    from movieclaw_api.settings.playback import PlaybackPolicySetting
    from movieclaw_api.settings.store import get_setting_store

    return bool((await get_setting_store().get(PlaybackPolicySetting)).reel_clips_enabled)


async def request_now(media_item_id: int) -> None:
    """预告 / 刷片要到了还没切的：排进档 0（顺手确保整库补切已排上）。"""
    queue = get_queue()
    queue.put(media_item_id, TIER_NOW)
    ensure_planned()
    _start_worker(queue)


def ensure_planned(*, video: bool = False) -> None:
    """开关开着时第一次用到片段：排一轮整库（只排没切过的）。``video`` 另排「其他」库。"""
    queue = get_queue()
    key = "video" if video else "film"
    last = queue.planned_pools.get(key)
    if last is not None and time.monotonic() - last < REPLAN_S:
        return
    queue.planned_pools[key] = time.monotonic()
    task = asyncio.create_task(_plan(queue, video=video))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


_tasks: set[asyncio.Task[Any]] = set()


async def _plan(queue: ClipQueue, *, video: bool) -> None:
    from movieclaw_api.services.library.access import NO_CONTENT_LIMIT
    from movieclaw_api.services.reels import feed

    try:
        async with get_database().session() as session:
            libraries = {
                lid: kind
                for lid, kind in (await _clip_libraries(session)).items()
                if (kind == "video") == video and kind in ("movie", "tv", "video")
            }
            if not libraries:
                return
            pool = await feed._title_pool(session, libraries, NO_CONTENT_LIMIT, None, 0)
            home = set() if video else await _home_items(session)
            ordered = feed.weighted_order(
                pool, await feed._ratings_of(session, [i for i, _ in pool]), seed=0
            )
        ready = ready_item_ids()
        tier = TIER_OTHER if video else TIER_LIBRARY
        for item_id, _kind in ordered:
            if item_id in ready:
                continue
            queue.put(item_id, TIER_HOME if item_id in home else tier)
        _cleanup_orphans_later(video)
        logger.info("片段预切：排队 %d 部（%s）", queue.pending, "其他" if video else "电影 / 剧集")
    except Exception:  # noqa: BLE001
        logger.warning("片段预切：整库排队失败", exc_info=True)
    finally:
        queue.planned = True
        _start_worker(queue)


async def _home_items(session) -> set[int]:
    """档 1：近期有观看记录的、最近入库的。"""
    since = utcnow() - timedelta(days=HOME_RECENT_DAYS)
    watched = await session.execute(
        select(PlaybackState.media_item_id).where(PlaybackState.updated_at >= since).distinct()
    )
    recent = await session.execute(
        select(MediaItem.id).order_by(MediaItem.created_at.desc()).limit(HOME_RECENT_ADDED)  # type: ignore[union-attr]
    )
    return {int(i) for i in watched.scalars()} | {int(i) for i in recent.scalars()}


def _cleanup_orphans_later(video: bool) -> None:
    if video:
        return

    async def cleanup() -> None:
        async with get_database().session() as session:
            ids = {int(i) for i in (await session.execute(select(LibraryFile.id))).scalars()}
        root = clips_root()
        if not root.is_dir():
            return
        for folder in root.iterdir():
            if folder.is_dir() and folder.name.isdigit() and int(folder.name) not in ids:
                await asyncio.to_thread(shutil.rmtree, folder, True)
                for item_id, info in list(_registry.by_item.items()):
                    if info.file_id == int(folder.name):
                        del _registry.by_item[item_id]

    task = asyncio.create_task(cleanup())
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def enqueue_ingested(media_item_id: int) -> None:
    """入库钩子：新片刚落位（还在本地盘上，读起来最便宜），开关开着就排进档 1。"""
    try:
        if await enabled():
            on_file_changed(media_item_id)
    except Exception:  # noqa: BLE001 —— 预切是锦上添花，不能影响入库
        logger.warning("片段预切：入库排队失败（条目 %s）", media_item_id, exc_info=True)


def on_file_changed(media_item_id: int) -> None:
    """入库 / 洗版换了文件：开关开着就排进档 1（调用方已确认开关）。"""
    queue = get_queue()
    queue.put(media_item_id, TIER_HOME)
    _start_worker(queue)


async def start() -> None:
    """打开开关：排一轮整库并开始切。"""
    ensure_planned()
    _start_worker(get_queue())


async def stop() -> None:
    """关掉开关：清队列、停掉正在切的那一段。"""
    queue = get_queue()
    queue.clear()
    queue.planned_pools.clear()
    queue.planned = False
    worker, queue.worker = queue.worker, None
    if worker is not None:
        worker.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await worker


async def library_progress() -> dict[str, Any]:
    """设置页用：全部电影与剧集里切好了几部。"""
    from movieclaw_api.services.library.access import NO_CONTENT_LIMIT
    from movieclaw_api.services.reels import feed

    async with get_database().session() as session:
        libraries = {
            lid: kind
            for lid, kind in (await _clip_libraries(session)).items()
            if kind in ("movie", "tv")
        }
        pool = (
            await feed._title_pool(session, libraries, NO_CONTENT_LIMIT, None, 0)
            if libraries
            else []
        )
    return progress([item_id for item_id, _ in pool])


def progress(pool_item_ids: Sequence[int]) -> dict[str, Any]:
    """这个池子（刷片当前筛选）切好了几部，队列在不在动。"""
    ready = ready_item_ids()
    done = sum(1 for i in pool_item_ids if i in ready)
    # 全切好了就是完成：刚重新打开开关时整库排队还在跑，不该显示「还在切」
    state = "done" if pool_item_ids and done >= len(pool_item_ids) else get_queue().state()
    return {"ready": done, "total": len(pool_item_ids), "state": state}

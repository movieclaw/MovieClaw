"""刷片片段：为一个文件算出「放哪一段」，带封面，结果落盘缓存。

一个文件的片段只算一次：读容器索引（零点几秒）→ 挑点（毫秒级）→ 抓起点那一帧当
封面（零点几秒～两秒），结果写成 ``data/cache/reels/<文件id>.json``。之后同一文件
再刷到，直接读这份记录。记录按「文件大小 + 修改时间 + 算法版本」认账：洗版换了文件、
挑点规则改了（``ALGO_VERSION`` +1），都会自然重算。

**黑场检查**：章节起点常是淡入，第一帧是全黑的——刷片里一滑过来先看到黑屏，观感
像是坏了。抓到的封面平均亮度太低，就把起点往后挪到下一个关键帧（每次至少 2 秒，
最多挪 3 次），终点与预取范围随之重算。挪完还是暗（夜戏本来就暗）就照用。

**并发**：同一文件同时被两次请求要到时共用一次计算（``_in_flight``）；计算本身
限 3 路并发，抓帧与章节图、主图共用 ``FRAME_GRAB_GATE``（最多两路 ffmpeg）。
计算放在独立任务里，请求超时或客户端断开都不会打断它——下次就能直接用。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import weakref
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library.thumbs import FRAME_GRAB_GATE, build_filter_chains
from movieclaw_api.services.media_probe import VideoColor, video_color_for
from movieclaw_api.services.media_scrape import assets_root
from movieclaw_api.services.reels import disc_index
from movieclaw_api.services.reels.picker import ByteRange, SegmentPick, pick_segment, reanchor
from movieclaw_api.services.reels.tracks import choose_subtitle
from movieclaw_db.models.library_file import DISC_CONTAINERS
from movieclaw_playback.container_index import KIND_SUBTITLE, ContainerIndex, read_container_index
from movieclaw_playback.streaming import is_strm

logger = logging.getLogger("movieclaw_api.reels")

#: 挑点规则或记录格式变了就 +1，已有记录全部作废重算
ALGO_VERSION = 1
#: 「这个文件挑不了」的判定规则版本：放宽了能挑的片源（如读不出索引改按台账片长挑）就 +1，
#: 只让以前判成挑不了的重算，挑好的片段与封面不动
UNSUPPORTED_VERSION = 2
#: 封面平均亮度（0～255）低于它算黑场
DARK_LUMA = 16.0
#: 黑场时起点往后挪的次数与每次至少挪多远（秒）
DARK_RETRIES = 3
DARK_STEP_S = 2.0
#: 封面宽度：竖屏横条 1260 像素宽，960 足够且与章节场景图一致
_COVER_SCALE = "scale='min(960,iw)':-2"
_FFMPEG_TIMEOUT = 30.0

#: 同时算片段的上限。按事件循环各建一个：模块级的信号量一旦等待过就绑死在当时的
#: 循环上，换一个循环（测试里每个用例一个）再用会报错
_COMPUTE_LIMIT = 3
_compute_gates: weakref.WeakKeyDictionary[asyncio.AbstractEventLoop, asyncio.Semaphore] = (
    weakref.WeakKeyDictionary()
)
_in_flight: dict[int, asyncio.Task[ReelSegment | None]] = {}


def _compute_gate() -> asyncio.Semaphore:
    loop = asyncio.get_running_loop()
    gate = _compute_gates.get(loop)
    if gate is None:
        gate = _compute_gates[loop] = asyncio.Semaphore(_COMPUTE_LIMIT)
    return gate


@dataclass(frozen=True)
class FileRef:
    """算片段需要的那一点台账信息（脱离数据库会话，能安全地交给后台任务）。"""

    id: int
    media_item_id: int
    path: str
    kind: str  # movie / episode
    size_bytes: int | None = None
    mtime_ns: int | None = None
    duration_s: float | None = None
    hdr: str | None = None
    subtitle_streams: list[dict[str, Any]] | None = None
    #: 台账容器（mkv / mp4 / ts / bluray / iso / dvd ……），决定从哪里读索引
    container: str | None = None
    #: 原盘目录的主播放列表（台账 ``disc_playlist``）
    disc_playlist: dict[str, Any] | None = None
    #: 台账章节 [{"start_ms": …}]：读不出索引的片源按它挑场景开头
    chapters: list[dict[str, Any]] | None = None

    @property
    def local_file(self) -> bool:
        """是 NAS 本机上的一个普通视频文件（ffmpeg 能直接从中间抓帧；不是光盘、不是网盘 strm）。"""
        return (self.container or "") not in DISC_CONTAINERS and not is_strm(self.path)


@dataclass(frozen=True)
class ReelSegment:
    """一个文件挑出来的片段。时间是原片时间轴上的毫秒。"""

    file_id: int
    start_ms: int
    end_ms: int
    method: str
    score: float
    prefetch: tuple[ByteRange, ...]
    #: 封面在图片资产目录里的相对路径；抓不出图（如杜比视界 P5 没有色调映射）为 None
    cover: str | None


def cover_rel_path(media_item_id: int, file_id: int, start_ms: int) -> str:
    """封面相对资产根目录的路径。首段是条目 id：``/images/assets`` 靠它做可见性校验，
    条目删除时整目录一起清理（与章节场景图同一套规则）。"""
    return f"{media_item_id}/reels/{file_id}/{start_ms:010d}.jpg"


# --- 缓存 ------------------------------------------------------------------------

_MISS = object()


def _cache_file(file_id: int) -> Path:
    return Path(get_settings().reels_cache_dir) / f"{file_id}.json"


def _read_cache(ref: FileRef) -> ReelSegment | None | object:
    """读缓存：命中返回片段；命中「这个文件挑不了」返回 None；没有或已过期返回 _MISS。"""
    path = _cache_file(ref.id)
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return _MISS
    if (
        record.get("v") != ALGO_VERSION
        or record.get("size") != ref.size_bytes
        or record.get("mtime_ns") != ref.mtime_ns
    ):
        return _MISS
    if "unsupported" in record:
        return None if record.get("uv") == UNSUPPORTED_VERSION else _MISS
    seg = record.get("segment") or {}
    try:
        return ReelSegment(
            file_id=ref.id,
            start_ms=int(seg["start_ms"]),
            end_ms=int(seg["end_ms"]),
            method=str(seg["method"]),
            score=float(seg.get("score") or 0.0),
            prefetch=tuple(
                ByteRange(int(o), int(n), str(p)) for o, n, p in seg.get("prefetch") or []
            ),
            cover=seg.get("cover"),
        )
    except (KeyError, TypeError, ValueError):
        return _MISS


def _write_cache(ref: FileRef, payload: dict[str, Any]) -> None:
    path = _cache_file(ref.id)
    record = {"v": ALGO_VERSION, "size": ref.size_bytes, "mtime_ns": ref.mtime_ns, **payload}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.part")
        tmp.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)
    except OSError as exc:
        # 写不进缓存不影响这次使用，只是下次还要重算
        logger.warning("刷片挑点结果写入缓存失败：%s（%s）", path, exc)


def cached_segment(ref: FileRef) -> ReelSegment | None | object:
    """只查缓存、不计算。返回值同 ``_read_cache``（外部用 ``is_miss`` 判断没算过）。"""
    return _read_cache(ref)


def is_miss(value: object) -> bool:
    return value is _MISS


# --- 计算 ------------------------------------------------------------------------


async def get_segment(ref: FileRef) -> ReelSegment | None:
    """取一个文件的片段：有缓存直接用，没有就算（同一文件并发请求共用一次计算）。

    返回 None 表示这个文件挑不了（容器不支持、没有索引、太短），调用方跳过它。
    """
    cached = _read_cache(ref)
    if cached is not _MISS:
        return cached  # type: ignore[return-value]
    task = _in_flight.get(ref.id)
    if task is None:
        task = asyncio.create_task(_compute(ref))
        _in_flight[ref.id] = task
        task.add_done_callback(lambda _t, fid=ref.id: _in_flight.pop(fid, None))
    # shield：请求被取消（超时、客户端断开）时计算照常跑完、结果照常落盘
    return await asyncio.shield(task)


def _speech_events(index: ContainerIndex, subtitle_ordinal: int | None) -> tuple[float, ...] | None:
    """判断「有没有人在说话」用的字幕事件：优先用刷片要显示的那条中文字幕，
    没有就用第一条有事件的字幕轨（对白的时间与语言无关）。"""
    subtitles = index.tracks_of(KIND_SUBTITLE)
    if subtitle_ordinal is not None:
        for track in subtitles:
            if track.order == subtitle_ordinal and index.subtitle_events.get(track.number):
                return index.subtitle_events[track.number]
    for track in subtitles:
        events = index.subtitle_events.get(track.number)
        if events:
            return events
    return None


async def _compute(ref: FileRef) -> ReelSegment | None:
    async with _compute_gate():
        try:
            return await _compute_locked(ref)
        except Exception:  # noqa: BLE001 —— 一个文件出错不能拖垮整页，记下来跳过
            logger.exception("刷片挑点失败：文件 %s（%s）", ref.id, ref.path)
            return None


def index_for(ref: FileRef) -> ContainerIndex | None:
    """一个文件的片段索引（阻塞 IO，放线程里调）。

    Matroska / MP4 读容器索引；光盘读盘上结构（disc_index.py）；其余片源（TS、AVI、WMV、
    网盘 strm……）以及前两类读不出的，按台账片长与章节给一份没有关键帧的索引——挑点按时间，
    起点交给 App 引擎定位。连片长都没有返回 None（这个文件挑不了）。
    """
    container = (ref.container or "").lower()
    index: ContainerIndex | None = None
    if container == "bluray":
        index = disc_index.bluray_folder_index(ref.path, ref.disc_playlist)
    elif container == "iso":
        index = disc_index.iso_index(ref.path)
    elif container == "dvd":
        index = disc_index.dvd_folder_index(ref.path)
    elif ref.local_file:
        index = read_container_index(ref.path)
    if index is not None and index.duration_s > 0:
        if index.chapters or not ref.chapters:
            return index
        return replace(index, chapters=_ledger_chapters(ref.chapters))
    if not ref.duration_s:
        return None
    return ContainerIndex(
        container=container or "unknown",
        file_size=ref.size_bytes or 0,
        duration_s=ref.duration_s,
        keyframes=(),
        tracks=(),
        chapters=_ledger_chapters(ref.chapters),
    )


def _ledger_chapters(chapters: list[dict[str, Any]] | None) -> tuple[tuple[float, str | None], ...]:
    out = []
    for chapter in chapters or []:
        start = chapter.get("start_ms") if isinstance(chapter, dict) else None
        if isinstance(start, (int, float)) and start >= 0:
            out.append((start / 1000, chapter.get("title")))
    return tuple(sorted(out, key=lambda c: c[0]))


async def _compute_locked(ref: FileRef) -> ReelSegment | None:
    index = await asyncio.to_thread(index_for, ref)
    if index is None:
        _write_cache(ref, {"unsupported": "读不出索引，台账也没有片长", "uv": UNSUPPORTED_VERSION})
        return None
    speech = _speech_events(index, choose_subtitle(ref.subtitle_streams))
    pick = pick_segment(index, kind=ref.kind, speech_events=speech, duration_s=ref.duration_s)
    if pick is None:
        _write_cache(ref, {"unsupported": "片子太短", "uv": UNSUPPORTED_VERSION})
        return None

    cover: str | None = None
    # 封面靠 ffmpeg 从起点抓一帧：光盘（目录或镜像）、网盘 strm 抓不了，用剧照
    if ref.local_file:
        try:
            color = await asyncio.to_thread(video_color_for, ref.path, fallback_hdr=ref.hdr)
            pick, cover = await _cover_with_dark_guard(ref, index, pick, speech, color)
        except (OSError, subprocess.SubprocessError) as exc:
            logger.warning("刷片封面抓取失败：文件 %s（%s）", ref.id, exc)

    segment = ReelSegment(
        file_id=ref.id,
        start_ms=int(round(pick.start_s * 1000)),
        end_ms=int(round(pick.end_s * 1000)),
        method=pick.method,
        score=pick.score,
        prefetch=pick.prefetch,
        cover=cover,
    )
    _write_cache(
        ref,
        {
            "segment": {
                "start_ms": segment.start_ms,
                "end_ms": segment.end_ms,
                "method": segment.method,
                "score": segment.score,
                "prefetch": [[r.offset, r.length, r.purpose] for r in segment.prefetch],
                "cover": segment.cover,
            }
        },
    )
    return segment


async def _cover_with_dark_guard(
    ref: FileRef,
    index: ContainerIndex,
    pick: SegmentPick,
    speech: tuple[float, ...] | None,
    color: VideoColor,
) -> tuple[SegmentPick, str | None]:
    """抓起点那一帧做封面；是黑场就把起点往后挪，最后返回（可能挪过的）片段与封面路径。"""
    times = [k.time_s for k in index.keyframes]
    for attempt in range(DARK_RETRIES + 1):
        start_ms = int(round(pick.start_s * 1000))
        rel = cover_rel_path(ref.media_item_id, ref.id, start_ms)
        dest = assets_root() / rel
        async with FRAME_GRAB_GATE:
            ok = await asyncio.to_thread(grab_frame, Path(ref.path), dest, pick.start_s, color)
        if not ok:
            return pick, None
        luma = await asyncio.to_thread(mean_luma, dest)
        if luma is None or luma >= DARK_LUMA or attempt == DARK_RETRIES:
            return pick, rel
        later = next((t for t in times if t >= pick.start_s + DARK_STEP_S), None)
        if later is None or later > pick.start_s + 10.0:
            return pick, rel
        dest.unlink(missing_ok=True)
        pick = reanchor(index, pick, later, speech_events=speech, duration_s=ref.duration_s)
    return pick, None


def grab_frame(video: Path, dest: Path, seconds: float, color: VideoColor) -> bool:
    """只解关键帧，取 ``seconds`` 处那一个关键帧（片段的第一帧）存成 JPEG。

    与章节场景图共用色彩决策（``build_filter_chains``：SDR 不动、HDR 色调映射、
    杜比视界 P5 只给映射链）。不用 ``thumbnail`` 挑代表帧——封面要的就是一滑过来
    看到的那一帧。``-noaccurate_seek``：定位到不晚于目标的关键帧后直接出这一帧，
    目标多给 10 毫秒防止时间戳舍入落到前一个 GOP。
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    for chain in build_filter_chains(color, _COVER_SCALE, thumbnail="null"):
        cmd = [
            "ffmpeg",
            "-v",
            "error",
            "-y",
            "-skip_frame",
            "nokey",
            "-noaccurate_seek",
            "-ss",
            f"{seconds + 0.010:.3f}",
            "-i",
            str(video),
            "-an",
            "-sn",
            "-vf",
            ",".join(chain),
            "-frames:v",
            "1",
            "-q:v",
            "4",
            str(dest),
        ]
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=_FFMPEG_TIMEOUT)
        except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
            logger.warning("刷片封面抓帧失败：%s（%s）", video, exc)
            return False
        if proc.returncode == 0 and dest.is_file():
            return True
    return False


def mean_luma(path: Path) -> float | None:
    """图片的平均亮度（0～255）；读不出返回 None（按不是黑场处理）。"""
    try:
        from PIL import Image, ImageStat

        with Image.open(path) as image:
            return float(ImageStat.Stat(image.convert("L")).mean[0])
    except (OSError, ValueError):
        return None

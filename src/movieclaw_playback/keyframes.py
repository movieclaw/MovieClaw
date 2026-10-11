"""全片关键帧索引——服务端生成 VOD 播放列表的地基（docs/design/web-player.md §12）。

为什么需要全片索引而不是采样：VOD 播放列表要在开会话时一次性写出**每个分片
的精确时长**（EXTINF）。直通档 ``-c:v copy`` 只能切在源片已有的关键帧上，
分片边界必须与 ffmpeg 实际会切的位置逐一吻合，差半个 GOP 播放器就会在
seek 时拿错分片。采样估出的平均间隔（media_probe）只够回答「稀不稀疏」，
回答不了「第 137 个分片从哪一秒开始」。

两条读取路径，按容器分：

- **Matroska（mkv）**：解析文件里的 Cues 索引元素。remux 场景的 mkv 基本
  出自 mkvmerge，它默认给视频轨每个 I 帧写一个 CuePoint；Cues 整块只有
  几十 KB 且 SeekHead 直接给出偏移，读一次是毫秒级。**不能**用 ffprobe：
  mkv 没有全局包索引，ffprobe 列包要顺序读完整个文件，30 GB 的 remux
  要读几分钟。（Jellyfin 的 MatroskaKeyframeExtractor 同款思路。）
- **MP4 / MOV**：读 moov 的样本表算关键帧的呈现时间，并抽检关键帧样本的 NAL 类型
  （``container_index.read_mp4_keyframe_times``），零点几秒。**不能**用 ffprobe 列包：
  ffprobe 列包会顺带把每个包的数据读出来，等于通读整个 mdat——2026-10-01 NAS 实测网络
  挂载上一部 10 GB 的 MP4 开会话「准备」93 秒，网页第一次播放要等一分半。读表的结果
  与 ffmpeg 不一致的风险（stss 登记了解析器不认的帧、多段编辑表等）由那边自行识别后
  交回 ffprobe 兜底。
- **其余容器（TS 等）**：没有索引可读，只能 ffprobe 列视频包挑关键帧（要通读文件）。
- **网盘直链（strm）**：按 HTTP Range 读同样的索引（``remote_range``）——Matroska 的 Cues
  三四个请求；MP4 的 moov 加 16 个关键帧样本的抽检（每个样本一个请求）。其余容器要通读，
  从网盘现拉等不起，返回 None：转码档用不着索引，换封装档退回会话相对模式
  （docs/design/strm-playback.md）。读不出的结论记十分钟，别每次开会话都白跑一轮请求。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from movieclaw_playback.container_index import (
    read_mp4_keyframes_checked,
    read_remote_mp4_keyframes,
    verify_all_mp4_keyframes,
)
from movieclaw_playback.streaming import STRM_EXT, open_strm_range

logger = logging.getLogger("movieclaw_playback.keyframes")

_FFPROBE_TIMEOUT = 120.0

# --- Matroska EBML 元素 ID（保留前导标记位的原始形式） ------------------------
_EBML_HEADER = 0x1A45DFA3
_SEGMENT = 0x18538067
_SEEK_HEAD = 0x114D9B74
_SEEK = 0x4DBB
_SEEK_ID = 0x53AB
_SEEK_POSITION = 0x53AC
_INFO = 0x1549A966
_TIMESTAMP_SCALE = 0x2AD7B1
_CUES = 0x1C53BB6B
_CUE_POINT = 0xBB
_CUE_TIME = 0xB3
_CUE_TRACK_POSITIONS = 0xB7
_CUE_TRACK = 0xF7
_TRACKS = 0x1654AE6B
_TRACK_ENTRY = 0xAE
_TRACK_NUMBER = 0xD7
_TRACK_TYPE = 0x83
_TRACK_TYPE_VIDEO = 1

#: MP4 / MOV 文件开头常见的顶层 box（网盘直链看不出扩展名，按文件头认）
_MP4_TOP_LEVEL_BOXES = frozenset({b"ftyp", b"moov", b"mdat", b"free", b"wide", b"skip"})
#: 网盘直链读不出索引的结论记多久（秒）：(strm 路径, mtime, 大小) → 记下的时刻
_REMOTE_UNINDEXED_TTL_S = 600.0
_remote_unindexed: dict[tuple[str, int, int], float] = {}


@dataclass(frozen=True)
class KeyframeIndex:
    """一个文件的视频关键帧时间表（秒，升序）。"""

    times_s: tuple[float, ...]


#: (路径, mtime_ns, 大小) → 索引。mkv 解析毫秒级本可不缓存，但 mp4 走
#: ffprobe 可能上秒；同一文件反复开会话（切集来回、降档重开）不该重算。
#: 满了整体清空——纯加速缓存，命中率短暂下降无所谓（media_probe 同款取舍）。
_index_cache: dict[tuple[str, int, int], KeyframeIndex] = {}
_INDEX_CACHE_MAX = 256

#: MP4 走了读 moov 的快路径、但只抽检了一部分关键帧样本的文件：开会话后由
#: ``schedule_background_index`` 在后台全量核对。核对通过就移出；发现 stss 里有 ffmpeg 不认的帧，
#: 就记进 ``_untrusted_mp4``（之后这个文件不再走快路径）并在后台用 ffprobe 重建索引。
_needs_full_check: set[tuple[str, int, int]] = set()
_untrusted_mp4: set[tuple[str, int, int]] = set()
_full_check_running: set[tuple[str, int, int]] = set()
_full_check_tasks: set[asyncio.Task] = set()
#: 后台 ffprobe 通读失败过的文件（超时、损坏）：本进程内不再重试，别每次开会话都白读一遍
_background_failed: set[tuple[str, int, int]] = set()
#: 一次只做一个文件：后台的读要给正在播放的取流让路
_full_check_lock: asyncio.Lock | None = None
#: 开会话后等多久再做：先让起播把盘让出来（video_cues 同款）
FULL_CHECK_DELAY_S = 15.0
#: 后台通读的时限：慢慢读、不卡起播（NAS 的 NFS 片库约 100 MB/s，30 分钟够读完 100 GB 以上）
_BACKGROUND_FFPROBE_TIMEOUT = 1800.0
#: 后台只通读这么大以内的文件：更大的读一遍太伤盘，留在会话相对模式（照样能放、能跳，
#: 只是拖出已转区间要换会话）
BACKGROUND_INDEX_MAX_BYTES = 24 << 30


def read_keyframe_index(path: str | Path, *, allow_ffprobe: bool = True) -> KeyframeIndex | None:
    """读取全片关键帧索引；失败返回 None（调用方退回旧的会话式播放）。

    结果按 (路径, mtime, 大小) 缓存；文件被换掉（洗版、改名归并）时三元组
    变化，缓存自然失效。只缓存成功结果——瞬时 IO 故障不该被钉死。

    ``allow_ffprobe=False``：只走读索引的快路径（Matroska Cues、MP4 moov），需要
    ffprobe 通读文件才拿得到时直接返回 None——给决策阶段估关键帧间隔用，那里宁可退回
    三段采样，也不能为它等一次整片通读。
    """
    path = Path(path)
    try:
        stat = path.stat()
    except OSError:
        return None
    key = (str(path), stat.st_mtime_ns, stat.st_size)
    cached = _index_cache.get(key)
    if cached is not None:
        return cached
    index = _read_keyframe_index(path, key, allow_ffprobe=allow_ffprobe)
    if index is not None:
        if len(_index_cache) >= _INDEX_CACHE_MAX:
            _index_cache.clear()
        _index_cache[key] = index
    return index


def _read_keyframe_index(
    path: Path, key: tuple[str, int, int], *, allow_ffprobe: bool = True
) -> KeyframeIndex | None:
    suffix = path.suffix.lower()
    try:
        if suffix == STRM_EXT:
            times = _read_remote_keyframes(path, key)
        elif suffix in {".mkv", ".webm"}:
            times = _read_matroska_cues(path)
        else:
            times = None
            if suffix in {".mp4", ".m4v", ".mov"} and key not in _untrusted_mp4:
                checked = read_mp4_keyframes_checked(path)
                if checked is not None:
                    times, sampled = checked
                    if sampled:
                        _needs_full_check.add(key)
            if times is None:
                if not allow_ffprobe:
                    return None
                times = _ffprobe_keyframes(path)
    # ValueError 是解析器自己抛的（不是 Matroska / 缺 Cues / 结构异常），
    # IndexError 是截断或损坏的文件让 _read_vint 读越了界。这里是「按合同
    # 失败返回 None」的唯一出口——扩展名叫 .mkv 不代表内容真是 Matroska，
    # 漏接任何一类都会把开会话接口打成 500，整个文件从此放不了（VOD 只是
    # 优化，读不出索引本该安静退回旧的会话式播放）。
    except (OSError, ValueError, IndexError) as exc:
        logger.warning("关键帧索引读取失败：%s（%s）", path, exc)
        return None
    if not times:
        return None
    # 索引必须从 0 附近开始：首个关键帧就是首帧（任何正常视频都如此），
    # 若 Cues 缺了片头（个别残缺文件），补一个 0 保证第一个分片存在。
    if times[0] > 0.001:
        times = [0.0, *times]
    return KeyframeIndex(times_s=tuple(times))


# --- Matroska Cues ----------------------------------------------------------


def _read_vint(data: bytes, pos: int, *, keep_marker: bool) -> tuple[int, int]:
    """读一个 EBML 变长整数，返回 (值, 新位置)。keep_marker=True 用于元素 ID。"""
    first = data[pos]
    length = 1
    mask = 0x80
    while mask and not (first & mask):
        length += 1
        mask >>= 1
    if not mask:
        raise ValueError("非法的 EBML 变长整数")
    value = first if keep_marker else first & (mask - 1)
    for i in range(1, length):
        value = (value << 8) | data[pos + i]
    return value, pos + length


def _iter_children(data: bytes, start: int, end: int):
    """遍历 [start, end) 区间内的 EBML 子元素，产出 (id, body_start, body_end)。"""
    pos = start
    while pos < end:
        element_id, pos = _read_vint(data, pos, keep_marker=True)
        size, pos = _read_vint(data, pos, keep_marker=False)
        yield element_id, pos, pos + size
        pos += size


def _read_uint(data: bytes, start: int, end: int) -> int:
    return int.from_bytes(data[start:end], "big")


def _read_matroska_cues(path: Path) -> list[float]:
    """从 mkv 的 SeekHead 定位 Cues 与 Info，解出关键帧时间表（秒）。"""
    with path.open("rb") as f:
        return _matroska_cues(f)


def _read_remote_keyframes(path: Path, key: tuple[str, int, int]) -> list[float] | None:
    """网盘条目（strm）的关键帧：Matroska 读 Cues、MP4 读样本表；其余容器返回 None。

    strm 指向挂载目录里的本地文件时同样只读索引（MP4 抽检样本、不通读）：挂载背后多半
    是网盘，通读就是把整片拉一遍。"""
    failed_at = _remote_unindexed.get(key)
    if failed_at is not None and time.monotonic() - failed_at < _REMOTE_UNINDEXED_TTL_S:
        return None
    times = None
    try:
        reader = open_strm_range(path)
        if reader is not None:
            with reader as f:
                head = f.read(8)
                f.seek(0)
                if head[:4] == _EBML_HEADER.to_bytes(4, "big"):
                    times = _matroska_cues(f)
                elif head[4:8] in _MP4_TOP_LEVEL_BOXES and f.size is not None:
                    times = read_remote_mp4_keyframes(f, f.size, str(path))
    except (OSError, ValueError, IndexError):
        times = None
    if not times:
        _remote_unindexed[key] = time.monotonic()
    return times


def _matroska_cues(f) -> list[float]:  # noqa: ANN001 — 本地文件或 RemoteRangeFile
    # 头部读 64KB：EBML 头 + Segment 头 + SeekHead 一定在这里面
    head = f.read(65536)
    pos = 0
    element_id, pos = _read_vint(head, pos, keep_marker=True)
    if element_id != _EBML_HEADER:
        raise ValueError("不是 Matroska 文件")
    size, pos = _read_vint(head, pos, keep_marker=False)
    pos += size
    element_id, pos = _read_vint(head, pos, keep_marker=True)
    if element_id != _SEGMENT:
        raise ValueError("缺少 Segment 元素")
    _, pos = _read_vint(head, pos, keep_marker=False)
    segment_start = pos  # SeekHead 的偏移都相对这里

    # SeekHead：id → 相对偏移
    offsets: dict[int, int] = {}
    for element_id, body_start, body_end in _iter_children(head, pos, len(head)):
        if element_id != _SEEK_HEAD:
            # SeekHead 总在 Segment 最前面；遇到第一个别的元素就停
            break
        for child_id, c_start, c_end in _iter_children(head, body_start, body_end):
            if child_id != _SEEK:
                continue
            target_id = target_pos = None
            for f_id, f_start, f_end in _iter_children(head, c_start, c_end):
                if f_id == _SEEK_ID:
                    target_id = _read_uint(head, f_start, f_end)
                elif f_id == _SEEK_POSITION:
                    target_pos = _read_uint(head, f_start, f_end)
            if target_id is not None and target_pos is not None:
                offsets[target_id] = target_pos
    if _CUES not in offsets:
        raise ValueError("SeekHead 里没有 Cues（此文件缺关键帧索引）")

    # 视频轨号：Cues 里混着音频/字幕轨的 CuePoint（mkvmerge 会为多轨写
    # cue），不按轨过滤会把索引搅密好几倍，分片边界全错。
    video_tracks: set[int] = set()
    if _TRACKS in offsets:
        f.seek(segment_start + offsets[_TRACKS])
        tracks = f.read(65536)
        p = 0
        element_id, p = _read_vint(tracks, p, keep_marker=True)
        size, p = _read_vint(tracks, p, keep_marker=False)
        for child_id, c_start, c_end in _iter_children(tracks, p, min(p + size, len(tracks))):
            if child_id != _TRACK_ENTRY:
                continue
            number = kind = None
            for f_id, f_start, f_end in _iter_children(tracks, c_start, c_end):
                if f_id == _TRACK_NUMBER:
                    number = _read_uint(tracks, f_start, f_end)
                elif f_id == _TRACK_TYPE:
                    kind = _read_uint(tracks, f_start, f_end)
            if kind == _TRACK_TYPE_VIDEO and number is not None:
                video_tracks.add(number)

    timestamp_scale = 1_000_000  # EBML 默认：每 tick 1ms
    if _INFO in offsets:
        f.seek(segment_start + offsets[_INFO])
        info = f.read(4096)
        p = 0
        element_id, p = _read_vint(info, p, keep_marker=True)
        size, p = _read_vint(info, p, keep_marker=False)
        for child_id, c_start, c_end in _iter_children(info, p, min(p + size, len(info))):
            if child_id == _TIMESTAMP_SCALE:
                timestamp_scale = _read_uint(info, c_start, c_end)

    # Cues 整块读进来（几十 KB~几 MB）
    f.seek(segment_start + offsets[_CUES])
    header = f.read(16)
    p = 0
    element_id, p = _read_vint(header, p, keep_marker=True)
    if element_id != _CUES:
        raise ValueError("SeekHead 指向的位置不是 Cues")
    size, p = _read_vint(header, p, keep_marker=False)
    f.seek(segment_start + offsets[_CUES])
    cues = f.read(p + size)

    times: list[float] = []
    for child_id, c_start, c_end in _iter_children(cues, p, len(cues)):
        if child_id != _CUE_POINT:
            continue
        cue_time = None
        is_video = not video_tracks  # Tracks 解析失败时不过滤，聊胜于无
        for f_id, f_start, f_end in _iter_children(cues, c_start, c_end):
            if f_id == _CUE_TIME:
                cue_time = _read_uint(cues, f_start, f_end)
            elif f_id == _CUE_TRACK_POSITIONS:
                for g_id, g_start, g_end in _iter_children(cues, f_start, f_end):
                    if g_id == _CUE_TRACK:
                        if _read_uint(cues, g_start, g_end) in video_tracks:
                            is_video = True
                        break
        if is_video and cue_time is not None:
            times.append(cue_time * timestamp_scale / 1_000_000_000)
    # 同一时间可能有多条（多视频轨/重复 cue），去重再排序
    return sorted(set(times))


# --- 其余容器：ffprobe ------------------------------------------------------


def _ffprobe_keyframes(
    path: Path, *, timeout: float = _FFPROBE_TIMEOUT, low_priority: bool = False
) -> list[float]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-print_format",
        "json",
        "-select_streams",
        "v:0",
        "-show_entries",
        "packet=pts_time,flags",
        str(path),
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            # 后台补全时调低优先级，别和正在转码 / 取流的进程抢 CPU
            preexec_fn=(lambda: os.nice(10)) if low_priority else None,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        logger.warning("ffprobe 列关键帧失败：%s（%s）", path, exc)
        return []
    if proc.returncode != 0:
        return []
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    times: list[float] = []
    for packet in payload.get("packets") or []:
        if "K" not in (packet.get("flags") or ""):
            continue
        try:
            times.append(float(packet.get("pts_time")))
        except (TypeError, ValueError):
            continue
    times.sort()
    return times


# --- MP4 快路径的后台全量核对 ---------------------------------------------------------


def schedule_background_index(path: str | Path, *, delay_s: float = FULL_CHECK_DELAY_S) -> None:
    """开会话后排一次后台的索引补全（视频直通的会话调用；不在事件循环里时跳过）。

    两种情况要做，都不在起播路径上（开会话只走快路径，``read_keyframe_index(allow_ffprobe=False)``）：

    1. **MP4 快路径只抽检了一部分关键帧样本**：抽检兜不住零星的坏条目——stss 里混进一两个 ffmpeg
       不认的帧，分片计划就会在那里多出一个 ffmpeg 不切的边界，播到那里分片编号错一位。这里全量
       核对（4 路并发），发现问题就让这个文件以后不走快路径，并用 ffprobe 把正确的索引算好换进缓存。
    2. **快路径拿不到索引**（TS 等没有索引可读的容器、MP4 抽检对不上）：原来开会话当场 ffprobe
       通读整片——NAS 的 NFS 片库上一部 36 GB 的 TS 要 6 分钟，120 秒超时作废后退回会话相对模式，
       而且不记失败，每次播放都白等 120 秒（2026-10-01 实测）。现在本次直接走会话相对模式，
       后台低优先级通读（单文件 24 GB 以内），算好的索引给下一次播放。

    当前这次播放用的已经是开会话时的计划，换不了；下一次打开就对了。一次只做一个文件。
    """
    path = Path(path)
    try:
        stat = path.stat()
    except OSError:
        return
    key = (str(path), stat.st_mtime_ns, stat.st_size)
    if key in _full_check_running:
        return
    verify = key in _needs_full_check
    build = (
        not verify
        and key not in _index_cache
        and key not in _background_failed
        # 网盘直链（strm）不在后台通读：那是把整片从网盘拉一遍
        and path.suffix.lower() not in {".mkv", ".webm", STRM_EXT}
        and stat.st_size <= BACKGROUND_INDEX_MAX_BYTES
    )
    if not (verify or build):
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    _full_check_running.add(key)
    task = loop.create_task(_background_index(path, key, delay_s, verify=verify))
    _full_check_tasks.add(task)
    task.add_done_callback(_full_check_tasks.discard)


async def _background_index(
    path: Path, key: tuple[str, int, int], delay_s: float, *, verify: bool
) -> None:
    global _full_check_lock
    try:
        if delay_s > 0:
            await asyncio.sleep(delay_s)
        if _full_check_lock is None:
            _full_check_lock = asyncio.Lock()
        async with _full_check_lock:
            if verify:
                if await asyncio.to_thread(verify_all_mp4_keyframes, path):
                    _needs_full_check.discard(key)
                    return
                logger.warning(
                    "MP4 关键帧表里有 ffmpeg 不认的帧，这个文件改用 ffprobe 列关键帧"
                    "（后台重建索引，下次播放生效）：%s",
                    path,
                )
                _untrusted_mp4.add(key)
                _needs_full_check.discard(key)
                _index_cache.pop(key, None)
            started = time.monotonic()
            times = await asyncio.to_thread(
                _ffprobe_keyframes, path, timeout=_BACKGROUND_FFPROBE_TIMEOUT, low_priority=True
            )
            if not times:
                _background_failed.add(key)
                return
            if times[0] > 0.001:
                times = [0.0, *times]
            _index_cache[key] = KeyframeIndex(times_s=tuple(times))
            logger.info(
                "后台补全关键帧索引：%s（%d 个关键帧，用时 %.0f 秒，下次播放起用 VOD 列表）",
                path,
                len(times),
                time.monotonic() - started,
            )
    except Exception:  # noqa: BLE001 — 只是优化，出错只记日志，播放照常
        logger.warning("关键帧索引后台补全出错：%s", path, exc_info=True)
    finally:
        _full_check_running.discard(key)

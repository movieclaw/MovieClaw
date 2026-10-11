"""容器索引读取：不解码、不读正文，只读文件头和索引，拿到「片子长什么样」。

刷片（docs/design/reels.md）要为每部片挑一段 30～60 秒的精彩片段，并告诉 App
这一段在文件里的字节位置好提前预取。这些信息全都能从容器自带的索引里得到，
不必解码画面、也不必把几十 GB 的正片读一遍：

- **视频关键帧的时间与字节位置**：相邻两个关键帧之间的字节数 ÷ 时间差 ≈ 那一段
  的码率。编码器给运动大、剪辑快、画面复杂的镜头分更多字节，码率曲线因此能粗略
  反映「激烈程度」；字节位置本身就是 App 预取「从某秒起播」所需数据的范围。
- **字幕事件的时间**：mkvmerge 默认给字幕轨的每一条事件都写索引点（PGS 图形字幕
  也一样），不用读正文就知道哪里在说话、哪里是两句对白之间的空隙——片段的起止
  卡在空隙上，才不会切在半句话中间。
- **章节**：原盘作者或片源标的章节，通常落在场景开头。
- **文件头与索引自身的字节范围**：引擎打开文件时要读文件头（Matroska 到第一个
  Cluster 为止，MP4 是 moov），跳到起点时要读索引（Cues / moov），这两段也要预取。

支持两类容器：
- **Matroska（mkv/webm）**：SeekHead 定位 Info / Tracks / Chapters / Cues，全部按
  元素自身长度精确读取，整个过程通常只读几百 KB～1 MB。
- **MP4 / MOV**：顶层 box 逐个跳过 mdat 找到 moov，解析 stbl 的各张表
  （stts / stss / stsz / stsc / stco / co64）。**不能用 ffprobe 列包**：ffprobe
  列包会顺带读出每个包的数据，等于把整个 mdat 通读一遍（2026-09-29 NAS 实测
  15.7 GB 的 MP4 读了 60 秒、5.7 GB 仍未读完）。

其余容器（TS / M2TS / AVI / 原盘目录 / 镜像）返回 None，由调用方跳过。
所有入口都是同步阻塞 IO，调用方负责放进线程池。

**文件尾被截掉的 Matroska**（下载或复制中断，Segment 声明的长度比文件长）：mkvmerge 把
Cues、Tags 和可能有的第二个 SeekHead 写在文件尾，截断后最先丢的就是它们。Cues 还完整
就照常解析——文件尾的 SeekHead 只是目录，读不出就跳过；Cues 已不在文件里则按合同返回
None，日志写明「文件不完整」，而不是报一句看不懂的越界。
"""

from __future__ import annotations

import logging
import os
import struct
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger("movieclaw_playback.container_index")

# 轨道类型（与容器无关的统一叫法）
KIND_VIDEO = "video"
KIND_AUDIO = "audio"
KIND_SUBTITLE = "subtitle"
KIND_OTHER = "other"


@dataclass(frozen=True)
class KeyframePoint:
    """一个视频关键帧：时间（秒）与起播时要从哪个字节开始读。

    ``offset`` 是「从这里开始读就能解出这个关键帧」的绝对文件偏移：Matroska 取
    关键帧所在 Cluster 的起点（Cluster 里音视频交错，从头读才完整），MP4 取这个
    关键帧样本本身的位置。
    """

    time_s: float
    offset: int


@dataclass(frozen=True)
class TrackInfo:
    """容器里的一条轨道。``number`` 是容器自己的轨号（Matroska TrackNumber /
    MP4 track_ID），``order`` 是同类轨里的先后序号（从 0 起，与 ffprobe 按类型
    排列的顺序一致，用来和台账里的 audio_streams / subtitle_streams 对上）。"""

    number: int
    kind: str
    codec: str
    order: int
    language: str | None = None
    name: str | None = None


@dataclass(frozen=True)
class ContainerIndex:
    """一个文件的索引摘要。所有时间都是秒，所有偏移都是绝对文件偏移。"""

    container: str  # "matroska" / "mp4"
    file_size: int
    duration_s: float
    keyframes: tuple[KeyframePoint, ...]
    tracks: tuple[TrackInfo, ...]
    #: 字幕轨号 → 这条轨上每个事件（显示或清屏）的时间，升序
    subtitle_events: dict[int, tuple[float, ...]] = field(default_factory=dict)
    #: (起点秒, 标题) 升序
    chapters: tuple[tuple[float, str | None], ...] = ()
    #: 引擎打开文件要读的文件头：[0, head_end)
    head_end: int = 0
    #: 索引自身的字节范围 [start, end)；已含在文件头里时为 None
    index_range: tuple[int, int] | None = None

    def tracks_of(self, kind: str) -> list[TrackInfo]:
        return [t for t in self.tracks if t.kind == kind]


#: (路径, mtime_ns, 大小) → 索引。解析一部片要零点几秒到一两秒（Cues 大的原盘
#: remux 有六万个索引点），同一次刷片里同一文件可能被反复用到。满了整体清空——
#: 纯加速缓存（keyframes.py 同款取舍）。
_cache: dict[tuple[str, int, int], ContainerIndex] = {}
_CACHE_MAX = 128

_MATROSKA_SUFFIXES = frozenset({".mkv", ".webm", ".mka"})
_MP4_SUFFIXES = frozenset({".mp4", ".m4v", ".mov"})
#: EBML 头的元素 ID，所有 Matroska / WebM 文件的开头 4 字节
_EBML_MAGIC = b"\x1a\x45\xdf\xa3"


def read_container_index(path: str | Path) -> ContainerIndex | None:
    """读取文件的容器索引；不支持的容器或解析失败返回 None。"""
    path = Path(path)
    try:
        stat = path.stat()
    except OSError:
        return None
    key = (str(path), stat.st_mtime_ns, stat.st_size)
    cached = _cache.get(key)
    if cached is not None:
        return cached
    suffix = path.suffix.lower()
    try:
        if suffix not in _MATROSKA_SUFFIXES | _MP4_SUFFIXES:
            return None
        # 以文件头魔数为准、后缀只是兜底：实际有 Matroska 内容却被命名成 .mp4 的片源
        # （ffmpeg 靠内容嗅探照常能播），只看后缀会按 MP4 解析，报「找不到 moov」。
        with path.open("rb") as f:
            magic = f.read(4)
        if magic == _EBML_MAGIC or suffix in _MATROSKA_SUFFIXES:
            index = _read_matroska(path, stat.st_size)
        else:
            index = _read_mp4(path, stat.st_size)
    # ValueError 是解析器自己抛的（结构不对、缺索引），IndexError / struct.error
    # 是截断或损坏的文件让解析读越了界。这里是「按合同失败返回 None」的唯一出口。
    except (OSError, ValueError, IndexError, struct.error) as exc:
        logger.warning("读取容器索引失败：%s（%s）", path, exc)
        return None
    if index is None or not index.keyframes:
        return None
    if len(_cache) >= _CACHE_MAX:
        _cache.clear()
    _cache[key] = index
    return index


# --- Matroska -----------------------------------------------------------------

_EBML_HEADER = 0x1A45DFA3
_SEGMENT = 0x18538067
_SEEK_HEAD = 0x114D9B74
_SEEK = 0x4DBB
_SEEK_ID = 0x53AB
_SEEK_POSITION = 0x53AC
_INFO = 0x1549A966
_TIMESTAMP_SCALE = 0x2AD7B1
_DURATION = 0x4489
_TRACKS = 0x1654AE6B
_TRACK_ENTRY = 0xAE
_TRACK_NUMBER = 0xD7
_TRACK_TYPE = 0x83
_CODEC_ID = 0x86
_LANGUAGE = 0x22B59C
_LANGUAGE_BCP47 = 0x22B59D
_NAME = 0x536E
_CHAPTERS = 0x1043A770
_EDITION_ENTRY = 0x45B9
_CHAPTER_ATOM = 0xB6
_CHAPTER_TIME_START = 0x91
_CHAPTER_FLAG_HIDDEN = 0x98
_CHAPTER_DISPLAY = 0x80
_CHAP_STRING = 0x85
_CUES = 0x1C53BB6B
_CUE_POINT = 0xBB
_CUE_TIME = 0xB3
_CUE_TRACK_POSITIONS = 0xB7
_CUE_TRACK = 0xF7
_CUE_CLUSTER_POSITION = 0xF1
_CLUSTER = 0x1F43B675

_MKV_TRACK_KIND = {1: KIND_VIDEO, 2: KIND_AUDIO, 17: KIND_SUBTITLE}

#: 单个索引类元素的读取上限。Cues 最大见过 1.4 MB（三小时 UHD remux、23 条字幕轨），
#: 超过 64 MB 的只可能是损坏文件，不值得读进内存。
_MAX_ELEMENT_BYTES = 64 << 20
#: 找第一个 Cluster 时最多跳过的顶层元素个数（SeekHead / Void / Info / Tracks /
#: Chapters / Attachments / Tags / Cues 加起来不过十来个）
_MAX_TOP_LEVEL_SCAN = 64


def _vint(data: bytes, pos: int, *, keep_marker: bool) -> tuple[int, int, bool]:
    """读一个 EBML 变长整数，返回 (值, 新位置, 是否为「未知长度」)。"""
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
    unknown = (not keep_marker) and value == (1 << (7 * length)) - 1
    return value, pos + length, unknown


def _children(data: bytes, start: int, end: int):
    """遍历 [start, end) 内的子元素，产出 (id, body_start, body_end)。"""
    pos = start
    while pos < end:
        element_id, pos, _ = _vint(data, pos, keep_marker=True)
        size, pos, unknown = _vint(data, pos, keep_marker=False)
        body_end = end if unknown else min(pos + size, end)
        yield element_id, pos, body_end
        pos = body_end


def _uint(data: bytes, start: int, end: int) -> int:
    return int.from_bytes(data[start:end], "big")


def _float(data: bytes, start: int, end: int) -> float:
    raw = data[start:end]
    if len(raw) == 4:
        return struct.unpack(">f", raw)[0]
    if len(raw) == 8:
        return struct.unpack(">d", raw)[0]
    return 0.0


def _text(data: bytes, start: int, end: int) -> str:
    return data[start:end].split(b"\x00", 1)[0].decode("utf-8", "replace")


def _read_element_at(f, offset: int, expected_id: int) -> tuple[bytes, int]:
    """读出 offset 处的整个元素，返回 (元素字节, 正文在其中的起点)。"""
    f.seek(offset)
    header = f.read(16)
    if not header:
        # SeekHead 记的位置在文件末尾之外：文件尾被截掉了（NAS 上见过只剩 64% 的 remux，
        # Cues 在第 186 亿字节、文件只有 118 亿字节）。不拦的话下面解析空字节会越界
        raise ValueError(
            f"元素 0x{expected_id:X} 应在第 {offset} 字节，文件却只有 "
            f"{os.fstat(f.fileno()).st_size} 字节：文件不完整，可能下载或复制时中断了"
        )
    element_id, p, _ = _vint(header, 0, keep_marker=True)
    if element_id != expected_id:
        raise ValueError(f"位置 {offset} 上不是期望的元素 0x{expected_id:X}")
    size, p, unknown = _vint(header, p, keep_marker=False)
    if unknown or size > _MAX_ELEMENT_BYTES:
        raise ValueError(f"元素 0x{expected_id:X} 长度异常")
    f.seek(offset)
    data = f.read(p + size)
    if len(data) < p + size:
        raise ValueError(f"元素 0x{expected_id:X} 被截断")
    return data, p


def _matroska_layout(f, file_size: int, path: Path) -> tuple[int, dict[int, int], int | None]:
    """走一遍 Matroska 的顶层结构。

    返回 (Segment 正文起点, 各顶层元素的绝对位置, 第一个 Cluster 的位置)。顶层元素逐个
    跳过直到第一个 Cluster，顺路收集 SeekHead；SeekHead 指向的位置（包括写在文件尾的
    第二个 SeekHead）再跟一层。只读元素头与 SeekHead 正文，不读别的元素正文。
    """
    f.seek(0)
    head = f.read(64 * 1024)
    element_id, pos, _ = _vint(head, 0, keep_marker=True)
    if element_id != _EBML_HEADER:
        raise ValueError("不是 Matroska 文件")
    size, pos, _ = _vint(head, pos, keep_marker=False)
    pos += size
    element_id, pos, _ = _vint(head, pos, keep_marker=True)
    if element_id != _SEGMENT:
        raise ValueError("缺少 Segment 元素")
    _, pos, _ = _vint(head, pos, keep_marker=False)
    segment_start = pos  # SeekHead 里的位置都相对这里

    # 顶层元素逐个跳过，直到第一个 Cluster：顺路收集 SeekHead 与各元素位置。
    # 每个元素只读 16 字节的头，正文按长度跳过。
    positions: dict[int, int] = {}
    seek_heads: list[int] = []
    first_cluster = None
    cursor = segment_start
    for _ in range(_MAX_TOP_LEVEL_SCAN):
        if cursor >= file_size:
            break
        f.seek(cursor)
        header = f.read(16)
        if len(header) < 2:
            break
        element_id, p, _ = _vint(header, 0, keep_marker=True)
        size, p, unknown = _vint(header, p, keep_marker=False)
        if element_id == _CLUSTER:
            first_cluster = cursor
            break
        if unknown:
            break
        if element_id == _SEEK_HEAD:
            seek_heads.append(cursor)
        elif element_id in (_INFO, _TRACKS, _CHAPTERS, _CUES):
            positions.setdefault(element_id, cursor)
        cursor += p + size

    # SeekHead 可能指向另一个 SeekHead（写在文件尾的第二索引），跟一层。
    # SeekHead 只是目录：文件尾被截掉时第二个 SeekHead 会读不全（NAS 上见过缺尾 900 KB
    # 的 UHD remux，Cues 完好、第二个 SeekHead 只剩半截），跳过它照样能用前面找到的
    # Cues；Cues 真找不到或读不了，由调用方报错
    visited: set[int] = set()
    while seek_heads:
        at = seek_heads.pop(0)
        if at in visited:
            continue
        visited.add(at)
        try:
            data, body = _read_element_at(f, at, _SEEK_HEAD)
        except ValueError as exc:
            logger.info("Matroska 元素目录（SeekHead）读不出，跳过它继续：%s（%s）", path, exc)
            continue
        for child_id, c_start, c_end in _children(data, body, len(data)):
            if child_id != _SEEK:
                continue
            target_id = target_pos = None
            for g_id, g_start, g_end in _children(data, c_start, c_end):
                if g_id == _SEEK_ID:
                    target_id = _uint(data, g_start, g_end)
                elif g_id == _SEEK_POSITION:
                    target_pos = _uint(data, g_start, g_end)
            if target_id is None or target_pos is None:
                continue
            absolute = segment_start + target_pos
            if target_id == _SEEK_HEAD:
                seek_heads.append(absolute)
            elif target_id in (_INFO, _TRACKS, _CHAPTERS, _CUES):
                positions.setdefault(target_id, absolute)
    return segment_start, positions, first_cluster


def _read_matroska(path: Path, file_size: int) -> ContainerIndex:
    with path.open("rb") as f:
        segment_start, positions, first_cluster = _matroska_layout(f, file_size, path)
        if _CUES not in positions:
            raise ValueError("找不到 Cues（此文件缺关键帧索引）")

        # Info：时间刻度与总时长
        timestamp_scale = 1_000_000
        duration_ticks = 0.0
        if _INFO in positions:
            data, body = _read_element_at(f, positions[_INFO], _INFO)
            for child_id, c_start, c_end in _children(data, body, len(data)):
                if child_id == _TIMESTAMP_SCALE:
                    timestamp_scale = _uint(data, c_start, c_end) or 1_000_000
                elif child_id == _DURATION:
                    duration_ticks = _float(data, c_start, c_end)
        tick_s = timestamp_scale / 1_000_000_000

        # Tracks：轨号 → 类型 / 编码 / 语言 / 名称
        tracks: list[TrackInfo] = []
        if _TRACKS in positions:
            data, body = _read_element_at(f, positions[_TRACKS], _TRACKS)
            order_by_kind: dict[str, int] = {}
            for child_id, c_start, c_end in _children(data, body, len(data)):
                if child_id != _TRACK_ENTRY:
                    continue
                number = kind_code = None
                codec = ""
                language = bcp47 = name = None
                for g_id, g_start, g_end in _children(data, c_start, c_end):
                    if g_id == _TRACK_NUMBER:
                        number = _uint(data, g_start, g_end)
                    elif g_id == _TRACK_TYPE:
                        kind_code = _uint(data, g_start, g_end)
                    elif g_id == _CODEC_ID:
                        codec = _text(data, g_start, g_end)
                    elif g_id == _LANGUAGE:
                        language = _text(data, g_start, g_end)
                    elif g_id == _LANGUAGE_BCP47:
                        bcp47 = _text(data, g_start, g_end)
                    elif g_id == _NAME:
                        name = _text(data, g_start, g_end)
                if number is None:
                    continue
                kind = _MKV_TRACK_KIND.get(kind_code or 0, KIND_OTHER)
                order = order_by_kind.get(kind, 0)
                order_by_kind[kind] = order + 1
                tracks.append(
                    TrackInfo(
                        number=number,
                        kind=kind,
                        codec=codec,
                        order=order,
                        language=bcp47 or language,
                        name=name or None,
                    )
                )
        video_numbers = {t.number for t in tracks if t.kind == KIND_VIDEO}
        subtitle_numbers = {t.number for t in tracks if t.kind == KIND_SUBTITLE}

        # Chapters：取第一个版本里不隐藏的章节
        chapters: list[tuple[float, str | None]] = []
        if _CHAPTERS in positions:
            data, body = _read_element_at(f, positions[_CHAPTERS], _CHAPTERS)
            for child_id, c_start, c_end in _children(data, body, len(data)):
                if child_id != _EDITION_ENTRY:
                    continue
                for atom_id, a_start, a_end in _children(data, c_start, c_end):
                    if atom_id != _CHAPTER_ATOM:
                        continue
                    start_ns = None
                    hidden = False
                    title = None
                    for g_id, g_start, g_end in _children(data, a_start, a_end):
                        if g_id == _CHAPTER_TIME_START:
                            start_ns = _uint(data, g_start, g_end)
                        elif g_id == _CHAPTER_FLAG_HIDDEN:
                            hidden = bool(_uint(data, g_start, g_end))
                        elif g_id == _CHAPTER_DISPLAY and title is None:
                            for d_id, d_start, d_end in _children(data, g_start, g_end):
                                if d_id == _CHAP_STRING:
                                    title = _text(data, d_start, d_end) or None
                                    break
                    if start_ns is not None and not hidden:
                        chapters.append((start_ns / 1_000_000_000, title))
                break

        # Cues：视频关键帧（时间 + Cluster 位置）与字幕事件时间
        cues_offset = positions[_CUES]
        data, body = _read_element_at(f, cues_offset, _CUES)
        cues_end = cues_offset + len(data)
        keyframes: dict[float, int] = {}
        subtitle_events: dict[int, list[float]] = {n: [] for n in subtitle_numbers}
        for child_id, c_start, c_end in _children(data, body, len(data)):
            if child_id != _CUE_POINT:
                continue
            cue_time = None
            positions_in_point: list[tuple[int, int]] = []
            for g_id, g_start, g_end in _children(data, c_start, c_end):
                if g_id == _CUE_TIME:
                    cue_time = _uint(data, g_start, g_end)
                elif g_id == _CUE_TRACK_POSITIONS:
                    track = cluster = None
                    for h_id, h_start, h_end in _children(data, g_start, g_end):
                        if h_id == _CUE_TRACK:
                            track = _uint(data, h_start, h_end)
                        elif h_id == _CUE_CLUSTER_POSITION:
                            cluster = _uint(data, h_start, h_end)
                    if track is not None and cluster is not None:
                        positions_in_point.append((track, cluster))
            if cue_time is None:
                continue
            time_s = cue_time * tick_s
            for track, cluster in positions_in_point:
                # Tracks 解析失败时视频轨号未知：只好把所有索引点都当视频
                if track in video_numbers or not video_numbers:
                    keyframes.setdefault(time_s, segment_start + cluster)
                elif track in subtitle_events:
                    subtitle_events[track].append(time_s)

    duration_s = duration_ticks * tick_s
    points = tuple(KeyframePoint(t, keyframes[t]) for t in sorted(keyframes))
    if not duration_s and points:
        duration_s = points[-1].time_s
    head_end = first_cluster if first_cluster is not None else min(file_size, 1 << 20)
    index_range = None if cues_end <= head_end else (cues_offset, cues_end)
    return ContainerIndex(
        container="matroska",
        file_size=file_size,
        duration_s=duration_s,
        keyframes=points,
        tracks=tuple(tracks),
        subtitle_events={k: tuple(sorted(v)) for k, v in subtitle_events.items()},
        chapters=tuple(sorted(chapters, key=lambda c: c[0])),
        head_end=head_end,
        index_range=index_range,
    )


# --- Matroska 精简索引（播放起播用） -------------------------------------------


@dataclass(frozen=True)
class MatroskaVideoCues:
    """只含视频轨索引点的 Matroska Cues 元素（docs/design/playback-qoe.md §9.12，引擎补丁 P58）。

    App 的播放引擎打开 MKV 时要先拿到整个 Cues 才能规划分片、定位续播点。mkvmerge
    给每条字幕轨的每个事件都写索引点，字幕轨多的片子 Cues 因此很大（片库抽样：中位
    68 KB、九成在 560 KB 以内、最大 4.2 MB；62 条字幕轨的那部 4K 有 1.25 MB），慢线路
    上要单独下好几秒。引擎只用得到视频轨的索引点，所以服务端从原 Cues 里挑出它们、
    原样（同一个 CueTime、同一个 CueClusterPosition）重新编码成一个很小的 Cues 元素，
    随播放会话下发；引擎在解复用器读 SeekHead 登记的 Cues 位置时直接给这份，不再下载
    原索引。

    只保留 libavformat 建索引用得到的三项（CueTime、CueTrack、CueClusterPosition，见
    FFmpeg ``matroska_add_index_entries``），数值与原文件逐位一致，解复用器看到的视频
    索引与读原 Cues 时相同。
    """

    #: Cues 元素在文件里的绝对位置（SeekHead 登记的那个位置）
    cues_offset: int
    #: 原 Cues 元素（含元素头）多少字节
    original_bytes: int
    #: 精简后的整个 Cues 元素（含元素头）
    data: bytes
    #: 保留了多少个索引点
    points: int


def _ebml_size(value: int) -> bytes:
    """EBML 元素长度的最短写法（全 1 是「未知长度」的保留值，要让开）。"""
    length = 1
    while value >= (1 << (7 * length)) - 1:
        length += 1
    return (value | (1 << (7 * length))).to_bytes(length, "big")


def _ebml_uint(value: int) -> bytes:
    return value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")


def _ebml_element(element_id: int, payload: bytes) -> bytes:
    return (
        element_id.to_bytes((element_id.bit_length() + 7) // 8, "big")
        + _ebml_size(len(payload))
        + payload
    )


def build_matroska_video_cues(path: str | Path) -> MatroskaVideoCues | None:
    """读 MKV 的 Cues，只留视频轨的索引点、重新编码成一个 Cues 元素。

    不是 MKV、没有 Cues、找不到视频轨、读失败时返回 None。同步阻塞 IO，调用方放进
    单独进程或线程池。"""
    path = Path(path)
    try:
        file_size = path.stat().st_size
        with path.open("rb") as f:
            _, positions, first_cluster = _matroska_layout(f, file_size, path)
            if _CUES not in positions or _TRACKS not in positions:
                return None
            # 只处理写在簇后面（文件尾）的 Cues：写在簇前面的会被解复用器读文件头时顺序走到，
            # 换成长度不同的精简版，它后面的元素就对不上了
            if first_cluster is None or positions[_CUES] < first_cluster:
                return None
            video_numbers: set[int] = set()
            data, body = _read_element_at(f, positions[_TRACKS], _TRACKS)
            for child_id, c_start, c_end in _children(data, body, len(data)):
                if child_id != _TRACK_ENTRY:
                    continue
                number = kind = None
                for g_id, g_start, g_end in _children(data, c_start, c_end):
                    if g_id == _TRACK_NUMBER:
                        number = _uint(data, g_start, g_end)
                    elif g_id == _TRACK_TYPE:
                        kind = _uint(data, g_start, g_end)
                if number is not None and kind == 1:
                    video_numbers.add(number)
            if not video_numbers:
                return None
            cues_offset = positions[_CUES]
            cues, body = _read_element_at(f, cues_offset, _CUES)
    except (OSError, ValueError, IndexError):
        return None

    out = bytearray()
    kept = 0
    for child_id, c_start, c_end in _children(cues, body, len(cues)):
        if child_id != _CUE_POINT:
            continue
        cue_time = None
        video_positions: list[tuple[int, int]] = []
        for g_id, g_start, g_end in _children(cues, c_start, c_end):
            if g_id == _CUE_TIME:
                cue_time = _uint(cues, g_start, g_end)
            elif g_id == _CUE_TRACK_POSITIONS:
                track = cluster = None
                for h_id, h_start, h_end in _children(cues, g_start, g_end):
                    if h_id == _CUE_TRACK:
                        track = _uint(cues, h_start, h_end)
                    elif h_id == _CUE_CLUSTER_POSITION:
                        cluster = _uint(cues, h_start, h_end)
                if track in video_numbers and cluster is not None:
                    video_positions.append((track, cluster))
        if cue_time is None or not video_positions:
            continue
        point = _ebml_element(_CUE_TIME, _ebml_uint(cue_time))
        for track, cluster in video_positions:
            point += _ebml_element(
                _CUE_TRACK_POSITIONS,
                _ebml_element(_CUE_TRACK, _ebml_uint(track))
                + _ebml_element(_CUE_CLUSTER_POSITION, _ebml_uint(cluster)),
            )
        out += _ebml_element(_CUE_POINT, point)
        kept += 1
    if kept < 2:
        return None  # libavformat 见到不足两个索引点的 Cues 会整个丢弃，不如让它读原索引
    return MatroskaVideoCues(
        cues_offset=cues_offset,
        original_bytes=len(cues),
        data=_ebml_element(_CUES, bytes(out)),
        points=kept,
    )


# --- MP4 / MOV ------------------------------------------------------------------

#: moov 的读取上限：三小时的片子样本表也就几十 MB，再大只可能是损坏文件
_MAX_MOOV_BYTES = 256 << 20
_MP4_HANDLER_KIND = {
    b"vide": KIND_VIDEO,
    b"soun": KIND_AUDIO,
    b"sbtl": KIND_SUBTITLE,
    b"subt": KIND_SUBTITLE,
    b"text": KIND_SUBTITLE,
    b"clcp": KIND_SUBTITLE,
}


def _boxes(data: bytes, start: int, end: int):
    """遍历 [start, end) 内的 box，产出 (类型, 正文起点, 正文终点)。"""
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack_from(">I4s", data, pos)
        header = 8
        if size == 1:
            size = struct.unpack_from(">Q", data, pos + 8)[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            raise ValueError("MP4 box 长度异常")
        yield kind, pos + header, min(pos + size, end)
        pos += size


def _find_box(data: bytes, start: int, end: int, kind: bytes) -> tuple[int, int] | None:
    for k, s, e in _boxes(data, start, end):
        if k == kind:
            return s, e
    return None


def _full_box_version(data: bytes, start: int) -> int:
    return data[start]


def _mp4_language(code: int) -> str | None:
    """mdhd 里的 ISO-639-2/T 三字母语言码（每字母 5 bit，+0x60）。"""
    if not code:
        return None
    letters = "".join(chr(((code >> shift) & 0x1F) + 0x60) for shift in (10, 5, 0))
    return None if letters in ("und", "```") else letters


def _read_moov(f, file_size: int) -> tuple[bytes, int, int, int | None]:
    """顶层 box 逐个看头、跳过 mdat，读出整个 moov。

    返回 (moov 字节, moov 起点, moov 终点, 第一个 mdat 正文起点或 None)。
    分片 MP4（moof）、找不到 moov、moov 过大或被截断都抛 ValueError。
    """
    moov = None
    first_mdat_body = None
    cursor = 0
    for _ in range(_MAX_TOP_LEVEL_SCAN):
        if cursor + 8 > file_size:
            break
        f.seek(cursor)
        header = f.read(16)
        if len(header) < 8:
            break
        size, kind = struct.unpack_from(">I4s", header, 0)
        header_len = 8
        if size == 1:
            size = struct.unpack_from(">Q", header, 8)[0]
            header_len = 16
        elif size == 0:
            size = file_size - cursor
        if size < header_len:
            raise ValueError("MP4 顶层 box 长度异常")
        if kind == b"moov":
            moov = (cursor, cursor + size)
        elif kind == b"mdat" and first_mdat_body is None:
            first_mdat_body = cursor + header_len
        elif kind == b"moof":
            raise ValueError("分片 MP4（moof）暂不支持")
        if moov is not None and first_mdat_body is not None:
            break
        cursor += size
    if moov is None:
        raise ValueError("找不到 moov")
    moov_start, moov_end = moov
    if moov_end - moov_start > _MAX_MOOV_BYTES:
        raise ValueError("moov 过大")
    f.seek(moov_start)
    data = f.read(moov_end - moov_start)
    if len(data) < moov_end - moov_start:
        raise ValueError("moov 被截断")
    return data, moov_start, moov_end, first_mdat_body


def _read_mp4(path: Path, file_size: int) -> ContainerIndex:
    with path.open("rb") as f:
        data, moov_start, moov_end, first_mdat_body = _read_moov(f, file_size)

    body_start = 8 if struct.unpack_from(">I", data, 0)[0] != 1 else 16
    movie_timescale = 0
    movie_duration = 0
    mvhd = _find_box(data, body_start, len(data), b"mvhd")
    if mvhd:
        s, _ = mvhd
        if _full_box_version(data, s) == 1:
            movie_timescale, movie_duration = struct.unpack_from(">IQ", data, s + 20)
        else:
            movie_timescale, movie_duration = struct.unpack_from(">II", data, s + 12)

    tracks: list[TrackInfo] = []
    keyframes: list[KeyframePoint] = []
    subtitle_events: dict[int, tuple[float, ...]] = {}
    order_by_kind: dict[str, int] = {}
    video_done = False
    for kind, t_start, t_end in _boxes(data, body_start, len(data)):
        if kind != b"trak":
            continue
        track = _parse_trak(data, t_start, t_end)
        if track is None:
            continue
        track_kind = track["kind"]
        order = order_by_kind.get(track_kind, 0)
        order_by_kind[track_kind] = order + 1
        tracks.append(
            TrackInfo(
                number=track["id"],
                kind=track_kind,
                codec=track["codec"],
                order=order,
                language=track["language"],
            )
        )
        if track_kind == KIND_VIDEO and not video_done:
            keyframes = _mp4_keyframes(track)
            video_done = True
        elif track_kind == KIND_SUBTITLE:
            subtitle_events[track["id"]] = _mp4_subtitle_events(track)

    chapters = _mp4_nero_chapters(data, body_start)
    duration_s = movie_duration / movie_timescale if movie_timescale else 0.0
    if not duration_s and keyframes:
        duration_s = keyframes[-1].time_s
    moov_first = first_mdat_body is None or moov_start < first_mdat_body
    if moov_first:
        head_end, index_range = moov_end, None
    else:
        head_end, index_range = first_mdat_body, (moov_start, moov_end)
    return ContainerIndex(
        container="mp4",
        file_size=file_size,
        duration_s=duration_s,
        keyframes=tuple(keyframes),
        tracks=tuple(tracks),
        subtitle_events=subtitle_events,
        chapters=chapters,
        head_end=head_end,
        index_range=index_range,
    )


def _parse_trak(data: bytes, start: int, end: int) -> dict | None:
    """解出一条轨的编号、类型、编码与样本表（只取刷片需要的几张表）。"""
    track_id = None
    tkhd = _find_box(data, start, end, b"tkhd")
    if tkhd:
        s, _ = tkhd
        offset = s + (20 if _full_box_version(data, s) == 1 else 12)
        track_id = struct.unpack_from(">I", data, offset)[0]
    mdia = _find_box(data, start, end, b"mdia")
    if track_id is None or mdia is None:
        return None
    m_start, m_end = mdia
    timescale = 0
    language = None
    mdhd = _find_box(data, m_start, m_end, b"mdhd")
    if mdhd:
        s, _ = mdhd
        if _full_box_version(data, s) == 1:
            timescale = struct.unpack_from(">I", data, s + 20)[0]
            language = _mp4_language(struct.unpack_from(">H", data, s + 32)[0])
        else:
            timescale = struct.unpack_from(">I", data, s + 12)[0]
            language = _mp4_language(struct.unpack_from(">H", data, s + 20)[0])
    handler = b""
    hdlr = _find_box(data, m_start, m_end, b"hdlr")
    if hdlr:
        handler = data[hdlr[0] + 8 : hdlr[0] + 12]
    minf = _find_box(data, m_start, m_end, b"minf")
    stbl = _find_box(data, minf[0], minf[1], b"stbl") if minf else None
    if stbl is None or not timescale:
        return None
    s_start, s_end = stbl
    tables: dict[bytes, tuple[int, int]] = {}
    for kind, b_start, b_end in _boxes(data, s_start, s_end):
        tables[kind] = (b_start, b_end)
    codec = ""
    if b"stsd" in tables:
        sd = tables[b"stsd"][0]
        if struct.unpack_from(">I", data, sd + 4)[0] > 0:
            codec = data[sd + 12 : sd + 16].decode("latin-1", "replace")
    return {
        "id": track_id,
        "kind": _MP4_HANDLER_KIND.get(handler, KIND_OTHER),
        "codec": codec.strip(),
        "language": language,
        "timescale": timescale,
        "data": data,
        "tables": tables,
    }


def _mp4_sample_times(track: dict) -> list[int]:
    """stts 展开成每个样本的解码时间（以轨道 timescale 计）。"""
    data, tables = track["data"], track["tables"]
    if b"stts" not in tables:
        raise ValueError("缺少 stts")
    s = tables[b"stts"][0]
    count = struct.unpack_from(">I", data, s + 4)[0]
    times: list[int] = []
    now = 0
    for i in range(count):
        n, delta = struct.unpack_from(">II", data, s + 8 + i * 8)
        for _ in range(n):
            times.append(now)
            now += delta
    return times


def _mp4_sample_sizes(track: dict, sample_count: int) -> list[int]:
    data, tables = track["data"], track["tables"]
    if b"stsz" not in tables:
        raise ValueError("缺少 stsz（stz2 暂不支持）")
    s = tables[b"stsz"][0]
    uniform, count = struct.unpack_from(">II", data, s + 4)
    if uniform:
        return [uniform] * count
    return list(struct.unpack_from(f">{count}I", data, s + 12))[:sample_count]


def _mp4_sample_offsets(track: dict, sizes: list[int]) -> list[int]:
    """stsc + stco/co64 展开成每个样本的文件偏移。"""
    data, tables = track["data"], track["tables"]
    if b"stco" in tables:
        s = tables[b"stco"][0]
        n = struct.unpack_from(">I", data, s + 4)[0]
        chunk_offsets = list(struct.unpack_from(f">{n}I", data, s + 8))
    elif b"co64" in tables:
        s = tables[b"co64"][0]
        n = struct.unpack_from(">I", data, s + 4)[0]
        chunk_offsets = list(struct.unpack_from(f">{n}Q", data, s + 8))
    else:
        raise ValueError("缺少 stco/co64")
    if b"stsc" not in tables:
        raise ValueError("缺少 stsc")
    s = tables[b"stsc"][0]
    n = struct.unpack_from(">I", data, s + 4)[0]
    runs = [struct.unpack_from(">III", data, s + 8 + i * 12)[:2] for i in range(n)]
    offsets: list[int] = []
    sample = 0
    for r, (first_chunk, per_chunk) in enumerate(runs):
        last_chunk = runs[r + 1][0] - 1 if r + 1 < len(runs) else len(chunk_offsets)
        for chunk in range(first_chunk, last_chunk + 1):
            if chunk - 1 >= len(chunk_offsets):
                break
            pos = chunk_offsets[chunk - 1]
            for _ in range(per_chunk):
                if sample >= len(sizes):
                    return offsets
                offsets.append(pos)
                pos += sizes[sample]
                sample += 1
    return offsets


def _mp4_keyframes(track: dict) -> list[KeyframePoint]:
    data, tables = track["data"], track["tables"]
    times = _mp4_sample_times(track)
    sizes = _mp4_sample_sizes(track, len(times))
    offsets = _mp4_sample_offsets(track, sizes)
    usable = min(len(times), len(offsets))
    if b"stss" in tables:
        s = tables[b"stss"][0]
        n = struct.unpack_from(">I", data, s + 4)[0]
        sync = [x - 1 for x in struct.unpack_from(f">{n}I", data, s + 8)]
    else:
        sync = list(range(usable))  # 没有 stss 表示每个样本都是关键帧
    scale = track["timescale"]
    return [KeyframePoint(times[i] / scale, offsets[i]) for i in sync if 0 <= i < usable]


def _mp4_subtitle_events(track: dict) -> tuple[float, ...]:
    """文字字幕轨：每个非空样本是一条字幕（mov_text 用 2 字节的空样本清屏）。"""
    times = _mp4_sample_times(track)
    sizes = _mp4_sample_sizes(track, len(times))
    scale = track["timescale"]
    return tuple(times[i] / scale for i in range(min(len(times), len(sizes))) if sizes[i] > 2)


def _mp4_nero_chapters(data: bytes, body_start: int) -> tuple[tuple[float, str | None], ...]:
    """moov/udta/chpl（Nero 章节，网盘/压制组的 MP4 常见）。QuickTime 章节轨不解析。"""
    udta = _find_box(data, body_start, len(data), b"udta")
    if not udta:
        return ()
    chpl = _find_box(data, udta[0], udta[1], b"chpl")
    if not chpl:
        return ()
    s, e = chpl
    version = data[s]
    p = s + 4 + (4 if version else 0)
    count = data[p]
    p += 1
    chapters: list[tuple[float, str | None]] = []
    for _ in range(count):
        if p + 9 > e:
            break
        start = struct.unpack_from(">Q", data, p)[0]
        length = data[p + 8]
        title = data[p + 9 : p + 9 + length].decode("utf-8", "replace") or None
        chapters.append((start / 10_000_000, title))
        p += 9 + length
    return tuple(sorted(chapters, key=lambda c: c[0]))


# --- MP4 关键帧呈现时间（服务端 HLS 分片计划用） ------------------------------------
#
# 为什么在这里：VOD 播放列表要在开会话时一次写出全片的分片边界，档 1/2（视频 copy）只能切在
# ffmpeg 认作关键帧的包上（keyframes.py）。MP4 原来靠 ffprobe 列包拿关键帧，而 ffprobe 列包会把
# 每个包的数据读出来——等于通读整个 mdat：2026-10-01 NAS 实测网络挂载上一部 10 GB 的 MP4
# 开会话「准备」93 秒（网页第一次播放要等一分半；iOS 直出原文件不走这条路）。这里改为只读 moov
# 的样本表算出关键帧的**呈现时间**，再抽检关键帧样本的 NAL 类型，零点几秒出结果。
#
# 两个口径必须与 ffmpeg 一字不差，否则分片编号会错位：
#
# 1. **时间**：libavformat 的 mov 解复用给出的包 pts = 解码时间（stts）+ 合成偏移（ctts，按有
#    符号读）− 编辑表第一段的 media_time；有编辑表时，处理完若最早一帧（编辑起点之后、不丢弃的）
#    pts 仍大于 0，整条轨再往前平移到 0（mov_fix_index 的「Offset DTS … to make first pts zero」）；
#    最后加上片头空段（edit 的 media_time 为 -1）换算到轨道时基。负 ctts 引起的 dts_shift 只挪
#    dts、不动 pts。NAS 片库 46 部抽样逐帧对照 ffprobe 核过（2026-10-01）。
# 2. **哪些算关键帧**：ffmpeg 读 H.264 / HEVC 时经过解析器，包的关键帧标记以解析器为准——
#    H.264 只认 IDR 与带恢复点 SEI 的帧，HEVC 认 IRAP（BLA / IDR / CRA）。stss 里登记的
#    非 IDR 的 I 帧 ffmpeg 不会在那里切片（片库抽样 31 部里 2 部如此）。所以 stss 只是候选：
#    均匀抽检至多 _VERIFY_MAX 个关键帧样本的 NAL 类型，有一个对不上就整份放弃，交还调用方
#    走 ffprobe（慢但准）。抽检是并发的随机小读：NAS 的片库挂在另一台机器的 NFS 上（机械盘），
#    串行每次 60～90 毫秒，128 个要十来秒；32 路并发约 0.3～0.45 秒（2026-10-01 实测）。
#
# 只支持 H.264（avc1 / avc3）与 HEVC（hvc1 / hev1）、编辑表至多「片头空段 + 一段」的常见形态；
# 其余（多段编辑、无 stss、别的编码）一律返回 None 让调用方兜底。

#: 抽检的关键帧样本数上限与并发数：每个样本是一次几 KB 的随机读
_VERIFY_MAX = 128
#: 网盘直链上抽检的样本数：每个样本是一次 Range 请求，抽得少一些
_REMOTE_VERIFY_MAX = 16
_VERIFY_WORKERS = 32
#: 每个样本先读这么多字节找第一个视频 NAL；SEI / 参数集特别大时再读一次大的
_VERIFY_READ = 8192
_VERIFY_READ_MAX = 1 << 18

_H264_SAMPLE_ENTRIES = frozenset({"avc1", "avc3"})
_HEVC_SAMPLE_ENTRIES = frozenset({"hvc1", "hev1"})


def read_mp4_keyframe_times(path: str | Path) -> list[float] | None:
    """MP4 / MOV 第一条视频轨里 ffmpeg 会认作关键帧的样本的呈现时间（秒，升序）。

    口径与 ``ffprobe -show_entries packet=pts_time,flags`` 里带 K 的包一致（见上方说明）。
    读不出、形态不支持、抽检对不上时返回 None——调用方据此退回 ffprobe，绝不给出可能错位的结果。
    """
    result = read_mp4_keyframes_checked(path)
    return None if result is None else result[0]


def read_mp4_keyframes_checked(path: str | Path) -> tuple[list[float], bool] | None:
    """同 :func:`read_mp4_keyframe_times`，另返回「是否只抽检了一部分关键帧样本」。

    抽检兜不住零星的坏条目（片库实测：一部 2486 个关键帧的片子 stss 里混了 2 个 NAL 类型非法的
    样本，抽 128 个没抽中）。调用方拿到 True 时应在空闲时用 :func:`verify_all_mp4_keyframes`
    全量核对一遍（keyframes.py 的 ``schedule_background_index``）。
    """
    return _read_mp4_keyframes(Path(path), verify_limit=_VERIFY_MAX, workers=_VERIFY_WORKERS)


def verify_all_mp4_keyframes(path: str | Path, *, workers: int = 4) -> bool:
    """全量核对：stss 里每一个关键帧样本都是 ffmpeg 眼里的关键帧才返回 True。

    并发压得很低（默认 4 路）：这是播放进行中在后台跑的，不能和正在读同一块盘的取流抢。
    """
    return _read_mp4_keyframes(Path(path), verify_limit=None, workers=workers) is not None


def read_remote_mp4_keyframes(f, file_size: int, label: str) -> list[float] | None:  # noqa: ANN001
    """网盘直链上的 MP4 / MOV 关键帧时间（``f`` 是 ``remote_range.RemoteRangeFile``）。

    与本地同一套读表与抽检，只是抽检的样本少（每个样本是一次 Range 请求）、并发低（家用的
    直链服务监听队列可能很浅，8 路并发实测会被重置连接）。读不出、抽检对不上时返回 None——
    调用方据此不给索引，不会给出可能错位的结果。
    """
    try:
        result = _mp4_keyframes_from(
            f, file_size, f.pread, label, verify_limit=_REMOTE_VERIFY_MAX, workers=4
        )
    except (OSError, ValueError, IndexError, struct.error) as exc:
        logger.info("网盘 MP4 关键帧表读取失败：%s（%s）", label, exc)
        return None
    return None if result is None else result[0]


def _read_mp4_keyframes(
    path: Path, *, verify_limit: int | None, workers: int
) -> tuple[list[float], bool] | None:
    try:
        file_size = path.stat().st_size
        with path.open("rb") as f:
            fd = f.fileno()
            result = _mp4_keyframes_from(
                f,
                file_size,
                lambda size, offset: os.pread(fd, size, offset),
                str(path),
                verify_limit=verify_limit,
                workers=workers,
            )
    except (OSError, ValueError, IndexError, struct.error) as exc:
        logger.info("MP4 关键帧表读取失败，改用 ffprobe：%s（%s）", path, exc)
        return None
    return result


def _mp4_keyframes_from(
    f,  # noqa: ANN001 — 本地文件或 RemoteRangeFile
    file_size: int,
    read_at: Callable[[int, int], bytes],
    label: str,
    *,
    verify_limit: int | None,
    workers: int,
) -> tuple[list[float], bool] | None:
    data, _, _, _ = _read_moov(f, file_size)
    track = _first_video_track(data)
    if track is None:
        return None
    if track["codec"] in _H264_SAMPLE_ENTRIES:
        is_key = _h264_access_unit_is_key
    elif track["codec"] in _HEVC_SAMPLE_ENTRIES:
        is_key = _hevc_access_unit_is_key
    else:
        return None
    tables = track["tables"]
    if b"stss" not in tables or track["nal_length_size"] is None:
        return None
    edit = _mp4_simple_edit(track)
    if edit is None:
        return None
    media_time, empty_ticks = edit
    dts = _mp4_sample_times(track)
    cts = _mp4_composition_offsets(track, len(dts))
    sizes = _mp4_sample_sizes(track, len(dts))
    offsets = _mp4_sample_offsets(track, sizes)
    s = tables[b"stss"][0]
    count = struct.unpack_from(">I", data, s + 4)[0]
    usable = min(len(dts), len(offsets))
    sync = [i - 1 for i in struct.unpack_from(f">{count}I", data, s + 8) if 0 < i <= usable]
    if not sync:
        return None
    picks = sync if verify_limit is None else _evenly_spaced(sync, verify_limit)
    failure = _verify_sync_samples(
        read_at, picks, offsets, sizes, track["nal_length_size"], is_key, workers
    )
    if failure is not None:
        index, verdict = failure
        logger.info(
            "MP4 关键帧表与码流不一致，改用 ffprobe 列关键帧：%s（第 %d 个样本%s）",
            label,
            index + 1,
            "不是 IDR / IRAP 帧" if verdict is False else "读不出视频数据",
        )
        return None
    scale = track["timescale"]
    if media_time >= scale:
        # 编辑表裁掉了 1 秒以上的片头：libavformat 要按 dts 往回找起始关键帧（还要往前多找 1 秒
        # 照顾 B 帧），留下哪些关键帧的规则太细碎，交给 ffprobe。片库里常见的编辑表只是抵消
        # 一两帧的合成偏移
        return None
    shift = 0
    if track["elst"]:
        # 编辑起点之前的帧（pts < 0）丢弃，剩下的最早一帧对齐到 0
        kept = [d + c - media_time for d, c in zip(dts, cts, strict=True) if d + c >= media_time]
        shift = max(0, min(kept, default=0))
    # 编辑起点之前的关键帧（pts 为负）也在：ffmpeg 要从它解起，ffprobe 列成「KD」（画面丢弃）
    times = sorted((dts[i] + cts[i] - media_time - shift + empty_ticks) / scale for i in sync)
    return times, len(picks) < len(sync)


def _first_video_track(data: bytes) -> dict | None:
    """moov 里的第一条视频轨（ffprobe 的 v:0）：样本表、时基、编辑表与 NAL 长度字段的字节数。"""
    body_start = 8 if struct.unpack_from(">I", data, 0)[0] != 1 else 16
    movie_timescale = 0
    mvhd = _find_box(data, body_start, len(data), b"mvhd")
    if mvhd:
        s, _ = mvhd
        offset = s + (20 if _full_box_version(data, s) == 1 else 12)
        movie_timescale = struct.unpack_from(">I", data, offset)[0]
    for kind, t_start, t_end in _boxes(data, body_start, len(data)):
        if kind != b"trak":
            continue
        track = _parse_trak(data, t_start, t_end)
        if track is None or track["kind"] != KIND_VIDEO:
            continue
        track["movie_timescale"] = movie_timescale
        track["elst"] = _mp4_edit_list(data, t_start, t_end)
        track["nal_length_size"] = _mp4_nal_length_size(data, track)
        return track
    return None


def _mp4_edit_list(data: bytes, t_start: int, t_end: int) -> list[tuple[int, int, float]]:
    """trak/edts/elst 的条目：(片段时长，按影片时基；media_time，-1 表示空段；播放速率)。"""
    edts = _find_box(data, t_start, t_end, b"edts")
    if not edts:
        return []
    elst = _find_box(data, edts[0], edts[1], b"elst")
    if not elst:
        return []
    s, _ = elst
    version = _full_box_version(data, s)
    count = struct.unpack_from(">I", data, s + 4)[0]
    entries = []
    p = s + 8
    for _ in range(count):
        if version == 1:
            duration, media_time, rate_int, rate_frac = struct.unpack_from(">QqhH", data, p)
            p += 20
        else:
            duration, media_time, rate_int, rate_frac = struct.unpack_from(">IihH", data, p)
            p += 12
        entries.append((duration, media_time, rate_int + rate_frac / 65536))
    return entries


def _mp4_simple_edit(track: dict) -> tuple[int, int] | None:
    """把编辑表折成 (media_time, 片头空段换算到轨道时基的刻度)。

    只认「若干片头空段 + 至多一段正常速率的媒体段」：这是封装器为了抵消 B 帧合成偏移、或让
    音画对齐写的常见形态。多段剪辑、变速段返回 None（libavformat 的处理复杂，交给 ffprobe）。
    """
    empty = 0
    media: list[tuple[int, float]] = []
    for duration, media_time, rate in track["elst"]:
        if media_time == -1:
            if media:
                return None
            empty += duration
        else:
            media.append((media_time, rate))
    if len(media) > 1 or (media and media[0][1] != 1):
        return None
    movie_timescale = track["movie_timescale"]
    if empty and not movie_timescale:
        return None
    # libavformat 用 av_rescale（四舍五入）把空段从影片时基换到轨道时基
    empty_ticks = (
        (empty * track["timescale"] + movie_timescale // 2) // movie_timescale if empty else 0
    )
    return (media[0][0] if media else 0), empty_ticks


def _mp4_composition_offsets(track: dict, sample_count: int) -> list[int]:
    """ctts 展开成每个样本的合成偏移。与 libavformat 一样一律按有符号 32 位读（版本 0 的表里
    也常见负值）；没有 ctts 就全是 0。"""
    data, tables = track["data"], track["tables"]
    offsets = [0] * sample_count
    if b"ctts" not in tables:
        return offsets
    s = tables[b"ctts"][0]
    count = struct.unpack_from(">I", data, s + 4)[0]
    index = 0
    for i in range(count):
        n, offset = struct.unpack_from(">Ii", data, s + 8 + i * 8)
        end = min(sample_count, index + n)
        for k in range(index, end):
            offsets[k] = offset
        index += n
        if index >= sample_count:
            break
    return offsets


def _mp4_nal_length_size(data: bytes, track: dict) -> int | None:
    """视频样本里每个 NAL 前的长度字段占几个字节（avcC / hvcC 的 lengthSizeMinusOne + 1）。"""
    tables = track["tables"]
    if b"stsd" not in tables:
        return None
    sd = tables[b"stsd"][0]
    if struct.unpack_from(">I", data, sd + 4)[0] < 1:
        return None
    entry_size = struct.unpack_from(">I", data, sd + 8)[0]
    # VisualSampleEntry 正文的固定字段共 78 字节，之后才是 avcC / hvcC 等子 box
    children_start = sd + 16 + 78
    entry_end = sd + 8 + entry_size
    if children_start > entry_end:
        return None
    if track["codec"] in _H264_SAMPLE_ENTRIES:
        box = _find_box(data, children_start, entry_end, b"avcC")
        return (data[box[0] + 4] & 0x03) + 1 if box else None
    if track["codec"] in _HEVC_SAMPLE_ENTRIES:
        box = _find_box(data, children_start, entry_end, b"hvcC")
        return (data[box[0] + 21] & 0x03) + 1 if box else None
    return None


def _evenly_spaced(items: list[int], limit: int) -> list[int]:
    """至多 ``limit`` 个均匀分布的元素（含首尾）；不超过上限就全要。"""
    if len(items) <= limit:
        return list(items)
    step = (len(items) - 1) / (limit - 1)
    return [items[round(k * step)] for k in range(limit)]


def _verify_sync_samples(
    read_at: Callable[[int, int], bytes],
    picks: list[int],
    offsets: list[int],
    sizes: list[int],
    length_size: int,
    is_key,
    workers: int,
) -> tuple[int, bool | None] | None:
    """并发检查关键帧样本：全部是 ffmpeg 眼里的关键帧返回 None，否则返回第一个不是的
    (样本下标, 判定)。``read_at(字节数, 偏移)`` 不动文件位置（本地是共享描述符的 pread）。"""

    def check(i: int) -> tuple[int, bool | None]:
        return i, _sample_is_key(read_at, offsets[i], sizes[i], length_size, is_key)

    with ThreadPoolExecutor(max_workers=max(1, min(workers, len(picks)))) as pool:
        for i, verdict in pool.map(check, picks):
            if verdict is not True:
                return i, verdict
    return None


def _sample_is_key(
    read_at: Callable[[int, int], bytes], offset: int, size: int, length_size: int, is_key
) -> bool | None:
    """读一个样本的开头判断它是不是 ffmpeg 眼里的关键帧；None = 读到的字节里没有视频 NAL。"""
    for budget in (_VERIFY_READ, _VERIFY_READ_MAX):
        buf = read_at(min(size, budget), offset)
        verdict = is_key(buf, length_size)
        if verdict is not None or len(buf) >= size:
            return verdict
    return None


def _iter_nals(buf: bytes, length_size: int):
    """长度前缀格式的 NAL 序列：产出 (NAL 起点, NAL 终点)；终点可能超出 buf（只读了开头）。"""
    pos = 0
    while pos + length_size < len(buf):
        length = int.from_bytes(buf[pos : pos + length_size], "big")
        pos += length_size
        if length <= 0:
            return
        yield pos, pos + length
        pos += length


def _h264_access_unit_is_key(buf: bytes, length_size: int) -> bool | None:
    """H.264：IDR，或第一个视频 NAL 之前带恢复点 SEI——与 ffmpeg 的 h264 解析器同判据。"""
    for start, end in _iter_nals(buf, length_size):
        nal_type = buf[start] & 0x1F
        if nal_type == 5:
            return True
        if nal_type == 6 and _sei_has_recovery_point(buf[start + 1 : min(end, len(buf))]):
            return True
        if 1 <= nal_type <= 4:
            return False
    return None


def _sei_has_recovery_point(payload: bytes) -> bool:
    """H.264 SEI 里有没有恢复点消息（payloadType 6）。"""
    data = payload.replace(b"\x00\x00\x03", b"\x00\x00")
    pos = 0
    while pos < len(data):
        if pos == len(data) - 1 and data[pos] == 0x80:
            break
        values = []
        for _ in range(2):
            value = 0
            while pos < len(data) and data[pos] == 0xFF:
                value += 255
                pos += 1
            if pos >= len(data):
                return False
            value += data[pos]
            pos += 1
            values.append(value)
        payload_type, payload_size = values
        if payload_type == 6:
            return True
        pos += payload_size
    return False


def _hevc_access_unit_is_key(buf: bytes, length_size: int) -> bool | None:
    """HEVC：第一个视频 NAL（类型 0～31）是 IRAP（16～23：BLA / IDR / CRA）。

    与 ffmpeg 的 hevc 解析器同判据。"""
    for start, _ in _iter_nals(buf, length_size):
        nal_type = (buf[start] >> 1) & 0x3F
        if nal_type <= 31:
            return 16 <= nal_type <= 23
    return None

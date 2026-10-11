"""按 Matroska Cues 只读字幕块，拼成一个只含字幕轨的小 MKV（docs/design/subtitle-cues.md）。

内封字幕和音视频按时间交错存放，ffmpeg 抽一条字幕轨只能把整个文件从头读到尾——Jellyfin、
Emby 都是这么做的。可 mkvmerge 默认给**每一条字幕**都写一个 CuePoint（带 CueRelativePosition，
定位到 Cluster 里的那个块）：NAS 片库抽样 200 个带内封字幕的 MKV，98% 每条字幕轨都有，
抽查的文件索引条数与全量数出的字幕包数逐轨一致（2026-10-11）。照着索引只读字幕块：

1. 读文件布局、Info、Tracks、Cues（几百 KB）；
2. 每条字幕一个块：Cluster 位置 + 块内偏移就是它的绝对位置，按位置排序、相邻的合并成
   一次读，并发取回（文字字幕每块几十到几百字节，PGS 几 KB 到几十 KB）；
3. 拼成一个小 MKV：原 EBML 头、原 Info、只含字幕轨的 Tracks（TrackEntry 原样拷贝，
   CodecPrivate、压缩设置都在里面），每个块单独一个 Cluster，Cluster 时间戳取 CueTime、
   块内相对时间戳清零。交给 ffmpeg 转 SRT / ASS / SUP，格式处理与整片抽取完全同一条路。

字幕轨顺序与原文件一致，``-map 0:s:N`` 的序号不变。任何一步对不上（没有 Cues、某条字幕轨
没有索引点、缺块内偏移、读出的块不是这条轨的）就返回 None，调用方退回整片通读——结果宁可
慢，不能错。
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from movieclaw_playback.container_index import (
    _CUE_CLUSTER_POSITION,
    _CUE_POINT,
    _CUE_TIME,
    _CUE_TRACK,
    _CUE_TRACK_POSITIONS,
    _CUES,
    _EBML_HEADER,
    _INFO,
    _SEGMENT,
    _TIMESTAMP_SCALE,
    _TRACK_ENTRY,
    _TRACK_NUMBER,
    _TRACK_TYPE,
    _TRACKS,
    _children,
    _ebml_element,
    _ebml_uint,
    _matroska_layout,
    _read_element_at,
    _uint,
    _vint,
)

logger = logging.getLogger("movieclaw_playback.subtitle_cues")

_CUE_RELATIVE_POSITION = 0xF0
_CLUSTER = 0x1F43B675
_CLUSTER_TIMESTAMP = 0xE7
_CRC32 = 0xBF
_VOID = 0xEC
_SIMPLE_BLOCK = 0xA3
_BLOCK_GROUP = 0xA0
_BLOCK = 0xA1
_TRACK_TYPE_SUBTITLE = 17
#: Segment 用「未知长度」：小 MKV 是一次写完的，不需要回填
_UNKNOWN_SIZE = b"\x01\xff\xff\xff\xff\xff\xff\xff"

#: 每个块先读这么多，超出再补读：文字字幕几百字节；PGS / VobSub 一块几 KB 到几十 KB，
#: 按 4 KB 探的话几乎每块都要多一次请求
_BLOCK_PROBE = 4096
_BITMAP_BLOCK_PROBE = 64 * 1024
_BITMAP_CODECS = frozenset({b"S_HDMV/PGS", b"S_VOBSUB"})
_CODEC_ID = 0x86
#: 相邻读取间隔不超过它就合并成一次请求；合并后单次最多读这么多
_MERGE_GAP = 16 * 1024
_MERGE_MAX = 1 << 20
#: 字幕块的长度上限：超过就当解析错位
_MAX_BLOCK = 8 << 20


@dataclass(frozen=True)
class _Cue:
    track: int
    time: int  # Segment 时间刻度下的绝对时间（与 Cluster 时间戳同单位）
    cluster: int  # Cluster 元素的绝对位置
    relative: int  # 块相对 Cluster 正文起点的偏移


@dataclass(frozen=True)
class SubtitleTracks:
    """抽出来的字幕轨：小 MKV 字节，以及每条轨的块数（日志 / 核对用）。

    ``start_s`` 是原片的起始时间（第一个 Cluster 的时间戳）。小 MKV 的起点是第一条字幕，
    ffmpeg 默认把输出时间戳减去输入起点——转出来的字幕会整体提前（PGS 实测偏了 93 秒）。
    转换时加 ``-copyts`` 保留绝对时间，再减去原片起点，与整片通读的结果逐字节一致。
    """

    data: bytes
    blocks: dict[int, int]
    start_s: float


def build_subtitle_mkv(
    f,  # noqa: ANN001 — 可 seek/read 的文件对象（本地文件或 RemoteRangeFile）
    read_at: Callable[[int, int], bytes],
    file_size: int,
    label: str,
    *,
    workers: int,
) -> SubtitleTracks | None:
    """读出全部字幕轨的块，拼成只含字幕轨的 MKV；索引不全或对不上时返回 None。

    ``read_at(字节数, 偏移)`` 要能多线程并发调用（本地是 pread，远端是 Range 请求）。
    """
    segment_start, positions, first_cluster = _matroska_layout(f, file_size, Path(label))
    if _TRACKS not in positions or _CUES not in positions or first_cluster is None:
        return None
    f.seek(0)
    head = f.read(64)
    element_id, pos, _ = _vint(head, 0, keep_marker=True)
    if element_id != _EBML_HEADER:
        return None
    size, pos, _ = _vint(head, pos, keep_marker=False)
    f.seek(0)
    ebml_header = f.read(pos + size)
    info = _read_element_at(f, positions[_INFO], _INFO)[0] if _INFO in positions else b""
    scale = 1_000_000  # TimestampScale 默认值：每刻 1 毫秒
    if info:
        _, info_body, _ = _vint(info, 0, keep_marker=True)
        _, info_body, _ = _vint(info, info_body, keep_marker=False)
        for child_id, c_start, c_end in _children(info, info_body, len(info)):
            if child_id == _TIMESTAMP_SCALE:
                scale = _uint(info, c_start, c_end)
    start = _cluster_timestamp(read_at, first_cluster)
    if start is None:
        return None

    tracks_data, body = _read_element_at(f, positions[_TRACKS], _TRACKS)
    entries: list[tuple[int, bytes]] = []
    probes: dict[int, int] = {}
    for child_id, c_start, c_end in _children(tracks_data, body, len(tracks_data)):
        if child_id != _TRACK_ENTRY:
            continue
        number = kind = None
        codec = b""
        for g_id, g_start, g_end in _children(tracks_data, c_start, c_end):
            if g_id == _TRACK_NUMBER:
                number = _uint(tracks_data, g_start, g_end)
            elif g_id == _TRACK_TYPE:
                kind = _uint(tracks_data, g_start, g_end)
            elif g_id == _CODEC_ID:
                codec = bytes(tracks_data[g_start:g_end])
        if kind == _TRACK_TYPE_SUBTITLE and number is not None:
            entries.append((number, _ebml_element(_TRACK_ENTRY, tracks_data[c_start:c_end])))
            probes[number] = _BITMAP_BLOCK_PROBE if codec in _BITMAP_CODECS else _BLOCK_PROBE
    if not entries:
        return None

    numbers = {number for number, _ in entries}
    cues = _subtitle_cues(f, positions[_CUES], segment_start, numbers)
    if cues is None or {cue.track for cue in cues} != numbers:
        return None
    blocks = _fetch_blocks(read_at, cues, file_size, probes, workers=workers)
    if blocks is None:
        logger.info("字幕块与索引对不上，退回整片读取：%s", label)
        return None

    # 按块在原文件里的位置排：ffmpeg 通读时就是这个顺序。同一时刻常有好几个块（PGS 一个
    # 清屏、一个显示），按时间排会打乱它们的先后（NAS 实测 PGS 轨因此对不上）
    clusters = bytearray()
    for cue, (_start, block) in sorted(zip(cues, blocks, strict=True), key=lambda x: x[1][0]):
        payload = _ebml_element(_CLUSTER_TIMESTAMP, _ebml_uint(cue.time)) + block
        clusters += _ebml_element(_CLUSTER, payload)
    tracks = _ebml_element(_TRACKS, b"".join(entry for _, entry in entries))
    data = ebml_header + _SEGMENT.to_bytes(4, "big") + _UNKNOWN_SIZE + info + tracks + clusters
    counts: dict[int, int] = {}
    for cue in cues:
        counts[cue.track] = counts.get(cue.track, 0) + 1
    return SubtitleTracks(data=bytes(data), blocks=counts, start_s=start * scale / 1e9)


def _cluster_timestamp(read_at: Callable[[int, int], bytes], cluster: int) -> int | None:
    """Cluster 的时间戳：排在 Cluster 最前面，前面至多有 CRC-32 / Void（ffmpeg 先写 CRC-32）。"""
    head = read_at(64, cluster)
    try:
        element_id, pos, _ = _vint(head, 0, keep_marker=True)
        if element_id != _CLUSTER:
            return None
        _, pos, _ = _vint(head, pos, keep_marker=False)
        for child_id, c_start, c_end in _children(head, pos, len(head)):
            if child_id == _CLUSTER_TIMESTAMP:
                return _uint(head, c_start, c_end)
            if child_id not in (_CRC32, _VOID):
                return None
    except (ValueError, IndexError):
        return None
    return None


def _subtitle_cues(f, cues_at: int, segment_start: int, numbers: set[int]) -> list[_Cue] | None:  # noqa: ANN001
    data, body = _read_element_at(f, cues_at, _CUES)
    cues: list[_Cue] = []
    for child_id, c_start, c_end in _children(data, body, len(data)):
        if child_id != _CUE_POINT:
            continue
        time = None
        found: list[tuple[int, int | None, int | None]] = []
        for g_id, g_start, g_end in _children(data, c_start, c_end):
            if g_id == _CUE_TIME:
                time = _uint(data, g_start, g_end)
            elif g_id == _CUE_TRACK_POSITIONS:
                track = cluster = relative = None
                for h_id, h_start, h_end in _children(data, g_start, g_end):
                    if h_id == _CUE_TRACK:
                        track = _uint(data, h_start, h_end)
                    elif h_id == _CUE_CLUSTER_POSITION:
                        cluster = _uint(data, h_start, h_end)
                    elif h_id == _CUE_RELATIVE_POSITION:
                        relative = _uint(data, h_start, h_end)
                if track in numbers:
                    found.append((track, cluster, relative))
        for track, cluster, relative in found:
            if time is None or cluster is None or relative is None:
                return None  # 缺块内偏移：要扫整个 Cluster 才找得到块，不走快路径
            cues.append(_Cue(track, time, segment_start + cluster, relative))
    return cues


def _fetch_blocks(
    read_at: Callable[[int, int], bytes],
    cues: list[_Cue],
    file_size: int,
    probes: dict[int, int],
    *,
    workers: int,
) -> list[tuple[int, bytes]] | None:
    """取回每个索引点指向的块：(块在原文件里的位置, 块元素原样、块内相对时间戳清零)。
    对不上返回 None。

    块的绝对位置 = Cluster 位置 + Cluster 元素头长 + 块内偏移。元素头长取决于 Cluster 长度
    字段的字节数，先读第一个 Cluster 的头学到它，其余照用；某个块按它解析不对，再单独读
    那个 Cluster 的头重算——长度字段的写法在同一个文件里几乎总是一样的。
    """
    header_len = _cluster_header_length(read_at, cues[0].cluster)
    if header_len is None:
        return None
    starts = [cue.cluster + header_len + cue.relative for cue in cues]
    lengths = [probes[cue.track] for cue in cues]
    windows = _read_windows(read_at, starts, lengths, file_size, workers=workers)
    blocks: list[tuple[int, bytes]] = []
    for cue, start, window in zip(cues, starts, windows, strict=True):
        block = _parse_block(read_at, window, start, cue.track)
        if block is None:
            exact = _cluster_header_length(read_at, cue.cluster)
            if exact is None or exact == header_len:
                return None
            start = cue.cluster + exact + cue.relative
            block = _parse_block(read_at, read_at(probes[cue.track], start), start, cue.track)
            if block is None:
                return None
        blocks.append((start, block))
    return blocks


def _cluster_header_length(read_at: Callable[[int, int], bytes], cluster: int) -> int | None:
    head = read_at(12, cluster)
    try:
        element_id, pos, _ = _vint(head, 0, keep_marker=True)
        if element_id != _CLUSTER:
            return None
        _, pos, _ = _vint(head, pos, keep_marker=False)
    except (ValueError, IndexError):
        return None
    return pos


def _read_windows(
    read_at: Callable[[int, int], bytes],
    starts: list[int],
    lengths: list[int],
    file_size: int,
    *,
    workers: int,
) -> list[bytes]:
    """每个块起点往后读 ``lengths`` 字节；相邻的合并成一次请求，并发取回。"""
    order = sorted(range(len(starts)), key=lambda i: starts[i])
    groups: list[tuple[int, int, list[int]]] = []  # (起点, 终点, 成员下标)
    for i in order:
        begin = starts[i]
        end = min(begin + lengths[i], file_size)
        if groups:
            g_begin, g_end, members = groups[-1]
            if begin <= g_end + _MERGE_GAP and end - g_begin <= _MERGE_MAX:
                groups[-1] = (g_begin, max(g_end, end), [*members, i])
                continue
        groups.append((begin, end, [i]))

    def fetch(group: tuple[int, int, list[int]]) -> bytes:
        begin, end, _ = group
        return read_at(end - begin, begin)

    windows: list[bytes] = [b""] * len(starts)
    with ThreadPoolExecutor(max_workers=max(1, min(workers, len(groups)))) as pool:
        for (begin, _end, members), data in zip(groups, pool.map(fetch, groups), strict=True):
            for i in members:
                windows[i] = data[starts[i] - begin : starts[i] - begin + lengths[i]]
    return windows


def _parse_block(
    read_at: Callable[[int, int], bytes], window: bytes, start: int, track: int
) -> bytes | None:
    """window 开头应是 track 这条轨的 SimpleBlock / BlockGroup；返回整个元素（时间戳已清零）。"""
    try:
        element_id, pos, _ = _vint(window, 0, keep_marker=True)
        if element_id not in (_SIMPLE_BLOCK, _BLOCK_GROUP):
            return None
        size, pos, unknown = _vint(window, pos, keep_marker=False)
    except (ValueError, IndexError):
        return None
    if unknown or size > _MAX_BLOCK:
        return None
    total = pos + size
    element = window[:total]
    if len(element) < total:
        element += read_at(total - len(element), start + len(element))
        if len(element) < total:
            return None
    element = bytearray(element)
    block_at = pos
    if element_id == _BLOCK_GROUP:
        block_at = None
        for child_id, c_start, _c_end in _children(element, pos, total):
            if child_id == _BLOCK:
                block_at = c_start
                break
        if block_at is None:
            return None
    try:
        number, after, _ = _vint(element, block_at, keep_marker=False)
    except (ValueError, IndexError):
        return None
    if number != track or after + 2 > total:
        return None
    element[after : after + 2] = b"\x00\x00"  # 块内相对时间戳清零：新 Cluster 的时间戳就是 CueTime
    return bytes(element)

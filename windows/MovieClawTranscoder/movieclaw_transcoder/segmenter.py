"""分片器：把 ffmpeg 输出的分片化 MP4 流切成 ``init.mp4`` 与按 HLS 栅格归段的片段。

与 macOS 转码器的 ``ProgressiveSegments.swift`` 同一条切段规则——这是播放列表与分片能对上
的前提：第一段编号是 NAS 给的起转分片号；之后从这一轮第一帧起算，满一格后的第一个同步帧
开新的一段。不能拿时间戳除以段长取整：``-force_key_frames`` 的 t 是从这一轮第一帧起算的。
"""

from __future__ import annotations

from dataclasses import dataclass


def _u32(data: bytes, at: int) -> int:
    return int.from_bytes(data[at : at + 4], "big")


def _u64(data: bytes, at: int) -> int:
    return int.from_bytes(data[at : at + 8], "big")


@dataclass
class FragmentOutput:
    kind: str  # "init" | "fragment"
    segment: int | None
    data: bytes
    starts_segment: bool


class FragmentSegmenter:
    """喂入 ffmpeg 写出的字节，吐出 init 与片段。格式坏到切不了段时 ``failure`` 写明原因。"""

    #: 单个盒子的合理上限：超过它说明流已经错位（把 mdat 的载荷当成了盒头）
    MAX_BOX_BYTES = 256 * 1024 * 1024

    def __init__(self, segment_seconds: float, start_segment: int | None = None) -> None:
        self.segment_seconds = segment_seconds
        self.start_segment = start_segment
        self.failure: str | None = None
        self._buffer = b""
        self._ftyp: bytes | None = None
        self._video_track_id: int | None = None
        self._timescale = 90_000.0
        self._pending_moof: bytes | None = None
        self._leading = b""
        self._current_segment: int | None = None
        #: (这一轮第一帧的时间, 它所在的分片号)
        self._run_start: tuple[float, int] | None = None

    def append(self, data: bytes) -> list[FragmentOutput]:
        if self.failure is not None:
            return []
        self._buffer += data
        outputs: list[FragmentOutput] = []
        while (box := self._next_box()) is not None:
            kind, payload = box
            if kind == "ftyp":
                self._ftyp = payload
            elif kind == "moov":
                self._parse_moov(payload)
                outputs.append(FragmentOutput("init", None, (self._ftyp or b"") + payload, True))
            elif kind == "moof":
                self._pending_moof = payload
            elif kind == "mdat" and self._pending_moof is not None:
                moof, self._pending_moof = self._pending_moof, None
                output = self._place(moof, moof + payload)
                if output is not None:
                    outputs.append(output)
            # styp / sidx / mfra / free：HLS 用不到
        return outputs

    def _next_box(self) -> tuple[str, bytes] | None:
        buf = self._buffer
        if len(buf) < 8:
            return None
        size = _u32(buf, 0)
        kind = buf[4:8].decode("latin-1")
        if size == 1:
            if len(buf) < 16:
                return None
            size = _u64(buf, 8)
        if size < 8 or size > self.MAX_BOX_BYTES:
            self.failure = f"分片化 MP4 里出现了长度不合理的盒子（{kind} {size} 字节）"
            self._buffer = b""
            return None
        if len(buf) < size:
            return None
        self._buffer = buf[size:]
        return kind, buf[:size]

    def _place(self, moof: bytes, fragment: bytes) -> FragmentOutput | None:
        timing = self._video_timing(moof)
        if self._run_start is None:
            if timing is None:
                # 视频轨还没出第一个片段（先到的是只有音频的片段）：先攒着，跟第一个视频片段一起走
                self._leading += fragment
                return None
            index = (
                self.start_segment
                if self.start_segment is not None
                else round(timing[0] / self.segment_seconds)
            )
            self._run_start = (timing[0], index)
            self._current_segment = index
            data, self._leading = self._leading + fragment, b""
            return FragmentOutput("fragment", index, data, True)
        current = self._current_segment
        if current is None:
            return None
        if timing is not None and timing[1]:
            start_pts, start_seg = self._run_start
            due = start_pts + (current - start_seg + 1) * self.segment_seconds - 0.001
            if timing[0] >= due:
                self._current_segment = current + 1
                return FragmentOutput("fragment", current + 1, fragment, True)
        return FragmentOutput("fragment", current, fragment, False)

    def _parse_moov(self, moov: bytes) -> None:
        for kind, trak in _children(moov):
            if kind != "trak":
                continue
            track_id: int | None = None
            handler: str | None = None
            scale: int | None = None
            for ckind, child in _children(trak):
                if ckind == "tkhd":
                    offset = 12 + (16 if child[8] == 1 else 8)
                    track_id = _u32(child, offset)
                elif ckind == "mdia":
                    for ikind, item in _children(child):
                        if ikind == "mdhd":
                            offset = 12 + (16 if item[8] == 1 else 8)
                            scale = _u32(item, offset)
                        elif ikind == "hdlr":
                            handler = item[16:20].decode("latin-1")
            if handler == "vide" and track_id is not None:
                self._video_track_id = track_id
                if scale and scale > 0:
                    self._timescale = float(scale)

    def _video_timing(self, moof: bytes) -> tuple[float, bool] | None:
        """视频轨在这个片段里的 (起点时间, 首个样本是不是同步帧)；不含视频轨返回 None。"""
        for kind, traf in _children(moof):
            if kind != "traf":
                continue
            track_id: int | None = None
            default_flags: int | None = None
            base = 0
            first_flags: int | None = None
            composition_offset = 0
            for bkind, data in _children(traf):
                if bkind == "tfhd":
                    flags = _u32(data, 8) & 0x00FF_FFFF
                    track_id = _u32(data, 12)
                    cursor = 16
                    if flags & 0x01:
                        cursor += 8
                    if flags & 0x02:
                        cursor += 4
                    if flags & 0x08:
                        cursor += 4
                    if flags & 0x10:
                        cursor += 4
                    if flags & 0x20:
                        default_flags = _u32(data, cursor)
                elif bkind == "tfdt":
                    base = _u64(data, 12) if data[8] == 1 else _u32(data, 12)
                elif bkind == "trun":
                    word = _u32(data, 8)
                    version = word >> 24
                    flags = word & 0x00FF_FFFF
                    cursor = 16
                    if flags & 0x01:
                        cursor += 4
                    if flags & 0x04:
                        first_flags = _u32(data, cursor)
                        cursor += 4
                    if flags & 0x100:
                        cursor += 4
                    if flags & 0x200:
                        cursor += 4
                    if flags & 0x400:
                        if first_flags is None:
                            first_flags = _u32(data, cursor)
                        cursor += 4
                    if flags & 0x800:
                        raw = _u32(data, cursor)
                        composition_offset = (
                            raw if version == 0 or raw < (1 << 31) else raw - (1 << 32)
                        )
            if track_id != self._video_track_id:
                continue
            flags = first_flags if first_flags is not None else (default_flags or 0)
            # sample_is_non_sync_sample 是第 16 位
            is_sync = (flags & 0x0001_0000) == 0
            return ((base + composition_offset) / self._timescale, is_sync)
        return None


def _children(box: bytes) -> list[tuple[str, bytes]]:
    out: list[tuple[str, bytes]] = []
    cursor = 8
    while cursor + 8 <= len(box):
        size = _u32(box, cursor)
        if size < 8 or cursor + size > len(box):
            break
        out.append((box[cursor + 4 : cursor + 8].decode("latin-1"), box[cursor : cursor + size]))
        cursor += size
    return out

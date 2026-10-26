"""手工拼分片化 MP4（测试专用）：不依赖 ffmpeg，切段规则的每个边界都能精确构造。

只拼分片器读得到的那几个盒子：``ftyp`` / ``moov``（``trak`` → ``tkhd`` + ``mdia`` →
``mdhd`` + ``hdlr``）与每个片段的 ``moof``（``traf`` → ``tfhd`` + ``tfdt`` + ``trun``）+ ``mdat``。
"""

from __future__ import annotations

import struct

TIMESCALE = 1000

#: sample_flags：普通样本（同步帧）/ 非同步样本（第 16 位 = sample_is_non_sync_sample）
_SYNC = 0x02000000
_NON_SYNC = 0x01010000


def box(kind: bytes, payload: bytes = b"") -> bytes:
    return struct.pack(">I", 8 + len(payload)) + kind + payload


def full_box(kind: bytes, version: int, flags: int, payload: bytes) -> bytes:
    return box(kind, struct.pack(">I", (version << 24) | flags) + payload)


def _track(track_id: int, handler: bytes) -> bytes:
    tkhd = full_box(b"tkhd", 0, 3, struct.pack(">IIII", 0, 0, track_id, 0) + b"\0" * 60)
    mdhd = full_box(b"mdhd", 0, 0, struct.pack(">IIII", 0, 0, TIMESCALE, 0) + b"\0" * 4)
    hdlr = full_box(b"hdlr", 0, 0, struct.pack(">I", 0) + handler + b"\0" * 12 + b"\0")
    return box(b"trak", tkhd + box(b"mdia", mdhd + hdlr))


def init_segment(*, with_audio: bool = True) -> bytes:
    """``ftyp`` + ``moov``：视频轨 id 1、（可选）音频轨 id 2；时间刻度 1000（毫秒）。"""
    ftyp = box(b"ftyp", b"isom" + struct.pack(">I", 0x200) + b"isomiso6")
    tracks = _track(1, b"vide") + (_track(2, b"soun") if with_audio else b"")
    return ftyp + box(b"moov", full_box(b"mvhd", 0, 0, b"\0" * 96) + tracks)


def fragment(
    *,
    track_id: int = 1,
    start_ms: int,
    sync: bool = True,
    size: int = 100,
    flags_in: str = "trun",
    tfdt_version: int = 1,
    composition_ms: int | None = None,
    large_mdat: bool = False,
) -> bytes:
    """一个 ``moof`` + ``mdat``：这条轨在 ``start_ms`` 毫秒起一个样本。

    - ``sync``：这个样本是不是同步帧；``flags_in`` 决定标志写在哪（``trun`` 的 first_sample_flags，
      或 ``tfhd`` 的 default_sample_flags）；
    - ``tfdt_version``：0 = 32 位时间，1 = 64 位；
    - ``composition_ms``：样本的合成时间偏移（带 B 帧的流里第一帧的 pts 比 dts 晚）；
    - ``large_mdat``：``mdat`` 用 64 位长度头（size 字段写 1，后跟 8 字节长度）。
    """
    flags = _SYNC if sync else _NON_SYNC
    if flags_in == "tfhd":
        # default-base-is-moof | default-sample-flags-present
        tfhd = full_box(b"tfhd", 0, 0x20000 | 0x20, struct.pack(">II", track_id, flags))
        trun_flags, trun_body = 0, struct.pack(">I", 1)
    else:
        tfhd = full_box(b"tfhd", 0, 0x20000, struct.pack(">I", track_id))
        trun_flags, trun_body = 0x04, struct.pack(">II", 1, flags)  # first-sample-flags-present
    tfdt = full_box(
        b"tfdt", tfdt_version, 0, struct.pack(">Q" if tfdt_version == 1 else ">I", start_ms)
    )
    version = 0
    if composition_ms is not None:
        # 单个样本：duration、size、composition_time_offset（有符号要 version 1）
        trun_flags |= 0x100 | 0x200 | 0x800
        trun_body += struct.pack(">II", 40, size) + struct.pack(">i", composition_ms)
        version = 1 if composition_ms < 0 else 0
    trun = full_box(b"trun", version, trun_flags, trun_body)
    moof = box(b"moof", box(b"traf", tfhd + tfdt + trun))
    payload = bytes([track_id]) * size
    if large_mdat:
        mdat = struct.pack(">I", 1) + b"mdat" + struct.pack(">Q", 16 + len(payload)) + payload
    else:
        mdat = box(b"mdat", payload)
    return moof + mdat


def video_stream(
    *, seconds: float, fragment_ms: int = 500, gop_ms: int = 2000, offset_ms: int = 0
) -> bytes:
    """一整条视频分片流：每 ``fragment_ms`` 一个片段，每 ``gop_ms`` 一个同步帧（首片段必是）。"""
    out = init_segment(with_audio=False)
    for at in range(0, int(seconds * 1000), fragment_ms):
        out += fragment(start_ms=offset_ms + at, sync=at % gop_ms == 0)
    return out

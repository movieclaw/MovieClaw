"""造一张真的 BDMV 目录（真 m2ts + 真 PGS 轨 + MPLS + CLPI）——测试专用。

ffmpeg 没有 PGS 编码器，但能把 ``.sup`` 流拷贝进 m2ts（``pgs_sup`` 拼字节）。每段剪辑的 PTS 从
``pts_base`` 起，主播放列表可以只用它的一截：真盘的 PTS 基本不从 0 开始，多剪辑各有各的基准，
时间轴对不对只有这样才测得出来。

端到端用例的画面是纯黑的，字幕是白色矩形（``make_sup`` 的 x/y/w/h），截图看亮度就知道它在不在。
"""

from __future__ import annotations

import struct
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

try:
    from pgs_sup import make_sup
except ImportError:  # 从 tests/e2e 按包路径导入时
    from tests.playback.pgs_sup import make_sup

MPLS_HZ = 45_000
_PGS_PID_BASE = 0x1200


@dataclass(frozen=True)
class Clip:
    """主播放列表里的一段。时间都是这段剪辑自己的秒数（0 = 片头），写盘时才加上 ``pts_base``。"""

    clip_id: str
    seconds: int
    pts_base: float
    #: 每条 PGS 轨的字幕，元素是 ``make_sup`` 的参数
    tracks: list[list[dict]] = field(default_factory=list)
    in_s: float = 0.0
    out_s: float | None = None
    #: 真盘有只带视频的小段（片尾的几帧）
    has_audio: bool = True

    @property
    def in_time(self) -> int:
        return round((self.pts_base + self.in_s) * MPLS_HZ)

    @property
    def out_time(self) -> int:
        end = self.seconds if self.out_s is None else self.out_s
        return round((self.pts_base + end) * MPLS_HZ)


def sup_presentations(data: bytes) -> list[float]:
    """``.sup`` 里每个合成段（PCS）的显示时间（秒）：既有显示集也有清屏集。"""
    times: list[float] = []
    pos = 0
    while pos + 13 <= len(data):
        if data[pos : pos + 2] != b"PG":
            # i18n-ignore: test fixture diagnostic
            raise ValueError(f"第 {pos} 字节不是 PGS 段头")
        pts, _dts, seg_type, size = struct.unpack(">IIBH", data[pos + 2 : pos + 13])
        if seg_type == 0x16:
            times.append(round(pts / 90_000, 3))
        pos += 13 + size
    return times


def mpls_bytes(clips: list[Clip]) -> bytes:
    body = bytearray(b"\0\0" + len(clips).to_bytes(2, "big") + b"\0\0")
    for clip in clips:
        core = (
            clip.clip_id.encode("ascii")
            + b"M2TS\0\0\0"
            + clip.in_time.to_bytes(4, "big")
            + clip.out_time.to_bytes(4, "big")
        )
        body += len(core).to_bytes(2, "big") + core
    header = b"MPLS0100" + (20).to_bytes(4, "big") + b"\0" * 8
    return header + len(body).to_bytes(4, "big") + bytes(body)


def _ep_map(keyframes: list[int]) -> bytes:
    """主视频流（0x1011）的 EP_map：关键帧 PTS（45 kHz，升序）。字节位置这里用不到，写 0。"""
    coarse: list[tuple[int, int]] = []
    fine: list[int] = []
    for pts in keyframes:
        if not coarse or coarse[-1][1] != pts >> 18:
            coarse.append((len(fine), pts >> 18))
        fine.append((pts >> 8) & 0x7FF)
    table = (4 + 8 * len(coarse)).to_bytes(4, "big")
    table += b"".join(((ref << 46) | (high << 32)).to_bytes(8, "big") for ref, high in coarse)
    table += b"".join((low << 17).to_bytes(4, "big") for low in fine)
    entry = (0x1011 << 80) | (1 << 66) | (len(coarse) << 50) | (len(fine) << 32) | 14
    return b"\0\x01" + entry.to_bytes(12, "big") + table


def clpi_bytes(subtitle_languages: list[str], keyframes: list[int]) -> bytes:
    """ProgramInfo（各条 PGS 的语言）+ CPI（关键帧表）。"""
    streams = bytearray()
    for index, language in enumerate(subtitle_languages):
        streams += (_PGS_PID_BASE + index).to_bytes(2, "big")
        streams += bytes([5, 0x90]) + language.encode("ascii") + b"\0"
    program = bytearray(b"\0\1" + (0).to_bytes(4, "big") + (0x100).to_bytes(2, "big"))
    program += bytes([len(subtitle_languages), 0]) + streams
    program_info = len(program).to_bytes(4, "big") + bytes(program)

    cpi_body = b"\0\x01" + _ep_map(keyframes)
    cpi = len(cpi_body).to_bytes(4, "big") + cpi_body

    program_offset = 32
    header = bytearray(program_offset)
    header[:8] = b"HDMV0200"
    header[12:16] = program_offset.to_bytes(4, "big")
    header[16:20] = (program_offset + len(program_info)).to_bytes(4, "big")
    return bytes(header) + program_info + cpi


def _write_m2ts(dest: Path, clip: Clip) -> None:
    inputs = ["-f", "lavfi", "-i", f"color=c=black:size=640x360:rate=24:duration={clip.seconds}"]
    maps = ["-map", "0:v"]
    if clip.has_audio:
        inputs += [
            "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={clip.seconds}",
        ]  # fmt: skip
        maps += ["-map", "1:a"]
    for index, subtitles in enumerate(clip.tracks):
        sup = dest.with_name(f".{dest.stem}.t{index}.sup")
        sup.write_bytes(b"".join(make_sup(**entry) for entry in subtitles))
        inputs += ["-f", "sup", "-i", str(sup)]
        maps += ["-map", f"{len(maps) // 2}:s"]
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-v", "error", "-y",
            *inputs,
            *maps,
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-g", "24", "-keyint_min", "24", "-sc_threshold", "0",
            # 真盘的音轨是 AC-3 这一类；AAC 从 TS 经 concat 封不进 fMP4（缺 ADTS 转换），也不真实
            "-c:a", "ac3", "-ac", "2", "-c:s", "copy",
            # -copyts：.sup 的时间戳原样进流。不加的话 ffmpeg 把每路输入都归零，字幕整体提前
            "-copyts", "-output_ts_offset", str(clip.pts_base),
            "-muxdelay", "0", "-muxpreload", "0",
            "-mpegts_m2ts_mode", "1",
            str(dest),
        ],
        check=True,
        timeout=120,
    )  # fmt: skip
    for sup in dest.parent.glob(f".{dest.stem}.t*.sup"):
        sup.unlink()


def make_bdmv(
    disc: Path,
    clips: list[Clip],
    *,
    languages: list[str] | None = None,
) -> Path:
    """写出 ``disc/BDMV/{STREAM,CLIPINF,PLAYLIST}``。``languages`` 是各条 PGS 轨的语言。"""
    stream_dir = disc / "BDMV" / "STREAM"
    clip_dir = disc / "BDMV" / "CLIPINF"
    playlist_dir = disc / "BDMV" / "PLAYLIST"
    for directory in (stream_dir, clip_dir, playlist_dir):
        directory.mkdir(parents=True, exist_ok=True)
    for clip in clips:
        _write_m2ts(stream_dir / f"{clip.clip_id}.m2ts", clip)
        keyframes = [round((clip.pts_base + s) * MPLS_HZ) for s in range(clip.seconds)]
        (clip_dir / f"{clip.clip_id}.clpi").write_bytes(
            clpi_bytes(languages or [], keyframes)
        )
    (playlist_dir / "00001.mpls").write_bytes(mpls_bytes(clips))
    return disc

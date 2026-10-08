"""DVD 的 IFO 解析：选主标题、读正片节目链（刷片挑点与服务端转码共用）。

选法与 App 引擎一致（``DiscReader.dvdTitleSet``）：VIDEO_TS.IFO 的标题表（TT_SRPT）列出的标题集
才算标题（读不出、或滤完为空就全算），其中正片内容 VOB（VTS_NN_1～9）总大小最大的是主标题；
主标题里最长的那条节目链（PGC）是正片。两边选的是同一个标题，挑出来的时间、转出来的画面才落在
引擎播放的那条时间轴上。全部只读几 KB 的 IFO，不碰视频本体。
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

SECTOR = 2048


@dataclass(frozen=True)
class Cell:
    """节目链里的一个单元：在标题集正片 VOB 里的扇区区间、所属 VOB、播放时长。

    扇区区间含首尾，扇区号相对 VTS_NN_1.VOB 的起点。同一个 VOB（``vob_id``）里时间戳连续，
    换 VOB 时时间戳可能从头再来（一张盘放两集的电视剧 DVD 常见）。
    """

    first: int
    last: int
    vob_id: int
    seconds: float


@dataclass(frozen=True)
class ProgramChain:
    """一条节目链：播放时长（整秒，与 App 引擎一致）与各单元。"""

    seconds: float
    cells: tuple[Cell, ...]


def main_title_set(vob_sizes: dict[str, int], read_ifo: Callable[[str], bytes]) -> int | None:
    """主标题所在的标题集号；没有正片 VOB 时 None。``read_ifo`` 读不出时按全部标题集算。"""
    totals: dict[int, int] = {}
    for name, size in vob_sizes.items():
        parts = name.upper().removeprefix("VTS_").removesuffix(".VOB").split("_")
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit() and int(parts[1]) >= 1:
            totals[int(parts[0])] = totals.get(int(parts[0]), 0) + size
    try:
        listed = title_set_numbers(read_ifo("VIDEO_TS.IFO"))
    except (KeyError, OSError, ValueError):
        listed = set()
    totals = {vts: size for vts, size in totals.items() if vts in listed} or totals
    if not totals:
        return None
    return min(totals, key=lambda vts: (-totals[vts], vts))


def title_set_numbers(data: bytes) -> set[int]:
    """VIDEO_TS.IFO 标题表（TT_SRPT，扇区号在 0xC4）里各标题所在的标题集号。

    表头 2 字节是标题个数，其后每条 12 字节，第 6 字节是标题集号（VTSN）。
    """
    if len(data) < 0xC8 or data[:12] != b"DVDVIDEO-VMG":
        raise ValueError("不是 VIDEO_TS.IFO")
    table = int.from_bytes(data[0xC4:0xC8], "big") * SECTOR
    if table + 8 > len(data):
        raise ValueError("标题表越界")
    count = int.from_bytes(data[table : table + 2], "big")
    return {
        data[table + 8 + i * 12 + 6]
        for i in range(min(count, 99))
        if table + 8 + i * 12 + 12 <= len(data)
    }


def longest_program_chain(data: bytes) -> ProgramChain:
    """标题集 IFO → 其中最长一条节目链。

    IFO 头 0xCC 是节目链信息表（VTS_PGCITI）的扇区号；表头 2 字节是节目链个数，其后每条
    8 字节（类别 4 字节 + 相对表头的偏移 4 字节）。节目链里：0x03 是单元个数，0x04 起 4 字节
    是 BCD 编码的播放时长（时、分、秒、帧；帧字节最高两位是帧率标志），0xE8 起 2 字节是
    单元播放信息表（C_PBIT）、0xEA 起 2 字节是单元位置表（C_POSIT）相对节目链的偏移。播放
    信息表每个单元 24 字节：4～7 是单元时长（同上的 BCD）、8～11 是首个 VOBU 的起始扇区、
    20～23 是末个 VOBU 的结束扇区；位置表每个单元 4 字节，0～1 是 VOB 号。
    """
    if len(data) < 0xD0 or data[:12] != b"DVDVIDEO-VTS":
        raise ValueError("不是标题集 IFO")
    table = int.from_bytes(data[0xCC:0xD0], "big") * SECTOR
    if table + 8 > len(data):
        raise ValueError("节目链信息表越界")
    count = int.from_bytes(data[table : table + 2], "big")
    best = ProgramChain(0.0, ())
    for i in range(min(count, 999)):
        entry = table + 8 + i * 8
        if entry + 8 > len(data):
            break
        pgc = table + int.from_bytes(data[entry + 4 : entry + 8], "big")
        if pgc + 0xEA > len(data):
            continue
        total = float(int(_playback_time(data[pgc + 4 : pgc + 8])))
        if total <= best.seconds:
            continue
        cells: list[Cell] = []
        cell_table = pgc + int.from_bytes(data[pgc + 0xE8 : pgc + 0xEA], "big")
        positions = pgc + int.from_bytes(data[pgc + 0xEA : pgc + 0xEC], "big")
        for c in range(data[pgc + 3]):
            cell = cell_table + c * 24
            if cell + 24 > len(data):
                break
            first = int.from_bytes(data[cell + 8 : cell + 12], "big")
            last = int.from_bytes(data[cell + 20 : cell + 24], "big")
            position = positions + c * 4
            vob_id = (
                int.from_bytes(data[position : position + 2], "big")
                if position + 4 <= len(data)
                else 0
            )
            if last >= first:
                cells.append(Cell(first, last, vob_id, _playback_time(data[cell + 4 : cell + 8])))
        best = ProgramChain(total, tuple(cells))
    return best


def _playback_time(raw: bytes) -> float:
    """BCD 播放时长（时、分、秒、帧）→ 秒。帧字节高两位是帧率：01=25，11=29.97。"""
    hours, minutes, seconds = (_bcd(b) for b in raw[:3])
    fps = {1: 25.0, 3: 30000 / 1001}.get(raw[3] >> 6)
    frames = _bcd(raw[3] & 0x3F) / fps if fps else 0.0
    return hours * 3600 + minutes * 60 + seconds + frames


def _bcd(value: int) -> int:
    return (value >> 4) * 10 + (value & 0x0F)

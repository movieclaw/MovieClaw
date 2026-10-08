"""只读 UDF 读取器：从蓝光光盘镜像（ISO）里列目录、读小文件。

服务端原来读不了镜像的盘内结构（docs/design/disc-direct-play.md §0），蓝光 ISO 连片长都
没有。刷片 / 大图预告要在镜像里挑一段放，需要主播放列表（MPLS）与关键帧入口表（CLPI），
这两样都是盘里的小文件，只要能按路径找到并读出来。

照搬 App 引擎里已在真机上跑过的实现：
``yipengfei329/AetherEngine/Sources/AetherEngine/Disc/UDFReader.swift``。
UDF 2.50，解析元数据分区与碎片化文件的分配描述符；扇区 2048 字节；只校验描述符标签号
（不校验 CRC）。所有长度字段都来自不可信的镜像，读之前一律夹紧。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import BinaryIO

SECTOR = 2048
#: 卷描述符序列最多读多少个扇区（标准是 16 个；长度字段不可信，夹紧防止成百万次读盘）
_MAX_VDS_SECTORS = 256
#: 一个目录最多读多少字节（诱饵盘 PLAYLIST 目录上千个条目也只有几百 KB）
_MAX_DIR_BYTES = 8 << 20
#: 分配扩展描述符链最深跟几层（防构造的自引用链）
_MAX_AED_DEPTH = 16

_TAG_AVDP = 2
_TAG_PD = 5
_TAG_LVD = 6
_TAG_TD = 8
_TAG_FSD = 256
_TAG_FID = 257
_TAG_AED = 258
_TAG_FE = 261
_TAG_EFE = 266


class UDFError(ValueError):
    """不是 UDF 镜像，或结构损坏、越界。"""


@dataclass(frozen=True)
class UDFEntry:
    """目录里的一项。"""

    name: str
    is_dir: bool
    icb_block: int
    icb_part_ref: int


@dataclass(frozen=True)
class _Extent:
    block: int
    length: int
    long_part_ref: int | None


@dataclass(frozen=True)
class _PartMap:
    is_metadata: bool
    physical_part_number: int
    metadata_file_block: int


@dataclass(frozen=True)
class _FileEntry:
    part_ref: int
    size: int
    extents: tuple[_Extent, ...]
    #: 分配描述符类型 3：数据直接内嵌在文件项里（小文件）
    embedded: bytes | None = None


def _u16(b: bytes, i: int) -> int:
    return int.from_bytes(b[i : i + 2], "little")


def _u32(b: bytes, i: int) -> int:
    return int.from_bytes(b[i : i + 4], "little")


def _tag(b: bytes) -> int:
    return _u16(b, 0) if len(b) >= 2 else -1


class UDFReader:
    """打开后按路径列目录（``list``）、读文件（``read``）、取大小（``size``）。"""

    def __init__(self, fh: BinaryIO) -> None:
        self._fh = fh
        self._phys_start: dict[int, int] = {}
        self._maps: list[_PartMap] = []
        self._meta_extents: list[tuple[int, int]] = []  # (起始物理扇区, 扇区数)
        self._root: tuple[int, int] = (0, 0)
        self._parse_volume_structure()

    # --- 对外 -----------------------------------------------------------------

    def list(self, path: list[str]) -> list[UDFEntry]:
        """列 ``path``（逐级目录名，区分大小写按盘上原样；找不到时不区分大小写再找一次）。"""
        block, part_ref = self._root
        for name in path:
            entries = self._read_directory(block, part_ref)
            match = next((e for e in entries if e.is_dir and e.name == name), None) or next(
                (e for e in entries if e.is_dir and e.name.upper() == name.upper()), None
            )
            if match is None:
                raise UDFError(f"目录不存在：{name}")
            block, part_ref = match.icb_block, match.icb_part_ref
        return self._read_directory(block, part_ref)

    def size(self, entry: UDFEntry) -> int:
        return self._read_file_entry(entry.icb_block, entry.icb_part_ref).size

    def byte_ranges(self, entry: UDFEntry) -> list[tuple[int, int]]:
        """文件内容在镜像里的位置：``[(起始字节, 长度), …]``，首尾相接的分配区合并成一段。

        大文件按 UDF 规定切成不超过 1 GB 的分配区，母盘工具基本都连续写，合并后通常只剩一段——
        服务端据此把镜像里的视频文件当成镜像上的一个字节区间交给 ffmpeg（``subfile`` 协议）。
        内嵌在文件项里的小文件没有独立位置，返回空表。
        """
        fe = self._read_file_entry(entry.icb_block, entry.icb_part_ref)
        ranges: list[tuple[int, int]] = []
        remaining = fe.size
        for ext in fe.extents:
            if remaining <= 0:
                break
            ref = ext.long_part_ref if ext.long_part_ref is not None else fe.part_ref
            start = self._resolve(ext.block, ref) * SECTOR
            length = min(ext.length, remaining)
            remaining -= length
            if ranges and ranges[-1][0] + ranges[-1][1] == start:
                ranges[-1] = (ranges[-1][0], ranges[-1][1] + length)
            else:
                ranges.append((start, length))
        return ranges

    def read(self, entry: UDFEntry, limit: int) -> bytes:
        """读整个文件（最多 ``limit`` 字节；超过即视为异常，抛 ``UDFError``）。"""
        fe = self._read_file_entry(entry.icb_block, entry.icb_part_ref)
        if fe.size > limit:
            raise UDFError(f"文件过大：{entry.name}（{fe.size} 字节）")
        if fe.embedded is not None:
            return fe.embedded[: fe.size]
        out = bytearray()
        for ext in fe.extents:
            if len(out) >= fe.size:
                break
            ref = ext.long_part_ref if ext.long_part_ref is not None else fe.part_ref
            sector = self._resolve(ext.block, ref)
            want = min(ext.length, fe.size - len(out))
            out += self._read_at(sector * SECTOR, want)
        if len(out) < fe.size:
            raise UDFError(f"文件数据不完整：{entry.name}")
        return bytes(out)

    # --- 读盘 -----------------------------------------------------------------

    def _read_at(self, offset: int, length: int) -> bytes:
        self._fh.seek(offset)
        data = self._fh.read(length)
        if len(data) != length:
            raise UDFError(f"读到镜像末尾：偏移 {offset}")
        return data

    def _sector(self, sector: int) -> bytes:
        return self._read_at(sector * SECTOR, SECTOR)

    # --- 卷结构 ---------------------------------------------------------------

    def _parse_volume_structure(self) -> None:
        avdp = self._sector(256)
        if _tag(avdp) != _TAG_AVDP:
            raise UDFError("不是 UDF 镜像（第 256 扇区没有锚点描述符）")
        vds_len, vds_loc = _u32(avdp, 16), _u32(avdp, 20)
        lvd: bytes | None = None
        for i in range(min(max(1, vds_len // SECTOR), _MAX_VDS_SECTORS)):
            d = self._sector(vds_loc + i)
            tag = _tag(d)
            if tag == _TAG_PD:
                self._phys_start[_u16(d, 22)] = _u32(d, 188)
            elif tag == _TAG_LVD:
                lvd = d
            elif tag == _TAG_TD:
                break
        if lvd is None:
            raise UDFError("没有逻辑卷描述符")
        fsd_block, fsd_ref = _u32(lvd, 252), _u16(lvd, 256)
        off = 440
        for _ in range(min(_u32(lvd, 268), 64)):
            if off + 2 > len(lvd):
                break
            kind, length = lvd[off], lvd[off + 1]
            if length == 0 or off + length > len(lvd):
                break
            if kind == 1 and length >= 6:
                self._maps.append(_PartMap(False, _u16(lvd, off + 4), 0))
            elif kind == 2 and length >= 44:
                self._maps.append(_PartMap(True, _u16(lvd, off + 38), _u32(lvd, off + 40)))
            else:
                self._maps.append(_PartMap(False, 0, 0))
            off += length
        # 元数据分区：它的物理扇区由「元数据文件」的分配描述符给出（相对物理分区起点）
        for pm in self._maps:
            if not pm.is_metadata or pm.physical_part_number not in self._phys_start:
                continue
            start = self._phys_start[pm.physical_part_number]
            meta = self._parse_file_entry(start + pm.metadata_file_block, None)
            self._meta_extents = [(start + e.block, e.length // SECTOR) for e in meta.extents]
        fsd = self._sector(self._resolve(fsd_block, fsd_ref))
        if _tag(fsd) != _TAG_FSD:
            raise UDFError("没有文件集描述符")
        self._root = (_u32(fsd, 404), _u16(fsd, 408))

    def _resolve(self, block: int, part_ref: int) -> int:
        """分区内逻辑块号 → 镜像里的物理扇区号。"""
        if part_ref >= len(self._maps):
            raise UDFError(f"分区引用越界：{part_ref}")
        pm = self._maps[part_ref]
        if not pm.is_metadata:
            start = self._phys_start.get(pm.physical_part_number)
            if start is None:
                raise UDFError("找不到物理分区")
            return start + block
        remaining = block
        for start, blocks in self._meta_extents:
            if remaining < blocks:
                return start + remaining
            remaining -= blocks
        raise UDFError(f"元数据块越界：{block}")

    # --- 文件项 ---------------------------------------------------------------

    def _read_file_entry(self, block: int, part_ref: int) -> _FileEntry:
        fe = self._parse_file_entry(self._resolve(block, part_ref), part_ref)
        return _FileEntry(part_ref, fe.size, fe.extents, fe.embedded)

    def _parse_file_entry(self, sector: int, recording_part_ref: int | None) -> _FileEntry:
        d = self._sector(sector)
        tag = _tag(d)
        if tag not in (_TAG_FE, _TAG_EFE):
            raise UDFError(f"不是文件项：扇区 {sector}，标签 {tag}")
        ad_type = _u16(d, 34) & 0x07
        size = int.from_bytes(d[56:64], "little")
        ea_off, ad_off, base = (208, 212, 216) if tag == _TAG_EFE else (168, 172, 176)
        l_ea, l_ad = _u32(d, ea_off), _u32(d, ad_off)
        start = base + l_ea
        if ad_type == 3:
            return _FileEntry(0, size, (), bytes(d[start : min(start + l_ad, len(d))]))
        extents: list[_Extent] = []
        self._parse_alloc(d, start, l_ad, ad_type, recording_part_ref, extents, 0)
        return _FileEntry(0, size, tuple(extents))

    def _parse_alloc(
        self,
        buf: bytes,
        start: int,
        length: int,
        ad_type: int,
        recording_part_ref: int | None,
        out: list[_Extent],
        depth: int,
    ) -> None:
        stride = 16 if ad_type == 1 else 8
        p, end = start, min(start + length, len(buf))
        while p + stride <= end:
            field = _u32(buf, p)
            ext_type, ext_len = (field >> 30) & 0x3, field & 0x3FFFFFFF
            block = _u32(buf, p + 4)
            long_ref = _u16(buf, p + 8) if ad_type == 1 else None
            if ext_type == 3:
                # 续接：block 指向下一段分配描述符（分配扩展描述符），它总是本段最后一个
                ref = long_ref if long_ref is not None else recording_part_ref
                if depth >= _MAX_AED_DEPTH or ext_len == 0 or ref is None:
                    return
                aed = self._sector(self._resolve(block, ref))
                if _tag(aed) == _TAG_AED:
                    self._parse_alloc(
                        aed, 24, _u32(aed, 20), ad_type, recording_part_ref, out, depth + 1
                    )
                return
            if ext_len == 0:
                return
            out.append(_Extent(block, ext_len, long_ref))
            p += stride

    # --- 目录 -----------------------------------------------------------------

    def _read_directory(self, block: int, part_ref: int) -> list[UDFEntry]:
        fe = self._read_file_entry(block, part_ref)
        if fe.embedded is not None:
            data = fe.embedded[: fe.size]
        else:
            chunks = bytearray()
            for ext in fe.extents:
                if len(chunks) + ext.length > _MAX_DIR_BYTES:
                    raise UDFError("目录过大")
                ref = ext.long_part_ref if ext.long_part_ref is not None else fe.part_ref
                chunks += self._read_at(self._resolve(ext.block, ref) * SECTOR, ext.length)
            data = bytes(chunks)
        entries: list[UDFEntry] = []
        p = 0
        while p + 38 <= len(data):
            if _tag(data[p : p + 16]) != _TAG_FID:
                break
            chars, lfi = data[p + 18], data[p + 19]
            icb_block, icb_ref = _u32(data, p + 24), _u16(data, p + 28)
            liu = _u16(data, p + 36)
            name_off = p + 38 + liu
            if lfi > 0 and not chars & 0x08 and name_off + lfi <= len(data):
                raw = data[name_off + 1 : name_off + lfi]
                name = (
                    raw.decode("utf-16-be", "replace")
                    if data[name_off] == 16
                    else raw.decode("latin-1")
                )
                entries.append(UDFEntry(name, bool(chars & 0x02), icb_block, icb_ref))
            fid_len = 38 + liu + lfi
            p += fid_len + (-fid_len % 4)
        return entries

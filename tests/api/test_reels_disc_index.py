"""刷片 / 大图预告的全格式片段索引：UDF 镜像读取、蓝光与 DVD 的盘上索引、没有关键帧表的挑点。"""

from __future__ import annotations

import io
from pathlib import Path

import pytest
from tests.api.test_bluray_clpi import _mpls, _mpls_with_marks

from movieclaw_api.services.library.bluray import parse_clpi_entry_points, parse_clpi_keyframes
from movieclaw_api.services.library.udf import UDFError, UDFReader
from movieclaw_api.services.reels import disc_index, picker, segments
from movieclaw_playback.container_index import ContainerIndex

S = 2048
CLOCK = 45_000


# ---------------------------------------------------------------------------
# 构造数据：带源包号的 CLPI、DVD 标题集 IFO、最小 UDF 镜像
# ---------------------------------------------------------------------------


def _clpi(points: list[tuple[int, int]]) -> bytes:
    """只含主视频（PID 0x1011）EP_map 的 CLPI；points 为 (PTS 45 kHz, 源包号)。

    粗表每个 PTS 高位桶一条（带该桶第一个入口点的 SPN），细表给 PTS 与 SPN 的低位。
    PTS 低 8 位会丢、SPN 必须与粗表同一个 2^17 段——测试数据都按这两条构造。
    """
    coarse: list[tuple[int, int, int]] = []
    fine: list[tuple[int, int]] = []
    for pts, spn in sorted(points):
        if not coarse or coarse[-1][1] != pts >> 18 or coarse[-1][2] >> 17 != spn >> 17:
            coarse.append((len(fine), pts >> 18, spn))
        fine.append(((pts >> 8) & 0x7FF, spn & 0x1FFFF))
    table = bytearray((4 + 8 * len(coarse)).to_bytes(4, "big"))
    for ref, pts_coarse, spn in coarse:
        table += ((ref << 46) | (pts_coarse << 32) | spn).to_bytes(8, "big")
    for pts_fine, spn_fine in fine:
        table += ((pts_fine << 17) | spn_fine).to_bytes(4, "big")
    raw = (0x1011 << 80) | (1 << 66) | (len(coarse) << 50) | (len(fine) << 32) | 14
    ep_map = b"\0\x01" + raw.to_bytes(12, "big") + bytes(table)
    cpi_body = b"\0\x01" + ep_map
    cpi = len(cpi_body).to_bytes(4, "big") + cpi_body
    header = b"HDMV0200" + b"\0" * 8 + (28).to_bytes(4, "big") + b"\0" * 8
    return header + cpi


def _bcd(n: int) -> int:
    return (n // 10) << 4 | n % 10


def _vmg_ifo(title_sets: list[int]) -> bytes:
    """VIDEO_TS.IFO：0xC4 指向第 1 扇区的标题表，每个标题只填所在标题集号。"""
    data = bytearray(3 * S)
    data[:12] = b"DVDVIDEO-VMG"
    data[0xC4:0xC8] = (1).to_bytes(4, "big")
    data[S : S + 2] = len(title_sets).to_bytes(2, "big")
    for i, vts in enumerate(title_sets):
        data[S + 8 + i * 12 + 6] = vts
    return bytes(data)


def _vts_ifo(pgc_seconds: list[int]) -> bytes:
    """标题集 IFO：0xCC 指向第 1 扇区的节目链信息表，每条节目链只填播放时长。"""
    data = bytearray(4 * S)
    data[:12] = b"DVDVIDEO-VTS"
    data[0xCC:0xD0] = (1).to_bytes(4, "big")
    table = S
    data[table : table + 2] = len(pgc_seconds).to_bytes(2, "big")
    for i, seconds in enumerate(pgc_seconds):
        pgc_rel = 8 + 8 * len(pgc_seconds) + i * 16
        entry = table + 8 + i * 8
        data[entry + 4 : entry + 8] = pgc_rel.to_bytes(4, "big")
        h, m, s = seconds // 3600, seconds // 60 % 60, seconds % 60
        data[table + pgc_rel + 4 : table + pgc_rel + 8] = bytes([_bcd(h), _bcd(m), _bcd(s), 0xC0])
    return bytes(data)


class _UdfBuilder:
    """最小 UDF 镜像：锚点 → 卷描述符序列（分区 + 逻辑卷）→ 文件集 → 目录树。

    ``metadata=True`` 时按蓝光盘的布局：文件项与目录都在元数据分区（分区引用 1，经元数据
    文件的分配描述符映射到物理扇区），文件数据用 long_ad 指向物理分区（分区引用 0）。
    """

    PART_START = 300

    def __init__(self, *, metadata: bool) -> None:
        self.metadata = metadata
        self.sectors: dict[int, bytes] = {}
        self.next_phys = 0  # 物理分区里下一个空闲块
        self.meta_blocks: list[int] = []  # 元数据虚拟块 → 物理分区块
        self.meta_ref = 1 if metadata else 0

    # 分配 ------------------------------------------------------------------
    def _phys_block(self, count: int = 1) -> int:
        block = self.next_phys
        self.next_phys += count
        return block

    def _meta_block(self) -> int:
        """元数据分区里的一块（非元数据模式就是物理块）。"""
        phys = self._phys_block()
        if not self.metadata:
            return phys
        self.meta_blocks.append(phys)
        return len(self.meta_blocks) - 1

    def _write_meta(self, block: int, data: bytes) -> None:
        phys = self.meta_blocks[block] if self.metadata else block
        self._write_phys(phys, data)

    def _write_phys(self, block: int, data: bytes) -> None:
        for i in range(0, max(len(data), 1), S):
            self.sectors[self.PART_START + block + i // S] = data[i : i + S].ljust(S, b"\0")

    @staticmethod
    def _tag(tag_id: int) -> bytearray:
        buf = bytearray(S)
        buf[0:2] = tag_id.to_bytes(2, "little")
        return buf

    def _fe(self, size: int, ads: bytes, ad_type: int) -> bytes:
        fe = self._tag(261)
        fe[34:36] = ad_type.to_bytes(2, "little")
        fe[56:64] = size.to_bytes(8, "little")
        fe[172:176] = len(ads).to_bytes(4, "little")
        fe[176 : 176 + len(ads)] = ads
        return bytes(fe)

    # 文件与目录 ------------------------------------------------------------
    def file(self, data: bytes, *, size: int | None = None) -> int:
        """写一个文件，返回其文件项所在的（元数据）块。``size`` 可大于数据（只登记大小）。"""
        blocks = max(1, -(-len(data) // S))
        phys = self._phys_block(blocks)
        self._write_phys(phys, data)
        if self.metadata:
            ad = len(data).to_bytes(4, "little") + phys.to_bytes(4, "little")
            ad += (0).to_bytes(2, "little") + b"\0" * 6  # long_ad：物理分区
            fe = self._fe(size if size is not None else len(data), ad, 1)
        else:
            ad = len(data).to_bytes(4, "little") + phys.to_bytes(4, "little")
            fe = self._fe(size if size is not None else len(data), ad, 0)
        fe_block = self._meta_block()
        self._write_meta(fe_block, fe)
        return fe_block

    def directory(self, children: dict[str, tuple[int, bool]]) -> int:
        """children: 名字 → (文件项块, 是否目录)。返回目录文件项所在块。"""
        fids = bytearray(self._fid("", 0, parent=True, is_dir=True))
        for name, (block, is_dir) in children.items():
            fids += self._fid(name, block, parent=False, is_dir=is_dir)
        data_block = self._meta_block()
        self._write_meta(data_block, bytes(fids))
        ad = len(fids).to_bytes(4, "little") + data_block.to_bytes(4, "little")
        fe_block = self._meta_block()
        self._write_meta(fe_block, self._fe(len(fids), ad, 0))  # short_ad：本分区
        return fe_block

    def _fid(self, name: str, block: int, *, parent: bool, is_dir: bool) -> bytes:
        encoded = (b"\x08" + name.encode("latin-1")) if name else b""
        fid = bytearray(38)
        fid[0:2] = (257).to_bytes(2, "little")
        fid[18] = (0x08 if parent else 0) | (0x02 if is_dir else 0)
        fid[19] = len(encoded)
        fid[24:28] = block.to_bytes(4, "little")
        fid[28:30] = self.meta_ref.to_bytes(2, "little")
        fid += encoded
        fid += b"\0" * (-len(fid) % 4)
        return bytes(fid)

    def tree(self, spec: dict) -> int:
        """嵌套 dict：值为 bytes（文件）、(bytes, size)（登记大小的文件）或 dict（目录）。"""
        children: dict[str, tuple[int, bool]] = {}
        for name, value in spec.items():
            if isinstance(value, dict):
                children[name] = (self.tree(value), True)
            elif isinstance(value, tuple):
                children[name] = (self.file(value[0], size=value[1]), False)
            else:
                children[name] = (self.file(value), False)
        return self.directory(children)

    # 卷结构 ----------------------------------------------------------------
    def build(self, spec: dict) -> bytes:
        root = self.tree(spec)
        fsd = self._tag(256)
        fsd[404:408] = root.to_bytes(4, "little")
        fsd[408:410] = self.meta_ref.to_bytes(2, "little")
        fsd_block = self._meta_block()
        self._write_meta(fsd_block, bytes(fsd))

        lvd = self._tag(6)
        lvd[252:256] = fsd_block.to_bytes(4, "little")
        lvd[256:258] = self.meta_ref.to_bytes(2, "little")
        maps = bytearray([1, 6, 0, 0, 0, 0])  # 类型 1：物理分区 0
        if self.metadata:
            meta_file = self._phys_block()
            # 元数据文件：一个 short_ad 覆盖所有元数据块（测试里它们不连续，逐块列出）
            ads = b"".join(
                S.to_bytes(4, "little") + phys.to_bytes(4, "little") for phys in self.meta_blocks
            )
            self._write_phys(meta_file, self._fe(len(self.meta_blocks) * S, ads, 0))
            type2 = bytearray(64)
            type2[0], type2[1] = 2, 64
            type2[38:40] = (0).to_bytes(2, "little")
            type2[40:44] = meta_file.to_bytes(4, "little")
            maps += type2
        lvd[268:272] = (2 if self.metadata else 1).to_bytes(4, "little")
        lvd[440 : 440 + len(maps)] = maps
        pd = self._tag(5)
        pd[22:24] = (0).to_bytes(2, "little")
        pd[188:192] = self.PART_START.to_bytes(4, "little")
        self.sectors[257] = bytes(pd)
        self.sectors[258] = bytes(lvd)
        self.sectors[259] = bytes(self._tag(8))
        avdp = self._tag(2)
        avdp[16:20] = (3 * S).to_bytes(4, "little")
        avdp[20:24] = (257).to_bytes(4, "little")
        self.sectors[256] = bytes(avdp)
        last = max(self.sectors) + 1
        return b"".join(self.sectors.get(i, b"\0" * S) for i in range(last))


# ---------------------------------------------------------------------------
# UDF
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("metadata", [False, True])
def test_udf_reader_lists_directories_and_reads_files(metadata):
    payload = bytes(range(256)) * 20  # 5120 字节，跨三个扇区
    image = _UdfBuilder(metadata=metadata).build(
        {
            "BDMV": {
                "PLAYLIST": {"00001.mpls": b"hello"},
                "STREAM": {"00001.m2ts": (b"", 9 << 30)},
            },
            "big.bin": payload,
        }
    )
    reader = UDFReader(io.BytesIO(image))
    assert {e.name for e in reader.list([])} == {"BDMV", "big.bin"}
    playlist = reader.list(["BDMV", "PLAYLIST"])
    assert [e.name for e in playlist] == ["00001.mpls"]
    assert reader.read(playlist[0], 1024) == b"hello"
    big = next(e for e in reader.list([]) if e.name == "big.bin")
    assert reader.read(big, 1 << 20) == payload
    stream = reader.list(["bdmv", "stream"])[0]  # 目录名大小写不敏感地兜底
    assert reader.size(stream) == 9 << 30
    with pytest.raises(UDFError):
        reader.read(big, 100)  # 超过上限
    with pytest.raises(UDFError):
        reader.list(["NOPE"])


def test_udf_reader_rejects_non_udf_images():
    with pytest.raises(UDFError):
        UDFReader(io.BytesIO(b"\0" * (300 * S)))


# ---------------------------------------------------------------------------
# 蓝光：EP_map 源包号、目录与镜像的索引
# ---------------------------------------------------------------------------


def test_clpi_entry_points_carry_source_packet_numbers():
    points = [(CLOCK * 10 + 256 * k * 40, 1000 + k * 5000) for k in range(60)]
    parsed = parse_clpi_entry_points(_clpi(points))
    assert [spn for _, spn in parsed] == [spn for _, spn in points]
    assert all(0 <= want - got <= 255 for (want, _), (got, _) in zip(points, parsed, strict=True))
    assert parse_clpi_keyframes(_clpi(points)) == [pts for pts, _ in parsed]


_Clips = list[tuple[str, int, int]]


def _two_clip_disc() -> tuple[_Clips, dict[str, bytes], list[tuple[int, int, int]]]:
    """两段剪辑：00001 播 0～600 秒、00002 播 0～300 秒（PTS 都从 10 秒起），2 秒一个入口点。"""
    clips = [("00001", CLOCK * 10, CLOCK * 610), ("00002", CLOCK * 10, CLOCK * 310)]
    clpis = {}
    for clip_id, in_time, out_time in clips:
        seconds = (out_time - in_time) // CLOCK
        clpis[clip_id] = _clpi([(in_time + CLOCK * 2 * k, 10 * k) for k in range(seconds // 2)])
    marks = [(1, 0, CLOCK * 10), (1, 0, CLOCK * 130), (1, 1, CLOCK * 70)]
    return clips, clpis, marks


def _assert_two_clip_index(index: ContainerIndex | None, first_size: int) -> None:
    assert index is not None
    assert index.container == "bluray"
    assert index.duration_s == pytest.approx(900)
    times = [k.time_s for k in index.keyframes]
    assert times[0] == pytest.approx(0, abs=0.01) and times[-1] == pytest.approx(898, abs=0.01)
    second = next(k for k in index.keyframes if k.time_s >= 600 - 0.01)
    # 第二段的字节位置接在第一段整个文件之后
    assert second.offset == first_size and second.time_s == pytest.approx(600, abs=0.01)
    assert [c for c, _ in index.chapters] == [0, 120, 660]
    # 光盘不给预取范围（字节位置是拼出来的，不是取流地址上的位置）
    assert picker.prefetch_for(index, 300) == ()


def test_bluray_folder_index_from_mpls_and_clpi(tmp_path):
    clips, clpis, marks = _two_clip_disc()
    disc = tmp_path / "Movie (2020)"
    for folder in ("PLAYLIST", "STREAM", "CLIPINF"):
        (disc / "BDMV" / folder).mkdir(parents=True)
    (disc / "BDMV" / "PLAYLIST" / "00800.mpls").write_bytes(_mpls_with_marks(clips, marks))
    for clip_id, data in clpis.items():
        (disc / "BDMV" / "CLIPINF" / f"{clip_id}.clpi").write_bytes(data)
    (disc / "BDMV" / "STREAM" / "00001.m2ts").write_bytes(b"\0" * 7777)
    (disc / "BDMV" / "STREAM" / "00002.M2TS").write_bytes(b"\0" * 10)  # 大写扩展名照样认
    _assert_two_clip_index(disc_index.bluray_folder_index(str(disc), None), 7777)


def test_bluray_folder_without_clpi_has_no_index(tmp_path):
    disc = tmp_path / "NoClpi"
    for folder in ("PLAYLIST", "STREAM"):
        (disc / "BDMV" / folder).mkdir(parents=True)
    (disc / "BDMV" / "PLAYLIST" / "00001.mpls").write_bytes(_mpls(("00001", 0, CLOCK * 600)))
    (disc / "BDMV" / "STREAM" / "00001.m2ts").write_bytes(b"x")
    assert disc_index.bluray_folder_index(str(disc), None) is None


@pytest.mark.parametrize("metadata", [False, True])
def test_bluray_iso_index_picks_main_playlist_past_decoys(tmp_path, metadata):
    clips, clpis, marks = _two_clip_disc()
    decoy = _mpls(*[("00009", 0, CLOCK * 60)] * 200)  # 循环诱饵：时长虚高、必须跳过
    image = _UdfBuilder(metadata=metadata).build(
        {
            "BDMV": {
                "PLAYLIST": {"00800.mpls": _mpls_with_marks(clips, marks), "00152.mpls": decoy},
                "CLIPINF": {f"{cid}.clpi": data for cid, data in clpis.items()},
                "STREAM": {
                    "00001.m2ts": (b"", 30 << 30),
                    "00002.m2ts": (b"", 1 << 30),
                    "00009.m2ts": (b"", 1 << 20),
                },
            },
            "CERTIFICATE": {},
        }
    )
    path = tmp_path / "movie.iso"
    path.write_bytes(image)
    _assert_two_clip_index(disc_index.iso_index(str(path)), 30 << 30)


def test_iso_that_is_not_udf_has_no_index(tmp_path):
    path = tmp_path / "plain.iso"
    path.write_bytes(b"\0" * (300 * S))
    assert disc_index.iso_index(str(path)) is None


# ---------------------------------------------------------------------------
# DVD：IFO 里最长的节目链当片长
# ---------------------------------------------------------------------------


def test_dvd_main_title_is_the_largest_title_set_like_the_engine(tmp_path):
    ifos = {
        # 标题表只列标题集 1、2：标题集 3 是附属内容（内容 VOB 最大也不算），与引擎同一口径
        "VIDEO_TS.IFO": _vmg_ifo([1, 2]),
        "VTS_03_0.IFO": _vts_ifo([5 * 3600]),
        "VTS_03_1.VOB": b"\0" * 900,
        # 标题集 1 的节目链更长（「连续播放全部花絮」），但内容 VOB 小：与引擎一样按 VOB 总大小
        # 选主标题，片长取主标题里最长的节目链
        "VTS_01_0.IFO": _vts_ifo([3 * 3600, 30]),
        "VTS_01_1.VOB": b"\0" * 10,
        "VTS_02_0.IFO": _vts_ifo([1 * 3600 + 52 * 60 + 7, 600]),  # 正片 1:52:07
        "VTS_02_0.VOB": b"\0" * 500,  # 菜单 VOB 不算
        "VTS_02_1.VOB": b"\0" * 30,
        "VTS_02_2.VOB": b"\0" * 30,
    }
    image = _UdfBuilder(metadata=False).build({"VIDEO_TS": dict(ifos), "AUDIO_TS": {}})
    iso = tmp_path / "dvd.iso"
    iso.write_bytes(image)
    index = disc_index.iso_index(str(iso))
    assert index is not None and index.duration_s == 6727 and index.keyframes == ()

    folder = tmp_path / "DVD" / "VIDEO_TS"
    folder.mkdir(parents=True)
    for name, data in ifos.items():
        (folder / name).write_bytes(data)
    index = disc_index.dvd_folder_index(str(folder.parent))
    assert index is not None and index.duration_s == 6727


# ---------------------------------------------------------------------------
# 片段索引的分派与没有关键帧表时的挑点
# ---------------------------------------------------------------------------


def _ref(path: Path | str, container: str, **kw) -> segments.FileRef:
    return segments.FileRef(
        id=1, media_item_id=1, path=str(path), kind="movie", container=container, **kw
    )


def test_index_for_falls_back_to_ledger_duration_and_chapters(tmp_path):
    ts = tmp_path / "movie.ts"
    ts.write_bytes(b"\0" * 188)
    chapters = [{"start_ms": 1_500_000, "title": "第 5 章"}, {"start_ms": 0}]
    index = segments.index_for(_ref(ts, "ts", duration_s=5400.0, chapters=chapters))
    assert index is not None and index.keyframes == ()
    assert index.duration_s == 5400 and index.chapters == ((0.0, None), (1500.0, "第 5 章"))
    # 网盘 strm 不读本地索引，只用台账
    strm = tmp_path / "remote.strm"
    strm.write_text("https://example.com/a.mkv")
    assert segments.index_for(_ref(strm, "mkv", duration_s=3000.0)).duration_s == 3000  # type: ignore[union-attr]
    # 连片长都没有：挑不了
    assert segments.index_for(_ref(ts, "ts")) is None
    # 原盘目录读不出结构时同样退回台账片长
    missing = segments.index_for(_ref(tmp_path / "missing", "bluray", duration_s=7200.0))
    assert missing is not None and missing.duration_s == 7200
    assert not _ref(tmp_path / "x.iso", "iso").local_file
    assert not _ref(strm, "mkv").local_file
    assert _ref(ts, "ts").local_file


def test_pick_without_keyframes_uses_chapters_or_position():
    flat = ContainerIndex(container="ts", file_size=0, duration_s=6000, keyframes=(), tracks=())
    pick = picker.pick_segment(flat, kind="movie")
    assert pick is not None and pick.method == "position" and pick.prefetch == ()
    lo, hi = 6000 * 0.05, 6000 * 0.75 - picker.TARGET_S
    assert pick.start_s == pytest.approx(lo + (hi - lo) / 3, abs=0.01)
    assert pick.end_s - pick.start_s == pytest.approx(picker.TARGET_S)

    chaptered = ContainerIndex(
        container="ts",
        file_size=0,
        duration_s=6000,
        keyframes=(),
        tracks=(),
        chapters=((0.0, None), (1500.0, None), (4000.0, None)),
    )
    pick = picker.pick_segment(chaptered, kind="movie")
    assert pick is not None and pick.method == "chapter" and pick.start_s == 1500.0
    assert (
        picker.pick_segment(
            ContainerIndex(container="ts", file_size=0, duration_s=20, keyframes=(), tracks=()),
            kind="movie",
        )
        is None
    )

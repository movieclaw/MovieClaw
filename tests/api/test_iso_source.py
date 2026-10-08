"""光盘镜像的服务端播放源：镜像里正片的字节区间、concat 清单、按区间供字节。"""

from __future__ import annotations

import json
import subprocess

import pytest
from starlette.applications import Starlette
from starlette.routing import Route
from starlette.testclient import TestClient
from tests.api.test_bluray_clpi import _mpls
from tests.api.test_reels_disc_index import S, _bcd, _clpi, _UdfBuilder, _vmg_ifo

from movieclaw_api.services import media_probe
from movieclaw_api.services.playback import iso_source
from movieclaw_playback.streaming import FileWindowResponse

CLOCK = 45_000


@pytest.fixture(autouse=True)
def _fresh_cache():
    iso_source.clear_cache()
    yield
    iso_source.clear_cache()


def _bluray_image(*, metadata: bool) -> tuple[bytes, bytes, bytes]:
    first, second = bytes([1]) * (3 * S + 100), bytes([2]) * (2 * S)
    clips = [("00001", CLOCK * 10, CLOCK * 610), ("00002", CLOCK * 10, CLOCK * 310)]
    clpis = {
        cid: _clpi([(i + CLOCK * 2 * k, 10 * k) for k in range((o - i) // CLOCK // 2)])
        for cid, i, o in clips
    }
    image = _UdfBuilder(metadata=metadata).build(
        {
            "BDMV": {
                "PLAYLIST": {
                    "00800.mpls": _mpls(*clips),
                    "00152.mpls": _mpls(*[("00009", 0, CLOCK * 60)] * 200),  # 循环诱饵
                },
                "CLIPINF": {f"{cid}.clpi": data for cid, data in clpis.items()},
                "STREAM": {"00001.m2ts": first, "00002.m2ts": second, "00009.m2ts": b"\0" * S},
            },
            "CERTIFICATE": {},
        }
    )
    return image, first, second


@pytest.mark.parametrize("metadata", [False, True])
def test_bluray_iso_main_clips_become_byte_ranges_of_the_image(tmp_path, metadata):
    image, first, second = _bluray_image(metadata=metadata)
    path = tmp_path / "movie.iso"
    path.write_bytes(image)

    source = iso_source.iso_disc_source(path)
    assert source is not None and source.image == "bluray"
    assert source.playlist_name == "00800.mpls"
    assert [c.clip_id for c in source.clips] == ["00001", "00002"]
    for clip, payload in zip(source.clips, (first, second), strict=True):
        start, end = clip.byte_range
        assert image[start:end] == payload  # 区间里正好是这段剪辑的字节
    assert source.duration_s == pytest.approx(900)
    assert source.uses_subfile

    listing = source.concat_list()
    start, end = source.clips[0].byte_range
    assert f"file 'subfile,,start,{start},end,{end},,:{path}'" in listing
    assert "inpoint 10.000000" in listing and "outpoint 610.000000" in listing

    # 关键帧表来自镜像里的 CLPI：两段拼成播放列表时间轴
    index = source.keyframe_index()
    assert index is not None
    assert index.times_s[0] == pytest.approx(0, abs=0.01)
    assert index.times_s[-1] == pytest.approx(898, abs=0.01)


def _vts_ifo_with_cells(seconds: int, cells: list[tuple[int, int]], extra: list[int]) -> bytes:
    """标题集 IFO：第一条节目链是正片（带单元表），``extra`` 是更短的附属节目链。"""
    data = bytearray(6 * S)
    data[:12] = b"DVDVIDEO-VTS"
    data[0xCC:0xD0] = (1).to_bytes(4, "big")
    table = S
    chains = [(seconds, cells), *((s, []) for s in extra)]
    data[table : table + 2] = len(chains).to_bytes(2, "big")
    pgc_rel = 8 + 8 * len(chains)
    for i, (secs, chain_cells) in enumerate(chains):
        entry = table + 8 + i * 8
        data[entry + 4 : entry + 8] = pgc_rel.to_bytes(4, "big")
        pgc = table + pgc_rel
        data[pgc + 3] = len(chain_cells)
        h, m, s = secs // 3600, secs // 60 % 60, secs % 60
        data[pgc + 4 : pgc + 8] = bytes([_bcd(h), _bcd(m), _bcd(s), 0xC0])
        cell_table = 0xEC
        data[pgc + 0xE8 : pgc + 0xEA] = cell_table.to_bytes(2, "big")
        for c, (first, last) in enumerate(chain_cells):
            cell = pgc + cell_table + c * 24
            data[cell + 8 : cell + 12] = first.to_bytes(4, "big")
            data[cell + 20 : cell + 24] = last.to_bytes(4, "big")
        pgc_rel += cell_table + 24 * len(chain_cells)
    return bytes(data)


class _ContiguousBuilder(_UdfBuilder):
    """文件项统一放到远处，文件数据按写入顺序首尾相接（母盘工具写正片 VOB 的样子）。"""

    def __init__(self) -> None:
        super().__init__(metadata=False)
        self._far = 4000

    def file(self, data: bytes, *, size: int | None = None) -> int:
        blocks = max(1, -(-len(data) // S))
        phys = self._phys_block(blocks)
        self._write_phys(phys, data)
        ad = len(data).to_bytes(4, "little") + phys.to_bytes(4, "little")
        fe_block, self._far = self._far, self._far + 1
        self._write_phys(fe_block, self._fe(size if size is not None else len(data), ad, 0))
        return fe_block


def test_dvd_iso_range_is_the_main_program_chain_not_the_whole_title_set(tmp_path):
    # 正片 VOB 两个文件共 6 个扇区：正片节目链只占前 5 个扇区，最后 1 个扇区是花絮单元
    # （时间戳从头再来，留在区间里会让 ffmpeg 把片长估错、跳转跳到末尾）
    vob1 = b"".join(bytes([0x10 + i]) * S for i in range(4))
    vob2 = b"".join(bytes([0x20 + i]) * S for i in range(2))
    image = _ContiguousBuilder().build(
        {
            "VIDEO_TS": {
                "VIDEO_TS.IFO": _vmg_ifo([1]),
                "VTS_01_0.IFO": _vts_ifo_with_cells(5400, [(0, 2), (3, 4)], [90]),
                "VTS_01_1.VOB": vob1,
                "VTS_01_2.VOB": vob2,
            },
            "AUDIO_TS": {},
        }
    )
    path = tmp_path / "dvd.iso"
    path.write_bytes(image)

    source = iso_source.iso_disc_source(path)
    assert source is not None and source.image == "dvd"
    (clip,) = source.clips
    start, end = clip.byte_range
    assert image[start:end] == (vob1 + vob2)[: 5 * S]
    assert source.duration_s == pytest.approx(5400)
    # DVD 段没有播放列表时间：清单只写时长，不写 IN/OUT
    listing = source.concat_list()
    assert "inpoint" not in listing and "duration 5400.000000" in listing
    assert source.keyframe_index() is None


def test_dvd_iso_with_scattered_title_vobs_is_not_readable_by_range(tmp_path):
    vob = bytes([1]) * S
    image = _UdfBuilder(metadata=False).build(
        {
            "VIDEO_TS": {
                "VIDEO_TS.IFO": _vmg_ifo([1]),
                "VTS_01_0.IFO": _vts_ifo_with_cells(600, [(0, 1)], []),
                "VTS_01_1.VOB": vob,
                "VTS_01_0.VOB": bytes([9]) * S,  # 夹在两个正片 VOB 之间：不连续
                "VTS_01_2.VOB": vob,
            },
        }
    )
    path = tmp_path / "scattered.iso"
    path.write_bytes(image)
    assert iso_source.iso_disc_source(path) is None


def test_not_udf_image_has_no_source(tmp_path):
    path = tmp_path / "plain.iso"
    path.write_bytes(b"\0" * (300 * S))
    assert iso_source.iso_disc_source(path) is None


def test_file_window_response_serves_a_slice_with_relative_ranges(tmp_path):
    path = tmp_path / "image.bin"
    data = bytes(range(256)) * 64  # 16 KB
    path.write_bytes(data)

    async def endpoint(request):
        return FileWindowResponse(path, offset=1000, length=5000, media_type="video/MP2T")

    client = TestClient(Starlette(routes=[Route("/clip", endpoint)]))
    whole = client.get("/clip")
    assert whole.status_code == 200 and whole.content == data[1000:6000]
    assert whole.headers["content-length"] == "5000"
    part = client.get("/clip", headers={"Range": "bytes=100-199"})
    assert part.status_code == 206 and part.content == data[1100:1200]
    assert part.headers["content-range"] == "bytes 100-199/5000"
    tail = client.get("/clip", headers={"Range": "bytes=4900-"})
    assert tail.content == data[5900:6000]


def test_probe_takes_the_disc_image_duration_from_the_main_title(tmp_path, monkeypatch):
    """ffprobe 对整个镜像估的片长不可信（NAS 实测一集 DVD 记成 4 秒）：台账用盘内正片的时长。"""
    image, _, _ = _bluray_image(metadata=False)
    path = tmp_path / "movie.iso"
    path.write_bytes(image)
    payload = {
        "format": {"duration": "4.0"},
        "streams": [{"codec_type": "video", "codec_name": "h264"}],
    }

    def fake_ffprobe(args, **_kwargs):
        return subprocess.CompletedProcess(args, 0, json.dumps(payload).encode(), b"")

    monkeypatch.setattr(media_probe.subprocess, "run", fake_ffprobe)
    assert media_probe.probe_media(path).duration_seconds == 900
    # 读不出盘内结构的镜像保留 ffprobe 的值
    plain = tmp_path / "plain.iso"
    plain.write_bytes(b"\0" * (300 * S))
    assert media_probe.probe_media(plain).duration_seconds == 4

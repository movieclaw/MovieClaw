"""扫描的介质规格补探阶段。

这一段存在的唯一理由：ffprobe 是**后装**的时候，扫描的主循环对已识别且
在位的行整体秒过，永远走不到探测那一步——「装好 ffmpeg 再重新扫描」这个
最直觉的动作必须真的有效。ffprobe 与 TMDB 均为假实现。
"""

from __future__ import annotations

import asyncio
import threading
import time
from dataclasses import replace
from pathlib import Path

import httpx
import pytest
import pytest_asyncio
from sqlmodel import select
from tests.api.test_bluray_clpi import _mpls
from tests.api.test_reels_disc_index import S, _UdfBuilder

import movieclaw_api.services.library.disc_main_playlists as playlist_heal_mod
import movieclaw_api.services.library.items as items_mod
import movieclaw_api.services.library.scan as scan_mod
import movieclaw_api.services.media_discover as discover_mod
import movieclaw_api.services.media_probe as probe_mod
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library.bluray import (
    DISC_PLAYLIST_VERSION,
    MainPlaylistReadResult,
    MplsParseError,
)
from movieclaw_api.services.library.disc_main_playlists import heal_disc_main_playlists
from movieclaw_api.services.library.scan import ScanSummary, scan_library
from movieclaw_api.services.media_probe import MediaSpec
from movieclaw_api.services.playback import iso_source
from movieclaw_api.services.playback.disc_source import disc_source_for_file
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import LibraryFile
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"

_SPEC = MediaSpec(
    resolution="1080p",
    video_codec="hevc",
    hdr=None,
    bit_depth=10,
    duration_seconds=5400,
    bit_rate=8_000_000,
    frame_rate=23.976,
    color_space="BT.709",
    audio_streams=[{"codec": "eac3", "channels": 6, "language": "chi", "default": True}],
    subtitle_streams=[{"codec": "subrip", "language": "chi"}],
)


def _body(tmdb_id: int) -> dict:
    return {
        "id": tmdb_id,
        "title": f"影片{tmdb_id}",
        "original_title": f"M{tmdb_id}",
        "release_date": "2020-01-01",
        "status": "Released",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
        "overview": "简介。",
        "vote_average": 7.0,
        "runtime": 100,
        "genres": [],
        "images": {"posters": [], "backdrops": []},
        "release_dates": {"results": []},
        "credits": {"cast": [], "crew": []},
    }


@pytest.fixture(autouse=True)
def _fresh_probe_retry_state():
    """探测失败记忆是进程级内存表，测试之间必须互不串味。"""
    probe_mod._retry_state.clear()
    yield
    probe_mod._retry_state.clear()


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'probe.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()

    def handler(request: httpx.Request) -> httpx.Response:
        seg = request.url.path.rstrip("/").split("/")[-1]
        if seg.isdigit():
            return httpx.Response(200, json=_body(int(seg)))
        return httpx.Response(200, json={"results": []})

    client = TmdbClient(api_key=_KEY, transport=httpx.MockTransport(handler))
    monkeypatch.setattr(discover_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


def _no_ffprobe(monkeypatch) -> None:
    """模拟"系统里没装 ffmpeg"：探测一律失败，可用性检查为假。"""
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: False)
    monkeypatch.setattr(scan_mod, "probe_media", lambda *_a, **_k: None)
    monkeypatch.setattr(items_mod, "probe_media", lambda *_a, **_k: None)


def _with_ffprobe(monkeypatch, calls: list | None = None) -> None:
    """模拟"ffmpeg 已装"：探测返回固定规格。"""

    def _probe(path, *_a, **_k):
        if calls is not None:
            calls.append(str(path))
        return _SPEC

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(scan_mod, "probe_media", _probe)
    monkeypatch.setattr(items_mod, "probe_media", _probe)


def _with_failing_ffprobe(monkeypatch, calls: list | None = None) -> None:
    """模拟"ffmpeg 已装但探测失败"（半截文件/挂载抖动/坏文件）。"""

    def _probe(path, *_a, **_k):
        if calls is not None:
            calls.append(str(path))
        return None

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(scan_mod, "probe_media", _probe)
    monkeypatch.setattr(items_mod, "probe_media", _probe)


def _rewind_retry_state(seconds: float) -> None:
    """把失败记忆的失败时刻拨到 seconds 秒之前，模拟退避到点。"""
    now = time.monotonic()
    for path, (failures, _last) in list(probe_mod._retry_state.items()):
        probe_mod._retry_state[path] = (failures, now - seconds)


async def _build(db, tmp_path, count: int = 3) -> int:
    root = tmp_path / "media" / "movies"
    for i in range(count):
        entry = root / f"影片{3000 + i} (2020)"
        entry.mkdir(parents=True)
        (entry / f"影片{3000 + i}.1080p.mkv").write_bytes(b"z" * (200 + i))
        (entry / "movie.nfo").write_text(
            f"<movie><tmdbid>{3000 + i}</tmdbid></movie>", encoding="utf-8"
        )
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
    return library.id


async def _rows(db) -> list[LibraryFile]:
    async with db.session() as session:
        return list((await session.execute(select(LibraryFile))).scalars().all())


async def test_rescan_backfills_specs_after_ffmpeg_is_installed(db, tmp_path, monkeypatch) -> None:
    """先在没有 ffprobe 的环境入库，装上之后重扫必须把规格补齐。

    这是本模块的正题：主循环对"已识别且在位"的行整体秒过，补探阶段是
    这些行唯一的救赎路径。
    """
    _no_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)

    rows = await _rows(db)
    assert len(rows) == 3
    assert all(r.audio_streams is None and r.resolution is None for r in rows)

    # 装上 ffmpeg，重新扫描
    _with_ffprobe(monkeypatch)
    summary = await scan_library(library_id)

    assert summary.skipped_known == 3, "主循环仍然应当秒过这些行——补探是独立阶段"
    assert summary.probed == 3
    rows = await _rows(db)
    assert all(r.resolution == "1080p" and r.video_codec == "hevc" for r in rows)
    assert all(r.audio_streams and r.audio_streams[0]["codec"] == "eac3" for r in rows)
    assert all(r.subtitle_streams for r in rows)


async def test_backfill_is_idempotent(db, tmp_path, monkeypatch) -> None:
    """补齐之后再扫不再重复探测——探过的行 audio_streams 非 NULL，直接出局。"""
    _no_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    await scan_library(library_id)
    assert len(calls) == 3
    calls.clear()

    summary = await scan_library(library_id)
    assert summary.probed == 0
    assert calls == []


async def test_background_scan_skips_historical_spec_backfill(db, tmp_path, monkeypatch) -> None:
    """后台对账和目录事件只盘点台账，不能对历史文件逐个启动 ffprobe。"""
    _no_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id, backfill_existing_specs=False)

    assert summary.probed == 0
    assert calls == []
    rows = await _rows(db)
    assert all(row.audio_streams is None for row in rows)


async def test_periodic_reconcile_skips_historical_spec_backfill(db, tmp_path, monkeypatch) -> None:
    """定时对账关闭全量补探（避免后台周期扫到全库历史规格），
    只带限量自愈参数与失败记忆的到点点名。"""
    library_id = await _build(db, tmp_path, count=1)
    calls: list[dict] = []

    async def fake_scan(current_library_id: int, **kwargs) -> ScanSummary:
        calls.append({"library_id": current_library_id, **kwargs})
        return ScanSummary(library_id=current_library_id)

    monkeypatch.setattr(scan_mod, "scan_library", fake_scan)
    await scan_mod.reconcile_libraries()

    assert len(calls) == 1
    assert calls[0]["library_id"] == library_id
    assert calls[0]["backfill_existing_specs"] is False
    assert calls[0]["probe_retry_limit"] == scan_mod._RECONCILE_PROBE_LIMIT
    assert calls[0]["reprobe_paths"] is None  # 失败记忆为空时不点名


async def test_stale_probe_version_rows_are_reprobed(db, tmp_path, monkeypatch) -> None:
    """用旧版字段集探测过的行必须被捞回来重探（issue #331）。

    这类行 ``audio_streams`` 是有值的——它们**探测成功过**，只是那一版探测层
    还没有 ``frame_rate`` / ``color_space`` / Dolby Vision 识别。原来的判据
    （只认 ``audio_streams IS NULL``）永远找不到它们，于是 DV 片永远识别不出，
    播放链读台账也就永远不做色调映射，画面发绿。
    """
    _with_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)

    # 把台账退回"旧版本探测过"的样子：规格在、色彩字段缺、版本为 NULL
    async with db.session() as session:
        for row in (await session.execute(select(LibraryFile))).scalars().all():
            row.probe_version = None
            row.color_space = None
            row.frame_rate = None
            row.hdr = None
            session.add(row)
        await session.commit()

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id)

    assert summary.probed == 3, "陈旧行必须进补探队列"
    assert len(calls) == 3
    rows = await _rows(db)
    assert all(r.color_space == "BT.709" for r in rows), "后来新增的字段要补上"
    assert all(r.frame_rate == 23.976 for r in rows)
    assert all(r.probe_version == probe_mod.PROBE_SCHEMA_VERSION for r in rows)


async def test_reprobed_rows_do_not_come_back(db, tmp_path, monkeypatch) -> None:
    """补探必须能终止：补过一轮的行，下一次扫描不能再被探一遍。

    这是判据设计的关键——如果拿"``color_space`` 为空"当判据，真的没有色彩标签
    的文件会每次手动扫描都被白探一遍，整库扫描永远慢一截。版本戳没有这个问题。
    """
    _with_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)
    async with db.session() as session:
        for row in (await session.execute(select(LibraryFile))).scalars().all():
            row.probe_version = None
            session.add(row)
        await session.commit()

    await scan_library(library_id)  # 补探这一轮

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id)

    assert summary.probed == 0, "版本已是最新，不该再进队列"
    assert calls == []


async def test_disc_images_without_a_video_codec_are_reprobed_once(
    db, tmp_path, monkeypatch
) -> None:
    """光盘镜像早先按整个镜像探，蓝光镜像多半什么都没认出（视频编码为空，播放决策判断不了能不能
    直推）：改探盘内正片后，手动扫描把这些行捞回来重探一次，探出编码后不再进队列。"""
    _with_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)
    image = _bluray_image_with_copies(smaller_is_longer=False)
    iso_source.clear_cache()
    async with db.session() as session:
        for row in (await session.execute(select(LibraryFile))).scalars().all():
            path = Path(row.file_path)
            path.write_bytes(image)
            row.size_bytes = len(image)
            row.file_mtime_ns = path.stat().st_mtime_ns
            row.container = "iso"
            row.video_codec = None
            row.audio_streams = []
            session.add(row)
        await session.commit()

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id)
    assert summary.probed == 3 and len(calls) == 3
    rows = await _rows(db)
    assert all(r.video_codec == "hevc" and r.audio_streams for r in rows)

    calls.clear()
    assert (await scan_library(library_id)).probed == 0
    assert calls == []


async def test_failed_disc_image_audit_blocks_missing_spec_probe(db, tmp_path, monkeypatch) -> None:
    """坏 ISO 的失败指纹一旦落账，缺规格补探不能紧接着再走 probe_media 重读整盘。"""
    _with_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path, count=1)
    await scan_library(library_id)
    async with db.session() as session:
        row = (await session.execute(select(LibraryFile))).scalars().one()
        row.container = "iso"
        row.video_codec = None
        row.audio_streams = []
        await session.commit()

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id)
    assert summary.probed == 0 and calls == []
    async with db.session() as session:
        row = (await session.execute(select(LibraryFile))).scalars().one()
        assert row.disc_playlist["audit"]["state"] == "failed"


async def test_files_without_color_tags_are_not_reprobed_forever(
    db, tmp_path, monkeypatch
) -> None:
    """探测成功但文件本身没有色彩标签的行，也必须只探一次。

    ``color_space`` 保持 NULL 是**正确结论**（文件确实没标签），不是"没探过"。
    版本戳区分得开这两者，判据用字段是否为空就区分不开。
    """
    spec_without_color = MediaSpec(
        resolution="1080p",
        video_codec="h264",
        hdr=None,
        bit_depth=8,
        duration_seconds=1200,
        bit_rate=3_000_000,
        frame_rate=25.0,
        color_space=None,  # 文件真的没有色彩标签
        audio_streams=[{"codec": "aac", "channels": 2}],
        subtitle_streams=[],
    )
    calls: list[str] = []

    def _probe(path, *_a, **_k):
        calls.append(str(path))
        return spec_without_color

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(scan_mod, "probe_media", _probe)
    monkeypatch.setattr(items_mod, "probe_media", _probe)

    library_id = await _build(db, tmp_path)
    await scan_library(library_id)
    calls.clear()

    summary = await scan_library(library_id)
    assert summary.probed == 0
    assert calls == [], "色彩标签为空是探测结论，不该被当成'没探过'反复重探"


async def test_limited_self_heal_ignores_stale_version_rows(
    db, tmp_path, monkeypatch
) -> None:
    """限量自愈只管"从没探测成功过"的行，不碰版本陈旧的。

    自愈每轮每库只有十个名额，是给"瞬时失败在几个周期内收敛"用的。把整库的
    陈旧行灌进去，真正需要重试的失败行会被永远挤在后面——历史规格补探按既有
    政策（scan.py 的说明）必须由用户主动扫描触发。
    """
    _with_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)
    async with db.session() as session:
        for row in (await session.execute(select(LibraryFile))).scalars().all():
            row.probe_version = None
            session.add(row)
        await session.commit()

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(
        library_id, backfill_existing_specs=False, probe_retry_limit=10
    )

    assert summary.probed == 0
    assert calls == []


async def test_backfill_skipped_when_ffprobe_missing(db, tmp_path, monkeypatch) -> None:
    """没装 ffprobe 时整段跳过：每轮扫描白跑一遍必然失败的探测毫无意义。"""
    calls: list[str] = []

    def _probe(path, *_a, **_k):
        calls.append(str(path))
        return None

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: False)
    monkeypatch.setattr(scan_mod, "probe_media", _probe)
    monkeypatch.setattr(items_mod, "probe_media", _probe)

    library_id = await _build(db, tmp_path)
    await scan_library(library_id)
    calls.clear()  # 首轮入账时每个新文件探一次是正常的

    summary = await scan_library(library_id)
    assert summary.probed == 0
    assert calls == [], "可用性检查为假时不该再调 ffprobe"


async def test_backfill_skips_strm_rows(db, tmp_path, monkeypatch) -> None:
    """strm 占位行不参与补探：本体没有媒体流，探了必失败，只会污染进度分母。"""
    _no_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path, count=1)
    entry = tmp_path / "media" / "movies" / "影片4000 (2020)"
    entry.mkdir(parents=True)
    (entry / "影片4000.strm").write_text("https://cloud.example.com/m.mkv", encoding="utf-8")
    (entry / "movie.nfo").write_text("<movie><tmdbid>4000</tmdbid></movie>", encoding="utf-8")
    await scan_library(library_id)

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id)

    assert summary.probed == 1, "只有真视频那行需要补探"
    assert all(not c.endswith(".strm") for c in calls)
    rows = {Path(r.file_path).suffix: r for r in await _rows(db)}
    assert rows[".strm"].audio_streams is None and rows[".strm"].resolution is None
    assert rows[".mkv"].audio_streams is not None


async def test_backfill_leaves_missing_and_ignored_rows_alone(db, tmp_path, monkeypatch) -> None:
    """已标记 missing 与用户忽略过的行不参与补探。

    前者文件根本不在磁盘上（探了也白探）；后者是用户明确处理完的决定，
    不该因为一次扫描又被摸一遍。
    """
    from movieclaw_db.models import utcnow

    _no_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)
    await scan_library(library_id)

    rows = await _rows(db)
    async with db.session() as session:
        missing = await session.get(LibraryFile, rows[0].id)
        ignored = await session.get(LibraryFile, rows[1].id)
        # 文件真的从磁盘删掉，否则重扫会把它当"文件回归"重新入账（那条路径
        # 本来就会探测，测不出补探阶段的取舍）
        Path(missing.file_path).unlink()
        missing.mark_missing()
        ignored.ignored_at = utcnow()
        await session.commit()

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id)

    assert summary.probed == 1  # 只剩第三行
    assert len(calls) == 1
    after = {r.id: r for r in await _rows(db)}
    assert after[rows[0].id].audio_streams is None
    assert after[rows[1].id].audio_streams is None
    assert after[rows[2].id].audio_streams is not None


def _clpi_with_languages() -> bytes:
    """一条中文音轨 + 一条中文字幕的最小 CLPI ProgramInfo。"""
    streams = [
        (0x1100, bytes([0x83, 0]) + b"eng"),
        (0x1200, bytes([0x90]) + b"zho" + b"\0"),
    ]
    entries = bytearray()
    for pid, coding_info in streams:
        entries.extend(pid.to_bytes(2, "big"))
        entries.append(len(coding_info))
        entries.extend(coding_info)
    body = bytearray(b"\0\1")
    body.extend((0).to_bytes(4, "big"))
    body.extend((0x100).to_bytes(2, "big"))
    body.extend(bytes([len(streams), 0]))
    body.extend(entries)
    header = bytearray(32)
    header[:8] = b"HDMV0200"
    header[12:16] = (32).to_bytes(4, "big")
    return bytes(header) + len(body).to_bytes(4, "big") + bytes(body)


async def test_backfill_enriches_existing_bluray_once_by_pid(db, tmp_path, monkeypatch) -> None:
    """已有流但 language=NULL 的 BDMV 也进入补探；版本写入后重扫不再读 m2ts。"""
    root = tmp_path / "bluray-library"
    disc = root / "1917 (2019)"
    stream_dir = disc / "BDMV" / "STREAM"
    clipinf_dir = disc / "BDMV" / "CLIPINF"
    stream_dir.mkdir(parents=True)
    clipinf_dir.mkdir(parents=True)
    stream = stream_dir / "00294.m2ts"
    stream.write_bytes(b"movie")
    (clipinf_dir / "00294.clpi").write_bytes(_clpi_with_languages())

    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="蓝光库", kind="movie", root_paths=[str(root)]
        )
        session.add(
            LibraryFile(
                library_id=library.id,
                file_path=str(disc),
                size_bytes=5,
                container="bluray",
                source="scanned",
                audio_streams=[{"codec": "truehd", "language": None}],
                subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "language": None}],
            )
        )
        await session.commit()

    spec = MediaSpec(
        resolution="1080p",
        video_codec="h264",
        hdr=None,
        bit_depth=8,
        duration_seconds=7200,
        bit_rate=20_000_000,
        frame_rate=24.0,
        color_space="BT.709",
        audio_streams=[{"codec": "truehd", "pid": 0x1100, "language": None}],
        subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "pid": 0x1200, "language": None}],
    )
    calls: list[str] = []

    def fake_probe(path):
        calls.append(str(path))
        return spec

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", fake_probe)

    async with db.session() as session:
        summary = ScanSummary(library_id=library.id)
        state = scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING)
        await scan_mod._probe_backfill(session, library.id, summary, state)
        row = (await session.execute(select(LibraryFile))).scalars().one()
        assert summary.probed == 1
        assert row.audio_streams[0]["language"] == "eng"
        assert row.subtitle_streams[0]["language"] == "zho"
        assert row.subtitle_streams[0]["language_source"] == "clpi"

    async with db.session() as session:
        second = ScanSummary(library_id=library.id)
        await scan_mod._probe_backfill(
            session,
            library.id,
            second,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
        )
        assert second.probed == 0
    assert calls == [str(stream)]


async def test_backfill_missing_clpi_still_completes_candidate_progress(
    db, tmp_path, monkeypatch
) -> None:
    """无 CLPI 时不重读 m2ts，但该候选已检查完，进度不能停在 0/N。"""
    root = tmp_path / "bluray-library"
    disc = root / "No CLPI (2020)"
    stream_dir = disc / "BDMV" / "STREAM"
    stream_dir.mkdir(parents=True)
    (stream_dir / "00001.m2ts").write_bytes(b"movie")

    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="蓝光库", kind="movie", root_paths=[str(root)]
        )
        session.add(
            LibraryFile(
                library_id=library.id,
                file_path=str(disc),
                size_bytes=5,
                container="bluray",
                source="scanned",
                audio_streams=[{"codec": "truehd", "language": None}],
                subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "language": None}],
            )
        )
        await session.commit()

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)

    def unexpected_probe(_path):
        raise AssertionError("没有 CLPI 时不应重读 m2ts")

    monkeypatch.setattr(items_mod, "probe_media", unexpected_probe)
    state = scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING)
    async with db.session() as session:
        summary = ScanSummary(library_id=library.id)
        await scan_mod._probe_backfill(session, library.id, summary, state)

    assert summary.probed == 0
    assert state.processed == state.total == 1


# ---------------------------------------------------------------------------
# 选主片的规则改过之后，存量行怎么跟上
# ---------------------------------------------------------------------------

_MAIN_SPEC = MediaSpec(
    resolution="1080p",
    video_codec="h264",
    hdr="HDR10",
    bit_depth=10,
    duration_seconds=5648,
    bit_rate=38_000_000,
    frame_rate=23.976,
    color_space="BT.2020",
    audio_streams=[{"codec": "truehd", "pid": 0x1100}, {"codec": "ac3", "pid": 0x1101}],
    subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "pid": 0x1200}],
)
#: 探错的那段视频的规格（一条音轨、没有字幕）
_SMALL_COPY_FIELDS = {
    "resolution": "720p",
    "video_codec": "mpeg2video",
    "hdr": None,
    "dv_profile": 8,
    "dv_bl_compatible": True,
    "bit_depth": 8,
    "duration_seconds": 5648,
    "bit_rate": 7_000_000,
    "frame_rate": 29.97,
    "color_space": "BT.709",
    "audio_streams": [{"codec": "ac3", "pid": 0x1100}],
    "subtitle_streams": [],
    "probe_version": probe_mod.PROBE_SCHEMA_VERSION,
}


def _two_copies_on_disk(disc: Path) -> None:
    """同样长的两条列表：名字靠后的是小拷贝，只比时长的旧规则选它。"""
    playlist_dir = disc / "BDMV" / "PLAYLIST"
    stream_dir = disc / "BDMV" / "STREAM"
    playlist_dir.mkdir(parents=True)
    stream_dir.mkdir()
    clock = 45_000
    (playlist_dir / "00001.mpls").write_bytes(_mpls(("00001", 0, clock * 5648)))
    (playlist_dir / "00002.mpls").write_bytes(_mpls(("00002", 0, clock * 5648)))
    (stream_dir / "00001.m2ts").write_bytes(b"f" * 5000)
    (stream_dir / "00002.m2ts").write_bytes(b"c" * 1000)


def _version_1_record(clip_id: str) -> dict:
    return {
        "version": 1,
        "name": f"{clip_id}.mpls",
        "clips": [{"id": clip_id, "in": 0, "out": 45_000 * 5648}],
    }


def _current_record(clip_id: str, *, seconds: int = 5648) -> dict:
    """v2 台账清单：历史部分读取落账之后就是这个形状。"""
    return {
        "version": 2,
        "name": f"{clip_id}.mpls",
        "clips": [{"id": clip_id, "in": 0, "out": 45_000 * seconds}],
    }


def _ledger_view(row: LibraryFile) -> dict:
    return {
        "disc_playlist": row.disc_playlist,
        "chapters": row.chapters,
        "updated_at": row.updated_at,
        **{field: getattr(row, field) for field in _SMALL_COPY_FIELDS},
    }


async def _stored_folder_disc(
    db,
    tmp_path,
    *,
    recorded_clip: str,
    on_disk: bool = True,
    playlist: dict | None = None,
) -> int:
    root = tmp_path / "bluray-library"
    disc = root / "Movie (2010)"
    if on_disk:
        _two_copies_on_disk(disc)
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="蓝光库", kind="movie", root_paths=[str(root)]
        )
        row = LibraryFile(
            library_id=library.id,
            file_path=str(disc),
            size_bytes=6000,
            container="bluray",
            source="scanned",
            chapters=[{"start_ms": 0, "end_ms": None, "title": None}],
            disc_playlist=playlist or _version_1_record(recorded_clip),
            **_SMALL_COPY_FIELDS,
        )
        session.add(row)
        await session.commit()
        return row.id


async def _load(db, file_id: int) -> LibraryFile:
    async with db.session() as session:
        row = await session.get(LibraryFile, file_id)
        assert row is not None
        return row


async def test_heal_reprobes_a_folder_disc_whose_main_playlist_changed(
    db, tmp_path, monkeypatch
) -> None:
    """魔女宅急便那样的盘：台账记的是全片分镜版。规格整组换成正片的，不是只补空。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    async with db.session() as session:
        stored = await session.get(LibraryFile, file_id)
        assert stored is not None
        stored.chapter_images = [{"start_ms": 0, "frame_ms": 1000, "image": "old.jpg"}]
        await session.commit()
    calls: list[str] = []

    def probe(path):
        calls.append(Path(path).name)
        return _MAIN_SPEC

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", probe)

    assert await heal_disc_main_playlists() == 1
    assert calls == ["00001.m2ts"]
    row = await _load(db, file_id)
    assert row.disc_playlist is not None
    assert row.disc_playlist["name"] == "00001.mpls"
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert (row.resolution, row.video_codec, row.hdr) == ("1080p", "h264", "HDR10")
    assert (row.bit_depth, row.bit_rate) == (10, 38_000_000)
    assert (row.frame_rate, row.color_space) == (23.976, "BT.2020")
    assert (row.dv_profile, row.dv_bl_compatible) == (None, None)  # 探错那段的杜比视界记录不留
    assert [stream["codec"] for stream in row.audio_streams or []] == ["truehd", "ac3"]
    assert len(row.subtitle_streams or []) == 1
    assert row.duration_seconds == 5648
    assert row.chapters == []
    assert row.chapter_images is None

    # 幂等：跟上之后不再读盘重探
    calls.clear()
    assert await heal_disc_main_playlists() == 0
    assert calls == []
    # 播放链路用的清单是新的
    source = disc_source_for_file(row, read_disc=False)
    assert source is not None and source.playlist_name == "00001.mpls"


async def test_first_trusted_folder_audit_overwrites_degraded_specs(
    db, tmp_path, monkeypatch
) -> None:
    """历史残缺入库没有旧 clips 时，首次完整审计也必须整组覆盖最大 m2ts 的错规格。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    async with db.session() as session:
        row = await session.get(LibraryFile, file_id)
        assert row is not None
        row.disc_playlist = None
        await session.commit()
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", lambda _path: _MAIN_SPEC)

    assert await heal_disc_main_playlists() == 1
    row = await _load(db, file_id)
    assert row.disc_playlist is not None
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert row.disc_playlist["name"] == "00001.mpls"
    assert (row.resolution, row.video_codec, row.bit_rate) == ("1080p", "h264", 38_000_000)


async def test_heal_only_refreshes_the_version_when_the_main_playlist_is_unchanged(
    db, tmp_path, monkeypatch
) -> None:
    """绝大多数盘不受影响：版本号换掉就好，不跑 ffprobe，规格一个字段都不动。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00001")
    before = await _load(db, file_id)

    def unexpected_probe(_path):
        raise AssertionError("主片没换不该重探")

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", unexpected_probe)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist is not None
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert row.updated_at == before.updated_at
    for field, value in _SMALL_COPY_FIELDS.items():
        assert getattr(row, field) == value, field


async def test_heal_leaves_discs_alone_while_the_library_is_not_mounted(
    db, tmp_path, monkeypatch
) -> None:
    """片库没挂上不是残缺盘：不能把好清单写成哨兵，等下次启动。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002", on_disk=False)
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist == _version_1_record("00002")
    assert row.resolution == "720p"


async def test_heal_does_nothing_without_ffprobe(db, tmp_path, monkeypatch) -> None:
    """重探不了就别把规格清掉。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    _no_ffprobe(monkeypatch)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist == _version_1_record("00002")
    assert row.resolution == "720p"


async def test_failed_reprobe_stays_unprobed_and_the_reconcile_retries_it(
    db, tmp_path, monkeypatch
) -> None:
    """探测失败不能留着另一段视频的规格；退回未探测后，定期对账的限量自愈捞得到。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    _with_failing_ffprobe(monkeypatch)

    assert await heal_disc_main_playlists() == 1
    row = await _load(db, file_id)
    assert row.disc_playlist is not None and row.disc_playlist["name"] == "00001.mpls"
    assert row.disc_playlist["audit"]["state"] == "pending_probe"
    assert "version" not in row.disc_playlist
    assert row.resolution is None and row.audio_streams is None

    monkeypatch.setattr(items_mod, "probe_media", lambda _path: _MAIN_SPEC)
    probe_mod._retry_state.clear()  # 退避到点
    async with db.session() as session:
        summary = ScanSummary(library_id=row.library_id)
        await scan_mod._probe_backfill(
            session,
            row.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
            limit=10,
        )
    assert summary.probed == 1
    row = await _load(db, file_id)
    assert row.resolution == "1080p" and row.audio_streams
    assert row.disc_playlist is not None
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION


async def test_changed_folder_disc_does_not_promote_stale_pending_playlist(
    db, tmp_path, monkeypatch
) -> None:
    """ffprobe 失败后盘被替换：pending 的旧 clips 不能直接盖 v3，必须按新指纹重审。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", lambda _path: None)

    assert await heal_disc_main_playlists() == 1
    pending = await _load(db, file_id)
    assert pending.disc_playlist is not None
    assert pending.disc_playlist["audit"]["state"] == "pending_probe"
    assert pending.disc_playlist["name"] == "00001.mpls"

    disc = Path(pending.file_path)
    (disc / "BDMV" / "STREAM" / "00002.m2ts").write_bytes(b"n" * 10_000)
    original = items_mod.read_main_playlist_result
    reads = 0

    def counted_read(path):
        nonlocal reads
        reads += 1
        return original(path)

    targets: list[str] = []

    def probe(path):
        targets.append(Path(path).name)
        return _MAIN_SPEC

    probe_mod._retry_state.clear()
    monkeypatch.setattr(items_mod, "read_main_playlist_result", counted_read)
    monkeypatch.setattr(items_mod, "probe_media", probe)

    assert await heal_disc_main_playlists() == 1
    row = await _load(db, file_id)
    assert reads == 1
    assert targets == ["00002.m2ts"]
    assert row.disc_playlist is not None
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert row.disc_playlist["name"] == "00002.mpls"


async def test_manual_scan_also_replaces_the_spec_when_the_main_playlist_changed(
    db, tmp_path, monkeypatch
) -> None:
    """启动时片库没挂上的行由手动扫描接手：同一条路径，结果一样。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", lambda _path: _MAIN_SPEC)
    row = await _load(db, file_id)

    async with db.session() as session:
        summary = ScanSummary(library_id=row.library_id)
        await scan_mod._probe_backfill(
            session,
            row.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
        )
    assert summary.probed == 1
    row = await _load(db, file_id)
    assert row.resolution == "1080p" and len(row.audio_streams or []) == 2


@pytest.mark.parametrize("first", ["startup", "manual"])
async def test_startup_heal_and_manual_scan_serialize_the_same_library(
    db, tmp_path, monkeypatch, first
) -> None:
    """后到的会话拿锁后重读 v3，不会用旧快照再清空已成功的规格。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    row = await _load(db, file_id)
    entered = threading.Event()
    release = threading.Event()
    calls = 0

    def probe(_path):
        nonlocal calls
        calls += 1
        entered.set()
        assert release.wait(5)
        return _MAIN_SPEC

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", probe)

    async def manual_scan() -> ScanSummary:
        async with db.session() as session:
            summary = ScanSummary(library_id=row.library_id)
            await scan_mod._probe_backfill(
                session,
                row.library_id,
                summary,
                scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
            )
            return summary

    first_task = asyncio.create_task(
        heal_disc_main_playlists() if first == "startup" else manual_scan()
    )
    assert await asyncio.to_thread(entered.wait, 5)
    second_task = asyncio.create_task(
        manual_scan() if first == "startup" else heal_disc_main_playlists()
    )
    await asyncio.sleep(0)
    release.set()
    first_result, second_result = await asyncio.gather(first_task, second_task)
    healed, summary = (
        (first_result, second_result)
        if first == "startup"
        else (second_result, first_result)
    )

    assert healed + summary.probed == 1
    assert calls == 1
    final = await _load(db, file_id)
    assert final.disc_playlist is not None
    assert final.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert final.resolution == "1080p" and final.audio_streams


async def test_unreadable_playlists_keep_a_good_record_until_they_read_again(
    db, tmp_path, monkeypatch
) -> None:
    """目录在、MPLS 读不出（NFS soft 挂载抖动）：旧清单是好的，不能写成「读过但没有」的哨兵。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(
        items_mod,
        "read_main_playlist_result",
        lambda _path: MainPlaylistReadResult(None, retryable=True),
    )

    def unexpected_probe(_path):
        raise AssertionError("读不出清单时不该重探")

    monkeypatch.setattr(items_mod, "probe_media", unexpected_probe)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist == _version_1_record("00002")
    assert row.resolution == "720p"


@pytest.mark.parametrize("failure", ["io_error", "short_read"])
async def test_incomplete_playlist_candidate_waits_for_a_complete_retry(
    db, tmp_path, monkeypatch, failure
) -> None:
    """正片 MPLS 读不全时不扶正小拷贝；恢复后仍会换正片并在线程里找流。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    original_read_bytes = Path.read_bytes
    fail_main_playlist = True

    def flaky_read_bytes(path: Path) -> bytes:
        if fail_main_playlist and path.name == "00001.mpls":
            if failure == "io_error":
                raise OSError("temporary NFS read failure")
            return original_read_bytes(path)[:30]
        return original_read_bytes(path)

    monkeypatch.setattr(Path, "read_bytes", flaky_read_bytes)
    loop_thread = threading.get_ident()
    stream_calls: list[str] = []

    def locate_stream(path: Path, *, playlist=None):
        assert threading.get_ident() != loop_thread
        assert playlist is not None
        stream_calls.append(playlist.path.name)
        return path / "BDMV" / "STREAM" / "00001.m2ts"

    probe_calls: list[str] = []

    def probe(path: Path):
        probe_calls.append(path.name)
        return _MAIN_SPEC

    monkeypatch.setattr(scan_mod, "disc_main_stream", locate_stream)
    monkeypatch.setattr(items_mod, "probe_media", probe)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist == _version_1_record("00002")
    for field, value in _SMALL_COPY_FIELDS.items():
        assert getattr(row, field) == value, field
    assert row.chapters == [{"start_ms": 0, "end_ms": None, "title": None}]
    assert stream_calls == [] and probe_calls == []

    fail_main_playlist = False
    assert await heal_disc_main_playlists() == 1
    row = await _load(db, file_id)
    assert row.disc_playlist is not None
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert row.disc_playlist["name"] == "00001.mpls"
    assert row.duration_seconds == 5648
    assert row.resolution == "1080p"
    assert stream_calls == ["00001.mpls"]
    assert probe_calls == ["00001.m2ts"]


def _folder(tmp_path: Path) -> Path:
    return tmp_path / "bluray-library" / "Movie (2010)"


def _unexpected_probe(_path: Path) -> MediaSpec:
    raise AssertionError("这张盘不该重探")


async def test_current_version_wrong_folder_recovers_only_after_a_complete_read(
    db, tmp_path, monkeypatch
) -> None:
    """旧版已经把花絮写成主片，版本却是最新。没挂上、读不全都不改；读全才扶正，再跑不动。"""
    file_id = await _stored_folder_disc(
        db, tmp_path, recorded_clip="00002", on_disk=False, playlist=_current_record("00002")
    )
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", _unexpected_probe)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist == _current_record("00002")
    assert row.resolution == "720p"

    _two_copies_on_disk(_folder(tmp_path))
    original_read_bytes = Path.read_bytes
    fail_main = True

    def flaky_read_bytes(path: Path) -> bytes:
        if fail_main and path.name == "00001.mpls":
            return original_read_bytes(path)[:30]
        return original_read_bytes(path)

    monkeypatch.setattr(Path, "read_bytes", flaky_read_bytes)
    loop_thread = threading.get_ident()
    stream_calls: list[str] = []

    def locate_stream(path: Path, *, playlist=None):
        assert threading.get_ident() != loop_thread
        assert playlist is not None
        stream_calls.append(playlist.path.name)
        return path / "BDMV" / "STREAM" / "00001.m2ts"

    probe_calls: list[str] = []

    def probe(path: Path):
        probe_calls.append(path.name)
        return _MAIN_SPEC

    monkeypatch.setattr(scan_mod, "disc_main_stream", locate_stream)
    monkeypatch.setattr(items_mod, "probe_media", probe)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist == _current_record("00002")
    assert row.resolution == "720p"
    assert row.chapters == [{"start_ms": 0, "end_ms": None, "title": None}]
    assert stream_calls == [] and probe_calls == []

    fail_main = False
    assert await heal_disc_main_playlists() == 1
    row = await _load(db, file_id)
    assert row.disc_playlist is not None
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert row.disc_playlist["name"] == "00001.mpls"
    assert row.disc_playlist["clips"] == _current_record("00001")["clips"]
    assert row.resolution == "1080p"
    assert row.duration_seconds == 5648
    assert [stream["codec"] for stream in row.audio_streams or []] == ["truehd", "ac3"]
    assert stream_calls == ["00001.mpls"]
    assert probe_calls == ["00001.m2ts"]
    source = disc_source_for_file(row, read_disc=False)
    assert source is not None and source.playlist_name == "00001.mpls"

    stream_calls.clear()
    probe_calls.clear()
    assert await heal_disc_main_playlists() == 0
    assert stream_calls == [] and probe_calls == []
    again = await _load(db, file_id)
    assert again.disc_playlist == row.disc_playlist
    assert again.resolution == "1080p"
    assert again.updated_at == row.updated_at


async def test_current_version_correct_folder_is_not_rewritten(db, tmp_path, monkeypatch) -> None:
    """清单本来就是正片：完整重读只盖 v3，之后启动和手动扫描都不再读。"""
    file_id = await _stored_folder_disc(
        db, tmp_path, recorded_clip="00001", playlist=_current_record("00001")
    )
    before = _ledger_view(await _load(db, file_id))
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", _unexpected_probe)
    original_read_bytes = Path.read_bytes
    fail_main = True

    def flaky_read_bytes(path: Path) -> bytes:
        if fail_main and path.name == "00001.mpls":
            raise OSError("temporary NFS read failure")
        return original_read_bytes(path)

    monkeypatch.setattr(Path, "read_bytes", flaky_read_bytes)
    assert await heal_disc_main_playlists() == 0
    assert _ledger_view(await _load(db, file_id)) == before

    fail_main = False
    assert await heal_disc_main_playlists() == 0
    verified = await _load(db, file_id)
    assert verified.disc_playlist is not None
    assert verified.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert verified.disc_playlist["clips"] == before["disc_playlist"]["clips"]
    for field, value in _SMALL_COPY_FIELDS.items():
        assert getattr(verified, field) == value, field
    after_verification = _ledger_view(verified)

    def unexpected_read(_path):
        raise AssertionError("v3 清单不应再完整重读")

    monkeypatch.setattr(items_mod, "read_main_playlist_result", unexpected_read)
    assert await heal_disc_main_playlists() == 0

    row = await _load(db, file_id)
    async with db.session() as session:
        summary = ScanSummary(library_id=row.library_id)
        await scan_mod._probe_backfill(
            session,
            row.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
        )
    assert summary.probed == 0
    assert _ledger_view(await _load(db, file_id)) == after_verification


async def test_current_version_folder_without_playlists_keeps_the_record(
    db, tmp_path, monkeypatch
) -> None:
    """目录在，但已经没有可播的主片：不能把旧清单写成「读过但没有」的哨兵。"""
    file_id = await _stored_folder_disc(
        db, tmp_path, recorded_clip="00002", on_disk=False, playlist=_current_record("00002")
    )
    disc = _folder(tmp_path)
    (disc / "BDMV" / "PLAYLIST").mkdir(parents=True)
    (disc / "BDMV" / "STREAM").mkdir()
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", _unexpected_probe)

    assert await heal_disc_main_playlists() == 0
    row = await _load(db, file_id)
    assert row.disc_playlist is not None
    assert row.disc_playlist["name"] == "00002.mpls"
    assert row.disc_playlist["clips"] == _current_record("00002")["clips"]
    assert row.disc_playlist["audit"]["state"] == "failed"
    assert "version" not in row.disc_playlist
    assert row.resolution == "720p"


async def test_permanently_broken_folder_is_reaudited_only_after_fingerprint_change(
    db, tmp_path, monkeypatch
) -> None:
    """稳定损坏的 MPLS 记失败指纹；启动/手扫不反复读，文件变化后再审计。"""
    file_id = await _stored_folder_disc(db, tmp_path, recorded_clip="00002")
    broken = _folder(tmp_path) / "BDMV" / "PLAYLIST" / "00001.mpls"
    broken.write_bytes(b"permanently broken mpls")
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    original = items_mod.read_main_playlist_result
    calls = 0

    def counted(path):
        nonlocal calls
        calls += 1
        return original(path)

    monkeypatch.setattr(items_mod, "read_main_playlist_result", counted)
    monkeypatch.setattr(items_mod, "probe_media", _unexpected_probe)

    assert await heal_disc_main_playlists() == 0
    assert calls == 1
    failed = await _load(db, file_id)
    assert failed.disc_playlist is not None
    assert failed.disc_playlist["audit"]["state"] == "failed"
    assert failed.resolution == "720p"

    assert await heal_disc_main_playlists() == 0
    assert calls == 1

    async with db.session() as session:
        unprobed = await session.get(LibraryFile, file_id)
        assert unprobed is not None
        unprobed.audio_streams = None
        unprobed.video_codec = None
        await session.commit()
        summary = ScanSummary(library_id=failed.library_id)
        await scan_mod._probe_backfill(
            session,
            failed.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
        )
    assert summary.probed == 0
    assert calls == 1

    monkeypatch.setattr(items_mod, "probe_media", lambda _path: _MAIN_SPEC)
    async with db.session() as session:
        summary = ScanSummary(library_id=failed.library_id)
        await scan_mod._probe_backfill(
            session,
            failed.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
            force_disc_playlist_audit=True,
        )
    assert calls == 2
    assert summary.probed == 1

    broken.write_bytes(b"still broken, but changed size")
    assert await heal_disc_main_playlists() == 0
    assert calls == 3


async def test_full_scan_corrects_current_version_wrong_folder_limited_reconcile_does_not(
    db, tmp_path, monkeypatch
) -> None:
    """手动全量补探走同一条扶正；定期对账的限量名额不重读这些已经探测过的行。"""
    file_id = await _stored_folder_disc(
        db, tmp_path, recorded_clip="00002", playlist=_current_record("00002")
    )
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", lambda _path: _MAIN_SPEC)
    row = await _load(db, file_id)

    async with db.session() as session:
        summary = ScanSummary(library_id=row.library_id)
        await scan_mod._probe_backfill(
            session,
            row.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
            limit=10,
        )
    assert summary.probed == 0
    row = await _load(db, file_id)
    assert row.disc_playlist == _current_record("00002")
    assert row.resolution == "720p"

    async with db.session() as session:
        summary = ScanSummary(library_id=row.library_id)
        await scan_mod._probe_backfill(
            session,
            row.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
        )
    assert summary.probed == 1
    row = await _load(db, file_id)
    assert row.disc_playlist is not None and row.disc_playlist["name"] == "00001.mpls"
    assert row.resolution == "1080p"

    async with db.session() as session:
        summary = ScanSummary(library_id=row.library_id)
        await scan_mod._probe_backfill(
            session,
            row.library_id,
            summary,
            scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
        )
    assert summary.probed == 0


def _bluray_image_with_copies(*, smaller_is_longer: bool) -> bytes:
    """蓝光镜像：smaller_is_longer 时小拷贝比正片长 6 秒（旧规则选它），否则正片本身最长。"""
    copy_seconds = 7118 if smaller_is_longer else 7106
    clock = 45_000
    return _UdfBuilder(metadata=False).build(
        {
            "BDMV": {
                "PLAYLIST": {
                    "00013.mpls": _mpls(("00097", 0, clock * 7112)),
                    "00019.mpls": _mpls(("00122", 0, clock * copy_seconds)),
                },
                "CLIPINF": {},
                "STREAM": {
                    "00097.m2ts": bytes([1]) * (30 * S),
                    "00122.m2ts": bytes([2]) * (10 * S),
                },
            },
        }
    )


async def _stored_image(db, tmp_path, name: str, image: bytes) -> int:
    root = tmp_path / "iso-library"
    root.mkdir(exist_ok=True)
    path = root / f"{name}.iso"
    path.write_bytes(image)
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name=name, kind="movie", root_paths=[str(root)]
        )
        row = LibraryFile(
            library_id=library.id,
            file_path=str(path),
            size_bytes=len(image),
            container="iso",
            source="scanned",
            **_SMALL_COPY_FIELDS,
        )
        session.add(row)
        await session.commit()
        return row.id


async def test_heal_reprobes_only_the_images_whose_main_playlist_changed(
    db, tmp_path, monkeypatch
) -> None:
    """镜像的台账不记清单，靠「只比时长会选哪条」认出受影响的盘；其余镜像的台账一个字节不动。"""
    iso_source.clear_cache()
    replaced = await _stored_image(
        db, tmp_path, "replaced", _bluray_image_with_copies(smaller_is_longer=True)
    )
    same = await _stored_image(
        db, tmp_path, "same", _bluray_image_with_copies(smaller_is_longer=False)
    )
    calls: list[str] = []

    def probe(path):
        calls.append(Path(path).name)
        return replace(_MAIN_SPEC, duration_seconds=7112)

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", probe)

    assert await heal_disc_main_playlists() == 1
    assert calls == ["replaced.iso"]
    row = await _load(db, replaced)
    assert row.disc_playlist is not None and row.disc_playlist["name"] == "00013.mpls"
    assert (row.resolution, row.duration_seconds) == ("1080p", 7112)
    assert [stream["codec"] for stream in row.audio_streams or []] == ["truehd", "ac3"]
    untouched = await _load(db, same)
    assert untouched.disc_playlist is not None
    assert untouched.disc_playlist["version"] == DISC_PLAYLIST_VERSION
    assert untouched.disc_playlist["name"] == "00013.mpls"
    for field, value in _SMALL_COPY_FIELDS.items():
        assert getattr(untouched, field) == value, field

    # 重启不再重探，也不因为清单写成了 ISO 就被当成原盘目录
    calls.clear()
    assert await heal_disc_main_playlists() == 0
    assert calls == []
    assert disc_source_for_file(row) is None


def _image_record(name: str, clip_id: str, seconds: int) -> dict:
    return {
        "version": 2,
        "name": name,
        "clips": [{"id": clip_id, "in": 0, "out": 45_000 * seconds}],
    }


async def _stamp_image_playlist(db, file_id: int, playlist: dict) -> LibraryFile:
    async with db.session() as session:
        row = await session.get(LibraryFile, file_id)
        assert row is not None
        row.disc_playlist = playlist
        await session.commit()
        return row


async def test_compat_manual_scan_stop_skips_iso_preread(db, tmp_path, monkeypatch) -> None:
    """bridge=None 的兼容扫描在 ISO 完整审计前也响应停止。"""
    iso_source.clear_cache()
    file_id = await _stored_image(
        db, tmp_path, "cancel-before-audit", _bluray_image_with_copies(smaller_is_longer=False)
    )
    row = await _load(db, file_id)
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    scan_mod._scan_tasks._stops.add(row.library_id)
    try:
        async with db.session() as session:
            summary = ScanSummary(library_id=row.library_id)
            await scan_mod._probe_backfill(
                session,
                row.library_id,
                summary,
                scan_mod.ScanState(phase=scan_mod.ScanPhase.WALKING),
            )
    finally:
        scan_mod._scan_tasks._stops.discard(row.library_id)
    assert summary.probed == 0
    assert (await _load(db, file_id)).disc_playlist is None


async def test_current_version_wrong_image_recovers_when_duration_already_picks_the_main(
    db, tmp_path, monkeypatch
) -> None:
    """正片本身最长时，旧逻辑不再重看镜像。版本已最新、清单却是小拷贝的，完整重读后仍要扶正。"""
    iso_source.clear_cache()
    file_id = await _stored_image(
        db, tmp_path, "duration-main", _bluray_image_with_copies(smaller_is_longer=False)
    )
    await _stamp_image_playlist(db, file_id, _image_record("00019.mpls", "00122", 7106))
    calls: list[str] = []

    def probe(path):
        calls.append(Path(path).name)
        return replace(_MAIN_SPEC, duration_seconds=7112)

    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", probe)

    assert await heal_disc_main_playlists() == 1
    assert calls == ["duration-main.iso"]
    row = await _load(db, file_id)
    assert row.disc_playlist is not None
    assert row.disc_playlist["name"] == "00013.mpls"
    assert row.disc_playlist["clips"] == _image_record("00013.mpls", "00097", 7112)["clips"]
    assert row.resolution == "1080p"
    assert row.duration_seconds == 7112

    calls.clear()
    assert await heal_disc_main_playlists() == 0
    assert calls == []
    again = await _load(db, file_id)
    assert again.disc_playlist == row.disc_playlist
    assert again.updated_at == row.updated_at


async def test_incomplete_image_read_does_not_replace_a_current_version_playlist(
    db, tmp_path, monkeypatch
) -> None:
    """镜像里有一条 MPLS 没读全时不改台账：不能把正片换成花絮，也不能靠残缺候选扶正。"""
    iso_source.clear_cache()
    file_id = await _stored_image(
        db, tmp_path, "partial", _bluray_image_with_copies(smaller_is_longer=False)
    )
    correct = _image_record("00013.mpls", "00097", 7112)
    wrong = _image_record("00019.mpls", "00122", 7106)
    await _stamp_image_playlist(db, file_id, correct)
    before = _ledger_view(await _load(db, file_id))
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", _unexpected_probe)
    original = iso_source.parse_mpls_playlist
    fail_name = "00013.mpls"

    def flaky_parse(data: bytes, *, path: Path = Path("unknown.mpls")):
        if path.name == fail_name:
            raise MplsParseError("truncated")
        return original(data, path=path)

    monkeypatch.setattr(iso_source, "parse_mpls_playlist", flaky_parse)
    assert await heal_disc_main_playlists() == 0
    failed_once = _ledger_view(await _load(db, file_id))
    assert failed_once["disc_playlist"]["name"] == correct["name"]
    assert failed_once["disc_playlist"]["clips"] == correct["clips"]
    assert failed_once["disc_playlist"]["audit"]["state"] == "failed"
    for field, value in before.items():
        if field not in {"disc_playlist", "updated_at"}:
            assert failed_once[field] == value
    assert await heal_disc_main_playlists() == 0
    assert _ledger_view(await _load(db, file_id)) == failed_once

    # 台账是花絮、正片那条又读不全：剩下的候选正好是花絮，也不能借这次残缺读取改账。
    iso_source.clear_cache()
    await _stamp_image_playlist(db, file_id, wrong)
    wrong_view = _ledger_view(await _load(db, file_id))
    fail_name = "00019.mpls"
    assert await heal_disc_main_playlists() == 0
    failed_wrong = _ledger_view(await _load(db, file_id))
    assert failed_wrong["disc_playlist"]["name"] == wrong["name"]
    assert failed_wrong["disc_playlist"]["clips"] == wrong["clips"]
    assert failed_wrong["disc_playlist"]["audit"]["state"] == "failed"
    for field, value in wrong_view.items():
        if field not in {"disc_playlist", "updated_at"}:
            assert failed_wrong[field] == value

    # 镜像被修复（mtime 指纹变化）后读全：才把花絮扶正成正片。
    iso_source.clear_cache()
    monkeypatch.setattr(iso_source, "parse_mpls_playlist", original)
    Path((await _load(db, file_id)).file_path).touch()

    def probe(path):
        return replace(_MAIN_SPEC, duration_seconds=7112)

    monkeypatch.setattr(items_mod, "probe_media", probe)
    assert await heal_disc_main_playlists() == 1
    row = await _load(db, file_id)
    assert row.disc_playlist is not None and row.disc_playlist["name"] == "00013.mpls"
    assert row.resolution == "1080p"
    assert await heal_disc_main_playlists() == 0


async def test_changed_image_reaudits_before_promoting_pending_playlist(
    db, tmp_path, monkeypatch
) -> None:
    """ISO pending 后换盘，即使清单名碰巧相同，也要按新指纹重新完整审计。"""
    iso_source.clear_cache()
    file_id = await _stored_image(
        db, tmp_path, "pending-replaced", _bluray_image_with_copies(smaller_is_longer=True)
    )
    monkeypatch.setattr(probe_mod, "ffprobe_available", lambda: True)
    monkeypatch.setattr(items_mod, "probe_media", lambda _path: None)

    assert await heal_disc_main_playlists() == 1
    pending = await _load(db, file_id)
    assert pending.disc_playlist is not None
    assert pending.disc_playlist["audit"]["state"] == "pending_probe"

    image = Path(pending.file_path)
    before = image.stat()
    image.touch()
    if image.stat().st_mtime_ns == before.st_mtime_ns:
        image.write_bytes(image.read_bytes() + b"\0")
    iso_source.clear_cache()
    original = playlist_heal_mod.iso_disc_source
    reads = 0

    def counted_read(path):
        nonlocal reads
        reads += 1
        return original(path)

    probe_mod._retry_state.clear()
    monkeypatch.setattr(playlist_heal_mod, "iso_disc_source", counted_read)
    monkeypatch.setattr(items_mod, "probe_media", lambda _path: _MAIN_SPEC)

    assert await heal_disc_main_playlists() == 1
    row = await _load(db, file_id)
    assert reads == 1
    assert row.disc_playlist is not None
    assert row.disc_playlist["version"] == DISC_PLAYLIST_VERSION


# ---------------------------------------------------------------------------
# 探测失败记忆与退避重试（media_probe 的进程内失败表）
# ---------------------------------------------------------------------------


def test_retry_backoff_escalates() -> None:
    """连续失败翻倍退避，封顶 24 小时——纯函数，直接验时间表。"""
    hour = 3600.0
    assert probe_mod._retry_due((1, 0.0), hour - 1) is False
    assert probe_mod._retry_due((1, 0.0), hour) is True
    assert probe_mod._retry_due((3, 0.0), 4 * hour - 1) is False
    assert probe_mod._retry_due((3, 0.0), 4 * hour) is True
    assert probe_mod._retry_due((10, 0.0), 24 * hour - 1) is False  # 封顶后不再翻倍
    assert probe_mod._retry_due((10, 0.0), 24 * hour) is True


async def test_manual_scan_backs_off_recent_probe_failures(db, tmp_path, monkeypatch) -> None:
    """探测失败进退避：手动重扫不再每轮为同一个坏文件全额付一次超时。"""
    calls: list[str] = []
    _with_failing_ffprobe(monkeypatch, calls)
    library_id = await _build(db, tmp_path, count=1)
    await scan_library(library_id)  # 入库探测失败，进入失败记忆
    assert len(calls) == 1
    calls.clear()

    summary = await scan_library(library_id)  # 退避未到点：补探阶段跳过该行
    assert summary.probed == 0
    assert calls == []

    _rewind_retry_state(2 * 3600)  # 退避到点，且这次文件恢复可读
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id)
    assert summary.probed == 1
    row = (await _rows(db))[0]
    assert row.audio_streams and row.resolution == "1080p"
    assert row.file_path not in probe_mod._retry_state, "成功后失败记忆应被抹掉"


async def test_reconcile_style_scan_heals_failed_probe_after_backoff(
    db, tmp_path, monkeypatch
) -> None:
    """无 watch 库的自愈路径：对账限量补探到点重试，退避未到点不动媒体盘。"""
    _with_failing_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path, count=1)
    await scan_library(library_id)

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id, backfill_existing_specs=False, probe_retry_limit=10)
    assert summary.probed == 0 and calls == [], "退避未到点，对账不该重试"

    _rewind_retry_state(2 * 3600)
    summary = await scan_library(library_id, backfill_existing_specs=False, probe_retry_limit=10)
    assert summary.probed == 1
    assert (await _rows(db))[0].audio_streams is not None


async def test_reconcile_budget_caps_probe_count(db, tmp_path, monkeypatch) -> None:
    """ffprobe 后装的存量库：对账每轮只补一小批，绝不演变成整库读盘。"""
    _no_ffprobe(monkeypatch)
    library_id = await _build(db, tmp_path)  # 3 个文件，规格全 NULL 且无失败记录
    await scan_library(library_id)

    calls: list[str] = []
    _with_ffprobe(monkeypatch, calls)
    summary = await scan_library(library_id, backfill_existing_specs=False, probe_retry_limit=2)
    assert summary.probed == 2 and len(calls) == 2

    summary = await scan_library(library_id, backfill_existing_specs=False, probe_retry_limit=2)
    assert summary.probed == 1, "下一轮接着补剩下的行"
    rows = await _rows(db)
    assert all(row.audio_streams is not None for row in rows)

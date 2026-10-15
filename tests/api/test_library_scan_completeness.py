"""扫描完整性检测的测试：新文件 mtime 太新 → 暂缓入账，静默够久 → 正常入账。

库对根路径的用途不做假设——它完全可能同时是下载目录，写入中的半成品
不该进台账。补扫任务的到点行为靠 _arm_rescan 打桩验证参数，不真等待。
"""

from __future__ import annotations

import os
import time

import pytest
import pytest_asyncio
from sqlmodel import select

import movieclaw_api.services.library.scan as scan_mod
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library.scan import scan_library
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import LibraryFile
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_media.models import MediaKind


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'scan.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    # 识别链不在本测试范围：TMDB 客户端打桩为惰性哑对象
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: object())
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def _make_library(db, root) -> int:
    root.mkdir(parents=True, exist_ok=True)
    async with db.session() as session:
        row = await LibraryRepository(session).create(
            name="测试电影库", kind=MediaKind.MOVIE.value, root_paths=[str(root)]
        )
        return row.id


def _age(path, seconds: int) -> None:
    """把文件 mtime 拨到 seconds 秒之前。"""
    past = time.time() - seconds
    os.utime(path, (past, past))


@pytest.mark.asyncio
async def test_fresh_strm_is_not_deferred(db, tmp_path, monkeypatch):
    """刚写出的 .strm 立刻入账（按文件名识别、播放时才读内容）；同目录刚写的真视频照旧暂缓。"""
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    (root / "上云电影 (2026).strm").write_text("https://example.com/play/1\n", encoding="utf-8")
    (root / "zzqx.mkv").write_bytes(b"downloading")
    monkeypatch.setattr(scan_mod, "_arm_rescan", lambda *a: None)

    summary = await scan_library(library_id)
    assert summary.deferred == 1
    async with db.session() as session:
        rows = list((await session.execute(select(LibraryFile.file_path))).scalars().all())
    assert rows == [str(root / "上云电影 (2026).strm")]


@pytest.mark.asyncio
async def test_fresh_file_deferred_then_ingested(db, tmp_path, monkeypatch):
    """mtime 太新的文件暂缓入账并安排补扫；静默够久后正常入账。"""
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    video = root / "zzqx.mkv"
    video.write_bytes(b"downloading")  # mtime = 现在，疑似写入中

    armed: list[tuple[int, float]] = []
    monkeypatch.setattr(
        scan_mod, "_arm_rescan", lambda lid, delay, *rest: armed.append((lid, delay))
    )

    summary = await scan_library(library_id)
    assert summary.deferred == 1
    assert summary.scanned == 0
    async with db.session() as session:
        rows = list((await session.execute(select(LibraryFile))).scalars().all())
    assert rows == []  # 半成品绝不进台账
    # 已按剩余静默时间安排补扫
    assert armed and armed[0][0] == library_id
    assert 5.0 <= armed[0][1] <= scan_mod.NEW_FILE_QUIET_SECONDS

    # 静默够久（拨旧 mtime）：补扫入账
    _age(video, scan_mod.NEW_FILE_QUIET_SECONDS + 60)
    summary = await scan_library(library_id)
    assert summary.deferred == 0
    assert summary.scanned == 1
    async with db.session() as session:
        rows = list((await session.execute(select(LibraryFile))).scalars().all())
    assert [r.file_path for r in rows] == [str(video)]


@pytest.mark.asyncio
async def test_old_files_ingest_immediately(db, tmp_path, monkeypatch):
    """存量文件（mtime 久远）不受静默窗口影响，首轮即入账。"""
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    video = root / "old.mkv"
    video.write_bytes(b"settled")
    _age(video, 3600)
    monkeypatch.setattr(scan_mod, "_arm_rescan", lambda *a: None)

    summary = await scan_library(library_id)
    assert summary.deferred == 0
    assert summary.scanned == 1


# ---- 写完的证据：不必干等静默窗口 / 暂缓不能被目录快照吞掉 / 补扫续得上期 ----


class _FakeBrief:
    def __init__(self, name: str, info_hash: str, completed: bool) -> None:
        self.name = name
        self.content_name = name
        self.info_hash = info_hash
        self.completed = completed


class _FakeDownloaderBridge(scan_mod.acquisition.NullBridge):
    """下载器里有一个任务：内容根就是条目目录，文件完成状态由测试控制。"""

    def __init__(self, entry, completed: bool) -> None:
        self.entry = entry
        self.completed = completed

    async def download_tasks(self):
        return [_FakeBrief(self.entry.name, "abc", self.completed)]

    async def task_files(self, matches):
        files = tuple(
            scan_mod.acquisition.TaskFile(
                source=p, selected=True, size_bytes=p.stat().st_size, completed=self.completed
            )
            for p in sorted(self.entry.iterdir())
        )
        return [scan_mod.acquisition.TaskFiles(info_hash="abc", completed=False, files=files)]


def _sparse(path, size: int = 128 << 20) -> None:
    """只写了开头 4KB 的稀疏文件：BT 不预分配、还没下完时的样子。

    给到 128MB：APFS 对小文件关闭后会把空洞填实（本机实测 16MB 不报空洞），
    稀疏文件不占真实磁盘，大一点无妨。
    """
    with open(path, "wb") as fh:
        fh.truncate(size)
        fh.write(b"x" * 4096)


async def _ledger_paths(db) -> list[str]:
    async with db.session() as session:
        return sorted((await session.execute(select(LibraryFile.file_path))).scalars().all())


@pytest.mark.asyncio
async def test_settled_event_ingests_without_quiet_window(db, tmp_path, monkeypatch):
    """文件事件说写入方已收尾（写后关闭/改名就位）、文件没有空洞 → 当场入账，不等五分钟。"""
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    video = root / "Movie (2024)" / "Movie.2024.mkv"
    video.parent.mkdir()
    video.write_bytes(b"complete" * 1024)
    monkeypatch.setattr(scan_mod, "_arm_rescan", lambda *a: None)

    summary = await scan_library(
        library_id, backfill_existing_specs=False, settled_paths={str(video)}
    )
    assert summary.deferred == 0
    assert await _ledger_paths(db) == [str(video)]


@pytest.mark.asyncio
async def test_settled_event_with_holes_still_deferred(db, tmp_path, monkeypatch):
    """暂停任务同样会关闭文件：有没下到的空洞时，收尾信号不采信，照旧暂缓。"""
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    video = root / "Movie (2024)" / "Movie.2024.mkv"
    video.parent.mkdir()
    _sparse(video)
    if not scan_mod._has_holes(video):
        pytest.skip("该文件系统不报告空洞")
    monkeypatch.setattr(scan_mod, "_arm_rescan", lambda *a: None)

    summary = await scan_library(
        library_id, backfill_existing_specs=False, settled_paths={str(video)}
    )
    assert summary.deferred == 1
    assert await _ledger_paths(db) == []


@pytest.mark.asyncio
async def test_downloader_completed_ingests_immediately(db, tmp_path, monkeypatch):
    """下载器报告文件写完：不等静默窗口，也不需要文件事件。"""
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    entry = root / "Movie.2024.1080p"
    entry.mkdir()
    video = entry / "Movie.2024.1080p.mkv"
    video.write_bytes(b"complete" * 1024)
    monkeypatch.setattr(scan_mod, "_arm_rescan", lambda *a: None)
    unbind = scan_mod.acquisition.bind(_FakeDownloaderBridge(entry, completed=True))
    try:
        summary = await scan_library(library_id, backfill_existing_specs=False)
    finally:
        unbind()
    assert summary.deferred == 0
    assert await _ledger_paths(db) == [str(video)]


@pytest.mark.asyncio
async def test_downloader_incomplete_overrides_settled_event(db, tmp_path, monkeypatch):
    """下载器说没写完以它为准（哪怕文件事件说关了），并登记为等下载器报告。"""
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    entry = root / "Movie.2024.1080p"
    entry.mkdir()
    video = entry / "Movie.2024.1080p.mkv"
    video.write_bytes(b"partial-but-preallocated" * 1024)
    armed: list[tuple] = []
    monkeypatch.setattr(scan_mod, "_arm_rescan", lambda *a: armed.append(a))
    unbind = scan_mod.acquisition.bind(_FakeDownloaderBridge(entry, completed=False))
    try:
        summary = await scan_library(
            library_id, backfill_existing_specs=False, settled_paths={str(video)}
        )
    finally:
        unbind()
    assert summary.deferred == 1
    assert await _ledger_paths(db) == []
    (_lid, _delay, scopes, awaiting) = armed[0]
    assert scopes == {str(entry)}
    assert awaiting == {str(video): str(root)}


@pytest.mark.asyncio
async def test_deferred_file_not_hidden_by_dir_snapshot(db, tmp_path, monkeypatch):
    """群里反馈的复现：暂缓之后写入结束不改目录 mtime，增量对账也必须重列这个目录。

    BT 往预分配好的文件里写数据不改目录 mtime；修复前，暂缓那一轮落下的快照让此后
    每一轮增量对账都凭「叶子目录没变」跳过它，文件要等一周一次的全量重建才入账。
    """
    root = tmp_path / "movies"
    library_id = await _make_library(db, root)
    old = root / "Old (2000)" / "Old.mkv"
    old.parent.mkdir()
    old.write_bytes(b"old")
    _age(old, 3600)
    monkeypatch.setattr(scan_mod, "_arm_rescan", lambda *a: None)
    await scan_library(library_id)  # 全量一轮，建立目录快照

    entry = root / "New (2024)"
    entry.mkdir()
    video = entry / "New.mkv"
    video.write_bytes(b"downloading")
    summary = await scan_library(library_id, backfill_existing_specs=False)  # 增量对账
    assert summary.deferred == 1

    # 写入结束：文件内容变了、静默够久，但目录 mtime 停在暂缓那一刻
    dir_mtime_ns = entry.stat().st_mtime_ns
    video.write_bytes(b"downloaded!")
    _age(video, scan_mod.NEW_FILE_QUIET_SECONDS + 60)
    os.utime(entry, ns=(dir_mtime_ns, dir_mtime_ns))  # 快照按纳秒比对，浮点秒会丢精度

    summary = await scan_library(library_id, backfill_existing_specs=False)  # 下一轮增量对账
    assert summary.deferred == 0
    assert str(video) in await _ledger_paths(db)


@pytest.mark.asyncio
async def test_rescan_rearms_from_inside_and_retries_when_busy(monkeypatch):
    """补扫这一轮又暂缓（文件还在写）要能续期；库忙让路要稍后重试，不能断链。"""
    import asyncio

    monkeypatch.setattr(scan_mod, "_RESCAN_BUSY_RETRY_SECONDS", 0.01)
    calls: list[set | None] = []
    done = asyncio.Event()

    async def fake_scan(library_id, **kwargs):
        calls.append(kwargs.get("scope_paths"))
        summary = scan_mod.ScanSummary(library_id=library_id)
        if len(calls) == 1:
            summary.postponed = True  # 第一次：库忙让路
        elif len(calls) == 2:
            scan_mod._arm_rescan(library_id, 0.01, {"/lib/B"})  # 第二次：又暂缓了文件
        else:
            done.set()
        return summary

    async def no_skip(*a, **k):
        return None

    import movieclaw_api.services.library.skip_segments as skip_mod

    monkeypatch.setattr(scan_mod, "scan_library", fake_scan)
    monkeypatch.setattr(skip_mod, "enqueue_after_scan", no_skip)
    scan_mod._arm_rescan(99, 0.01, {"/lib/A"})
    await asyncio.wait_for(done.wait(), 5)
    assert calls == [{"/lib/A"}, {"/lib/A"}, {"/lib/B"}]
    assert 99 not in scan_mod._rescan_requests


@pytest.mark.asyncio
async def test_rescan_fires_early_when_downloader_reports_done(monkeypatch):
    """等下载器的暂缓文件：静默期没满，下载器一报告写完就提前补扫。"""
    import asyncio

    monkeypatch.setattr(scan_mod, "_DOWNLOADER_POLL_SECONDS", 0.01)
    answers = iter([False, False, True])

    class FakeEvidence:
        async def verdict(self, file, root):
            return next(answers)

    fired = asyncio.Event()

    async def fake_scan(library_id, **kwargs):
        fired.set()
        return scan_mod.ScanSummary(library_id=library_id)

    async def no_skip(*a, **k):
        return None

    import movieclaw_api.services.library.skip_segments as skip_mod

    monkeypatch.setattr(scan_mod, "_DownloaderEvidence", FakeEvidence)
    monkeypatch.setattr(scan_mod, "scan_library", fake_scan)
    monkeypatch.setattr(skip_mod, "enqueue_after_scan", no_skip)
    scan_mod._arm_rescan(98, 300, {"/lib/A"}, {"/lib/A/a.mkv": "/lib"})
    await asyncio.wait_for(fired.wait(), 5)  # 远早于 300 秒的静默期

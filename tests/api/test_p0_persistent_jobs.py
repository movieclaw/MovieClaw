"""P0 后台作业的跨重启恢复边界。

这些测试不只断言 Job 状态机本身，而是刻意把领域操作停在最危险的账实窗口：
磁盘已经变化、SQLite 台账尚未提交。新进程必须能据持久化计划补齐台账，且
整库刷新只能从最后一个完整批次继续。
"""

from __future__ import annotations

import asyncio
import os

import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs, media_scrape
from movieclaw_api.services.library import organize, scan, transfer
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import FileSource, JobStatus, LibraryFile, MediaItem
from movieclaw_db.repositories.library_repo import LibraryRepository


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'p0-jobs.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()

    async def _noop_notify() -> None:
        return None

    monkeypatch.setattr(
        "movieclaw_api.services.media_server_notify.notify_media_server_refresh",
        _noop_notify,
    )
    yield get_database()
    await jobs.close_job_dispatcher()
    await dispose_db()
    get_settings.cache_clear()


async def _wait_status(job_id: str, status: JobStatus, timeout: float = 3.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        async with get_database().session() as session:
            row = await jobs.get_job(session, job_id)
            assert row is not None
            if row.status is status:
                return row
        if asyncio.get_running_loop().time() >= deadline:
            raise AssertionError(f"作业未进入 {status.value}，当前为 {row.status.value}")
        await asyncio.sleep(0.01)


async def test_library_metadata_refresh_resumes_from_completed_batch(db, tmp_path, monkeypatch):
    """更新发生在第二批时，前三个已完整刮削的条目不应从头再跑。"""
    root = tmp_path / "metadata"
    root.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
        item_ids: list[int] = []
        for index in range(4):
            item = MediaItem(
                kind="movie",
                tmdb_id=1000 + index,
                title=f"电影 {index}",
                original_title=f"Movie {index}",
            )
            session.add(item)
            await session.flush()
            assert item.id is not None and library.id is not None
            item_ids.append(item.id)
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    file_path=str(root / f"{index}.mkv"),
                    size_bytes=1,
                    source=FileSource.SCANNED,
                )
            )
        await session.commit()
        created = await media_scrape.enqueue_library_metadata_refresh_job(
            session, library.id, library.name
        )

    fourth_started = asyncio.Event()
    release_fourth = asyncio.Event()
    calls: list[int] = []

    async def _fake_scrape(media_item_id, *, force=False, on_phase=None, progress=None):
        assert force is True
        calls.append(media_item_id)
        if on_phase is not None:
            on_phase("测试刮削")
        if media_item_id == item_ids[3]:
            fourth_started.set()
            await release_fourth.wait()
        return True

    monkeypatch.setattr(media_scrape, "scrape_media_item", _fake_scrape)
    await jobs.init_job_dispatcher(max_parallel=1)
    await asyncio.wait_for(fourth_started.wait(), timeout=2)
    await jobs.close_job_dispatcher()

    paused = await _wait_status(created.job.id, JobStatus.QUEUED)
    assert paused.progress["current"] == 3
    assert paused.attempt == 0

    release_fourth.set()
    await jobs.init_job_dispatcher(max_parallel=1)
    completed = await _wait_status(created.job.id, JobStatus.SUCCEEDED)
    assert completed.result["processed"] == 4
    assert [calls.count(item_id) for item_id in item_ids[:3]] == [1, 1, 1]
    assert calls.count(item_ids[3]) == 2  # 被重启打断的当前单位允许幂等重跑


async def test_item_metadata_refresh_uses_persistent_job(db, tmp_path, monkeypatch):
    """单条目刷新也必须走同一 Job 状态机，而不是退回 FastAPI BackgroundTasks。"""
    root = tmp_path / "item-metadata"
    root.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
        item = MediaItem(kind="movie", tmdb_id=1500, title="单片刷新", original_title="Movie")
        session.add(item)
        await session.flush()
        assert library.id is not None and item.id is not None
        session.add(
            LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(root / "movie.mkv"),
                size_bytes=1,
                source=FileSource.SCANNED,
            )
        )
        await session.commit()
        created = await media_scrape.enqueue_item_metadata_refresh_job(
            session,
            library_id=library.id,
            media_item_id=item.id,
            title=item.title,
        )

    async def _fake_scrape(media_item_id, *, force=False, on_phase=None, progress=None):
        assert media_item_id == item.id and force is True
        if on_phase is not None:
            on_phase("写入元数据")
        return True

    monkeypatch.setattr(media_scrape, "scrape_media_item", _fake_scrape)
    await jobs.init_job_dispatcher(max_parallel=1)
    completed = await _wait_status(created.job.id, JobStatus.SUCCEEDED)
    assert completed.result["media_item_id"] == item.id
    assert completed.progress["percent"] == 100.0


async def _seed_movies(db, root, count: int):
    root.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
        ids: list[int] = []
        for index in range(count):
            item = MediaItem(
                kind="movie", tmdb_id=2000 + index, title=f"片 {index}", original_title="M"
            )
            session.add(item)
            await session.flush()
            assert item.id is not None and library.id is not None
            ids.append(item.id)
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    file_path=str(root / f"{index}.mkv"),
                    size_bytes=1,
                    source=FileSource.SCANNED,
                )
            )
        await session.commit()
        return library, ids


def _fake_images(progress, *, downloaded: int, reused: int, failed: int) -> None:
    """模拟刮削走到「下载图片」：第 4 / 5 步，逐张结算。"""
    progress.phase, progress.step, progress.steps = "下载图片", 4, 5
    progress.images.planned += downloaded + reused + failed
    for _ in range(downloaded):
        progress.images.record("downloaded", 1024 * 1024)
    for _ in range(reused):
        progress.images.record("reused")
    for _ in range(failed):
        progress.images.record("failed")


async def test_item_metadata_refresh_reports_steps_and_image_tally(db, tmp_path, monkeypatch):
    """单条目刷新：任务进度带第几步 / 共几步与图片记账，完成摘要写清新下载、沿用、失败。"""
    library, (item_id,) = await _seed_movies(db, tmp_path / "item-tally", 1)
    async with db.session() as session:
        created = await media_scrape.enqueue_item_metadata_refresh_job(
            session, library_id=library.id, media_item_id=item_id, title="片 0"
        )

    async def _fake_scrape(media_item_id, *, force=False, on_phase=None, progress=None):
        _fake_images(progress, downloaded=2, reused=3, failed=1)
        return True

    monkeypatch.setattr(media_scrape, "scrape_media_item", _fake_scrape)
    await jobs.init_job_dispatcher(max_parallel=1)
    completed = await _wait_status(created.job.id, JobStatus.SUCCEEDED)

    images = completed.result["images"]
    assert (images["downloaded"], images["reused"], images["failed"]) == (2, 3, 1)
    assert "新下载 2 张（2.0 MB）" in completed.result["message"]
    assert "沿用 3 张" in completed.result["message"]
    assert "1 张失败" in completed.result["message"]
    # 完成后进度里的明细原样保留，任务卡据此显示
    assert completed.progress["details"]["images"]["failed"] == 1
    assert (completed.progress["current"], completed.progress["total"]) == (6, 6)
    assert completed.progress["phase_count"] == 5


async def test_library_metadata_refresh_aggregates_image_tally(db, tmp_path, monkeypatch):
    """整库刷新：逐部推进计数、全库图片记账汇总，检查点与展示分开存。"""
    library, ids = await _seed_movies(db, tmp_path / "lib-tally", 4)
    async with db.session() as session:
        created = await media_scrape.enqueue_library_metadata_refresh_job(
            session, library.id, library.name
        )

    async def _fake_scrape(media_item_id, *, force=False, on_phase=None, progress=None):
        _fake_images(progress, downloaded=1, reused=2, failed=0)
        return media_item_id != ids[0]  # 第一部整部失败

    monkeypatch.setattr(media_scrape, "scrape_media_item", _fake_scrape)
    await jobs.init_job_dispatcher(max_parallel=1)
    completed = await _wait_status(created.job.id, JobStatus.SUCCEEDED)

    details = completed.progress["details"]
    assert details["images"]["downloaded"] == 4 and details["images"]["reused"] == 8
    assert details["failed"] == 1
    assert details["active"] == []
    assert details["checkpoint"]["resume_at"] == 4
    assert completed.result["failed"] == 1
    assert "其中 1 个未完成" in completed.result["message"]
    assert "新下载 4 张" in completed.result["message"]


async def test_library_scan_job_resumes_from_persisted_checkpoint(db, tmp_path, monkeypatch):
    """扫描中更新服务后，Job 自动续跑且已确认的单位不重复执行。"""
    root = tmp_path / "scan-resume"
    root.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="续跑电影库", kind="movie", root_paths=[str(root)]
        )
        assert library.id is not None
        created = await scan.enqueue_scan_job(session, library.id, library.name)

    first_unit_saved = asyncio.Event()
    invocations = 0
    units: list[int] = []

    async def _fake_scan(
        library_id,
        *,
        backfill_existing_specs=True,
        reprobe_paths=None,
        reconcile_root_change=False,
        previous_root_paths=None,
        job_context=None,
        raise_unexpected=False,
    ):
        nonlocal invocations
        assert library_id == library.id
        assert backfill_existing_specs is True
        assert job_context is not None and raise_unexpected is True
        invocations += 1
        persisted = await job_context.current_progress()
        resume_at = int(persisted.get("current") or 0)
        summary = scan.ScanSummary(library_id=library_id, scanned=resume_at)
        for index in range(resume_at, 2):
            units.append(index)
            summary.scanned = index + 1
            await job_context.update_progress(
                mode="determinate",
                phase="ingesting",
                message=f"测试扫描 {index + 1} / 2",
                current=index + 1,
                total=2,
                percent=(index + 1) * 50.0,
                details=scan.scan_summary_payload(summary),
            )
            if invocations == 1 and index == 0:
                first_unit_saved.set()
                await asyncio.Event().wait()
        return summary

    monkeypatch.setattr(scan, "scan_library", _fake_scan)
    await jobs.init_job_dispatcher(max_parallel=1)
    await asyncio.wait_for(first_unit_saved.wait(), timeout=2)
    await jobs.close_job_dispatcher()

    paused = await _wait_status(created.job.id, JobStatus.QUEUED)
    assert paused.progress["current"] == 1
    assert paused.attempt == 0

    await jobs.init_job_dispatcher(max_parallel=1)
    completed = await _wait_status(created.job.id, JobStatus.SUCCEEDED)
    assert completed.result["scanned"] == 2
    assert units == [0, 1]
    assert invocations == 2


async def test_direct_reconcile_scan_yields_to_library_job_lock(db, tmp_path):
    """文件监听/定时对账不进历史，但不能越过统一库级资源锁。"""
    root = tmp_path / "scan-lock"
    root.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="互斥电影库", kind="movie", root_paths=[str(root)]
        )
        assert library.id is not None
        created = await jobs.create_job(
            session,
            job_type="test.library-lock",
            input_data={},
            resources=[jobs.ResourceRef("library", library.id)],
        )

    entered = asyncio.Event()
    release = asyncio.Event()

    @jobs.register_job_handler("test.library-lock")
    async def _hold_library_lock(context, _input):
        entered.set()
        await release.wait()

    await jobs.init_job_dispatcher(max_parallel=1)
    await asyncio.wait_for(entered.wait(), timeout=2)
    summary = await scan.scan_library(library.id, backfill_existing_specs=False)
    assert summary.errors == ["该库有后台作业正在执行，扫描已顺延到下一次触发"]
    async with db.session() as session:
        await jobs.request_cancel(session, created.job.id, requested_by="test")
    release.set()
    await _wait_status(created.job.id, JobStatus.CANCELLED)


async def test_organize_repairs_ledger_after_rename_before_commit(db, tmp_path):
    """文件已原子改名但进程退出时，恢复执行只补台账，不把目标当冲突。"""
    root = tmp_path / "organize"
    root.mkdir()
    source = root / "messy.mkv"
    source.write_bytes(b"video")
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
        item = MediaItem(
            kind="movie", tmdb_id=2000, title="规整电影", original_title="Movie", year=2024
        )
        session.add(item)
        await session.flush()
        assert library.id is not None and item.id is not None
        session.add(
            LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(source),
                size_bytes=source.stat().st_size,
                source=FileSource.SCANNED,
            )
        )
        await session.commit()
        plan = await organize.build_organize_plan(session, library)
        created = await organize.enqueue_organize_job(session, library, plan)

    assert len(plan.renames) == 1
    action = plan.renames[0]
    organize._move_no_clobber(source, organize.Path(action.target_path))

    await jobs.init_job_dispatcher(max_parallel=1)
    completed = await _wait_status(created.job.id, JobStatus.SUCCEEDED)
    assert completed.result["renamed"] == 1
    async with db.session() as session:
        row = (await session.execute(select(LibraryFile))).scalar_one()
    assert row.file_path == action.target_path


async def test_transfer_repairs_ledger_after_target_publish(db, tmp_path):
    """目标目录已发布、源已消失时，重启后应继续迁移台账而不是宣告冲突。"""
    source_root = tmp_path / "source"
    target_root = tmp_path / "target"
    source_entry = source_root / "测试电影 (2024)"
    source_entry.mkdir(parents=True)
    target_root.mkdir()
    video = source_entry / "测试电影 (2024).mkv"
    video.write_bytes(b"video")
    async with db.session() as session:
        repo = LibraryRepository(session)
        source_library = await repo.create(
            name="源电影库", kind="movie", root_paths=[str(source_root)]
        )
        target_library = await repo.create(
            name="目标电影库", kind="movie", root_paths=[str(target_root)]
        )
        item = MediaItem(
            kind="movie", tmdb_id=3000, title="测试电影", original_title="Movie", year=2024
        )
        session.add(item)
        await session.flush()
        assert source_library.id and target_library.id and item.id
        row = LibraryFile(
            library_id=source_library.id,
            media_item_id=item.id,
            file_path=str(video),
            size_bytes=video.stat().st_size,
            source=FileSource.SCANNED,
        )
        session.add(row)
        await session.commit()
        plan = await transfer.build_transfer_plan(
            session, source_library, target_library, item, [row]
        )
        created = await transfer.enqueue_transfer_job(
            session, plan, target_library_name=target_library.name
        )

    target_entry = target_root / source_entry.name
    os.rename(source_entry, target_entry)
    await jobs.init_job_dispatcher(max_parallel=1)
    completed = await _wait_status(created.job.id, JobStatus.SUCCEEDED)
    assert completed.result["files_relocated"] == 1
    async with db.session() as session:
        moved = (await session.execute(select(LibraryFile))).scalar_one()
    assert moved.library_id == target_library.id
    assert moved.file_path == str(target_entry / video.name)


def test_cross_device_partial_file_continues_from_existing_bytes(tmp_path, monkeypatch):
    """跨盘隐藏副本存在时按长度追加，不能清空后从零复制。"""
    source = tmp_path / "large.mkv"
    partial = tmp_path / ".large.partial"
    source.write_bytes(b"abcdefghijkl")
    monkeypatch.setattr(transfer, "_COPY_CHUNK_BYTES", 4)

    copied, total = transfer._copy_file_chunk(source, partial)
    assert (copied, total) == (4, 12)
    assert partial.read_bytes() == b"abcd"
    copied, total = transfer._copy_file_chunk(source, partial)
    assert (copied, total) == (8, 12)
    assert partial.read_bytes() == b"abcdefgh"
    copied, total = transfer._copy_file_chunk(source, partial)
    assert (copied, total) == (12, 12)
    assert partial.read_bytes() == source.read_bytes()

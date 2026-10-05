"""真实文件处理与搜索的一致性回归：只替换外部 TMDB 和媒体探测。

扫描、入库作业、物理改名、转移、回收与恢复均走实际业务实现；每一步通过
HTTP 搜索检查当前库存，覆盖索引尚未消费和消费完成两种状态。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import httpx
import pytest
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs, media_scrape
from movieclaw_api.services.library import ingest, scan
from movieclaw_api.services.library.recycle import recycle_file
from movieclaw_api.services.library.search_index import refresh_index_batch
from movieclaw_api.services.media_probe import MediaSpec
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import ImportWatch, IngestEntry, JobStatus, Library, LibraryFile, MediaItem
from movieclaw_media.tmdb import TmdbClient

_SPEC = MediaSpec("1080p", "h264", None, 8, 3600, None)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'lifecycle.db'}")
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()

    def tmdb_response(request):
        if request.url.path == "/3/movie/101":
            return httpx.Response(
                200,
                json={
                    "id": 101,
                    "title": "星际验收",
                    "original_title": "Search Lifecycle",
                    "release_date": "2020-01-01",
                    "status": "Released",
                    "external_ids": {},
                    "alternative_titles": {"titles": [{"title": "验收别名"}]},
                    "translations": {"translations": []},
                    "credits": {
                        "cast": [],
                        "crew": [
                            {
                                "id": 525,
                                "name": "克里斯托弗·诺兰",
                                "original_name": "Christopher Nolan",
                                "job": "Director",
                                "department": "Directing",
                            }
                        ],
                    },
                },
            )
        return httpx.Response(200, json={"results": []})

    tmdb = TmdbClient("test-key", transport=httpx.MockTransport(tmdb_response))
    monkeypatch.setattr(scan, "get_tmdb_client", lambda: tmdb)
    monkeypatch.setattr(ingest, "get_tmdb_client", lambda: tmdb)
    monkeypatch.setattr(scan, "probe_media", lambda _path: _SPEC)
    monkeypatch.setattr(ingest, "probe_media", lambda _path: _SPEC)
    monkeypatch.setattr(scan, "NEW_FILE_QUIET_SECONDS", 0)
    monkeypatch.setattr(ingest, "QUIET_SECONDS", 0)
    for attr in ("_stability", "_deferred", "_failed_retry", "_last_swept"):
        monkeypatch.setattr(ingest, attr, {})
    monkeypatch.setattr(ingest, "_briefs_cache", (float("-inf"), None))

    async def no_assets(*_args, **_kwargs):
        return None

    monkeypatch.setattr(media_scrape, "ensure_assets", no_assets)
    await jobs.init_job_dispatcher(max_parallel=2)
    yield get_database()
    await jobs.close_job_dispatcher()
    await dispose_db()
    await tmdb.aclose()
    get_settings.cache_clear()


@pytest_asyncio.fixture
async def client(db):
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="lifecycle")
    app.dependency_overrides[require_login] = lambda: admin
    app.dependency_overrides[require_admin] = lambda: admin
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


async def _library(client, root: Path, *, kind="movie") -> int:
    root.mkdir(parents=True, exist_ok=True)
    response = await client.post(
        "/api/v1/libraries",
        json={
            "name": root.name,
            "kind": kind,
            "root_paths": [str(root)],
            "auto_clear_missing": False,
        },
    )
    assert response.status_code == 200, response.text
    library_id = response.json()["data"]["id"]
    # 建库会自动盘点空根，待它结束再写入样本，避免把扫描互斥当成业务失败。
    for _ in range(500):
        response = await client.get(f"/api/v1/libraries/{library_id}")
        assert response.status_code == 200, response.text
        if not response.json()["data"]["scanning"]:
            return library_id
        await asyncio.sleep(0.01)
    raise AssertionError("建库后的初次扫描未完成")


async def _search(client, query):
    response = await client.get("/api/v1/search/library", params={"q": query})
    assert response.status_code == 200, response.text
    return response.json()["data"]


async def _run_job(client, url, **kwargs):
    response = await client.post(url, **kwargs)
    assert response.status_code == 202, response.text
    job_id = response.json()["data"]["job_id"]
    for _ in range(500):
        response = await client.get(f"/api/v1/jobs/{job_id}")
        assert response.status_code == 200, response.text
        job = response.json()["data"]
        if job["status"] == "succeeded":
            return job["result"]
        assert job["status"] not in {"failed", "blocked", "cancelled"}, job
        await asyncio.sleep(0.01)
    raise AssertionError(f"业务作业未完成：{job_id}")


async def _indexed(client, query, item_id):
    before = await _search(client, query)
    assert [h["item"]["media_item_id"] for h in before["items"]] == [item_id]
    while await refresh_index_batch():
        pass
    after = await _search(client, query)
    assert after["items"] == before["items"]
    assert after["index_pending"] is False


async def test_scan_organize_relink_transfer_recycle_search(db, client, tmp_path):
    source_root, target_root = tmp_path / "movies", tmp_path / "target"
    source_id = await _library(client, source_root)
    target_id = await _library(client, target_root)
    folder = source_root / "星际验收 (2020)"
    folder.mkdir()
    video = folder / "messy.mkv"
    video.write_bytes(b"movie")
    video.with_suffix(".zh.srt").write_text("subtitle", encoding="utf-8")
    (folder / "movie.nfo").write_text(
        "<movie><title>星际验收</title><tmdbid>101</tmdbid></movie>", encoding="utf-8"
    )
    # 另一个在位视频让缺失检测面对真实的非空库；其未识别身份不应混入搜索。
    (source_root / "unknown.mkv").write_bytes(b"unknown")
    result = await _run_job(client, f"/api/v1/libraries/{source_id}/scan")
    assert result["identified"] == 1
    hit = (await _search(client, "xjys"))["items"][0]
    item_id = hit["item"]["media_item_id"]
    await _indexed(client, "xjys", item_id)
    await _indexed(client, "诺兰", item_id)

    preview = await client.post(f"/api/v1/libraries/{source_id}/file-organization-preview")
    assert preview.status_code == 200, preview.text
    result = await _run_job(client, f"/api/v1/libraries/{source_id}/file-organizations")
    assert result["renamed"] == 1 and result["errors"] == []
    tidy = folder / "星际验收 (2020).mkv"
    assert tidy.read_bytes() == b"movie"
    assert tidy.with_suffix(".zh.srt").exists()
    await _indexed(client, "xjys", item_id)

    renamed = tidy.with_name("外部改名.mkv")
    tidy.rename(renamed)
    await _run_job(client, f"/api/v1/libraries/{source_id}/scan")
    async with db.session() as session:
        row = (
            (await session.execute(select(LibraryFile).where(LibraryFile.media_item_id == item_id)))
            .scalars()
            .one()
        )
        file_id = row.id
        assert row.file_path == str(renamed)
    await _indexed(client, "xjys", item_id)

    backup = tmp_path / "absent.mkv"
    renamed.rename(backup)
    await _run_job(client, f"/api/v1/libraries/{source_id}/scan")
    assert (await _search(client, "xjys"))["items"] == []
    assert (await _search(client, "诺兰"))["people"] == []
    backup.rename(renamed)
    await _run_job(client, f"/api/v1/libraries/{source_id}/scan")
    await _indexed(client, "xjys", item_id)

    result = await _run_job(
        client,
        f"/api/v1/libraries/{source_id}/items/{item_id}/transfers",
        json={"target_library_id": target_id},
    )
    assert result["files_relocated"] == 1 and result["errors"] == []
    assert (target_root / folder.name / renamed.name).read_bytes() == b"movie"
    hit = (await _search(client, "xjys"))["items"][0]
    assert hit["library_ids"] == [target_id] and hit["item"]["library_id"] == target_id

    async def recycle():
        async with db.session() as session:
            row = await session.get(LibraryFile, file_id)
            assert (
                await recycle_file(
                    session,
                    row,
                    reason="upgrade_replaced",
                    trigger={"kind": "system", "label": "搜索生命周期验收"},
                    note="测试回收",
                )
                == "moved_to_trash"
            )
            await session.commit()
            return Path(row.file_path)

    trash = await recycle()
    assert trash.exists() and (await _search(client, "xjys"))["items"] == []
    base = f"/api/v1/libraries/{target_id}/items/{item_id}/files/{file_id}"
    restored = await client.post(base + "/restore")
    assert restored.status_code == 200, restored.text
    await _indexed(client, "xjys", item_id)
    trash = await recycle()
    purged = await client.post(base + "/purge")
    assert purged.status_code == 200, purged.text
    assert not trash.exists() and (await _search(client, "xjys"))["items"] == []
    await media_scrape.cleanup_orphan_items([item_id])
    while await refresh_index_batch():
        pass
    assert (await _search(client, "诺兰"))["people"] == []


@pytest.mark.parametrize("strategy", ["hardlink", "copy"])
async def test_ingest_job_makes_new_item_searchable(db, client, tmp_path, strategy):
    root, watch = tmp_path / "movies", tmp_path / "watch"
    library_id = await _library(client, root)
    entry = watch / "星际验收 (2020)"
    entry.mkdir(parents=True)
    source = entry / "source.mkv"
    source.write_bytes(b"video")
    (entry / "movie.nfo").write_text(
        "<movie><title>星际验收</title><tmdbid>101</tmdbid></movie>", encoding="utf-8"
    )
    rule = ImportWatch(source_path=str(watch), strategy=strategy, library_id=library_id)
    async with db.session() as session:
        session.add(rule)
        await session.commit()
    assert (await _search(client, "xjys"))["items"] == []
    for _ in range(2):
        async with db.session() as session:
            library = await session.get(Library, library_id)
        await ingest._sweep_dir(rule, library)
    for _ in range(500):
        async with db.session() as session:
            job = await jobs.latest_job_for_resource(
                session, "ingest_entry", 1, job_type="library.ingest"
            )
        if job and job.status is JobStatus.SUCCEEDED:
            break
        assert not job or job.status not in {JobStatus.FAILED, JobStatus.BLOCKED}, job
        await asyncio.sleep(0.01)
    else:
        raise AssertionError("入库作业未完成")
    target = root / "星际验收 (2020)" / "星际验收 (2020).mkv"
    assert target.read_bytes() == source.read_bytes() == b"video"
    assert (target.stat().st_ino == source.stat().st_ino) is (strategy == "hardlink")
    async with db.session() as session:
        row = (await session.execute(select(LibraryFile))).scalars().one()
        record = (await session.execute(select(IngestEntry))).scalars().one()
        assert record.status == "imported" and row.resolution == "1080p"
    await _indexed(client, "xjys", row.media_item_id)
    await _indexed(client, "诺兰", row.media_item_id)


async def test_local_nfo_refresh_and_rollback_keep_search_consistent(db, client, tmp_path):
    """NFO 真实改名立即覆盖旧索引；业务事务回滚同时撤销名称和 dirty 标记。"""
    root = tmp_path / "home"
    library_id = await _library(client, root, kind="video")
    video = root / "录像.mkv"
    video.write_bytes(b"video")
    nfo = video.with_suffix(".nfo")
    nfo.write_text("<movie><title>旧片名验收</title></movie>", encoding="utf-8")
    await _run_job(client, f"/api/v1/libraries/{library_id}/scan")
    item_id = (await _search(client, "jpmys"))["items"][0]["item"]["media_item_id"]
    await _indexed(client, "jpmys", item_id)
    nfo.write_text("<movie><title>新片名验收</title></movie>", encoding="utf-8")
    assert await media_scrape.reread_local_nfo(item_id)
    assert (await _search(client, "jpmys"))["items"] == []
    await _indexed(client, "xpmys", item_id)
    async with db.session() as session:
        item = await session.get(MediaItem, item_id)
        item.title = "回滚片名验收"
        item.original_title = item.title
        await session.flush()
        await session.rollback()
    assert (await _search(client, "hgpmys"))["items"] == []
    assert (await _search(client, "xpmys"))["index_pending"] is False
    await _indexed(client, "xpmys", item_id)


async def test_background_index_and_scan_writes_can_complete_together(db, client, tmp_path):
    """批量索引占用同一 SQLite 时，扫描和改名仍可提交，最终名称不会被旧批次覆盖。"""
    from sqlalchemy import text

    from movieclaw_api.services.library.search_index import close_search_index, start_search_index

    library_id = await _library(client, tmp_path / "home", kind="video")
    async with db.session() as session:
        session.add_all(
            [
                MediaItem(
                    kind="movie",
                    tmdb_id=10000 + i,
                    title=f"索引构建验收{i}",
                    original_title=f"索引构建验收{i}",
                )
                for i in range(450)
            ]
        )
        await session.commit()
    video = tmp_path / "home" / "录像.mkv"
    video.write_bytes(b"video")
    video.with_suffix(".nfo").write_text(
        "<movie><title>并发扫描验收</title></movie>", encoding="utf-8"
    )
    start_search_index()
    try:
        await _run_job(client, f"/api/v1/libraries/{library_id}/scan")
        item_id = (await _search(client, "bfsmys"))["items"][0]["item"]["media_item_id"]
        video.with_suffix(".nfo").write_text(
            "<movie><title>并发改名验收</title></movie>", encoding="utf-8"
        )
        assert await media_scrape.reread_local_nfo(item_id)
        assert (await _search(client, "bfsmys"))["items"] == []
        assert (await _search(client, "bfgmys"))["items"][0]["item"]["media_item_id"] == item_id
        for _ in range(500):
            async with db.session() as session:
                pending = await session.scalar(text("SELECT count(*) FROM library_search_dirty"))
            if not pending:
                break
            await asyncio.sleep(0.01)
        else:
            raise AssertionError("后台索引未能消费扫描与改名产生的所有变更")
        assert (await _search(client, "bfsmys"))["items"] == []
        assert (await _search(client, "bfgmys"))["index_pending"] is False
    finally:
        await close_search_index()

"""#1164：忽略目录复用后，下载完成 → 巡检 → HTTP 告警 → 手动恢复。

使用真实文件、数据库、监听巡检、下载巡检和 HTTP 路由；仅下载器边界打桩。
"""

from datetime import timedelta

import httpx
import pytest
from fastapi import FastAPI
from sqlmodel import select
from tests.api.test_download_health import _seed
from tests.api.test_library_ingest import _get_library, _make_rule
from tests.api.test_library_ingest import db as db

from movieclaw_api.api.routes.import_watch import router as watch_router
from movieclaw_api.api.routes.system_notices import router as notice_router
from movieclaw_api.services import acquisition_ingest, download_progress
from movieclaw_api.services.download_tasks import _landing_errors
from movieclaw_api.services.library import ingest
from movieclaw_db.engine import get_session
from movieclaw_db.models import (
    ActivityType,
    DownloaderClient,
    ImportWatch,
    IngestEntry,
    IngestStatus,
    Job,
    LibraryFile,
    NoticeStatus,
    Subscription,
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    SystemNotice,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_downloader import TorrentBrief, TorrentStatus
from movieclaw_downloader.models import TorrentFile


@pytest.mark.asyncio
async def test_ignored_new_episode_is_visible_and_manual_restore_clears_notice(
    db, tmp_path, monkeypatch
):
    info_hash = "a" * 40
    stale = utcnow() - timedelta(minutes=download_progress._LANDING_GRACE_MINUTES + 5)
    sub_id, wanted_id = await _seed(
        db, tmdb_id=1, title="剧A", info_hash=info_hash, grabbed_at=stale
    )
    watch = tmp_path / "downloads"
    entry = watch / "Show"
    entry.mkdir(parents=True)
    (entry / "Show.S01E00.mkv").write_bytes(b"existing ignored content")
    async with db.session() as session:
        sub = await session.get(Subscription, sub_id)
        library_id = sub.library_id
        downloader = DownloaderClient(
            name="qb",
            client_type="qbittorrent",
            url="http://downloader.invalid",
            status=ConfigStatus.ACTIVE,
            path_mappings=[{"local": str(watch), "remote": "/downloads"}],
        )
        record = IngestEntry(entry_path=str(entry), fingerprint="old", status=IngestStatus.PENDING)
        session.add_all([downloader, record])
        await session.commit()
        entry_id = record.id
    await _make_rule(db, library_id=library_id, source=watch)
    async with db.session() as session:
        rule = (await session.execute(select(ImportWatch))).scalar_one()
    library = await _get_library(db, library_id)

    async def session_override():
        async with db.session() as session:
            yield session

    app = FastAPI()
    app.include_router(watch_router, prefix="/api/v1")
    app.include_router(notice_router, prefix="/api/v1")
    app.dependency_overrides[get_session] = session_override
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        ignored = await client.post(f"/api/v1/import-watch/entries/{entry_id}/ignore")
        assert ignored.status_code == 200
        source = entry / "Show.S01E01.mkv"
        original = b"new downloaded episode"
        source.write_bytes(original)
        status = TorrentStatus(
            name="Show",
            info_hash=info_hash,
            completed=True,
            progress=1.0,
            save_path="/downloads",
            size_bytes=len(original),
            state="completed",
            files=[TorrentFile(path="Show/Show.S01E01.mkv", size_bytes=len(original))],
        )

        async def lookup(*args, **kwargs):
            return download_progress._TorrentLookup(match=(downloader, status), reachable_count=1)

        async def briefs():
            return [
                TorrentBrief(name="Show", content_name="Show", info_hash=info_hash, completed=True)
            ]

        monkeypatch.setattr(download_progress, "_lookup_torrent", lookup)
        monkeypatch.setattr(acquisition_ingest, "downloader_briefs", briefs)
        await ingest._sweep_dir(rule, library)
        for _ in range(2):
            await download_progress.check_download_progress()
        response = await client.get("/api/v1/system/notices")
        assert response.status_code == 200
        [notice] = response.json()["data"]
        assert notice["payload"]["ignored_paths"] == [str(entry)]
        assert "S01E01" in notice["message"] and "被跳过" in notice["message"]
        assert str(entry) in notice["message"] and "恢复该条目后等待巡检" in notice["message"]
        assert "设置 → 自动入库" in notice["message"]
        async with db.session() as session:
            assert (await _landing_errors(session))[(sub_id, info_hash)] == notice["message"]
            assert (await session.get(IngestEntry, entry_id)).status == IngestStatus.IGNORED
            assert (await session.get(WantedItem, wanted_id)).status == WantedStatus.GRABBED
            assert (
                await session.execute(select(SubscriptionDownloadAttempt))
            ).scalar_one().status == "completed"
            [activity] = (
                (
                    await session.execute(
                        select(SubscriptionActivity).where(
                            SubscriptionActivity.type == ActivityType.IMPORT_FAILED
                        )
                    )
                )
                .scalars()
                .all()
            )
            assert activity.payload["reason"] == "ingest_ignored"
            assert activity.message == notice["message"]
            assert activity.payload["ignored_paths"] == [str(entry)]
            assert not (await session.execute(select(Job))).scalars().all()
            assert not (await session.execute(select(LibraryFile))).scalars().all()
        assert source.read_bytes() == original

        # 手动忽略告警后，重复巡检不应先消退再重新点亮、反复打扰用户。
        dismissed = await client.post(f"/api/v1/system/notices/{notice['id']}/dismiss")
        assert dismissed.status_code == 200
        await download_progress.check_download_progress()
        assert (await client.get("/api/v1/system/notices")).json()["data"] == []
        async with db.session() as session:
            assert (await session.get(SystemNotice, notice["id"])).status == NoticeStatus.DISMISSED

        restored = await client.post(f"/api/v1/import-watch/entries/{entry_id}/restore")
        assert restored.status_code == 200
        await download_progress.check_download_progress()
        assert (await client.get("/api/v1/system/notices")).json()["data"] == []
        async with db.session() as session:
            assert (await session.get(SystemNotice, notice["id"])).status == NoticeStatus.RESOLVED
            assert await _landing_errors(session) == {}
            assert (await session.get(IngestEntry, entry_id)).status == IngestStatus.PENDING
            assert (await session.get(WantedItem, wanted_id)).status == WantedStatus.GRABBED
        assert source.read_bytes() == original

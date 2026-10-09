"""二 A 新增的宿主操作（docs/design/plugin-phase2a.md §5.3）：关联查询、删除演练、按目录扫描。

走真实应用的 HTTP 接口（管理员身份），与插件经宿主操作调用的是同一条路。
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select
from tests.api.test_domain_events import seed_show

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events
from movieclaw_db.engine import get_database
from movieclaw_db.models import Job, LibraryFile, ManualDownloadIntent


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ops.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    with TestClient(app) as c:
        yield c
    get_settings.cache_clear()
    durable_events.reset_state()


def seed(client, tmp_path) -> dict:
    return client.portal.call(seed_show, get_database(), tmp_path)


# ---------------------------------------------------------------------- 关联
def test_relations_list_subscription_and_torrents(client, tmp_path) -> None:
    seeded = seed(client, tmp_path)

    async def add_manual_intent() -> None:
        async with get_database().session() as session:
            session.add(
                ManualDownloadIntent(
                    info_hash="extrahash",
                    media_item_id=seeded["item_id"],
                    library_id=seeded["library_id"],
                    downloader_id=seeded["downloader_id"],
                    download_name="Test.Show.S01E03",
                )
            )
            await session.commit()

    client.portal.call(add_manual_intent)
    resp = client.get(
        f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}/relations"
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["subscription_id"] == seeded["sub_id"]
    assert data["subscription_status"] == "active"
    by_hash = {t["info_hash"]: t for t in data["torrents"]}
    assert by_hash.keys() == {"packhash", "extrahash"}
    pack = by_hash["packhash"]
    assert pack["source"] == "subscription" and pack["downloader_name"] == "qb"
    assert pack["owned_by_movieclaw"] is True and pack["hit_and_run"] is False
    assert pack["units"] == [[1, 1], [1, 2]]
    assert sorted(pack["file_ids"]) == sorted(seeded["file_ids"])
    assert by_hash["extrahash"]["source"] == "manual"

    missing = client.get(f"/api/v1/libraries/{seeded['library_id']}/items/99999/relations")
    assert missing.status_code == 404


# ---------------------------------------------------------------------- 删除演练
def test_delete_dry_run_reports_without_touching_anything(client, tmp_path) -> None:
    seeded = seed(client, tmp_path)
    base = f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}"

    one = client.delete(f"{base}/files/{seeded['file_ids'][0]}", params={"dry_run": True})
    assert one.status_code == 200, one.text
    plan = one.json()["data"]
    assert plan["dry_run"] is True
    assert plan["removed_paths"] == [str(seeded["paths"][0])]
    assert plan["rows_deleted"] == 1 and plan["freed_bytes"] == 2

    whole = client.delete(base, params={"dry_run": True})
    assert whole.status_code == 200, whole.text
    plan = whole.json()["data"]
    assert plan["dry_run"] is True and plan["rows_deleted"] == 2
    # 条目目录里只有这一个条目：整删目录（与真删同一套分组判定）
    assert plan["removed_paths"] == [str(Path(seeded["paths"][0]).parent.parent)]
    assert "演练" in whole.json()["message"]

    assert all(path.exists() for path in seeded["paths"])

    async def rows() -> int:
        async with get_database().session() as session:
            return len((await session.execute(select(LibraryFile))).scalars().all())

    assert client.portal.call(rows) == 2

    # 真删：同一条接口不带 dry_run 照常删除
    real = client.delete(base)
    assert real.status_code == 200 and real.json()["data"]["dry_run"] is False
    assert not seeded["paths"][0].exists()


def test_torrent_delete_dry_run_shows_what_would_be_requeued(client, tmp_path, monkeypatch) -> None:
    from movieclaw_api.services import download_tasks
    from movieclaw_db.models import WantedItem, WantedStatus
    from movieclaw_downloader import TorrentStatus

    seeded = seed(client, tmp_path)

    async def add_wanted() -> None:
        async with get_database().session() as session:
            session.add(
                WantedItem(
                    subscription_id=seeded["sub_id"],
                    media_item_id=seeded["item_id"],
                    season_number=1,
                    episode_number=2,
                    status=WantedStatus.GRABBED,
                    info_hash="packhash",
                )
            )
            await session.commit()

    client.portal.call(add_wanted)
    deleted: list[str] = []

    class FakeAdapter:
        async def get_torrent(self, info_hash, *, include_files=True):
            return TorrentStatus(
                info_hash=info_hash,
                name="Test.Show.S01.1080p",
                progress=0.5,
                completed=False,
                save_path="/downloads",
                files=[],
            )

        async def delete_torrent(self, info_hash, *, delete_files=False):
            deleted.append(info_hash)

        async def close(self):
            return None

    monkeypatch.setattr(download_tasks, "create_downloader", lambda config: FakeAdapter())
    monkeypatch.setattr(
        download_tasks.DownloaderRepository, "decrypted_password", lambda self, row: None
    )
    resp = client.delete(
        f"/api/v1/downloaders/{seeded['downloader_id']}/torrents/{'a' * 40}",
        params={"dry_run": True},
    )
    assert resp.status_code == 200, resp.text
    plan = resp.json()["data"]
    assert plan["dry_run"] is True and plan["exists"] is True
    assert plan["requeued_units"] == [] and plan["cancelled_attempts"] == 0

    # 真实存在关联的 hash：演练说清楚会退回哪些集，但下载器任务一个都没删
    attempts_hash = "b" * 40

    async def rehash() -> None:
        from sqlalchemy import update

        from movieclaw_db.models import SubscriptionDownloadAttempt

        async with get_database().session() as session:
            await session.execute(
                update(SubscriptionDownloadAttempt).values(info_hash=attempts_hash)
            )
            await session.execute(update(WantedItem).values(info_hash=attempts_hash))
            await session.commit()

    client.portal.call(rehash)
    resp = client.delete(
        f"/api/v1/downloaders/{seeded['downloader_id']}/torrents/{attempts_hash}",
        params={"dry_run": True},
    )
    plan = resp.json()["data"]
    assert plan["requeued_units"] == [[1, 2]]
    assert plan["title"] == "Test.Show.S01.1080p"
    assert deleted == []


# ---------------------------------------------------------------------- 按目录扫描
def test_scan_can_be_scoped_to_entry_directories(client, tmp_path, monkeypatch) -> None:
    import asyncio

    import movieclaw_api.services.library.scan as scan_mod

    scanned: list[dict] = []

    async def fake_scan(library_id, **kwargs):
        scanned.append(kwargs)
        return scan_mod.ScanSummary()

    # 只验证作业把范围交给了扫描；真扫描会去连 TMDB
    monkeypatch.setattr(scan_mod, "scan_library", fake_scan)
    seeded = seed(client, tmp_path)
    episode = seeded["paths"][0]
    entry = episode.parent.parent  # 「测试剧集 (2024)」——库根下第一级

    resp = client.post(
        f"/api/v1/libraries/{seeded['library_id']}/scan", json={"paths": [str(episode)]}
    )
    assert resp.status_code == 202, resp.text
    assert "1 个目录" in resp.json()["data"]["message"]

    async def scan_jobs() -> list[Job]:
        async with get_database().session() as session:
            return list(
                (await session.execute(select(Job).where(Job.job_type == "library.scan"))).scalars()
            )

    [job] = client.portal.call(scan_jobs)
    assert job.input_data["scope_paths"] == [str(entry)]
    assert job.input_data["backfill_existing_specs"] is False

    async def ran() -> None:
        async with asyncio.timeout(10):
            while not scanned:
                await asyncio.sleep(0.05)

    client.portal.call(ran)
    assert scanned[0]["scope_paths"] == {str(entry)}
    assert scanned[0]["backfill_existing_specs"] is False

    outside = client.post(
        f"/api/v1/libraries/{seeded['library_id']}/scan", json={"paths": ["/elsewhere/x.mkv"]}
    )
    assert outside.status_code == 400
    relative = client.post(
        f"/api/v1/libraries/{seeded['library_id']}/scan", json={"paths": ["relative/x"]}
    )
    assert relative.status_code == 400
    # 不带范围照旧整库扫描（另一个作业，不与范围扫描去重）
    whole = client.post(f"/api/v1/libraries/{seeded['library_id']}/scan")
    assert whole.status_code == 202
    assert "目录" not in whole.json()["data"]["message"]

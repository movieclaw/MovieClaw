"""删片时「同时删除下载任务和源文件」（docs/design/library-boundary.md §4；issue #622），端到端。

真实应用 + 内置下载模块登记的删除参与方，下载器换成记录调用的假实现，走 HTTP：
删除预览里的选项与说明 → 勾选删除 → 后续任务删种 → 结果与来源记录清理；以及各种不能删的情况。
"""

from __future__ import annotations

import asyncio
import os
import time
from functools import partial

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select
from tests.api.test_domain_events import seed_shared_pack, seed_show

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import download_tasks, durable_events, jobs
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    DownloadFileSource,
    JobStatus,
    LibraryFile,
    SubscriptionDownloadAttempt,
    SystemNotice,
)

ADMIN = {"username": "admin", "password": "s3cret-pass"}
HASH = "c" * 40
KEY = "downloads:remove-source"


class FakeDownloader:
    def __init__(self) -> None:
        self.deleted: list[tuple[str, bool]] = []
        self.missing: set[str] = set()
        self.fail_delete = False

    def adapter(self, config):
        fake = self

        class Adapter:
            async def get_torrent(self, info_hash, *, include_files=True):
                from movieclaw_downloader import TorrentStatus

                if info_hash in fake.missing:
                    return None
                return TorrentStatus(
                    info_hash=info_hash,
                    name="Test.Show.S01.1080p",
                    progress=1.0,
                    completed=True,
                    save_path="/downloads",
                    files=[],
                )

            async def delete_torrent(self, info_hash, *, delete_files=False):
                if fake.fail_delete:
                    from movieclaw_downloader import DownloaderException

                    raise DownloaderException("下载器拒绝了请求")
                fake.deleted.append((info_hash, delete_files))

            async def close(self):
                return None

        return Adapter()


@pytest.fixture
def downloader(monkeypatch) -> FakeDownloader:
    fake = FakeDownloader()
    monkeypatch.setattr(download_tasks, "create_downloader", fake.adapter)
    monkeypatch.setattr(
        download_tasks.DownloaderRepository, "decrypted_password", lambda self, row: None
    )
    return fake


@pytest.fixture
def client(tmp_path, monkeypatch, downloader):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'remove.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import reset_auth_state

    reset_auth_state()
    app = create_app()
    with TestClient(app) as test_client:
        resp = test_client.post("/api/v1/auth/bootstrap", json=ADMIN)
        assert resp.status_code == 200, resp.text
        yield test_client
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


def wait_until(client: TestClient, check, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        call(client, asyncio.sleep, 0.05)
    raise AssertionError("等待超时")


async def job_status(job_id: str) -> str:
    async with get_database().session() as session:
        return (await jobs.get_job(session, job_id)).status


async def job_row(job_id: str):
    async with get_database().session() as session:
        return await jobs.get_job(session, job_id)


async def sources() -> list[int]:
    async with get_database().session() as session:
        return [
            r.library_file_id for r in (await session.execute(select(DownloadFileSource))).scalars()
        ]


async def notices() -> list[SystemNotice]:
    async with get_database().session() as session:
        return list((await session.execute(select(SystemNotice))).scalars())


async def set_attempt(**values) -> None:
    async with get_database().session() as session:
        for attempt in (await session.execute(select(SubscriptionDownloadAttempt))).scalars():
            for key, value in values.items():
                setattr(attempt, key, value)
        await session.commit()


async def forget_sources() -> None:
    """模拟扫描进来、不知道来源的文件。"""
    async with get_database().session() as session:
        for row in (await session.execute(select(DownloadFileSource))).scalars():
            await session.delete(row)
        for row in (await session.execute(select(LibraryFile))).scalars():
            row.info_hash = None
        await session.commit()


def base(seeded: dict) -> str:
    return f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}"


def option(client: TestClient, seeded: dict, file_id: int | None = None) -> dict:
    params = {"file_id": file_id} if file_id is not None else {}
    resp = client.get(f"{base(seeded)}/delete-preview", params=params)
    assert resp.status_code == 200, resp.text
    [found] = [o for o in resp.json()["data"]["options"] if o["key"] == KEY]
    return found


def seed_linked_show(client: TestClient, tmp_path) -> dict:
    seeded = call(client, seed_show, get_database(), tmp_path, info_hash=HASH)
    downloads = tmp_path / "downloads"
    downloads.mkdir()
    for i, path in enumerate(seeded["paths"]):
        os.link(path, downloads / f"e{i}.mkv")  # 硬链接入库
    return seeded


def test_whole_item_delete_removes_the_torrent_and_its_data(client, tmp_path, downloader) -> None:
    seeded = seed_linked_show(client, tmp_path)
    found = option(client, seeded)
    assert found["available"] is True and found["label"] == "同时删除下载任务和源文件"
    texts = [line["text"] for line in found["lines"]]
    assert any("下载器「qb」" in t and "Test.Show.S01.1080p" in t for t in texts)
    assert any("空间才真正腾出来" in t for t in texts)
    assert any("订阅还在追" in t for t in texts)
    assert found["lines"][-1] == {"text": "源文件删除后不可恢复", "tone": "danger"}

    resp = client.delete(base(seeded), params={"options": KEY})
    assert resp.status_code == 200, resp.text
    [follow] = resp.json()["data"]["follow_ups"]
    wait_until(
        client, lambda: call(client, job_status, follow["job_id"]) == JobStatus.SUCCEEDED.value
    )
    assert downloader.deleted == [(HASH, True)]
    job = call(client, job_row, follow["job_id"])
    assert "已删除 1 个下载任务和源文件" in job.result["message"]
    # 处理完了，来源记录清掉
    assert call(client, sources) == []


def test_deleting_one_episode_of_a_season_pack_is_refused(client, tmp_path, downloader) -> None:
    seeded = seed_linked_show(client, tmp_path)
    found = option(client, seeded, file_id=seeded["file_ids"][0])
    assert found["available"] is False
    assert "同一部片的另外 1 个文件" in found["reason"]
    resp = client.delete(f"{base(seeded)}/files/{seeded['file_ids'][0]}", params={"options": KEY})
    assert resp.status_code == 400
    assert seeded["paths"][0].exists() and downloader.deleted == []


def test_collection_torrent_shared_with_another_movie_is_refused(client, tmp_path) -> None:
    seeded = call(
        client, seed_shared_pack, get_database(), tmp_path, other_identified=True, info_hash=HASH
    )
    found = option(client, seeded)
    assert found["available"] is False and "《电影乙》" in found["reason"]


@pytest.mark.parametrize(
    ("values", "reason"),
    [
        ({"owned_by_movieclaw": False}, "不是 MovieClaw 投递的种子"),
        ({"hit_and_run": True}, "H&R"),
    ],
)
def test_torrents_that_are_not_ours_to_delete(client, tmp_path, values, reason) -> None:
    seeded = seed_linked_show(client, tmp_path)
    call(client, set_attempt, **values)
    found = option(client, seeded)
    assert found["available"] is False and reason in found["reason"]


def test_files_without_a_known_download_only_delete_the_library_copy(client, tmp_path) -> None:
    seeded = seed_linked_show(client, tmp_path)
    call(client, forget_sources)
    found = option(client, seeded)
    assert found["available"] is False and "没找到对应的下载任务" in found["reason"]


def test_task_already_gone_from_the_downloader(client, tmp_path, downloader) -> None:
    seeded = seed_linked_show(client, tmp_path)
    downloader.missing.add(HASH)
    found = option(client, seeded)
    assert found["available"] is False and "已经不在下载器" in found["reason"]


def test_failed_delete_fails_the_job_and_raises_a_notice(client, tmp_path, downloader) -> None:
    seeded = seed_linked_show(client, tmp_path)
    downloader.fail_delete = True  # 预览（只查任务）好好的，执行删除时下载器出错
    resp = client.delete(base(seeded), params={"options": KEY})
    assert resp.status_code == 200, resp.text
    [follow] = resp.json()["data"]["follow_ups"]
    wait_until(
        client,
        lambda: (
            call(client, job_status, follow["job_id"])
            in (JobStatus.FAILED.value, JobStatus.SUCCEEDED.value)
        ),
    )
    assert call(client, job_status, follow["job_id"]) == JobStatus.FAILED.value
    # 媒体库这边已经删了，下载器那边失败单独报告
    assert not seeded["paths"][0].exists()
    [notice] = call(client, notices)
    assert "没能全部删除" in notice.title and "媒体库文件已删除" in notice.message
    # 失败时留着来源记录，重试还用得上
    assert sorted(call(client, sources)) == sorted(seeded["file_ids"])

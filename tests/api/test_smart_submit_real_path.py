# ruff: noqa: F811
"""智能投递走真实 ``submit_torrent``：只替换站点取种与下载器协议，其余全是生产代码。

覆盖 #996（中文季集命名的整季包）、#997（确定性失败清理本次新建的暂停任务）、
#998（领域拒绝不能被包装成上游故障进入无限退避）。
"""

from __future__ import annotations

import hashlib
from datetime import timedelta
from types import SimpleNamespace

import pytest
from sqlmodel import select
from tests.api.test_smart_subscription import smart_sub
from tests.api.test_subscription_pipeline import _insert_torrent, _wanted_map, db  # noqa: F401

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.services.subscription.smart_scheduler import recover_submissions
from movieclaw_db.crypto import init_secret_box, reset_secret_box
from movieclaw_db.models import ClientType, SubscriptionDownloadAttempt, utcnow
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_db.repositories.downloader_repo import DownloaderRepository
from movieclaw_downloader.models import SubmitResult, TorrentFile, TorrentStatus
from movieclaw_downloader.torrent import compute_info_hash


def _bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(_bencode(v) for v in value) + b"e"
    return b"d" + b"".join(_bencode(k) + _bencode(v) for k, v in sorted(value.items())) + b"e"


def _torrent(name: str, files: list[str]) -> bytes:
    return _bencode(
        {
            b"info": {
                b"name": name,
                b"files": [{b"length": 1024, b"path": f.split("/")} for f in files],
                b"piece length": 16384,
                b"pieces": hashlib.sha1(name.encode()).digest(),
                b"private": 1,
            }
        }
    )


class FakeQbit:
    """按 qBittorrent 语义：已存在的任务不加标签；暂停添加；按真实索引选文件。"""

    tasks: dict[str, TorrentStatus] = {}
    files: dict[str, list[str]] = {}
    deleted: list[tuple[str, bool]] = []

    def __init__(self, _config):
        pass

    async def submit(self, request):
        info_hash = compute_info_hash(request.torrent_bytes)
        if info_hash in self.tasks:
            return SubmitResult(info_hash=info_hash, already_exists=True)
        self.tasks[info_hash] = TorrentStatus(
            info_hash=info_hash,
            name="pack",
            progress=0,
            completed=False,
            save_path=request.save_path or "/downloads",
            state="paused" if request.paused else "downloading",
            tags=list(request.tags),
            files=[
                TorrentFile(index=i, path=p, size_bytes=1024)
                for i, p in enumerate(self.files[info_hash])
            ],
        )
        return SubmitResult(info_hash=info_hash, name="pack")

    async def get_torrent(self, info_hash, include_files=False):
        task = self.tasks.get(info_hash)
        return task.model_copy(deep=True) if task else None

    async def set_file_selection(self, info_hash, indices):
        for f in self.tasks[info_hash].files:
            f.selected = f.index in indices

    async def resume(self, info_hash):
        self.tasks[info_hash].state = "downloading"

    async def delete_torrent(self, info_hash, *, delete_files=False):
        self.deleted.append((info_hash, delete_files))
        self.tasks.pop(info_hash, None)

    async def close(self):
        pass


@pytest.fixture
async def real_path(db, monkeypatch, tmp_path):
    FakeQbit.tasks, FakeQbit.files, FakeQbit.deleted = {}, {}, []
    blobs: dict[str, bytes] = {}

    async def get_site(_site):
        async def download_torrent(url):
            return blobs[url]

        return SimpleNamespace(download_torrent=download_torrent)

    monkeypatch.setattr(
        "movieclaw_api.services.torrent_submit.get_site_access",
        lambda: SimpleNamespace(get=get_site),
    )
    monkeypatch.setattr("movieclaw_api.services.torrent_submit.create_downloader", FakeQbit)
    monkeypatch.setattr(
        "movieclaw_api.services.subscription.smart_submission.create_downloader",
        FakeQbit,
        raising=False,
    )
    monkeypatch.setattr("movieclaw_downloader.factory.create_downloader", FakeQbit)
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "false")
    get_settings.cache_clear()
    reset_secret_box()
    init_secret_box(None, tmp_path / "t.secret")
    async with db.session() as session:
        row = await DownloaderRepository(session).create(
            name="qBittorrent",
            client_type=ClientType.QBITTORRENT,
            url="http://qbit.invalid",
            username="admin",
            password="x",
            save_path="/downloads",
        )
        row.status = ConfigStatus.ACTIVE
        await session.commit()

    async def pack(session, torrent_id, title, files):
        blob = _torrent(title, files)
        FakeQbit.files[compute_info_hash(blob)] = [f"{title}/{f}" for f in files]
        url = f"https://test.invalid/{torrent_id}.torrent"
        blobs[url] = blob
        row = await _insert_torrent(
            session,
            torrent_id,
            title,
            {
                "media_type": "tv",
                "year": 2024,
                "seasons": [1],
                "resolution": "1080p",
                "media_source": "WEB-DL",
                "release_group": "A",
            },
        )
        row.download_url = url
        await session.commit()
        return row, compute_info_hash(blob)

    yield SimpleNamespace(db=db, pack=pack)
    reset_secret_box()


async def test_chinese_named_pack_with_stray_file_is_submitted_selectively(real_path):
    """#996：「第N季 第N集」命名 + 一个认不出的文件，需要的集都在 → 只下需要的集。"""
    async with real_path.db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        torrent, info_hash = await real_path.pack(
            session,
            "cn",
            "Test Show S01 1080p WEB-DL-A",
            [
                "测试剧集 - 第01季 第01集 国英双语 1080p.mkv",
                "测试剧集第1季 第2集_3840x2160_H265.mp4",
                "测试剧集第10季 第3集_3840x2160_H265.mp4",
                "花絮.mkv",
            ],
        )
        await evaluate_and_dispatch(session, [torrent], source="整季包")
        intent = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        assert intent.status == "active", intent.cleanup_note
        rows = await _wanted_map(session, sub.id)
        assert rows[(1, 1)].status == rows[(1, 2)].status == "grabbed"
        task = FakeQbit.tasks[info_hash]
        assert [f.selected for f in task.files] == [True, True, False, False]
        assert task.state == "downloading"


async def test_unsatisfiable_pack_removes_only_its_own_paused_task(real_path):
    """#997：文件清单证明一集都满足不了 → 意图失败，同时删掉本次新建的 0% 暂停任务。"""
    async with real_path.db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        torrent, info_hash = await real_path.pack(
            session,
            "s2only",
            "Test Show S01 1080p WEB-DL-A",
            ["Test.Show.S02E01.mkv", "Test.Show.S02E02.mkv"],
        )
        await evaluate_and_dispatch(session, [torrent], source="整季包")
        intent = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        assert intent.status == "failed" and intent.submission["stage"] == "rejected"
        assert FakeQbit.deleted == [(info_hash, False)]
        assert info_hash not in FakeQbit.tasks
        assert "暂停任务已从下载器移除" in intent.cleanup_note
        rows = await _wanted_map(session, sub.id)
        assert rows[(1, 1)].status == rows[(1, 2)].status == "wanted"


async def test_unsatisfiable_keeps_task_without_our_owner_tag(real_path):
    """#997 安全边界：任务不带本次所有权标签（用户自己的在途任务）→ 不删。"""
    async with real_path.db.session() as session:
        await smart_sub(session, wait_seconds=0)
        torrent, info_hash = await real_path.pack(
            session,
            "s2only",
            "Test Show S01 1080p WEB-DL-A",
            ["Test.Show.S02E01.mkv", "Test.Show.S02E02.mkv"],
        )
        await evaluate_and_dispatch(session, [torrent], source="整季包")
        intent = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        assert intent.status == "failed"
        # 直接调用清理，模拟任务已被用户接手（标签被摘掉 / 已开始下载）
        from movieclaw_api.services.subscription.smart_submission import remove_own_paused_task

        FakeQbit.tasks[info_hash] = TorrentStatus(
            info_hash=info_hash,
            name="pack",
            progress=0,
            completed=False,
            save_path="/downloads",
            state="paused",
            tags=["user"],
        )
        assert not await remove_own_paused_task(session, intent)
        FakeQbit.tasks[info_hash].tags = [intent.submission["selection_owner"]]
        FakeQbit.tasks[info_hash].progress = 0.3
        assert not await remove_own_paused_task(session, intent)
        assert info_hash in FakeQbit.tasks


async def test_duplicate_hash_rejection_through_real_submit_is_terminal(real_path):
    """#998：prepare_remote 的领域拒绝穿过 submit_torrent 后仍是拒绝，不进退避。"""
    async with real_path.db.session() as session:
        sub = await smart_sub(session, wait_seconds=0)
        torrent, info_hash = await real_path.pack(
            session,
            "dup",
            "Test Show S01 1080p WEB-DL-A",
            ["Test.Show.S01E01.mkv", "Test.Show.S01E02.mkv"],
        )
        session.add(
            SubscriptionDownloadAttempt(
                subscription_id=sub.id,
                info_hash=info_hash,
                status="failed",
                units=[[1, 1], [1, 2]],
                last_progress_at=utcnow(),
            )
        )
        await session.commit()
        await evaluate_and_dispatch(session, [torrent], source="缺口搜索")
        intent = (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.site_id == "testsite"
                )
            )
        ).scalar_one()
        assert intent.status == "failed", intent.cleanup_note
        assert intent.submission["stage"] == "rejected"
        assert "recover_failures" not in intent.submission
        assert not FakeQbit.tasks  # 网络提交前就被拦下
        rows = await _wanted_map(session, sub.id)
        assert rows[(1, 1)].status == "wanted"
        # 被否决的候选不会被下一轮重新选中
        await recover_submissions(session, now=utcnow() + timedelta(hours=2))
        assert (
            await evaluate_and_dispatch(session, [torrent], source="重找")
        ).dispatched_units == 0

# ruff: noqa: F811
"""隔离真实下载器协议测试。显式运行 MOVIECLAW_SMART_LAB=1 pytest ... -m integration。"""

from __future__ import annotations

import asyncio
import functools
import hashlib
import http.server
import os
import re
import subprocess
import threading
from datetime import timedelta
from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest
from sqlmodel import select
from tests.api.test_smart_subscription import resource
from tests.api.test_subscription_pipeline import (
    _TV_ROUTES,
    _fake_tmdb,
    _service,
    _wanted_map,
    db,  # noqa: F401
)

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.services.subscription.smart_profiles import save_profile
from movieclaw_api.services.subscription.smart_scheduler import recover_submissions
from movieclaw_db.crypto import init_secret_box, reset_secret_box
from movieclaw_db.models import ClientType, LibraryFile, SubscriptionDownloadAttempt, utcnow
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_db.repositories.downloader_repo import DownloaderRepository
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_downloader.factory import create_downloader
from movieclaw_downloader.models import DownloaderConfig
from movieclaw_matcher.smart import SmartPreferences
from movieclaw_media.models import MediaKind

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        os.environ.get("MOVIECLAW_SMART_LAB") != "1", reason="需要显式启用隔离下载器实验"
    ),
]


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(bencode(v) for v in value) + b"e"
    return b"d" + b"".join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b"e"


async def test_real_qbittorrent_timeout_recovery_download_and_import(db, tmp_path, monkeypatch):
    name = f"movieclaw-smart-lab-{uuid4().hex[:10]}"
    seed = tmp_path / "seed"
    seed.mkdir()
    downloads = tmp_path / "downloads"
    downloads.mkdir()
    video = seed / "Test.Show.S01E01.1080p.WEB-DL-A.mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=1920x1080:rate=24",
            "-t",
            "2",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            str(video),
        ],
        check=True,
    )

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("0.0.0.0", 0), functools.partial(QuietHandler, directory=str(seed))
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    content = video.read_bytes()
    size = 16384

    def seed_torrent(video):
        return bencode(
            {
                b"info": {
                    b"length": len(content),
                    b"name": video.name.encode(),
                    b"piece length": size,
                    b"pieces": b"".join(
                        hashlib.sha1(content[n : n + size]).digest()
                        for n in range(0, len(content), size)
                    ),
                    b"private": 1,
                },
                b"url-list": [f"http://host.docker.internal:{server.server_port}/{video.name}"],
            }
        )

    torrent_bytes = seed_torrent(video)
    config = tmp_path / "config"
    (config / "qBittorrent").mkdir(parents=True)
    (config / "qBittorrent" / "qBittorrent.conf").write_text(
        "[Preferences]\nWebUI\\HostHeaderValidation=false\nWebUI\\CSRFProtection=false\n"
    )
    subprocess.run(
        [
            "docker",
            "run",
            "--detach",
            "--rm",
            "--name",
            name,
            "-e",
            "PUID=0",
            "-e",
            "PGID=0",
            "-p",
            "127.0.0.1::8080",
            "-v",
            f"{downloads}:/downloads",
            "-v",
            f"{config}:/config",
            "lscr.io/linuxserver/qbittorrent@sha256:b522f9f4b769f8f36d49d22d5eb6a92e9aa18904c6a1830b1439df511ec21983",
        ],
        check=True,
        capture_output=True,
    )
    try:
        address = subprocess.check_output(["docker", "port", name, "8080/tcp"], text=True).strip()
        url = f"http://{address}"
        password = None
        for _ in range(60):
            logs = subprocess.check_output(
                ["docker", "logs", name], text=True, stderr=subprocess.STDOUT
            )
            found = re.search(r"temporary password is provided for this session: (\S+)", logs)
            if found:
                password = re.sub(r"\x1b\[[0-9;]*m", "", found.group(1))
                break
            await asyncio.sleep(1)
        assert password, "隔离下载器未就绪"
        monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost,host.docker.internal")
        monkeypatch.setenv("no_proxy", "127.0.0.1,localhost,host.docker.internal")
        async with httpx.AsyncClient(trust_env=False) as client:
            login = await client.post(
                f"{url}/api/v2/auth/login", data={"username": "admin", "password": password}
            )
            assert login.status_code in (200, 204), login.status_code
            assert (await client.get(f"{url}/api/v2/torrents/info")).status_code == 200

        monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "false")
        get_settings.cache_clear()
        reset_secret_box()
        init_secret_box(None, tmp_path / "lab.secret")

        async def download_torrent(_url):
            return torrent_bytes

        async def get_site(_site):
            return SimpleNamespace(download_torrent=download_torrent)

        monkeypatch.setattr(
            "movieclaw_api.services.torrent_submit.get_site_access",
            lambda: SimpleNamespace(get=get_site),
        )
        monkeypatch.setattr(
            "movieclaw_api.services.media_discover.get_tmdb_client",
            lambda: _fake_tmdb(
                {**_TV_ROUTES, "/3/search/tv": {"results": [_TV_ROUTES["/3/tv/200"]]}}
            ),
        )
        monkeypatch.setattr(
            "movieclaw_api.services.library.scan.get_tmdb_client",
            lambda: _fake_tmdb(
                {**_TV_ROUTES, "/3/search/tv": {"results": [_TV_ROUTES["/3/tv/200"]]}}
            ),
        )
        real_factory = create_downloader
        lost = False

        class LoseResponse:
            def __init__(self, config):
                self.real = real_factory(config)

            def __getattr__(self, key):
                return getattr(self.real, key)

            async def submit(self, request):
                nonlocal lost
                result = await self.real.submit(request)
                if not lost:
                    lost = True
                    raise TimeoutError("injected after real acceptance")
                return result

        monkeypatch.setattr("movieclaw_api.services.torrent_submit.create_downloader", LoseResponse)
        async with db.session() as session:
            library = await LibraryRepository(session).create(
                name="实验剧集库", kind="tv", root_paths=[str(downloads)]
            )
            downloader = await DownloaderRepository(session).create(
                name="隔离下载器",
                client_type=ClientType.QBITTORRENT,
                url=url,
                username="admin",
                password=password,
                save_path=str(downloads),
                path_mappings=[{"local": str(downloads), "remote": "/downloads"}],
            )
            downloader.status = ConfigStatus.ACTIVE
            await session.commit()
            await save_profile(
                session, "tv", SmartPreferences(resolution="2160p", wait_seconds=0), 0
            )
            sub = await _service(session).create(
                MediaKind.TV,
                200,
                selected_seasons=[1],
                library_id=library.id,
                selection_mode="smart",
                smart_profile_revision=1,
            )
            sub_id, library_id = sub.id, library.id
            row = await resource(session)
            row.download_url = "https://test.invalid/own-fixture.torrent"
            await session.commit()
            result = await evaluate_and_dispatch(session, [row], source="真实下载器实验")
            assert result.dispatched_units == 0 and lost
            intent = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
            assert intent.status == "submitting"
            info_hash = intent.info_hash

        # 响应丢失后站点离线、用户暂停：只读对账仍必须找回已接收任务。
        async def offline(_url):
            raise AssertionError("已有指纹的恢复不应再次取种")

        async def offline_site(_site):
            return SimpleNamespace(download_torrent=offline)

        monkeypatch.setattr(
            "movieclaw_api.services.torrent_submit.get_site_access",
            lambda: SimpleNamespace(get=offline_site),
        )
        from movieclaw_db.models import Subscription

        async with db.session() as session:
            paused = await session.get(Subscription, sub_id)
            paused.status = "paused"
            await session.commit()
        # 新数据库会话模拟进程重启；保留的是同一 hash，不重新选资源。
        async with db.session() as session:
            await recover_submissions(session, now=utcnow() + timedelta(minutes=2))
            intents = (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()
            assert len(intents) == 1 and intents[0].status == "submitting"
            assert intents[0].info_hash == info_hash
            sub = await session.get(Subscription, sub_id)
            assert sub.status == "paused"
            sub.status = "active"
            await session.commit()
        async with db.session() as session:
            await recover_submissions(session, now=utcnow() + timedelta(minutes=4))
            intents = (await session.execute(select(SubscriptionDownloadAttempt))).scalars().all()
            assert len(intents) == 1 and intents[0].status == "active"
        adapter = real_factory(
            DownloaderConfig(type="qbittorrent", url=url, username="admin", password=password)
        )
        for _ in range(120):
            status = await adapter.get_torrent(info_hash)
            if status and status.completed:
                break
            await asyncio.sleep(1)
        assert status and status.completed, "真实测试视频未完成下载"
        async with httpx.AsyncClient() as client:
            await client.post(
                f"{url}/api/v2/auth/login", data={"username": "admin", "password": password}
            )
            assert len((await client.get(f"{url}/api/v2/torrents/info")).json()) == 1
        from movieclaw_api.services.download_progress import check_download_progress
        from movieclaw_api.services.library.scan import scan_library

        await check_download_progress()
        # 下载已由真实客户端确认完成；推进文件静默时间，避免测试空等五分钟。
        import time

        for downloaded in downloads.rglob("*.mkv"):
            os.utime(downloaded, (time.time() - 600, time.time() - 600))
        summary = await scan_library(library_id, raise_unexpected=True)
        async with db.session() as session:
            wanted = (await _wanted_map(session, sub_id))[(1, 1)]
            files = (
                (
                    await session.execute(
                        select(LibraryFile).where(LibraryFile.media_item_id == wanted.media_item_id)
                    )
                )
                .scalars()
                .all()
            )
            assert wanted.status == "imported", (
                summary,
                [(f.file_path, f.resolution) for f in files],
            )
            assert wanted.quality["resolution"] == "1080p"
            assert not wanted.selection_state.get("target_reached")
            old_paths = [f.file_path for f in files]
            old_hash = wanted.info_hash

        # 第二次真实下载宣称 4K，文件仍为 1080p；核验必须保留已入库版本。
        bad_video = seed / "Test.Show.S01E01.2160p.WEB-DL-B.mkv"
        bad_video.write_bytes(content)
        torrent_bytes = seed_torrent(bad_video)
        monkeypatch.setattr(
            "movieclaw_api.services.torrent_submit.get_site_access",
            lambda: SimpleNamespace(get=get_site),
        )
        async with db.session() as session:
            sub = await session.get(Subscription, sub_id)
            sub.status = "active"
            await session.commit()
            bad = await resource(session, "false-4k", "2160p", group="B")
            bad.download_url = "https://test.invalid/false-4k.torrent"
            await session.commit()
            assert (
                await evaluate_and_dispatch(session, [bad], source="真实伪品质实验")
            ).dispatched_units == 1
            attempt = (
                await session.execute(
                    select(SubscriptionDownloadAttempt).where(
                        SubscriptionDownloadAttempt.torrent_id == "false-4k"
                    )
                )
            ).scalar_one()
            bad_hash = attempt.info_hash
        for _ in range(120):
            status = await adapter.get_torrent(bad_hash)
            if status and status.completed:
                break
            await asyncio.sleep(1)
        assert status and status.completed
        await check_download_progress()
        for downloaded in downloads.rglob("*.mkv"):
            os.utime(downloaded, (time.time() - 600, time.time() - 600))
        await scan_library(library_id, raise_unexpected=True)
        from pathlib import Path

        async with db.session() as session:
            wanted = (await _wanted_map(session, sub_id))[(1, 1)]
            assert wanted.info_hash == old_hash and wanted.quality["resolution"] == "1080p"
            assert not wanted.selection_state.get("target_reached")
            assert all(Path(path).exists() for path in old_paths)

        # 真正的 18 集整包只补 16—18，HTTP webseed 提供测试自制文件。
        from movieclaw_api.services.torrent_submit import submit_torrent
        from movieclaw_downloader.torrent import compute_info_hash

        pack_name = "Cold.Hunt.S01"
        pack_dir = seed / pack_name
        pack_dir.mkdir()
        aligned = content + b"\0" * ((-len(content)) % size)
        names = [f"Cold.Hunt.S01E{i:02}.2160p.WEB-DL-UBWEB.mkv" for i in range(1, 19)]
        for file_name in names:
            (pack_dir / file_name).write_bytes(aligned)
        data = aligned * len(names)
        torrent_bytes = bencode(
            {
                b"info": {
                    b"name": pack_name,
                    b"files": [{b"length": len(aligned), b"path": [n]} for n in names],
                    b"piece length": size,
                    b"pieces": b"".join(
                        hashlib.sha1(data[n : n + size]).digest() for n in range(0, len(data), size)
                    ),
                    b"private": 1,
                },
                b"url-list": [f"http://host.docker.internal:{server.server_port}/"],
            }
        )
        pack_hash = compute_info_hash(torrent_bytes)

        # 第一次取消恢复，模拟选择已经写入后进程中断。第二次必须找回同一任务。
        async def interrupted():
            raise RuntimeError("injected before resume")

        async with db.session() as session:
            with pytest.raises(Exception, match="injected before resume"):
                await submit_torrent(
                    session,
                    site_id="testsite",
                    download_url="https://test.invalid/pack",
                    tags=["movieclaw-sub"],
                    select_units={(1, 16), (1, 17), (1, 18)},
                    known_seasons=[1],
                    selection_owner="pack-owner",
                    before_resume=interrupted,
                )
            paused = await adapter.get_torrent(pack_hash)
            assert paused.state == "paused"
            assert [f.selected for f in paused.files] == [False] * 15 + [True] * 3
            result, _ = await submit_torrent(
                session,
                site_id="testsite",
                download_url="https://test.invalid/pack",
                tags=["movieclaw-sub"],
                select_units={(1, 16), (1, 17), (1, 18)},
                known_seasons=[1],
                selection_owner="pack-owner",
            )
            assert result.info_hash == pack_hash and result.skipped_file_count == 15
        for _ in range(90):
            actual = await adapter.get_torrent(pack_hash)
            if actual and actual.completed:
                break
            await asyncio.sleep(1)
        assert actual and actual.completed
        assert all(f.completed_bytes == 0 for f in actual.files[:15])
        assert all(f.completed_bytes == f.size_bytes for f in actual.files[15:])
        assert len([t for t in await adapter.list_torrents() if t.info_hash == pack_hash]) == 1
        await adapter.close()

    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        reset_secret_box()

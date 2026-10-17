"""只在网盘上的库文件怎么取流（docs/design/cloud-storage.md §7）。

假网盘插件（主进程与独立进程各跑一遍）给的直链指向一个本地 Range 服务，并且**按 UA 签发**：
用别的 UA 去取就 403——和 115 一样。据此验证：

- 家里的设备经家里转发：服务器用自己的 UA 取链、取字节，Range 照常；
- 「总是直连」时在外面的设备 302 到用播放器 UA 签发的直链；「自动」不给不能降级的客户端直链，
  能降级的客户端同一时间只给一处；
- 同时播放数：同一路播放的几条请求共用一个名额，满了给明确的 503 原因；
- 直链按（账号、文件、UA）缓存，并发只取一次；
- 播放层的读字节入口（``media_input`` / ``open_strm_range`` / ``file_stamp``）认出网盘文件：转码、
  抽字幕、读索引都读网盘直链，缓存指纹用台账的大小与修改时间；
- 网盘要重新登录时取流给明确原因。
"""

from __future__ import annotations

import asyncio
import re
import sys
import textwrap
import threading
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events

ADMIN = {"username": "admin", "password": "s3cret-pass"}
CONTENT = bytes(range(256)) * 64  # 16 KB，按位置可辨认

PLUGIN = """
import itertools
from urllib.parse import quote

from pydantic import BaseModel

from movieclaw_sdk import plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS,
    AccountInfo,
    AuthExpired,
    Capabilities,
    DirectLink,
    DriveBackend,
    Login,
    LoginResult,
    NotFound,
    RemoteFile,
)


class Config(BaseModel):
    base: str


_links = itertools.count(1)


class FakeDrive(DriveBackend):
    type = "fake"
    title = "假网盘"
    capabilities = Capabilities(writable=True, default_qps=100.0, default_read_slots=2)
    login = Login(cookie_domains=("fake.example",))

    def __init__(self, base):
        self.base = base

    async def login_with_cookie(self, cookie_header):
        return LoginResult(user_id="u1", display_name="测试盘", credentials={"token": "ok"})

    async def account_info(self, account):
        return AccountInfo(display_name="测试盘")

    async def stat(self, account, remote_id):
        if remote_id != "f1":
            raise NotFound("没有这个文件")
        return RemoteFile(remote_id="f1", name="movie.mkv", size=16384)

    async def direct_link(self, account, remote_id, user_agent):
        if account.credentials.get("token") == "dead":
            raise AuthExpired("登录已失效")
        n = next(_links)
        return DirectLink(
            url=f"{self.base}/{remote_id}?n={n}&ua={quote(user_agent)}", expires_in=600
        )


@plugin("fake-drive", title="假网盘", config=Config)
async def apply(ctx) -> None:
    ctx.contribute(DRIVE_BACKENDS, "fake", FakeDrive(ctx.config.base))
"""


class _Cdn:
    """仿网盘 CDN：直链按 UA 签发，UA 对不上 403；只认 Range。记下每个请求。"""

    def __init__(self) -> None:
        self.requests: list[tuple[str, str | None, str | None]] = []
        cdn = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                from urllib.parse import parse_qs, urlsplit

                parts = urlsplit(self.path)
                ua = self.headers.get("User-Agent")
                cdn.requests.append((self.path, self.headers.get("Range"), ua))
                expected = parse_qs(parts.query).get("ua", [""])[0]
                if ua != expected:
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                size = len(CONTENT)
                match = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
                start = int(match.group(1)) if match else 0
                end = int(match.group(2)) if match and match.group(2) else size - 1
                body = CONTENT[start : end + 1]
                self.send_response(206 if match else 200)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Accept-Ranges", "bytes")
                if match:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.server.shutdown()


@pytest.fixture
def cdn():
    server = _Cdn()
    yield server
    server.close()


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch, cdn):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.services.drives import gateway, sources
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'drives.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    gateway.reset_state()
    sources.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "fake_drive.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: fake-drive
              local: true
              module: fake_drive
              runtime: {request.param}
              config: {{base: "{cdn.base}"}}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        login = test_client.post(
            "/api/v1/drives/accounts/cookie", json={"backend": "fake", "cookie": "UID=u1"}
        )
        assert login.status_code == 201, login.text
        test_client.account_id = login.json()["data"]["account"]["id"]  # type: ignore[attr-defined]
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    gateway.reset_state()
    sources.reset_state()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


async def _seed_cloud_file(tmp_path: Path, account_id: int) -> tuple[int, str]:
    """一个只在网盘上的库文件：本地路径不存在，副本已核验。"""
    from movieclaw_api.services.drives import sources
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import (
        FileSource,
        FileState,
        LibraryFile,
        LibraryFileReplica,
        MediaItem,
    )
    from movieclaw_db.models.base import utcnow
    from movieclaw_db.repositories.library_repo import LibraryRepository

    root = tmp_path / "cloud-lib"
    root.mkdir(exist_ok=True)
    path = root / "Movie (2024)" / "Movie (2024).mkv"
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name="网盘电影", kind="movie", root_paths=[str(root)]
        )
        item = MediaItem(kind="movie", tmdb_id=1, title="示例", original_title="Example")
        session.add(item)
        await session.flush()
        row = LibraryFile(
            library_id=library.id,
            media_item_id=item.id,
            file_path=str(path),
            size_bytes=len(CONTENT),
            file_mtime_ns=123,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="mkv",
            video_codec="h264",
            resolution="1080p",
            duration_seconds=600,
            audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
            local_bytes=False,
        )
        session.add(row)
        await session.flush()
        session.add(
            LibraryFileReplica(
                library_file_id=row.id,
                account_id=account_id,
                remote_id="f1",
                origin="imported",
                state="verified",
                size_bytes=len(CONTENT),
                verified_at=utcnow(),
            )
        )
        await session.commit()
        file_id = row.id
    await sources.refresh_file(file_id)
    return file_id, str(path)


def seed(client: TestClient, tmp_path: Path) -> tuple[int, str]:
    return call(client, _seed_cloud_file, tmp_path, client.account_id)  # type: ignore[attr-defined]


def _token(client: TestClient, file_id: int, device: str = "dev-a") -> str:
    from movieclaw_api.services.playback.signing import issue_stream_token

    return call(client, issue_stream_token, member_id=0, file_id=file_id, device_id=device)


def _stream(client: TestClient, file_id: int, *, device: str = "dev-a", **kwargs):
    token = _token(client, file_id, device)
    return client.get(
        f"/api/v1/playback/files/{file_id}/stream",
        params={"token": token},
        follow_redirects=False,
        **kwargs,
    )


def test_home_clients_get_bytes_relayed_with_the_server_user_agent(client, tmp_path, cdn):
    from movieclaw_api.services.drives.sources import SERVER_USER_AGENT

    file_id, path = seed(client, tmp_path)
    assert not Path(path).exists()
    full = _stream(client, file_id)
    assert full.status_code == 200, full.text
    assert full.content == CONTENT
    part = _stream(client, file_id, headers={"Range": "bytes=100-199", "User-Agent": "Infuse"})
    assert part.status_code == 206 and part.content == CONTENT[100:200]
    # 转发时服务器用自己的 UA 取链、取字节（按 UA 签发的直链才不会 403）；播放器的 UA 不外传
    assert {ua for _p, _r, ua in cdn.requests} == {SERVER_USER_AGENT}


def test_direct_mode_redirects_outside_clients_with_their_own_user_agent(
    client, tmp_path, cdn, monkeypatch
):
    from movieclaw_api.services.drives import sources

    file_id, _path = seed(client, tmp_path)
    monkeypatch.setattr(sources, "is_home_client", lambda host: False)
    # 默认「自动」：网页播放器不能降级，不给直链
    relayed = _stream(client, file_id, headers={"User-Agent": "Mozilla/Phone"})
    assert relayed.status_code == 200
    saved = client.put("/api/v1/playback/policy", json={"cloud_stream_mode": "direct"})
    assert saved.status_code == 200 and saved.json()["data"]["cloud_stream_mode"] == "direct"
    redirected = _stream(client, file_id, headers={"User-Agent": "Mozilla/Phone"})
    assert redirected.status_code == 302
    target = redirected.headers["location"]
    assert "ua=Mozilla/Phone" in target
    # 播放器带着自己的 UA 跟过去能取到
    import httpx

    assert httpx.get(target, headers={"User-Agent": "Mozilla/Phone"}).content == CONTENT
    # App 直连失败带 relay=1 重来：改走转发
    fallback = client.get(
        f"/api/v1/playback/files/{file_id}/stream",
        params={"token": _token(client, file_id), "relay": "1"},
        headers={"User-Agent": "Mozilla/Phone"},
        follow_redirects=False,
    )
    assert fallback.status_code == 200 and fallback.content == CONTENT


def test_auto_mode_gives_direct_links_to_one_outside_place_at_a_time(monkeypatch):
    from movieclaw_api.services.drives import sources

    sources.reset_state()
    choose = partial(
        sources.choose_direct, mode="auto", account_id=1, force_relay=False, original_link=True
    )
    assert choose(client_host="192.168.1.20", relay_fallback=True) is False, "家里一律转发"
    assert choose(client_host="8.8.8.8", relay_fallback=False) is False, "不能降级的客户端转发"
    assert choose(client_host="8.8.8.8", relay_fallback=True) is True
    assert choose(client_host="8.8.8.8", relay_fallback=True) is True, "同一处再取照常直连"
    assert choose(client_host="1.1.1.1", relay_fallback=True) is False, "第二处在外面的转发"
    assert choose(client_host="100.80.1.2", relay_fallback=True) is False, "Tailscale 也算第二处"
    assert (
        sources.choose_direct(
            mode="relay",
            account_id=2,
            client_host="8.8.8.8",
            relay_fallback=True,
            force_relay=False,
            original_link=True,
        )
        is False
    )
    assert (
        sources.choose_direct(
            mode="direct",
            account_id=3,
            client_host="8.8.8.8",
            relay_fallback=False,
            force_relay=False,
            original_link=False,
        )
        is False
    ), "直链不是原画就不直连"
    assert sources.is_home_client(None) is True, "取不到对端地址按家里（全部转发，安全的那一边）"


def test_concurrent_playback_slots(client, tmp_path):
    file_id, _path = seed(client, tmp_path)
    client.patch(f"/api/v1/drives/accounts/{client.account_id}", json={"read_slots": 1})
    from movieclaw_api.services.drives import sources

    sources.forget_limits(client.account_id)
    assert _stream(client, file_id, device="dev-a").status_code == 200
    # 同一路播放的几条请求共用名额
    assert (
        _stream(client, file_id, device="dev-a", headers={"Range": "bytes=0-9"}).status_code == 206
    )
    full = _stream(client, file_id, device="dev-b")
    assert full.status_code == 503
    assert "同时播放数已满（1）" in full.json()["message"]


def test_direct_links_are_cached_and_coalesced(client, tmp_path):
    from movieclaw_api.services.drives import gateway, sources

    file_id, _path = seed(client, tmp_path)
    before = gateway.usage_today(client.account_id)

    async def burst():
        return await asyncio.gather(
            *(sources.direct_url(client.account_id, "f1", "UA-1") for _ in range(5))
        )

    urls = call(client, burst)
    assert len(set(urls)) == 1, "并发只取一次"
    again = call(client, sources.direct_url, client.account_id, "f1", "UA-1")
    other = call(client, sources.direct_url, client.account_id, "f1", "UA-2")
    assert again == urls[0] and other != urls[0], "按 UA 分开缓存"
    assert gateway.usage_today(client.account_id) - before == 2
    sources.forget_links(client.account_id, "f1")
    assert call(client, sources.direct_url, client.account_id, "f1", "UA-1") != urls[0]


def test_byte_readers_resolve_cloud_paths(client, tmp_path):
    """转码、抽字幕、读索引用的同步入口：网盘文件读服务器直链，缓存指纹用台账。"""
    from movieclaw_api.services.drives.sources import SERVER_USER_AGENT
    from movieclaw_playback import streaming

    _file_id, path = seed(client, tmp_path)
    assert streaming.is_cloud(path) and streaming.is_remote(path)
    assert streaming.file_stamp(path) == (len(CONTENT), 123)

    def read_in_thread():
        source = streaming.media_input(path)
        reader = streaming.open_strm_range(path)
        assert reader is not None
        with reader as f:
            data = f.read(64)
        return source, data

    source, data = call(client, asyncio.to_thread, read_in_thread)
    url, options = source
    assert url.startswith("http://127.0.0.1") and "/f1?" in url
    assert SERVER_USER_AGENT in " ".join(options), "ffmpeg 带服务器 UA 读直链"
    assert data == CONTENT[:64]
    assert streaming.is_cloud(str(tmp_path / "elsewhere.mkv")) is False


def test_auth_expired_drive_gives_a_clear_reason(client, tmp_path):
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    file_id, _path = seed(client, tmp_path)

    async def kill():
        async with get_database().session() as session:
            await DriveAccountRepository(session).save_credentials(
                client.account_id, {"token": "dead"}
            )

    call(client, kill)
    failed = _stream(client, file_id)
    assert failed.status_code == 503
    assert "需要重新登录" in failed.json()["message"]

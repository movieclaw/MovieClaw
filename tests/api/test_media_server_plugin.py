"""第三方媒体服务器按只读网盘后端接入（docs/design/media-server-plugins.md）。

一台真实 HTTP 的假媒体服务器（令牌鉴权、分页、支持 Range），加一个真实经 SDK 网络出口跟它
说话的插件，主进程与独立进程各跑一遍。TMDB 为假实现，其余全是真的。按用户实际的使用顺序验证：

- 填表连上服务器（令牌加密存、不回显），目录选择器列出对方的库，建库即纳管；
- 服务器给了 TMDB 编号的条目不走文件名搜索，直接钉死身份，剧集季集正确；没给的进待识别；
- 拉取失败（第二页 502）一条缺失都不标，拉全后真少了的才标，回来了认回来；
- 取流：令牌只在服务器到对方这一段，播放器看不到；外网的设备也不会被 302 到内网地址；
  ffprobe 探规格带得上令牌；
- 只读：不能当主根，删条目 / 删文件 / 自动清理都不碰对方，写方法一次都不调；
- 插件自动建库：能按 ``OpsError.message_key`` 分辨失败原因；
- 复查周期按后端声明。
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import textwrap
import threading
import time
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events

ADMIN = {"username": "admin", "password": "s3cret-pass"}
TOKEN = "server-token-abc123"
CONTENT = bytes(range(256)) * 64  # 16 KB，按位置可辨认
PAGE_SIZE = 2

PLUGIN = """
import httpx
from fastapi import APIRouter
from pydantic import BaseModel, Field, SecretStr

from movieclaw_api.plugins.keys import PLUGIN_ROUTES
from movieclaw_sdk import net, plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS, AccountInfo, AuthExpired, Capabilities, DirectLink, DriveBackend, Login,
    LoginResult, RemoteDir, RemoteFile, RemoteTree, Transient,
)
from movieclaw_sdk.ops import HOST_OPS, OpsError


class Config(BaseModel):
    recheck_hours: int = 1


class Credentials(BaseModel):
    base_url: str = Field(title="服务器地址")
    token: SecretStr = Field(title="访问令牌")


def _client():
    return httpx.AsyncClient(transport=net.http_transport("fake-server"), timeout=10.0)


async def _get(base_url, token, path, **params):
    async with _client() as client:
        response = await client.get(base_url + path, headers={"X-Token": token}, params=params)
    if response.status_code == 401:
        raise AuthExpired("服务器不认这个令牌")
    if response.status_code >= 400:
        raise Transient(f"服务器返回 {response.status_code}：{path}")
    return response.json()


def _rel_path(item):
    # 身份写进路径：现成的 [tmdbid=N] 标记。服务器不知道身份的不写，退回文件名识别
    if not item.get("tmdb_id"):
        return f"{item['title']}/{item['name']}"
    folder = f"{item['title']} ({item['year']}) [tmdbid={item['tmdb_id']}]"
    if item.get("episode"):
        ext = item["name"].rsplit(".", 1)[-1]
        s, e = item["season"], item["episode"]
        return f"{folder}/Season {s:02d}/S{s:02d}E{e:02d}.{ext}"
    return f"{folder}/{item['name']}"


class MediaServer(DriveBackend):
    type = "fake-server"
    title = "假媒体服务器"
    login = Login(form=Credentials)

    def __init__(self, recheck_hours):
        self.capabilities = Capabilities(
            writable=False, recheck_hours=recheck_hours,
            default_qps=1000.0, default_daily_budget=100000, default_read_slots=8,
        )

    async def login_with_form(self, values):
        creds = Credentials.model_validate(values)
        token = creds.token.get_secret_value()
        info = await _get(creds.base_url, token, "/info")
        return LoginResult(
            user_id=info["server_id"], display_name=info["name"],
            credentials={"base_url": creds.base_url, "token": token},
        )

    async def account_info(self, account):
        info = await _get(account.credentials["base_url"], account.credentials["token"], "/info")
        return AccountInfo(display_name=info["name"])

    async def list_dir(self, account, dir_id):
        if dir_id:
            return []
        libraries = await _get(
            account.credentials["base_url"], account.credentials["token"], "/libraries"
        )
        return [RemoteDir(remote_id=x["id"], name=x["name"], has_children=False) for x in libraries]

    async def list_tree(self, account, dir_id):
        creds = account.credentials
        files, page = [], 0
        while True:
            # 哪一页失败都直接抛（_get）：结果必须完整，这一轮不对账
            data = await _get(
                creds["base_url"], creds["token"], f"/libraries/{dir_id}/items", page=page
            )
            files.extend(
                RemoteFile(
                    remote_id=item["id"], name=item["name"], size=item["size"],
                    rel_path=_rel_path(item),
                )
                for item in data["items"]
            )
            if not data["more"]:
                return RemoteTree(files=tuple(files))
            page += 1

    async def direct_link(self, account, remote_id, user_agent):
        return DirectLink(
            url=f"{account.credentials['base_url']}/stream/{remote_id}",
            headers={"X-Token": account.credentials["token"]},
            expires_in=600,
        )

    # 只读后端：宿主绝不该调到写方法，调到就把痕迹带进报错里
    async def delete(self, account, remote_ids):
        raise Transient("BUG：宿主调了只读后端的 delete")

    async def ensure_dir(self, account, parent_id, path):
        raise Transient("BUG：宿主调了只读后端的 ensure_dir")


@plugin(
    "fake-server",
    title="假媒体服务器",
    config=Config,
    inject=(HOST_OPS, PLUGIN_ROUTES),
    permissions=("library.create", "drives.accounts.list"),
)
async def apply(ctx) -> None:
    ctx.contribute(DRIVE_BACKENDS, "fake-server", MediaServer(ctx.config.recheck_hours))
    ops = await ctx.use(HOST_OPS).client(ctx)
    router = APIRouter()

    @router.post("/auto-import", operation_id="plugins.fake-server.auto-import")
    async def auto_import(body: dict) -> dict:
        # 插件自动接入对方的库：建库走主线的接口；失败按稳定的键分辨原因，不比较文案
        [account] = await ops.call("drives.accounts.list")
        try:
            created = await ops.call(
                "library.create",
                {
                    "name": body["name"],
                    "kind": body["kind"],
                    "root_paths": [body["root"]],
                    "cloud_folders": [
                        {
                            "account_id": account["id"],
                            "remote_dir_id": body["view"],
                            "display_path": body["view"],
                        }
                    ],
                },
            )
        except OpsError as exc:
            return {"created": None, "message_key": exc.message_key, "params": exc.params}
        return {"created": created["id"], "message_key": None, "params": {}}

    ctx.use(PLUGIN_ROUTES).mount(ctx, router, zone="admin")
"""


class _Server:
    """假媒体服务器：要 ``X-Token``；条目分页；``/stream`` 支持 Range。"""

    def __init__(self, video: bytes) -> None:
        self.video = video
        self.requests: list[dict] = []
        self.fail_pages: set[tuple[str, int]] = set()
        self.libraries: dict[str, dict] = {
            "v-movies": {
                "name": "电影库",
                "items": [
                    # 文件名故意认不出：身份只能来自服务器给的编号
                    _item("m1", "abc123.mkv", title="沙丘2", year=2024, tmdb_id=693134),
                    _item("m2", "未命名(3).mkv", title="家庭录像"),
                ],
            },
            "v-tv": {
                "name": "剧集库",
                "items": [
                    _item(
                        f"e{n}",
                        f"x{n}.mkv",
                        title="测试剧集",
                        year=2024,
                        tmdb_id=200,
                        season=1,
                        episode=n,
                    )
                    for n in (1, 2, 3)
                ],
            },
        }
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass

            def _json(self, status: int, payload: object) -> None:
                body = json.dumps(payload, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:  # noqa: N802
                parts = urlsplit(self.path)
                server.requests.append(
                    {
                        "path": parts.path,
                        "token": self.headers.get("X-Token"),
                        "ua": self.headers.get("User-Agent"),
                    }
                )
                if self.headers.get("X-Token") != TOKEN:
                    self._json(401, {"error": "unauthorized"})
                    return
                if parts.path == "/info":
                    self._json(200, {"server_id": "srv-1", "name": "家里的服务器"})
                elif parts.path == "/libraries":
                    self._json(
                        200,
                        [{"id": k, "name": v["name"]} for k, v in server.libraries.items()],
                    )
                elif match := re.fullmatch(r"/libraries/([^/]+)/items", parts.path):
                    view = match.group(1)
                    page = int(parse_qs(parts.query).get("page", ["0"])[0])
                    if (view, page) in server.fail_pages:
                        self._json(502, {"error": "upstream"})
                        return
                    items = server.libraries[view]["items"]
                    chunk = items[page * PAGE_SIZE : (page + 1) * PAGE_SIZE]
                    self._json(200, {"items": chunk, "more": (page + 1) * PAGE_SIZE < len(items)})
                elif parts.path.startswith("/stream/"):
                    self._stream()
                else:
                    self._json(404, {})

            def _stream(self) -> None:
                size = len(server.video)
                match = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
                start = int(match.group(1)) if match else 0
                end = int(match.group(2)) if match and match.group(2) else size - 1
                end = min(end, size - 1)
                body = server.video[start : end + 1]
                self.send_response(206 if match else 200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Accept-Ranges", "bytes")
                if match:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.end_headers()
                self.wfile.write(body)

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.http.server_address[1]}"

    def list_calls(self, view: str) -> int:
        return sum(1 for r in self.requests if r["path"] == f"/libraries/{view}/items")

    def close(self) -> None:
        self.http.shutdown()


def _item(remote_id: str, name: str, **extra) -> dict:
    return {"id": remote_id, "name": name, "size": 4_000_000_000, **extra}


_TMDB_BASE = {
    "status": "Released",
    "external_ids": {},
    "alternative_titles": {"titles": [], "results": []},
    "translations": {"translations": []},
}
_TMDB = {
    "/3/movie/693134": {
        **_TMDB_BASE,
        "id": 693134,
        "title": "沙丘2",
        "original_title": "Dune: Part Two",
        "release_date": "2024-02-27",
        "runtime": 167,
    },
    "/3/tv/200": {
        **_TMDB_BASE,
        "id": 200,
        "name": "测试剧集",
        "original_name": "Test Show",
        "first_air_date": "2024-01-01",
        "status": "Returning Series",
        "seasons": [{"season_number": 1}],
    },
    "/3/tv/200/season/1": {
        "name": "第 1 季",
        "air_date": "2024-01-01",
        "episodes": [
            {"episode_number": n, "name": f"E{n}", "air_date": "2024-01-01"} for n in (1, 2, 3)
        ],
    },
}
SEARCHES: list[str] = []


def _fake_tmdb():
    from movieclaw_media.tmdb import TmdbClient

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.startswith("/3/search/"):
            SEARCHES.append(request.url.params.get("query", ""))
            return httpx.Response(200, json={"results": []})
        payload = _TMDB.get(path)
        return httpx.Response(200, json=payload) if payload else httpx.Response(404, json={})

    return TmdbClient("0123456789abcdef0123456789abcdef", transport=httpx.MockTransport(handler))


@pytest.fixture(scope="module")
def video(tmp_path_factory) -> bytes:
    """一小段真视频（ffprobe 探得出规格）；没有 ffmpeg 时退回可辨认的字节，探规格的用例跳过。"""
    if shutil.which("ffmpeg") is None:
        return CONTENT
    path = tmp_path_factory.mktemp("video") / "sample.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=10",
            "-f", "lavfi", "-i", "sine=duration=2",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
            "-movflags", "+faststart", str(path),
        ],
        check=True,
    )  # fmt: skip
    return path.read_bytes()


@pytest.fixture
def server(video):
    fake = _Server(video)
    yield fake
    fake.close()


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch, server):
    import movieclaw_api.services.library.scan as scan_mod
    import movieclaw_api.services.media_discover as discover_mod
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.services.drives import gateway, sources
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'media-server.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    tmdb = _fake_tmdb()
    monkeypatch.setattr(discover_mod, "get_tmdb_client", lambda: tmdb)
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: tmdb)
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    gateway.reset_state()
    sources.reset_state()
    SEARCHES.clear()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "fake_server.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: fake-server
              local: true
              module: fake_server
              runtime: {request.param}
              grants: ["library.create", "drives.accounts.list"]
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app(), headers={"Accept-Language": "zh-Hans"}) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
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


def _connect(client: TestClient, server: _Server) -> int:
    login = client.post(
        "/api/v1/drives/accounts/form",
        json={"backend": "fake-server", "values": {"base_url": server.base, "token": TOKEN}},
    )
    assert login.status_code == 201, login.text
    return login.json()["data"]["account"]["id"]


def _wait_idle(client: TestClient, library_id: int) -> dict:
    deadline = time.monotonic() + 120
    while True:
        view = client.get(f"/api/v1/libraries/{library_id}").json()["data"]
        if not view["scanning"]:
            return view
        assert time.monotonic() < deadline, view
        time.sleep(0.1)


def _mount(
    client: TestClient,
    tmp_path: Path,
    account_id: int,
    view: str,
    kind: str,
    *,
    primary: bool = False,
    expect: int = 200,
):
    staging = tmp_path / f"local-{view}"
    staging.mkdir(exist_ok=True)
    created = client.post(
        "/api/v1/libraries",
        json={
            "name": view,
            "kind": kind,
            "root_paths": [str(staging)],
            "cloud_folders": [
                {
                    "account_id": account_id,
                    "remote_dir_id": view,
                    "display_path": view,
                    "is_primary": primary,
                }
            ],
        },
    )
    assert created.status_code == expect, created.text
    if expect != 200:
        return created.json()
    return _wait_idle(client, created.json()["data"]["id"])


async def _rows(library_id: int) -> dict[str, dict]:
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LibraryFile, LibraryFileReplica, MediaItem

    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(LibraryFile, LibraryFileReplica, MediaItem)
                .join(LibraryFileReplica, LibraryFileReplica.library_file_id == LibraryFile.id)
                .join(MediaItem, MediaItem.id == LibraryFile.media_item_id, isouter=True)
                .where(LibraryFile.library_id == library_id)
            )
        ).all()
    return {
        replica.remote_id: {
            "id": row.id,
            "path": row.file_path,
            "state": str(row.state),
            "local_bytes": row.local_bytes,
            "media_item_id": row.media_item_id,
            "tmdb_id": item.tmdb_id if item is not None else None,
            "season": row.season_number,
            "episode": row.episode_number,
            "identity_source": str(row.identity_source),
            "unidentified": row.unidentified_code,
            "replica": replica.state,
            "video_codec": row.video_codec,
        }
        for row, replica, item in rows
    }


def rows_of(client: TestClient, library_id: int) -> dict[str, dict]:
    return call(client, _rows, library_id)


def _scan(client: TestClient, library_id: int, **kwargs):
    from movieclaw_api.services.library.scan import scan_library

    return call(client, scan_library, library_id, **kwargs)


def _stream(client: TestClient, file_id: int, **kwargs):
    from movieclaw_api.services.playback.signing import issue_stream_token

    token = call(client, issue_stream_token, member_id=0, file_id=file_id, device_id="dev-a")
    return client.get(
        f"/api/v1/playback/files/{file_id}/stream",
        params={"token": token},
        follow_redirects=False,
        **kwargs,
    )


def test_connect_browse_mount_identify_and_play(client, tmp_path, server, video):
    # 令牌不对：明确告诉用户，账号不建
    wrong = client.post(
        "/api/v1/drives/accounts/form",
        json={"backend": "fake-server", "values": {"base_url": server.base, "token": "nope"}},
    )
    assert wrong.status_code == 400, wrong.text
    assert client.get("/api/v1/drives/accounts").json()["data"] == []

    account_id = _connect(client, server)
    # 令牌加密存、接口不回显
    assert TOKEN not in client.get("/api/v1/drives/accounts").text

    async def stored_credentials() -> str:
        from movieclaw_db.engine import get_database
        from movieclaw_db.models.drive_account import DriveAccount

        async with get_database().session() as session:
            return (await session.get(DriveAccount, account_id)).credentials

    assert TOKEN not in call(client, stored_credentials)

    # 目录选择器列出对方的库
    dirs = client.get(f"/api/v1/drives/accounts/{account_id}/dirs").json()["data"]
    assert [d["id"] for d in dirs] == ["v-movies", "v-tv"]
    assert (
        client.get("/api/v1/drives/backends").json()["data"][0]["capabilities"]["writable"] is False
    )

    # 电影库：服务器给了编号的钉死身份、不去搜；没给的进待识别
    movies = _mount(client, tmp_path, account_id, "v-movies", "movie")
    assert movies["cloud_folders"][0]["report"]["videos"] == 2
    rows = rows_of(client, movies["id"])
    assert rows["m1"]["tmdb_id"] == 693134
    assert rows["m1"]["identity_source"].endswith("path_tag")
    assert rows["m1"]["local_bytes"] is False and rows["m1"]["replica"] == "verified"
    assert rows["m2"]["tmdb_id"] is None and rows["m2"]["unidentified"] is not None
    assert not any("abc123" in q for q in SEARCHES), SEARCHES
    # 本地一个文件都不落
    assert not list((tmp_path / "local-v-movies").rglob("*.mkv"))

    # 剧集库：季集来自路径
    shows = _mount(client, tmp_path, account_id, "v-tv", "tv")
    rows = rows_of(client, shows["id"])
    assert {k: (v["tmdb_id"], v["season"], v["episode"]) for k, v in rows.items()} == {
        "e1": (200, 1, 1),
        "e2": (200, 1, 2),
        "e3": (200, 1, 3),
    }
    # 同一部剧合成一个条目
    assert len({v["media_item_id"] for v in rows.values()}) == 1

    # 家里的设备：字节由 MovieClaw 转发，Range 照常；令牌只在服务器到对方这一段
    file_id = rows["e2"]["id"]
    full = _stream(client, file_id)
    assert full.status_code == 200, full.text
    assert full.content == video
    part = _stream(client, file_id, headers={"Range": "bytes=100-199", "User-Agent": "Infuse"})
    assert part.status_code == 206 and part.content == video[100:200]
    assert TOKEN not in str(dict(part.headers))
    streamed = [r for r in server.requests if r["path"] == "/stream/e2"]
    assert streamed and all(r["token"] == TOKEN for r in streamed)
    assert all(r["ua"] != "Infuse" for r in streamed), "播放器的 UA 不外传"

    # 外网设备选「总是直连」也不会被 302：内网地址连不上，还会把令牌交出去
    saved = client.put("/api/v1/playback/policy", json={"cloud_stream_mode": "direct"})
    assert saved.status_code == 200
    outside = {"User-Agent": "Mozilla/Phone", "X-Forwarded-Host": "movie.example.com:8888"}
    relayed = _stream(client, file_id, headers=outside)
    assert relayed.status_code == 200 and relayed.content == video
    assert "location" not in relayed.headers


@pytest.mark.skipif(shutil.which("ffprobe") is None, reason="没有 ffprobe")
def test_probing_specs_reaches_the_server_with_the_token(client, tmp_path, server, monkeypatch):
    from movieclaw_api.services.media_probe import probe_media
    from movieclaw_api.services.playback import strm_probe
    from movieclaw_api.services.playback.strm_probe import probe_file
    from movieclaw_playback.streaming import media_input

    monkeypatch.setattr(strm_probe, "probe_media", probe_media)  # 单测默认打桩，这里要真探
    account_id = _connect(client, server)
    shows = _mount(client, tmp_path, account_id, "v-tv", "tv")
    row = rows_of(client, shows["id"])["e1"]

    server.requests.clear()
    result = call(client, probe_file, row["id"], respect_backoff=False)
    assert result.status == "probed", result
    assert rows_of(client, shows["id"])["e1"]["video_codec"] == "h264"
    probed = [r for r in server.requests if r["path"] == "/stream/e1"]
    assert probed and all(r["token"] == TOKEN for r in probed)

    # 转码读同一个入口：ffmpeg 的输入带上令牌
    from movieclaw_api.services.drives import sources

    async def transcode_input():
        await sources.prefetch(row["path"])

    call(client, transcode_input)
    source, args = media_input(row["path"])
    assert source == f"{server.base}/stream/e1"
    assert f"X-Token: {TOKEN}" in args[args.index("-headers") + 1]


def test_partial_listing_never_marks_missing_but_a_complete_one_reconciles(
    client, tmp_path, server
):
    account_id = _connect(client, server)
    library_id = _mount(client, tmp_path, account_id, "v-tv", "tv")["id"]
    before = rows_of(client, library_id)
    assert all(v["state"] == "in_place" for v in before.values())

    # 第二页（第三集所在）接口超时：这一轮什么都不判，也说清楚了原因
    server.fail_pages.add(("v-tv", 1))
    summary = _scan(client, library_id)
    assert summary.errors and "v-tv" in summary.errors[0]
    assert all(v["state"] == "in_place" for v in rows_of(client, library_id).values())

    # 拉全了，第三集真没了：只标它
    server.fail_pages.clear()
    removed = server.libraries["v-tv"]["items"].pop()
    _scan(client, library_id)
    rows = rows_of(client, library_id)
    assert rows["e3"]["state"] == "missing" and rows["e3"]["replica"] == "lost"
    assert rows["e1"]["state"] == rows["e2"]["state"] == "in_place"

    # 回来了认回原行
    server.libraries["v-tv"]["items"].append(removed)
    _scan(client, library_id)
    rows = rows_of(client, library_id)
    assert rows["e3"]["state"] == "in_place" and rows["e3"]["id"] == before["e3"]["id"]


def test_read_only_backend_is_never_written_to(client, tmp_path, server):
    from movieclaw_api.services.library.recycle import recycle_file
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LibraryFile

    account_id = _connect(client, server)
    # 不能当主根：主根是新片上传的去处
    refused = _mount(client, tmp_path, account_id, "v-tv", "tv", primary=True, expect=400)
    assert refused["message_key"] == "library.cloud.readOnlyPrimary"
    assert "只读" in refused["message"]

    library_id = _mount(client, tmp_path, account_id, "v-tv", "tv")["id"]
    rows = rows_of(client, library_id)
    item_id, file_id = rows["e1"]["media_item_id"], rows["e1"]["id"]

    # 删除预览说清楚
    preview = client.get(f"/api/v1/libraries/{library_id}/items/{item_id}/delete-preview")
    assert preview.status_code == 200, preview.text
    cloud = preview.json()["data"]["cloud"]
    assert cloud["read_only"] is True and cloud["backend_title"] == "假媒体服务器"

    # 删条目、删文件都被拒绝，台账不动，写方法一次都没调到
    for url in (
        f"/api/v1/libraries/{library_id}/items/{item_id}",
        f"/api/v1/libraries/{library_id}/items/{item_id}/files/{file_id}",
    ):
        deleted = client.delete(url)
        assert deleted.status_code == 200, deleted.text
        errors = deleted.json()["data"]["errors"]
        assert errors and "只读" in errors[0] and "BUG" not in errors[0], errors
        assert deleted.json()["data"]["rows_deleted"] == 0
    assert set(rows_of(client, library_id)) == {"e1", "e2", "e3"}

    # 自动清理（洗版替换、取消订阅、重复清理都走这里）：行不动
    async def auto_recycle() -> tuple[str, str, object]:
        async with get_database().session() as session:
            row = await session.get(LibraryFile, file_id)
            outcome = await recycle_file(
                session, row, reason="upgrade_replaced", trigger={"kind": "system"}
            )
            await session.commit()
            await session.refresh(row)
            return outcome, str(row.state), row.purge_after

    outcome, state, purge_after = call(client, auto_recycle)
    assert outcome == "read_only"
    assert state.endswith("in_place") and purge_after is None

    # 从库里拿掉目录：只删台账
    removed = client.put(
        f"/api/v1/libraries/{library_id}",
        json={
            "name": "v-tv",
            "kind": "tv",
            "root_paths": [str(tmp_path / "local-v-tv")],
            "cloud_folders": [],
        },
    )
    assert removed.status_code == 200, removed.text
    assert rows_of(client, library_id) == {}
    assert len(server.libraries["v-tv"]["items"]) == 3


def test_duplicate_cleanup_reports_read_only_files_instead_of_touching_them(
    client, tmp_path, server
):
    from movieclaw_api.services.library.duplicates import resolve_unit
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, FileState, LibraryFile

    account_id = _connect(client, server)
    library_id = _mount(client, tmp_path, account_id, "v-movies", "movie")["id"]
    remote = rows_of(client, library_id)["m1"]

    local_path = tmp_path / "local-v-movies" / "沙丘2 (2024)" / "Dune.2024.1080p.mkv"
    local_path.parent.mkdir(parents=True)
    local_path.write_bytes(b"x" * 1024)

    async def clean_up() -> tuple[object, int]:
        async with get_database().session() as session:
            local = LibraryFile(
                library_id=library_id,
                media_item_id=remote["media_item_id"],
                file_path=str(local_path),
                size_bytes=4_000_000_000,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                container="mkv",
                resolution="1080p",
                video_codec="h264",
                duration_seconds=10020,
            )
            session.add(local)
            await session.commit()
            local_id = local.id
            outcome = await resolve_unit(
                session,
                media_item_id=remote["media_item_id"],
                season_number=0,
                episode_number=0,
                keep=local_id,
                trigger={"kind": "member", "id": None, "label": "测试"},
            )
            return outcome, local_id

    outcome, _local_id = call(client, clean_up)
    assert outcome.done == 0
    assert [failure[0] for failure in outcome.failed] == [remote["id"]]
    assert "只读" in outcome.failed[0][2]
    assert rows_of(client, library_id)["m1"]["state"].endswith("in_place")


def test_plugin_auto_import_can_tell_why_creating_a_library_failed(client, tmp_path, server):
    _connect(client, server)
    root = tmp_path / "auto"
    root.mkdir()
    url = "/api/v1/plugins/fake-server/auto-import"

    created = client.post(
        url, json={"name": "自动建的", "kind": "tv", "view": "v-tv", "root": str(root)}
    )
    assert created.status_code == 200, created.text
    library_id = created.json()["created"]
    assert library_id is not None
    _wait_idle(client, library_id)
    assert set(rows_of(client, library_id)) == {"e1", "e2", "e3"}

    # 同一个目录再接一次（两轮同步撞车）：有稳定的键，不用猜文案
    again = client.post(
        url, json={"name": "又一个", "kind": "tv", "view": "v-tv", "root": str(tmp_path / "other")}
    ).json()
    assert again["created"] is None
    assert again["message_key"] == "library.cloud.overlapLibrary"
    assert again["params"]["library"] == "自动建的"

    # 库名重了：另一个键
    (tmp_path / "other").mkdir()
    named = client.post(
        url,
        json={
            "name": "自动建的",
            "kind": "movie",
            "view": "v-movies",
            "root": str(tmp_path / "other"),
        },
    ).json()
    assert named["created"] is None and named["message_key"] == "errors.library.nameInUse"


def test_recheck_follows_what_the_backend_declares(client, tmp_path, server):
    from datetime import timedelta

    account_id = _connect(client, server)
    view = _mount(client, tmp_path, account_id, "v-tv", "tv")
    library_id, folder_id = view["id"], view["cloud_folders"][0]["id"]

    async def listed_hours_ago(hours: float) -> None:
        from movieclaw_db.engine import get_database
        from movieclaw_db.models import LibraryCloudFolder
        from movieclaw_db.models.base import utcnow

        async with get_database().session() as session:
            folder = await session.get(LibraryCloudFolder, folder_id)
            folder.listed_at = utcnow() - timedelta(hours=hours)
            session.add(folder)
            await session.commit()

    # 插件声明 1 小时：半小时前列过的这轮不列，两小时前列过的到期（默认一周）
    call(client, listed_hours_ago, 0.5)
    before = server.list_calls("v-tv")
    _scan(client, library_id, backfill_existing_specs=False)
    assert server.list_calls("v-tv") == before

    call(client, listed_hours_ago, 2)
    _scan(client, library_id, backfill_existing_specs=False)
    assert server.list_calls("v-tv") > before


def test_unplayable_when_the_plugin_is_gone_but_the_library_stays(client, tmp_path, server):
    account_id = _connect(client, server)
    library_id = _mount(client, tmp_path, account_id, "v-tv", "tv")["id"]
    rows = rows_of(client, library_id)

    call(client, client.app.state.kernel.disable, "fake-server")
    # 库还在、能浏览；放的时候说清楚原因
    assert client.get(f"/api/v1/libraries/{library_id}").status_code == 200
    assert client.get(f"/api/v1/libraries/{library_id}/items").status_code == 200
    stream = _stream(client, rows["e1"]["id"])
    assert stream.status_code == 503, stream.text
    assert set(rows_of(client, library_id)) == {"e1", "e2", "e3"}

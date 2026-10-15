"""OpenList 直链示例插件端到端（strm-playback.md §10）。

把示例插件 ``openlist_direct_link.py`` 当本地插件装进临时数据目录（主进程、独立进程各跑一遍），
起一个仿 OpenList：``/api/fs/get`` 验令牌、给签名，``/d/…`` 带着请求方的 UA 302 到网盘 CDN。
strm 指向挂载里的文件：在规则里的被 302 到网盘 CDN（直链按播放器的 UA 签），不在规则里的、
OpenList 停了的，照旧由服务器出字节。
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
import textwrap
import threading
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, quote, unquote

import pytest
from fastapi.testclient import TestClient
from tests.api.test_playback_stream import _ADMIN, _seed

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events
from movieclaw_api.services.playback import strm_direct

EXAMPLES = (
    Path(__file__).resolve().parents[2]
    / "src"
    / "movieclaw_agent"
    / "builtin-skills"
    / "movieclaw-plugin-dev"
    / "references"
    / "examples"
)
sys.path.insert(0, str(EXAMPLES))
from openlist_direct_link import Rule, openlist_path  # noqa: E402

TOKEN = "openlist-token-1"
CDN = "https://cdn.cloud-mock.com"
PLAYER_UA = "Infuse-Direct/8.1"
BODY = bytes(range(256)) * 16


def _sig(path: str, ua: str | None) -> str:
    return hashlib.sha1(f"{path}|{ua}".encode()).hexdigest()[:12]


class _OpenList:
    """仿 OpenList：只认 ``/115`` 存储；``/d/`` 不开代理，302 到与 UA 绑定的网盘 CDN。"""

    def __init__(self) -> None:
        self.log: list[SimpleNamespace] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass

            def do_POST(self) -> None:  # noqa: N802
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.log.append(
                    SimpleNamespace(api=body["path"], auth=self.headers.get("Authorization"))
                )
                if self.headers.get("Authorization") != TOKEN:
                    reply = {"code": 401, "message": "token is invalidated"}
                elif body["path"].startswith("/115/"):
                    reply = {
                        "code": 200,
                        "data": {"name": body["path"].rsplit("/", 1)[1], "sign": "s1gn"},
                    }
                else:
                    reply = {"code": 500, "message": "object not found"}
                data = json.dumps(reply).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self) -> None:  # noqa: N802
                raw, _, query = self.path.partition("?")
                ua = self.headers.get("User-Agent")
                owner.log.append(SimpleNamespace(d=unquote(raw), ua=ua))
                if not raw.startswith("/d/") or parse_qs(query).get("sign") != ["s1gn"]:
                    self.send_error(403)
                    return
                path = unquote(raw.removeprefix("/d"))
                self.send_response(302)
                self.send_header("Location", f"{CDN}/cdn{quote(path)}?sig={_sig(path, ua)}")
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def test_rules_match_whole_segments_longest_first() -> None:
    rules = [
        Rule(mount="/cd2/CloudDrive", openlist="/all"),
        Rule(mount="/cd2/CloudDrive/115/", openlist="/115"),
    ]
    assert openlist_path("/cd2/CloudDrive/115/电影/a.mkv", rules) == "/115/电影/a.mkv"
    assert openlist_path("/cd2/CloudDrive/阿里/a.mkv", rules) == "/all/阿里/a.mkv"
    assert openlist_path("/cd2/CloudDrive2/a.mkv", rules) is None  # 不能按字符前缀误配
    assert openlist_path("/mnt/a.mkv", rules) is None


@pytest.fixture
def openlist():
    server = _OpenList()
    yield server
    server.close()


@pytest.fixture(params=["inline", "process"])
def app_client(request, tmp_path, monkeypatch, openlist):
    from movieclaw_api.settings.store import reset_setting_store

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ol.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    strm_direct._cache.clear()
    (tmp_path / "plugins").mkdir()
    shutil.copy(EXAMPLES / "openlist_direct_link.py", tmp_path / "plugins")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: openlist-direct-link
              local: true
              runtime: {request.param}
              config:
                base_url: "{openlist.base}"
                token: "{TOKEN}"
                rules: [{{ mount: "{tmp_path / "cd2" / "115"}", openlist: /115 }}]
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as client:
        client.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield app, client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    durable_events.reset_state()
    strm_direct._cache.clear()
    get_settings.cache_clear()


def _stream(client, tmp_path, target: Path, ua: str = PLAYER_UA):
    file_id = client.portal.call(
        partial(_seed, tmp_path, container="mkv", strm=True, strm_url=str(target))
    )
    resp = client.post(
        "/api/v1/playback/sessions", json={"file_id": file_id, "capability": {"universal": True}}
    )
    assert resp.status_code == 200, resp.text
    url = resp.json()["data"]["stream_url"]
    return client.get(
        url, headers={"User-Agent": ua, "Range": "bytes=0-99"}, follow_redirects=False
    )


def test_mount_files_in_the_rules_play_straight_from_the_cloud(app_client, tmp_path, openlist):
    app, client = app_client
    fiber = app.state.kernel.fiber("openlist-direct-link")
    assert fiber.state.value == "active", fiber.error
    movie = tmp_path / "cd2" / "115" / "电影" / "星际 穿越 (2014).mkv"
    other = tmp_path / "rclone" / "阿里" / "a.mkv"
    for path in (movie, other):
        path.parent.mkdir(parents=True)
        path.write_bytes(BODY)

    resp = _stream(client, tmp_path, movie)
    path = "/115/电影/星际 穿越 (2014).mkv"
    assert resp.status_code == 302
    assert resp.headers["location"] == f"{CDN}/cdn{quote(path)}?sig={_sig(path, PLAYER_UA)}"
    # 令牌只发给 OpenList 的查询接口；/d/ 由服务端带着播放器的 UA 去跟
    assert [(e.api, e.auth) for e in openlist.log if hasattr(e, "api")] == [(path, TOKEN)]
    assert [(e.d, e.ua) for e in openlist.log if hasattr(e, "d")] == [(f"/d{path}", PLAYER_UA)]

    # 不在规则里的挂载：插件不认领，照旧由服务器出字节
    resp = _stream(client, tmp_path, other)
    assert resp.status_code == 206 and resp.content == BODY[:100]

    # OpenList 停了：照旧出字节，播放不受影响
    openlist.close()
    strm_direct._cache.clear()
    resp = _stream(client, tmp_path, movie, ua="VLC/3")
    assert resp.status_code == 206 and resp.content == BODY[:100]

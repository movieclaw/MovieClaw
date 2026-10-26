"""网盘挂载直链钩子在真实应用里跑（strm-playback.md §10）：本地插件在主进程、独立进程各跑一遍。

钩子开放给进程外插件（``movieclaw_sdk.protocol.known_events``）：载荷与结果经插件 IPC 编解码，
播放器的 User-Agent 要原样到插件手里（115 直链与它绑定）。没认领的照旧由服务器出字节。
"""

from __future__ import annotations

import shutil
import sys
import textwrap
from functools import partial

import pytest
from fastapi.testclient import TestClient
from tests.api.test_playback_stream import _ADMIN, _seed

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events
from movieclaw_api.services.playback import strm_direct

PLUGIN = """
from movieclaw_api.hooks import STRM_DIRECT_LINK, DirectLink
from movieclaw_kernel import plugin


@plugin("mount-link", title="挂载直链（测试）")
async def mount_link(ctx):
    async def direct_link(file):
        if "/cloud/" not in file.path:
            return None
        return DirectLink(url=f"https://cdn.example.com/{file.file_id}?ua={file.user_agent}")

    ctx.on(STRM_DIRECT_LINK, direct_link)
"""
BODY = bytes(range(256)) * 16


@pytest.fixture(params=["inline", "process"])
def app_client(request, tmp_path, monkeypatch):
    from movieclaw_api.settings.store import reset_setting_store

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'link.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    strm_direct._cache.clear()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "mount_link.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: mount-link
              local: true
              runtime: {request.param}
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
    shutil.rmtree(tmp_path / "plugins", ignore_errors=True)
    reset_setting_store()
    durable_events.reset_state()
    strm_direct._cache.clear()
    get_settings.cache_clear()


def _stream(client, tmp_path, target):
    file_id = client.portal.call(
        partial(_seed, tmp_path, container="mkv", strm=True, strm_url=str(target))
    )
    resp = client.post(
        "/api/v1/playback/sessions", json={"file_id": file_id, "capability": {"universal": True}}
    )
    assert resp.status_code == 200, resp.text
    url = resp.json()["data"]["stream_url"]
    headers = {"User-Agent": "Infuse-Direct/8.1", "Range": "bytes=0-99"}
    return file_id, client.get(url, headers=headers, follow_redirects=False)


def test_plugin_claims_mount_files_in_both_runtimes(app_client, tmp_path):
    app, client = app_client
    fiber = app.state.kernel.fiber("mount-link")
    assert fiber.state.value == "active", fiber.error
    claimed, other = tmp_path / "cloud" / "a.mkv", tmp_path / "local-disk" / "b.mkv"
    for path in (claimed, other):
        path.parent.mkdir(parents=True)
        path.write_bytes(BODY)

    file_id, resp = _stream(client, tmp_path, claimed)
    assert resp.status_code == 302
    assert resp.headers["location"] == f"https://cdn.example.com/{file_id}?ua=Infuse-Direct/8.1"

    _, resp = _stream(client, tmp_path, other)
    assert resp.status_code == 206 and resp.content == BODY[:100]

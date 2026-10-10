"""插件详情（设置 → 插件 → 点一个插件）：按用户关心的问题聚合，「给系统加了什么」翻成人话。"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events

PLUGIN = """
from fastapi import APIRouter

from movieclaw_api import hooks
from movieclaw_api.domain_events import LIBRARY_INGEST_IMPORTED
from movieclaw_api.plugins.keys import PLUGIN_DATA, PLUGIN_ROUTES
from movieclaw_kernel import DURABLE_EVENTS
from movieclaw_sdk import plugin
from movieclaw_sdk.callbacks import PLUGIN_CALLBACKS, CallbackResponse


@plugin(
    "acme-detail",
    title="详情示例",
    inject=(DURABLE_EVENTS, PLUGIN_ROUTES, PLUGIN_DATA, PLUGIN_CALLBACKS),
)
async def apply(ctx) -> None:
    async def on_imported(event) -> None:
        pass

    def pick(query):
        return None

    ctx.on(LIBRARY_INGEST_IMPORTED, on_imported, id="imported")
    ctx.on(hooks.DOWNLOADER_SELECT, pick)
    router = APIRouter()

    @router.get("/recent", operation_id="plugins.acme-detail.recent")
    async def recent() -> dict:
        return {}

    ctx.use(PLUGIN_ROUTES).mount(ctx, router)
    await ctx.use(PLUGIN_DATA).scoped(ctx).set("seen", 1)

    async def hook(req):
        return CallbackResponse.text("ok")

    ctx.use(PLUGIN_CALLBACKS).endpoint(ctx, "push", hook)
    await ctx.use(PLUGIN_CALLBACKS).issue(ctx, "push")
"""


@pytest.fixture
def app_env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'detail.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    from movieclaw_api import spec_state

    monkeypatch.setattr(spec_state, "routes_changed", lambda app: None)
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_detail.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        "- id: acme-detail\n  local: true\n  module: acme_detail\n", encoding="utf-8"
    )
    folder = tmp_path / "plugins" / "data" / "acme-detail"
    folder.mkdir(parents=True)
    (folder / "cache.bin").write_bytes(b"x" * 2048)
    yield tmp_path
    durable_events.reset_state()
    get_settings.cache_clear()


def start() -> TestClient:
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    return TestClient(app)


def detail(client: TestClient, entry_id: str) -> dict:
    reply = client.get(f"/api/v1/app/plugins/{entry_id}")
    assert reply.status_code == 200, reply.text
    return reply.json()["data"]


def test_detail_translates_what_a_plugin_adds(app_env) -> None:
    with start() as client:
        data = detail(client, "acme-detail")
        assert data["kind"] == "local"
        assert data["plugin"]["state"] == "active"
        titles = {(a["kind"], a["title"]) for a in data["adds"]}
        assert ("command", "mclaw plugins acme-detail recent") in titles
        assert ("trigger", "「下载条目整理入库完成」后会自动处理") in titles
        assert any(k == "decision" and "下载器" in t for k, t in titles)
        assert [c["endpoint"] for c in data["callbacks"]] == ["push"]
        assert "****" in data["callbacks"][0]["url"]
        assert [c["event"] for c in data["consumers"]] == ["library.ingest.imported"]
        assert data["data_rows"] == 1
        assert data["disk_bytes"] == 2048
        # 管理接口的固定路径不会被当成插件 id
        assert client.get("/api/v1/app/plugins/callbacks").status_code == 200


def test_official_channel_and_system_module(app_env) -> None:
    with start() as client:
        weixin = detail(client, "weixin-channel")
        assert weixin["kind"] == "official"
        assert weixin["version"] and weixin["description"]
        assert weixin["package"] is None
        [channel] = [a for a in weixin["adds"] if a["kind"] == "channel"]
        assert channel["title"] == "消息通道「微信」"
        assert channel["detail"] == "还没有接入账号" and channel["href"] == "/settings/im-push"

        scheduler = detail(client, "scheduler")
        assert scheduler["kind"] == "system"
        assert client.get("/api/v1/app/plugins/no-such-plugin").status_code == 404

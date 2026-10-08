"""插件数据与插件健康（docs/design/plugin-phase2b.md §4、§5）。

真实应用 + 运行中挂载的插件（以第三方来源挂，验证实验级契约对本地插件开放）：
数据按条目隔离、实体作用域、秘密加密；健康降级进通知与诊断、恢复与卸载时消退。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.keys import PLUGIN_DATA, PLUGIN_HEALTH
from movieclaw_api.services import durable_events
from movieclaw_api.services.plugin_data import entity_scope
from movieclaw_db.engine import get_database
from movieclaw_db.models import NoticeStatus, PluginData, SystemNotice
from movieclaw_kernel import Entry, plugin


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pd.db'}")
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
    with TestClient(app) as client:
        yield app, client
    get_settings.cache_clear()
    durable_events.reset_state()


def mount(app, client, entry_id: str, inject, body=None):
    holder: dict = {}

    @plugin(entry_id, title=f"测试插件 {entry_id}", inject=inject)
    async def apply(ctx) -> None:
        holder["ctx"] = ctx
        if PLUGIN_DATA in inject:
            holder["store"] = ctx.use(PLUGIN_DATA).scoped(ctx)
        if PLUGIN_HEALTH in inject:
            holder["health"] = ctx.use(PLUGIN_HEALTH).reporter(ctx)

    fiber = client.portal.call(app.state.kernel.mount, Entry(entry_id, apply, source="local"))
    assert fiber.state.value == "active", fiber.error or fiber.incompatible
    return holder


def run(client, coro_fn):
    return client.portal.call(coro_fn)


# ---------------------------------------------------------------------- 数据
def test_plugin_data_is_isolated_scoped_and_secret(app_client) -> None:
    app, client = app_client
    a = mount(app, client, "acme.a", (PLUGIN_DATA,))["store"]
    b = mount(app, client, "acme.b", (PLUGIN_DATA,))["store"]
    sub35 = entity_scope("subscription", 35)

    async def scenario() -> None:
        await a.set("keywords", ["国语", "简中"], scope=sub35)
        await a.set("keywords", ["粤语"], scope=entity_scope("subscription", 36))
        await a.set("cursor", 42)
        await a.set("token", {"access": "s3cret"}, secret=True)
        await b.set("cursor", 7)

        assert await a.get("keywords", scope=sub35) == ["国语", "简中"]
        assert await a.get("cursor") == 42
        assert await b.get("cursor") == 7  # 同一个键，按条目隔离
        assert await b.get("keywords", scope=sub35) is None
        assert await a.get("missing", default="x") == "x"
        assert await a.get("token") == {"access": "s3cret"}
        assert await a.scopes("keywords", entity="subscription") == {
            "subscription:35": ["国语", "简中"],
            "subscription:36": ["粤语"],
        }
        await a.set("cursor", 43)  # 覆盖写
        assert await a.items() == {"cursor": 43, "token": {"access": "s3cret"}}
        assert await a.delete("cursor") is True
        assert await a.delete("cursor") is False

        # 秘密在库里是密文
        async with get_database().session() as session:
            row = (
                await session.execute(select(PluginData).where(PluginData.key == "token"))
            ).scalar_one()
        assert row.secret and "s3cret" not in str(row.value)

        with pytest.raises(ValueError, match="作用域"):
            await a.set("k", 1, scope="../etc")
        with pytest.raises(ValueError, match="KB"):
            await a.set("big", "x" * (70 * 1024))

    run(client, scenario)
    plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
    assert plugins["acme.a"]["data_rows"] == 3 and plugins["acme.b"]["data_rows"] == 1


def test_plugin_data_survives_reload(app_client) -> None:
    app, client = app_client
    store = mount(app, client, "acme.persist", (PLUGIN_DATA,))["store"]
    run(client, lambda: store.set("state", {"n": 1}))
    client.portal.call(app.state.kernel.unmount, "acme.persist")
    again = mount(app, client, "acme.persist", (PLUGIN_DATA,))["store"]
    assert run(client, lambda: again.get("state")) == {"n": 1}


# ---------------------------------------------------------------------- 健康
async def _notices(prefix: str) -> list[SystemNotice]:
    async with get_database().session() as session:
        rows = (await session.execute(select(SystemNotice))).scalars().all()
    return [n for n in rows if n.dedupe_key.startswith(prefix)]


def test_health_degraded_raises_notice_and_recovery_resolves(app_client) -> None:
    app, client = app_client
    health = mount(app, client, "acme.trakt", (PLUGIN_HEALTH,))["health"]

    run(
        client,
        lambda: health.degraded(
            "token", "Trakt 令牌已过期", action_href="/settings/app?tab=plugins"
        ),
    )
    run(client, lambda: health.degraded("token", "Trakt 令牌已过期"))  # 重复报告不刷新通知
    [notice] = run(client, lambda: _notices("plugin:acme.trakt:health:"))
    assert notice.status == NoticeStatus.ACTIVE.value
    assert notice.source == "plugin" and "令牌已过期" in notice.message
    assert notice.payload["action_href"] == "/settings/app?tab=plugins"

    plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
    [item] = plugins["acme.trakt"]["health"]
    assert item["ok"] is False and item["message"] == "Trakt 令牌已过期"

    run(client, lambda: health.ok("token"))
    [notice] = run(client, lambda: _notices("plugin:acme.trakt:health:"))
    assert notice.status == NoticeStatus.RESOLVED.value

    with pytest.raises(ValueError, match="站内路径"):
        run(client, lambda: health.degraded("x", "y", action_href="https://evil.example"))


def test_unloading_a_plugin_clears_its_degraded_health(app_client) -> None:
    app, client = app_client
    health = mount(app, client, "acme.flaky", (PLUGIN_HEALTH,))["health"]
    run(client, lambda: health.degraded("upstream", "外部系统连不上"))
    client.portal.call(app.state.kernel.unmount, "acme.flaky")
    [notice] = run(client, lambda: _notices("plugin:acme.flaky:health:"))
    assert notice.status == NoticeStatus.RESOLVED.value
    plugins = {p["id"] for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
    assert "acme.flaky" not in plugins

"""内置插件诊断、启动失败提醒、禁用补丁（docs/design/plugin-kernel.md §9、§10、§12.3）。

走真实应用：
- ``GET /app/plugins`` 列出全部内置插件与契约；
- 非关键插件启动失败 → 待处理事项出现；修好后重启 → 自动消退；
- ``data/plugins.yaml`` 能关掉允许关闭的插件，关不掉关键插件；格式不对只告警、照常启动。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    yield tmp_path
    get_settings.cache_clear()


def make_admin_client() -> tuple[object, TestClient]:
    get_settings.cache_clear()
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    return app, TestClient(app)


def test_plugins_endpoint_lists_every_entry_and_contract(env) -> None:
    app, client = make_admin_client()
    with client:
        body = client.get("/api/v1/app/plugins").json()["data"]
        by_id = {p["id"]: p for p in body["plugins"]}
        assert by_id.keys() == {f.id for f in app.state.kernel.fibers}
        assert by_id["core.database"]["state"] == "active"
        assert by_id["core.database"]["critical"] is True
        assert by_id["core.database"]["apply_ms"] > 0
        # 每个内置插件都归进了「设置 → 插件 → 内置」的某个分组（新增内置插件别忘了归组）
        assert body["groups"][0] == "基础"
        ungrouped = [p["id"] for p in body["plugins"] if p["group"] not in body["groups"]]
        assert ungrouped == []
        assert by_id["core.database"]["group"] == "基础"
        assert by_id["boost.sentinel"]["group"] == "资源站点与下载"
        assert by_id["scheduler"]["state"] == "disabled"
        assert by_id["scheduler"]["disabled_by"] == "env:SCHEDULER_ENABLED"
        assert by_id["boost.sentinel"]["blocked_by"] == [
            {"key": "scheduler", "reason": "提供方 scheduler 状态为 disabled"}
        ]

        services = {c["name"]: c for c in body["contracts"]["services"]}
        assert services["db"]["provider"] == "core.database"
        registries = {c["name"]: c for c in body["contracts"]["registries"]}
        task_ids = {c["id"] for c in registries["scheduled-tasks"]["contributions"]}
        assert "library_reconcile" in task_ids
        events = {c["name"]: c for c in body["contracts"]["events"]}
        assert events["kernel/plugin-state"]["listeners"] == ["kernel.notices:failure-notices"]


def _plugin_notices(client: TestClient) -> list[dict]:
    notices = client.get("/api/v1/system/notices").json()["data"]
    return [n for n in notices if n["source"] == "plugin"]


def test_failed_plugin_raises_a_notice_and_recovery_resolves_it(env, monkeypatch) -> None:
    from movieclaw_api.services import weixin_channel

    real_init = weixin_channel.init_weixin_channel

    async def broken() -> None:
        raise ConnectionError("微信网关不可达")

    monkeypatch.setattr(weixin_channel, "init_weixin_channel", broken)
    _, client = make_admin_client()
    with client:
        client.portal.call(client.app.state.kernel.bus.drain)  # type: ignore[attr-defined]
        notices = _plugin_notices(client)
        assert len(notices) == 1
        assert notices[0]["title"] == "「微信通道」启动失败"
        assert "微信网关不可达" in notices[0]["message"]
        assert "设置 → 插件 → 内置" in notices[0]["message"]
        assert notices[0]["payload"] == {
            "entry_id": "channel.weixin",
            "action_href": "/settings/plugins?tab=builtin",
        }

    # 修好之后重启：插件恢复运行，告警自动消退
    monkeypatch.setattr(weixin_channel, "init_weixin_channel", real_init)
    _, client = make_admin_client()
    with client:
        client.portal.call(client.app.state.kernel.bus.drain)  # type: ignore[attr-defined]
        assert _plugin_notices(client) == []


def test_patch_file_disables_only_disableable_plugins(env, monkeypatch, caplog) -> None:
    from movieclaw_jellyfin import udp

    started: list[int] = []

    async def fake_start(port: int) -> None:
        started.append(port)

    monkeypatch.setattr(udp, "start_discovery", fake_start)
    (env / "plugins.yaml").write_text(
        "- id: jellyfin.discovery\n"
        "  disabled: true\n"
        "- id: core.database\n"
        "  disabled: true\n"
        "- id: no.such.plugin\n"
        "  disabled: true\n",
        encoding="utf-8",
    )
    app, client = make_admin_client()
    with client:
        kernel = app.state.kernel
        discovery = kernel.fiber("jellyfin.discovery")
        assert discovery.state.value == "disabled"
        assert discovery.disabled_by == "patch"
        assert started == [], "被禁用的插件不该执行"
        assert kernel.fiber("core.database").state.value == "active"
    assert "core.database 不允许禁用" in caplog.text
    assert "no.such.plugin 不存在" in caplog.text


def test_malformed_patch_file_is_ignored_with_a_warning(env, caplog) -> None:
    (env / "plugins.yaml").write_text("jellyfin.discovery: [unclosed", encoding="utf-8")
    app, client = make_admin_client()
    with client:
        assert app.state.kernel.fiber("jellyfin.discovery").state.value == "active"
    assert "插件补丁文件" in caplog.text


def test_durable_section_and_dead_letter_actions(env) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import DomainEvent, EventDeadLetter

    _, client = make_admin_client()
    with client:
        body = client.get("/api/v1/app/plugins").json()["data"]
        assert body["durable"] == {"consumers": [], "dead_letters": []}

        async def seed() -> int:
            async with get_database().session() as session:
                session.add(DomainEvent(seq=5, id="01EVT", name="library.item.deleted", payload={}))
                letter = EventDeadLetter(
                    consumer_id="acme.gone:main",
                    event_seq=5,
                    event_id="01EVT",
                    event_name="library.item.deleted",
                    error="RuntimeError: boom",
                    attempts=6,
                )
                session.add(letter)
                await session.commit()
                return letter.id

        letter_id = client.portal.call(seed)  # 在应用自己的事件循环里写库
        [letter] = client.get("/api/v1/app/plugins").json()["data"]["durable"]["dead_letters"]
        assert letter["id"] == letter_id and letter["error"] == "RuntimeError: boom"

        # 订阅它的插件不在运行：重放给出可读原因，不改死信
        resp = client.post(f"/api/v1/app/plugins/dead-letters/{letter_id}/replay")
        assert resp.status_code == 409
        assert "没有运行" in resp.json()["message"]
        assert client.post("/api/v1/app/plugins/dead-letters/999/replay").status_code == 404

        assert (
            client.post(f"/api/v1/app/plugins/dead-letters/{letter_id}/dismiss").status_code == 200
        )
        assert client.get("/api/v1/app/plugins").json()["data"]["durable"]["dead_letters"] == []


def test_durable_section_is_empty_when_delivery_plugin_disabled(env) -> None:
    (env / "plugins.yaml").write_text("- id: kernel.durable-events\n  disabled: true\n")
    _, client = make_admin_client()
    with client:
        body = client.get("/api/v1/app/plugins").json()["data"]
        by_id = {p["id"]: p for p in body["plugins"]}
        assert by_id["kernel.durable-events"]["state"] == "disabled"
        assert body["durable"] is None
        resp = client.post("/api/v1/app/plugins/dead-letters/1/dismiss")
        assert resp.status_code == 409

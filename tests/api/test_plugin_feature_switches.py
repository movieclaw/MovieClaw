"""功能开关的状态管理（docs/design/plugin-page-tiers.md §6）。

走真实应用：插件页停用一个功能 → 组成插件当场停下、状态落盘；重启后保持；开启后当场恢复。
管理员在 data/plugins.yaml 里关掉的功能，开关锁住并写明原因；切换出错时状态回滚。
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import plugin_features
from movieclaw_kernel import State

FEATURES = "/api/v1/app/features"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    yield tmp_path
    get_settings.cache_clear()


def make_client(*, admin: bool = True) -> tuple[object, TestClient]:
    get_settings.cache_clear()
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    who = Principal(kind="admin", name="tester", is_admin=True) if admin else None
    if who is None:
        who = Principal(kind="member", name="family", is_admin=False)
    app.dependency_overrides[require_login] = lambda: who
    return app, TestClient(app)


def by_key(client: TestClient) -> dict[str, dict]:
    reply = client.get(FEATURES)
    assert reply.status_code == 200, reply.text
    return {f["key"]: f for f in reply.json()["data"]}


def switch(client: TestClient, key: str, enabled: bool):
    return client.put(f"{FEATURES}/{key}", json={"enabled": enabled})


def test_disable_takes_effect_now_survives_restart_and_enables_back(env) -> None:
    app, client = make_client()
    with client:
        kernel = app.state.kernel
        features = by_key(client)
        assert features["jellyfin-discovery"]["switchable"] is True
        assert features["jellyfin-discovery"]["enabled"] is True
        assert features["subtitle-gen"]["switchable"] is False
        assert "agent" not in features  # AI 助手是核心，不在功能目录里

        reply = switch(client, "jellyfin-discovery", False)
        assert reply.status_code == 200, reply.text
        view = reply.json()["data"]
        assert view["enabled"] is False and view["changed_by"] == "tester" and view["changed_at"]
        fiber = kernel.fiber("jellyfin.discovery")
        assert fiber.state is State.DISABLED
        assert fiber.disabled_by == "feature:jellyfin-discovery"
        saved = json.loads((env / "plugins-features.json").read_text("utf-8"))
        assert saved["disabled"]["jellyfin-discovery"]["by"] == "tester"
        # 再停一次是无操作，不改停用时间
        assert switch(client, "jellyfin-discovery", False).status_code == 200
        assert json.loads((env / "plugins-features.json").read_text("utf-8")) == saved

    # 重启：启动时就不运行（补丁层），诊断写明是功能开关关的
    app, client = make_client()
    with client:
        fiber = app.state.kernel.fiber("jellyfin.discovery")
        assert fiber.state is State.DISABLED
        assert fiber.disabled_by == "feature:jellyfin-discovery"
        plugins = client.get("/api/v1/app/plugins").json()["data"]
        listed = {f["key"]: f for f in plugins["features"]}
        assert listed["jellyfin-discovery"]["enabled"] is False

        reply = switch(client, "jellyfin-discovery", True)
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["enabled"] is True
        assert fiber.state is State.ACTIVE
        assert json.loads((env / "plugins-features.json").read_text("utf-8"))["disabled"] == {}


def test_multi_plugin_feature_stops_in_reverse_and_starts_in_order(env, monkeypatch) -> None:
    from movieclaw_api.plugins.features import Feature

    pair = Feature(
        "pair", "成对功能", "测试用", ("library.watch", "library.ingest-watch"), None, True
    )
    monkeypatch.setattr(plugin_features, "feature", lambda key: pair if key == "pair" else None)
    app, client = make_client()
    with client:
        kernel = app.state.kernel
        calls: list[tuple[str, str]] = []
        real_disable, real_enable = kernel.disable, kernel.enable

        async def disable(entry_id, *, source="runtime"):
            calls.append(("disable", entry_id))
            await real_disable(entry_id, source=source)

        async def enable(entry_id):
            calls.append(("enable", entry_id))
            await real_enable(entry_id)

        monkeypatch.setattr(kernel, "disable", disable)
        monkeypatch.setattr(kernel, "enable", enable)
        settings = get_settings()
        client.portal.call(
            lambda: plugin_features.set_enabled(kernel, settings, "pair", False, actor="t")
        )
        client.portal.call(
            lambda: plugin_features.set_enabled(kernel, settings, "pair", True, actor="t")
        )
        assert calls == [
            ("disable", "library.ingest-watch"),
            ("disable", "library.watch"),
            ("enable", "library.watch"),
            ("enable", "library.ingest-watch"),
        ]


def test_admin_override_locks_the_switch(env) -> None:
    (env / "plugins.yaml").write_text("- id: library.watch\n  disabled: true\n", encoding="utf-8")
    app, client = make_client()
    with client:
        view = by_key(client)["library-watch"]
        assert view["enabled"] is False
        assert view["locked_by"] == "已在 data/plugins.yaml 中关闭"
        for enabled in (True, False):
            reply = switch(client, "library-watch", enabled)
            assert reply.status_code == 409
            assert reply.json()["code"] == "FEATURE_LOCKED"
        assert not (env / "plugins-features.json").exists()


def test_unknown_and_core_features_cannot_be_switched(env) -> None:
    _, client = make_client()
    with client:
        assert switch(client, "nope", False).status_code == 404
        reply = switch(client, "subtitle-gen", False)
        assert reply.status_code == 400 and reply.json()["code"] == "FEATURE_NOT_SWITCHABLE"


def test_kernel_failure_rolls_the_state_back(env, monkeypatch) -> None:
    app, client = make_client()
    with client:
        kernel = app.state.kernel

        async def broken(entry_id, *, source="runtime"):
            raise RuntimeError("内核出错")

        monkeypatch.setattr(kernel, "disable", broken)
        with pytest.raises(RuntimeError):
            client.portal.call(
                lambda: plugin_features.set_enabled(
                    kernel, get_settings(), "arrivals", False, actor="t"
                )
            )
        assert plugin_features.read_disabled(get_settings()) == {}
        assert kernel.fiber("push.arrivals").state is State.ACTIVE


def test_members_can_read_but_not_switch(env) -> None:
    _, client = make_client(admin=False)
    with client:
        assert by_key(client)["arrivals"]["enabled"] is True
        assert switch(client, "arrivals", False).status_code == 403


def test_state_file_is_tolerant(env, caplog) -> None:
    settings = get_settings()
    path = plugin_features.state_path(settings)
    path.write_text("{坏的 json", encoding="utf-8")
    assert plugin_features.read_disabled(settings) == {}
    path.write_text(
        json.dumps(
            {"disabled": {"subtitle-gen": {}, "gone": {}, "arrivals": {"at": "t", "by": "a"}}}
        ),
        encoding="utf-8",
    )
    # 不可停用的、已不存在的功能都忽略，免得一个旧开关永远关着某个插件
    assert list(plugin_features.read_disabled(settings)) == ["arrivals"]
    patches = plugin_features.feature_patches(settings)
    assert [(p.id, p.source) for p in patches] == [("push.arrivals", "feature:arrivals")]

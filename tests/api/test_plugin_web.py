"""插件网页（docs/design/plugin-web-pages.md）。

真实应用、真实接口：只带网页的插件包上传 → 批准页预览侧边栏入口 → 不同意授信不让装 → 同意后托管
（同源可嵌、ETag、单页回退只对页面导航）→ ``/ui/apps`` 按 manifest 给出侧边栏项 → 成员默认看不到；
本地插件确认一次后改文件即时生效、撤销后不再托管；安全模式全停；插件路由不能占 ``/web``。
"""

from __future__ import annotations

import io
import json
import sys
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events, plugin_packages, plugin_web

MANIFEST = """
[plugin]
id = "acme-web"
title = "看板插件"
version = "{version}.0.0"
"""

WEBMANIFEST = {
    "name": "本周看板",
    "short_name": "看板",
    "start_url": ".",
    "icons": [
        {"src": "big.png", "sizes": "512x512", "type": "image/png"},
        {"src": "icon.svg", "type": "image/svg+xml", "purpose": "monochrome"},
    ],
    "shortcuts": [
        {"name": "下载统计", "url": "downloads"},
        {"name": "越界", "url": "/library"},
    ],
}
ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2h20v20H2z"/></svg>'


def web_package(version: int = 1) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("movieclaw-plugin.toml", MANIFEST.format(version=version))
        archive.writestr("web/index.html", f"<!doctype html><title>v{version}</title>")
        archive.writestr("web/app.js", "console.log('hi')")
        archive.writestr("web/manifest.webmanifest", json.dumps(WEBMANIFEST))
        archive.writestr("web/icon.svg", ICON)
    return buffer.getvalue()


@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'web.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(plugin_packages, "GRACE_POLL", 0.1)
    get_settings.cache_clear()
    durable_events.reset_state()
    yield tmp_path
    for name in [m for m in sys.modules if m.startswith("movieclaw_packages")]:
        del sys.modules[name]
    durable_events.reset_state()
    get_settings.cache_clear()


class Who:
    """按测试切换请求主体：管理员 / 成员。"""

    def __init__(self) -> None:
        from movieclaw_api.services.auth import Principal

        self.admin = Principal(kind="admin", name="tester")
        self.member = Principal(kind="member", name="family", is_admin=False)
        self.current = self.admin


def start() -> tuple[TestClient, Who]:
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.exceptions import ForbiddenException

    app = create_app()
    who = Who()

    def admin_only():
        if not who.current.is_admin:
            raise ForbiddenException("该操作需要管理员权限")
        return who.current

    app.dependency_overrides[require_admin] = admin_only
    app.dependency_overrides[require_login] = lambda: who.current
    return TestClient(app), who


def upload(client: TestClient, data: bytes):
    return client.post(
        "/api/v1/app/plugins/packages",
        files={"file": ("acme.mcplugin", data, "application/zip")},
    )


def approve(client: TestClient, version: str, **extra):
    return client.post(
        "/api/v1/app/plugins/packages/acme-web/approve",
        json={"version": version, "operations": [], **extra},
    )


def apps(client: TestClient) -> dict:
    return {a["id"]: a for a in client.get("/api/v1/ui/apps").json()["data"]}


def test_web_only_package_from_upload_to_sidebar(data_dir) -> None:
    client, who = start()
    with client:
        uploaded = upload(client, web_package())
        assert uploaded.status_code == 200, uploaded.text
        preview = uploaded.json()["data"]["web"]
        assert preview["name"] == "本周看板"
        main, downloads = preview["entries"]  # 越界的那项 shortcut 被丢掉
        assert main["label"] == "看板" and main["path"] == "" and main["monochrome"]
        assert main["icon"].startswith("data:image/svg+xml;base64,")
        assert downloads == {**downloads, "label": "下载统计", "path": "downloads"}

        # 待批准时不托管
        assert client.get("/api/v1/plugins/acme-web/web/").status_code == 404

        refused = approve(client, "1.0.0")
        assert refused.status_code == 400 and "身份运行" in refused.json()["message"]
        result = approve(client, "1.0.0", allow_web=True)
        assert result.status_code == 200, result.text
        assert result.json()["data"]["status"] == "active"

        listed = apps(client)["acme-web"]
        assert listed["nav"] is True and listed["base"] == "/api/v1/plugins/acme-web/web/"
        assert [e["label"] for e in listed["entries"]] == ["看板", "下载统计"]
        assert listed["entries"][0]["icon"] == "/api/v1/plugins/acme-web/web/icon.svg"

        page = client.get("/api/v1/plugins/acme-web/web/", headers={"sec-fetch-dest": "iframe"})
        assert page.status_code == 200 and "<title>v1</title>" in page.text
        assert page.headers["x-frame-options"] == "SAMEORIGIN"
        assert "frame-ancestors 'self'" in page.headers["content-security-policy"]
        assert page.headers["cache-control"] == "no-cache"
        etag = page.headers["etag"]
        cached = client.get("/api/v1/plugins/acme-web/web/", headers={"if-none-match": etag})
        assert cached.status_code == 304

        manifest = client.get("/api/v1/plugins/acme-web/web/manifest.webmanifest")
        assert manifest.headers["content-type"].startswith("application/manifest+json")
        script = client.get("/api/v1/plugins/acme-web/web/app.js")
        assert script.headers["content-type"].startswith("text/javascript")

        # 单页回退：页面导航给 index.html；脚本、图片找不到照常 404
        deep = client.get(
            "/api/v1/plugins/acme-web/web/downloads/2026-10", headers={"sec-fetch-dest": "iframe"}
        )
        assert deep.status_code == 200 and "<title>v1</title>" in deep.text
        missing = client.get(
            "/api/v1/plugins/acme-web/web/missing.js", headers={"sec-fetch-dest": "script"}
        )
        assert missing.status_code == 404
        escaped = client.get("/api/v1/plugins/acme-web/web/%2e%2e/%2e%2e/state.json")
        assert escaped.status_code == 404

        root = client.get("/api/v1/plugins/acme-web/web?x=1", follow_redirects=False)
        assert root.status_code == 308
        assert root.headers["location"] == "/api/v1/plugins/acme-web/web/?x=1"

        # 成员默认看不到，也取不到文件；管理员勾上「成员也能看到」后才行
        who.current = who.member
        assert "acme-web" not in apps(client)
        assert client.get("/api/v1/plugins/acme-web/web/").status_code == 404
        who.current = who.admin
        updated = client.put(
            "/api/v1/app/plugins/acme-web/web", json={"nav": False, "members": True}
        )
        assert updated.status_code == 200, updated.text
        who.current = who.member
        assert apps(client)["acme-web"]["nav"] is False
        assert client.get("/api/v1/plugins/acme-web/web/").status_code == 200
        assert client.put("/api/v1/app/plugins/acme-web/web", json={}).status_code == 403

        # 升级：每个版本重新同意，文件跟着换
        who.current = who.admin
        upload(client, web_package(2))
        assert approve(client, "2.0.0").status_code == 400
        assert approve(client, "2.0.0", allow_web=True).json()["data"]["status"] == "active"
        assert "<title>v2</title>" in client.get("/api/v1/plugins/acme-web/web/").text
        installed = client.get("/api/v1/app/plugins/packages").json()["data"]["installed"]
        assert installed[0]["web"] == {"nav": True, "members": False}

        # 撤销：不再托管、不进列表，插件本身还在
        assert client.delete("/api/v1/app/plugins/acme-web/web").status_code == 200
        assert "acme-web" not in apps(client)
        assert client.get("/api/v1/plugins/acme-web/web/").status_code == 404
        pages = client.get("/api/v1/app/plugins/pages").json()["data"]
        assert [(p["id"], p["approved"]) for p in pages] == [("acme-web", False)]


def test_package_without_entry_or_web_is_rejected(data_dir) -> None:
    client, _ = start()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("movieclaw-plugin.toml", MANIFEST.format(version=1))
    with client:
        rejected = upload(client, buffer.getvalue())
    assert rejected.status_code == 400
    assert "web/index.html" in rejected.json()["message"]


def write_local(data_dir: Path) -> Path:
    (data_dir / "plugins.yaml").write_text("- id: weekly-board\n  local: true\n", encoding="utf-8")
    web = data_dir / "plugins" / "weekly_board" / "web"
    web.mkdir(parents=True)
    (web / "index.html").write_text("<title>本地</title>", encoding="utf-8")
    return web


def test_local_web_plugin_needs_one_confirmation_then_edits_are_live(data_dir) -> None:
    web = write_local(data_dir)
    client, _ = start()
    with client:
        # 只有 web/ 的本地插件照常加载成一个空插件
        state = client.get("/api/v1/app/plugins/weekly-board").json()["data"]["plugin"]["state"]
        assert state == "active"
        pages = client.get("/api/v1/app/plugins/pages").json()["data"]
        assert [(p["id"], p["source"], p["approved"]) for p in pages] == [
            ("weekly-board", "local", False)
        ]
        assert client.get("/api/v1/plugins/weekly-board/web/").status_code == 404
        assert "weekly-board" not in apps(client)

        confirmed = client.put("/api/v1/app/plugins/weekly-board/web", json={})
        assert confirmed.status_code == 200 and confirmed.json()["message"] == "已同意"
        entry = apps(client)["weekly-board"]["entries"][0]
        assert entry == {"label": "weekly-board", "path": "", "icon": None, "monochrome": False}
        assert "本地" in client.get("/api/v1/plugins/weekly-board/web/").text

        # 改文件即时生效，加 manifest 也不用重启
        (web / "index.html").write_text("<title>改过了</title>", encoding="utf-8")
        (web / "manifest.webmanifest").write_text('{"short_name": "周报"}', encoding="utf-8")
        assert "改过了" in client.get("/api/v1/plugins/weekly-board/web/").text
        assert apps(client)["weekly-board"]["entries"][0]["label"] == "周报"

        assert client.delete("/api/v1/app/plugins/weekly-board/web").status_code == 200
        assert client.get("/api/v1/plugins/weekly-board/web/").status_code == 404


def test_confirmation_must_come_from_a_person_in_the_browser(data_dir) -> None:
    from dataclasses import replace

    write_local(data_dir)
    client, who = start()
    # 命令行 / Agent 的令牌：管理员身份，但不是人在第一方客户端里操作
    who.current = replace(who.admin, kind="agent")
    assert not who.current.interactive
    with client:
        refused = client.put("/api/v1/app/plugins/weekly-board/web", json={})
        assert refused.status_code == 403 and "网页里操作" in refused.json()["message"]
        assert plugin_web.read_local_consents(get_settings()) == {}


def test_safe_mode_hides_every_page(data_dir, monkeypatch) -> None:
    from movieclaw_api.plugins import safe_mode

    write_local(data_dir)
    plugin_web.write_local_consent(get_settings(), "weekly-board", plugin_web.Consent())
    client, _ = start()
    with client:
        assert "weekly-board" in apps(client)
        monkeypatch.setattr(safe_mode, "current", lambda: safe_mode.SafeMode(active=True))
        assert apps(client) == {}
        assert client.get("/api/v1/plugins/weekly-board/web/").status_code == 404


def test_plugin_routes_cannot_take_the_web_segment() -> None:
    from fastapi import APIRouter

    from movieclaw_api.services.plugin_routes import PluginRoutes

    class Ctx:
        entry_id = "acme-web"

        def effect(self, *args, **kwargs) -> None:
            raise AssertionError("不该挂上")

    router = APIRouter()

    @router.get("/web/x", operation_id="plugins.acme-web.x")
    async def handler() -> None:
        return None

    with pytest.raises(ValueError, match="/web"):
        PluginRoutes(app=None, store_for=None).mount(Ctx(), router)


def test_manifest_fields_follow_the_standard(tmp_path) -> None:
    root = tmp_path / "web"
    root.mkdir()
    (root / "index.html").write_text("x", encoding="utf-8")
    plugin = plugin_web.WebPlugin(id="p", title="插件名", source="local", root=root, consent=None)
    # 没有 manifest：一项主入口，文字用插件名
    assert plugin_web.read_manifest(plugin).entries == [plugin_web.NavEntry("插件名", "")]
    (root / "manifest.json").write_text(
        json.dumps(
            {
                "name": "完整名字",
                "start_url": "./home?tab=1",
                "icons": [{"src": "a.png"}],
                "shortcuts": [{"short_name": "外站", "url": "https://example.com/"}],
            }
        ),
        encoding="utf-8",
    )
    manifest = plugin_web.read_manifest(plugin)
    assert manifest.name == "完整名字"
    assert manifest.entries == [
        plugin_web.NavEntry("完整名字", "home?tab=1", "/api/v1/plugins/p/web/a.png", False)
    ]
    (root / "manifest.json").write_text("{坏的", encoding="utf-8")
    assert plugin_web.read_manifest(plugin).entries == [plugin_web.NavEntry("插件名", "")]


def test_nav_hidden_round_trips_through_ui_preferences(data_dir) -> None:
    client, _ = start()
    with client:
        prefs = client.get("/api/v1/ui/preferences").json()["data"]
        assert prefs["nav"]["hidden"] is None
        prefs["nav"]["hidden"] = ["app:acme-web:1"]
        saved = client.put("/api/v1/ui/preferences", json=prefs)
        assert saved.status_code == 200, saved.text
        again = client.get("/api/v1/ui/preferences").json()["data"]
        assert again["nav"]["hidden"] == ["app:acme-web:1"]

        # 老的 iPhone App 整体回写时不带 hidden：保留原值；显式给 null 才清空
        del again["nav"]["hidden"]
        again["home"] = {"rows": []}
        client.put("/api/v1/ui/preferences", json=again)
        kept = client.get("/api/v1/ui/preferences").json()["data"]
        assert kept["nav"]["hidden"] == ["app:acme-web:1"]
        client.put("/api/v1/ui/preferences", json={**kept, "nav": {"order": [], "hidden": None}})
        assert client.get("/api/v1/ui/preferences").json()["data"]["nav"]["hidden"] is None


def test_page_errors_go_to_the_system_log_with_a_rate_limit(data_dir, caplog) -> None:
    import logging

    write_local(data_dir)
    plugin_web.write_local_consent(get_settings(), "weekly-board", plugin_web.Consent())
    plugin_web._error_window.clear()
    client, who = start()
    with client, caplog.at_level(logging.WARNING, logger="movieclaw_api.plugin_web"):
        sent = client.post(
            "/api/v1/ui/apps/weekly-board/errors",
            json={"message": "TypeError: x is undefined", "detail": "app.js:3"},
        )
        assert sent.status_code == 200
        assert any("weekly-board" in r.message and "TypeError" in r.message for r in caplog.records)
        for _ in range(plugin_web.ERRORS_PER_MINUTE + 5):
            client.post("/api/v1/ui/apps/weekly-board/errors", json={"message": "again"})
        recorded = [r for r in caplog.records if "again" in r.message]
        assert len(recorded) == plugin_web.ERRORS_PER_MINUTE - 1
        # 看不到的页面不收报错
        who.current = who.member
        hidden = client.post("/api/v1/ui/apps/weekly-board/errors", json={"message": "x"})
        assert hidden.status_code == 404


def test_static_requests_do_not_reparse_plugins_yaml(data_dir, monkeypatch) -> None:
    """静态文件请求每次都查插件：plugins.yaml 没变就不重新解析（不重复告警、不重复登记事件）。"""
    from movieclaw_api.plugins import manifest

    write_local(data_dir)
    plugin_web.write_local_consent(get_settings(), "weekly-board", plugin_web.Consent())
    calls = []
    original = manifest.read_patch_items
    monkeypatch.setattr(manifest, "read_patch_items", lambda s: calls.append(1) or original(s))
    plugin_web._local_cache.clear()
    client, _ = start()
    with client:
        calls.clear()
        for _ in range(5):
            assert client.get("/api/v1/plugins/weekly-board/web/").status_code == 200
        assert len(calls) <= 1


def test_concurrent_local_consents_are_all_kept(data_dir) -> None:
    import threading

    settings = get_settings()
    threads = [
        threading.Thread(
            target=plugin_web.write_local_consent, args=(settings, f"p{i}", plugin_web.Consent())
        )
        for i in range(20)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(plugin_web.read_local_consents(settings)) == sorted(f"p{i}" for i in range(20))


def test_page_error_cannot_forge_log_lines(caplog) -> None:
    import logging

    plugin_web._error_window.clear()
    with caplog.at_level(logging.WARNING, logger="movieclaw_api.plugin_web"):
        plugin_web.log_page_error(
            "weekly-board",
            "family",
            "boom\n2026-10-19 00:00:00 | ERROR | movieclaw_api | 伪造",
            "app.js:1\n\x1b[31mred",
        )
    text = caplog.records[-1].getMessage()
    lines = text.splitlines()
    assert "伪造" in lines[0]  # 消息里的换行被压掉，伪造的内容留在第一行里
    assert all(line.startswith("    ") for line in lines[1:])  # 出处逐行缩进
    assert "\x1b" not in text

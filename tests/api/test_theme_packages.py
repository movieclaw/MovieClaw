"""网页主题插件（docs/design/theme-plugins.md §4.6）。

真实应用、真实接口：主题包上传 → 批准页预览选择卡 → 带外框组件不同意授信不让装 → 装上后进主题目录、
聚合样式表、样式免登录可取、外框组件要登录 → 停用 / 卸载即消失；随带主题可卸载、恢复、
被同 id 包替换，安全模式照常；契约不兼容的列出来但不托管；清单与文件对不上的拒装。
"""

from __future__ import annotations

import io
import sys
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.api.routes import themes as themes_routes
from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins import bundled as bundled_mod
from movieclaw_api.plugins import packages as pkg
from movieclaw_api.services import durable_events, plugin_packages

THEME_TOML = """
[plugin]
id = "{id}"
title = "{title}"
version = "{version}"

[requires]
"ui.theme" = "{requires}"

[theme]
label = "{label}"
description = "测试主题"
preview = {{ bg = "#141414", accent = "#e50914" }}
theme_color = "#000000"
layout = "{layout}"
glass = false
"""

CSS = 'html[data-theme="{id}"] {{ --bg: #000; background: url("assets/bg.png"); }}'
JS = "export default { slots: {}, pages: {} };"


def theme_files(
    theme_id: str = "acme-theme",
    *,
    version: str = "1.0.0",
    layout: str = "cinema",
    requires: str = "^1.0",
    with_js: bool = True,
    label: str = "Acme",
) -> dict[str, str | bytes]:
    files: dict[str, str | bytes] = {
        "movieclaw-plugin.toml": THEME_TOML.format(
            id=theme_id,
            title=f"{label} 主题",
            version=version,
            requires=requires,
            label=label,
            layout=layout,
        ),
        "theme/theme.css": CSS.format(id=theme_id),
        "theme/assets/bg.png": b"\x89PNG fake",
    }
    if with_js:
        files["theme/index.js"] = JS
    return files


def zipped(files: dict[str, str | bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return buffer.getvalue()


def write_tree(root: Path, files: dict[str, str | bytes]) -> Path:
    for name, content in files.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            target.write_bytes(content)
        else:
            target.write_text(content, encoding="utf-8")
    return root


@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'theme.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(plugin_packages, "GRACE_POLL", 0.1)
    # 随带插件包换成测试目录：只有一个随带主题
    bundled_root = tmp_path / "bundled"
    bundled_root.mkdir()
    monkeypatch.setattr(bundled_mod, "root", lambda: bundled_root)
    bundled_mod.bundled.cache_clear()
    get_settings.cache_clear()
    durable_events.reset_state()
    yield tmp_path
    bundled_mod.bundled.cache_clear()
    for name in [m for m in sys.modules if m.startswith("movieclaw_packages")]:
        del sys.modules[name]
    durable_events.reset_state()
    get_settings.cache_clear()


class Who:
    def __init__(self) -> None:
        from movieclaw_api.services.auth import Principal

        self.admin = Principal(kind="admin", name="tester")
        self.member = Principal(kind="member", name="family", is_admin=False)
        self.current = self.admin
        self.anonymous = False


def start() -> tuple[TestClient, Who]:
    from movieclaw_api.api.deps import optional_login, require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.exceptions import ForbiddenException, UnauthorizedException

    app = create_app()
    who = Who()

    def login():
        if who.anonymous:
            raise UnauthorizedException("请先登录")
        return who.current

    def admin_only():
        if not login().is_admin:
            raise ForbiddenException("该操作需要管理员权限")
        return who.current

    app.dependency_overrides[require_admin] = admin_only
    app.dependency_overrides[require_login] = login
    app.dependency_overrides[optional_login] = lambda: None if who.anonymous else who.current
    app.dependency_overrides[themes_routes._script_viewer] = lambda: (
        None if who.anonymous else who.current
    )
    return TestClient(app), who


def upload(client: TestClient, data: bytes):
    return client.post(
        "/api/v1/app/plugins/packages",
        files={"file": ("theme.mcplugin", data, "application/zip")},
    )


def catalog(client: TestClient) -> dict[str, dict]:
    response = client.get("/api/v1/ui/themes")
    assert response.status_code == 200, response.text
    return {t["id"]: t for t in response.json()["data"]}


def test_theme_package_from_upload_to_catalog_and_uninstall(data_dir) -> None:
    client, who = start()
    with client:
        uploaded = upload(client, zipped(theme_files()))
        assert uploaded.status_code == 200, uploaded.text
        assert uploaded.json()["data"]["entry"] == ""  # 没有后端代码：批准页据此不写「独立进程」
        preview = uploaded.json()["data"]["theme"]
        assert preview == {
            "label": "Acme",
            "description": "测试主题",
            "preview": {"bg": "#141414", "accent": "#e50914"},
            "layout": "cinema",
            "glass": False,
            "has_code": True,
        }
        # 待批准时不进目录
        assert "acme-theme" not in catalog(client)

        body = {"version": "1.0.0", "operations": []}
        refused = client.post("/api/v1/app/plugins/packages/acme-theme/approve", json=body)
        assert refused.status_code == 400 and "身份运行" in refused.json()["message"]
        approved = client.post(
            "/api/v1/app/plugins/packages/acme-theme/approve", json={**body, "allow_theme": True}
        )
        assert approved.status_code == 200, approved.text
        assert approved.json()["data"]["status"] == "active"

        theme = catalog(client)["acme-theme"]
        assert theme["label"] == "Acme" and theme["layout"] == "cinema"
        assert theme["glass"] is False and theme["theme_color"] == "#000000"
        assert theme["source"] == "package" and theme["status"] == "ok"
        assert theme["css"].startswith("/api/v1/ui/themes/acme-theme/theme.css?v=1.0.0-")
        assert theme["script"].startswith("/api/v1/ui/themes/acme-theme/index.js?v=1.0.0-")

        # 成员也能列出、选用（装卸是管理员的事，选主题是每个人自己的偏好）
        who.current = who.member
        assert "acme-theme" in catalog(client)
        who.current = who.admin

        # 聚合样式表与样式文件免登录；带 v 的地址长缓存
        who.anonymous = True
        sheet = client.get("/api/v1/ui/themes.css")
        assert sheet.status_code == 200 and sheet.headers["content-type"].startswith("text/css")
        assert f'@import url("{theme["css"]}");' in sheet.text
        assert sheet.headers["cache-control"] == "no-cache"
        assert (
            client.get(
                "/api/v1/ui/themes.css", headers={"if-none-match": sheet.headers["etag"]}
            ).status_code
            == 304
        )
        css = client.get(theme["css"])
        assert css.status_code == 200 and 'html[data-theme="acme-theme"]' in css.text
        assert css.headers["cache-control"] == "public, max-age=31536000, immutable"
        assert client.get("/api/v1/ui/themes/acme-theme/assets/bg.png").status_code == 200
        # 外框组件只给登录的人；目录接口也要登录
        assert client.get(theme["script"]).status_code == 401
        assert client.get("/api/v1/ui/themes").status_code == 401
        who.anonymous = False
        script = client.get(theme["script"])
        assert script.status_code == 200 and script.headers["content-type"].startswith(
            "text/javascript"
        )
        assert script.headers["cache-control"] == "private, max-age=31536000, immutable"
        # 越界与不存在
        assert (
            client.get("/api/v1/ui/themes/acme-theme/%2e%2e/movieclaw-plugin.toml").status_code
            == 404
        )
        assert client.get("/api/v1/ui/themes/nope/theme.css").status_code == 404

        # 停用：从目录、样式表消失，文件不再托管
        off = client.put("/api/v1/app/plugins/acme-theme/enabled", json={"enabled": False})
        assert off.status_code == 200, off.text
        assert "acme-theme" not in catalog(client)
        assert "acme-theme" not in client.get("/api/v1/ui/themes.css").text
        assert client.get(theme["css"]).status_code == 404
        on = client.put("/api/v1/app/plugins/acme-theme/enabled", json={"enabled": True})
        assert on.status_code == 200, on.text
        assert "acme-theme" in catalog(client)

        # 卸载：全部消失
        removed = client.delete("/api/v1/app/plugins/packages/acme-theme")
        assert removed.status_code == 200, removed.text
        assert "acme-theme" not in catalog(client)
        assert "acme-theme" not in client.get("/api/v1/ui/themes.css").text


def test_pure_css_theme_needs_no_extra_consent(data_dir) -> None:
    client, _ = start()
    with client:
        files = theme_files("calm-theme", layout="panel", with_js=False)
        assert upload(client, zipped(files)).json()["data"]["theme"]["has_code"] is False
        approved = client.post(
            "/api/v1/app/plugins/packages/calm-theme/approve",
            json={"version": "1.0.0", "operations": []},
        )
        assert approved.status_code == 200, approved.text
        theme = catalog(client)["calm-theme"]
        assert theme["layout"] == "panel" and theme["script"] is None


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda f: f.pop("theme/theme.css"), "theme/theme.css"),
        (
            lambda f: f.update(
                {
                    "movieclaw-plugin.toml": f["movieclaw-plugin.toml"].replace(
                        '"ui.theme" = "^1.0"', ""
                    )
                }
            ),
            '"ui.theme"',
        ),
        (lambda f: f.pop("theme/index.js"), "cinema 版式"),
        (
            lambda f: f.update(
                {"movieclaw-plugin.toml": f["movieclaw-plugin.toml"].split("[theme]")[0]}
            ),
            "[theme] 段",
        ),
        (
            lambda f: f.update(
                {"movieclaw-plugin.toml": f["movieclaw-plugin.toml"].replace("#e50914", "red")}
            ),
            "颜色",
        ),
    ],
    ids=["no-css", "no-requires", "cinema-without-js", "theme-dir-without-section", "bad-color"],
)
def test_mismatched_theme_packages_are_rejected(mutate, message) -> None:
    files = theme_files()
    mutate(files)
    with pytest.raises(pkg.PackageError, match=message.replace("[", r"\[").replace("]", r"\]")):
        pkg.read_archive(zipped(files))


def test_incompatible_contract_is_listed_but_not_served(data_dir, monkeypatch) -> None:
    write_tree(data_dir / "bundled" / "future", theme_files("future-theme", requires="^2.0"))
    client, _ = start()
    with client:
        theme = catalog(client)["future-theme"]
        assert theme["status"] == "incompatible" and "2.0" in theme["reason"]
        assert theme["css"] is None and theme["script"] is None
        assert "future-theme" not in client.get("/api/v1/ui/themes.css").text
        assert client.get("/api/v1/ui/themes/future-theme/theme.css").status_code == 404


def test_bundled_theme_can_be_uninstalled_restored_and_replaced(data_dir, monkeypatch) -> None:
    from movieclaw_api.plugins import safe_mode

    write_tree(data_dir / "bundled" / "netflix", theme_files("netflix", label="Netflix"))
    client, _ = start()
    with client:
        theme = catalog(client)["netflix"]
        assert theme["source"] == "bundled" and theme["status"] == "ok"
        # 安全模式：随带主题照常（与随带插件包同口径）
        with monkeypatch.context() as m:
            m.setattr(safe_mode, "current", lambda: safe_mode.SafeMode(active=True))
            assert "netflix" in catalog(client)

        # 在插件页卸载 → 消失；恢复 → 回来
        gone = client.delete("/api/v1/app/plugins/netflix/bundled")
        assert gone.status_code == 200, gone.text
        assert "netflix" not in catalog(client)
        assert "netflix" not in client.get("/api/v1/ui/themes.css").text
        back = client.post("/api/v1/app/plugins/netflix/bundled/restore")
        assert back.status_code == 200, back.text
        assert catalog(client)["netflix"]["source"] == "bundled"

        # 同 id 插件包替换随带版本（热修通道）：目录里是插件包那份；卸载包后随带版本回来
        upload(client, zipped(theme_files("netflix", version="9.0.0", label="Netflix 热修")))
        approved = client.post(
            "/api/v1/app/plugins/packages/netflix/approve",
            json={"version": "9.0.0", "operations": [], "allow_theme": True},
        )
        assert approved.status_code == 200, approved.text
        replaced = catalog(client)["netflix"]
        assert replaced["source"] == "package" and replaced["label"] == "Netflix 热修"
        assert client.delete("/api/v1/app/plugins/packages/netflix").status_code == 200
        restored = catalog(client)["netflix"]
        assert restored["source"] == "bundled" and restored["label"] == "Netflix"


def test_safe_mode_drops_package_themes(data_dir, monkeypatch) -> None:
    from movieclaw_api.plugins import safe_mode

    client, _ = start()
    with client:
        upload(client, zipped(theme_files("calm-theme", layout="panel", with_js=False)))
        client.post(
            "/api/v1/app/plugins/packages/calm-theme/approve",
            json={"version": "1.0.0", "operations": []},
        )
        assert "calm-theme" in catalog(client)
        monkeypatch.setattr(safe_mode, "current", lambda: safe_mode.SafeMode(active=True))
        assert "calm-theme" not in catalog(client)
        assert client.get("/api/v1/ui/themes/calm-theme/theme.css").status_code == 404


def test_only_subresource_types_are_served_and_sandboxed(data_dir) -> None:
    """主题目录与主程序同源、样式免登录：能当页面打开的文件一律不给，给的都带沙箱 CSP。"""
    files = theme_files("calm-theme", layout="panel", with_js=False)
    files["theme/evil.html"] = "<script>fetch('/api/v1/app/plugins')</script>"
    files["theme/icon.svg"] = (
        '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    )
    write_tree(data_dir / "bundled" / "calm", files)
    client, _ = start()
    with client:
        assert client.get("/api/v1/ui/themes/calm-theme/evil.html").status_code == 404
        svg = client.get("/api/v1/ui/themes/calm-theme/icon.svg")
        assert svg.status_code == 200 and svg.headers["content-type"].startswith("image/svg+xml")
        assert "sandbox" in svg.headers["content-security-policy"]
        css = client.get("/api/v1/ui/themes/calm-theme/theme.css")
        assert "sandbox" in css.headers["content-security-policy"]


def test_stale_cookie_does_not_block_theme_styles(data_dir) -> None:
    """浏览器带着过期 / 吊销的 Cookie 打开登录页：样式照常给，外框组件按未登录拒。"""
    from movieclaw_api.app import create_app

    write_tree(data_dir / "bundled" / "netflix", theme_files("netflix", label="Netflix"))
    with TestClient(create_app()) as client:
        client.cookies.set("movieclaw_session", "stale-or-revoked")
        assert client.get("/api/v1/ui/themes.css").status_code == 200
        assert client.get("/api/v1/ui/themes/netflix/theme.css").status_code == 200
        assert client.get("/api/v1/ui/themes/netflix/assets/bg.png").status_code == 200
        assert client.get("/api/v1/ui/themes/netflix/index.js").status_code == 401

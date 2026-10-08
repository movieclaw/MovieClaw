"""插件贡献站点类与站点数据包（docs/design/plugin-phase2b.md §6）。

真实应用：一个本地来源的插件贡献 BaseSite 子类与一个站点 YAML 目录，站点目录接口立刻出现新站点；
插件卸下，站点随之消失、内置站点不受影响。
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.keys import SITE_CLASSES, SITE_DATA_PACKS
from movieclaw_kernel import Entry, plugin


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'sites.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
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
    from movieclaw_tracker import load_all_sites

    load_all_sites()


def catalog(client) -> dict[str, dict]:
    resp = client.get("/api/v1/sites/catalog")
    assert resp.status_code == 200, resp.text
    return {item["site_id"]: item for item in resp.json()["data"]}


def test_plugin_contributed_site_appears_and_goes_away(app_client, tmp_path: Path) -> None:
    from movieclaw_tracker import get_site_config
    from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite

    app, client = app_client

    class AcmeSite(NexusPHPSite):
        pass

    pack = tmp_path / "acme-pack"
    pack.mkdir()
    (pack / "acmept.yaml").write_text(
        "site_id: acmept\ndisplay_name: Acme PT\nbase_url: https://acme.example\n"
        "framework: nexusphp\ncustom_class: 'acme.sites:AcmeSite'\ncategories:\n  movie: [401]\n",
        encoding="utf-8",
    )

    @plugin("acme.sites", title="Acme 站点")
    async def acme(ctx) -> None:
        ctx.contribute(SITE_CLASSES, "AcmeSite", AcmeSite)
        ctx.contribute(SITE_DATA_PACKS, "pack", pack)

    builtin_before = set(catalog(client))
    assert "acmept" not in builtin_before

    fiber = client.portal.call(app.state.kernel.mount, Entry("acme.sites", acme, source="local"))
    assert fiber.state.value == "active", fiber.error or fiber.incompatible
    sites = catalog(client)
    assert sites["acmept"]["display_name"] == "Acme PT"
    # 第三方贡献的 id 自动带插件前缀，YAML 按带前缀的名字引用
    assert get_site_config("acmept").site_class is AcmeSite

    client.portal.call(app.state.kernel.unmount, "acme.sites")
    assert set(catalog(client)) == builtin_before

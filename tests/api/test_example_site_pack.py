"""站点数据包示例插件端到端（docs/design/plugin-phase2b.md §10 B8）。

把示例插件 ``site_pack/`` 当本地受信插件（包形式）装进临时数据目录，真实应用：
站点目录接口出现数据包里的站点；停用插件站点消失、内置站点不受影响；
用户目录里同 site_id 的配置覆盖数据包。
"""

from __future__ import annotations

import shutil
import sys
import textwrap
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE

EXAMPLES = (
    Path(__file__).resolve().parents[2]
    / "src"
    / "movieclaw_agent"
    / "builtin-skills"
    / "movieclaw-plugin-dev"
    / "references"
    / "examples"
)


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pack.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    shutil.copytree(EXAMPLES / "site_pack", tmp_path / "plugins" / "site_pack")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: site-pack
              local: true
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    with TestClient(app) as client:
        yield app, client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    get_settings.cache_clear()
    from movieclaw_tracker import load_all_sites

    load_all_sites()


def catalog(client) -> dict[str, dict]:
    resp = client.get("/api/v1/sites/catalog")
    assert resp.status_code == 200, resp.text
    return {item["site_id"]: item for item in resp.json()["data"]}


def test_site_pack_adds_sites_and_user_configs_still_win(app_client, tmp_path) -> None:
    from movieclaw_tracker import get_site_config
    from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite

    app, client = app_client
    kernel = app.state.kernel
    assert kernel.fiber("site-pack").state.value == "active"
    sites = catalog(client)
    assert sites["examplept"]["display_name"] == "Example PT（数据包示例）"
    assert get_site_config("examplept").site_class is NexusPHPSite
    builtin = set(sites) - {"examplept"}
    assert {"mteam", "hdsky"} <= builtin

    client.portal.call(kernel.disable, "site-pack")
    sites = catalog(client)
    assert "examplept" not in sites
    assert set(sites) == builtin

    # 用户目录同 site_id 覆盖数据包（优先级：内置 < 数据包 < 用户目录）
    user_dir = tmp_path / "site-configs"
    user_dir.mkdir(exist_ok=True)
    user = (EXAMPLES / "site_pack" / "sites" / "examplept.yaml").read_text(encoding="utf-8")
    (user_dir / "examplept.yaml").write_text(
        user.replace("Example PT（数据包示例）", "我改过的 Example"), encoding="utf-8"
    )
    client.portal.call(kernel.enable, "site-pack")
    assert catalog(client)["examplept"]["display_name"] == "我改过的 Example"

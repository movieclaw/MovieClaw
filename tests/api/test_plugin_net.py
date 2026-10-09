"""插件的网络出口（``movieclaw_sdk.net``，docs/design/plugin-channels.md §7）。

进程外插件读不到主程序的代理设置，向宿主询问；代理地址可能带账号密码，宿主只回答插件自己的服务名
（条目 id 的最后一段），问别的服务一律直连。
"""

from __future__ import annotations

import sys
import textwrap

from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE

PLUGIN = """
from fastapi import APIRouter

from movieclaw_api.plugins.keys import PLUGIN_ROUTES
from movieclaw_sdk import net, plugin


@plugin("acme.relay", title="出口插件", inject=(PLUGIN_ROUTES,))
async def apply(ctx) -> None:
    router = APIRouter()

    @router.get("/proxy", operation_id="plugins.acme.relay.proxy")
    async def proxy() -> dict:
        return {"own": await net.proxy_url("relay"), "other": await net.proxy_url("tmdb")}

    ctx.use(PLUGIN_ROUTES).mount(ctx, router, zone="admin")
"""


def test_process_plugins_only_learn_the_proxy_of_their_own_service(tmp_path, monkeypatch) -> None:
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal
    from movieclaw_net import EgressConfig, ProxyMode, apply_egress_config, get_egress_config

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'n.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_relay.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: acme.relay
              local: true
              module: acme_relay
              runtime: process
            """
        ),
        encoding="utf-8",
    )
    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    before = get_egress_config()
    try:
        with TestClient(app) as client:
            apply_egress_config(
                EgressConfig(
                    proxy_mode=ProxyMode.MANUAL,
                    proxy_url="http://user:secret@proxy.lan:7890",
                    proxy_services=frozenset({"relay", "tmdb"}),
                )
            )
            reply = client.get("/api/v1/plugins/acme.relay/proxy")
            assert reply.status_code == 200, reply.text
            assert reply.json() == {"own": "http://user:secret@proxy.lan:7890", "other": None}
    finally:
        apply_egress_config(before)
        for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
            del sys.modules[name]
        get_settings.cache_clear()

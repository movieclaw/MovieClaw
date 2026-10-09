"""本地受信插件（docs/design/plugin-phase2a.md §6）。

真实应用 + 真实的 ``data/plugins/`` 与 ``data/plugins.yaml``：只加载显式开启的条目；
导入失败、找不到插件、用内部契约都只影响它自己；授权取「声明 ∩ grants」；诊断标出来源。
"""

from __future__ import annotations

import sys
import textwrap
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events

HELLO = """
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_kernel import plugin

calls = []


@plugin(
    "acme.hello",
    title="你好插件",
    inject=(HOST_OPS,),
    permissions=("app.plugins.list", "subscriptions.*"),
    critical=True,  # 本地插件声明关键也不算数
)
async def hello(ctx):
    ops = await ctx.use(HOST_OPS).client(ctx)
    calls.append((ctx.config, sorted(ops.operations)))
"""


@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'local.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    yield tmp_path
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    get_settings.cache_clear()
    durable_events.reset_state()


def write(data_dir: Path, relative: str, text: str) -> None:
    path = data_dir / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text), encoding="utf-8")


def start_app():
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    return app, TestClient(app)


def plugins_by_id(client) -> dict:
    return {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}


def test_only_explicitly_enabled_plugins_are_loaded(data_dir) -> None:
    write(data_dir, "plugins/hello.py", HELLO)
    # 目录里还有一个没在 plugins.yaml 开启的文件：它的顶层代码绝不能被执行
    write(data_dir, "plugins/sneaky.py", "raise SystemExit('不该被导入')\n")
    write(
        data_dir,
        "plugins.yaml",
        """
        - id: acme.hello
          local: true
          config: {greeting: 你好}
          grants: [app.plugins.list]
        """,
    )
    app, client = start_app()
    with client:
        by_id = plugins_by_id(client)
        hello = by_id["acme.hello"]
        assert hello["state"] == "active" and hello["source"] == "local"
        assert hello["critical"] is False and hello["disableable"] is True
        assert "acme.sneaky" not in by_id and "sneaky" not in by_id
        module = sys.modules[f"{PACKAGE}.hello"]
        # 授权 = 声明 ∩ 用户批准：subscriptions.* 声明了但没批准
        assert module.calls == [({"greeting": "你好"}, ["app.plugins.list"])]
        assert f"{PACKAGE}.sneaky" not in sys.modules


def test_broken_local_plugins_fail_alone(data_dir) -> None:
    write(data_dir, "plugins/broken.py", "import does_not_exist\n")
    write(data_dir, "plugins/nameless.py", "x = 1\n")
    write(
        data_dir,
        "plugins/greedy.py",
        """
        from movieclaw_api.plugins.keys import DB
        from movieclaw_kernel import plugin

        @plugin("acme.greedy", title="想要数据库", inject=(DB,))
        async def greedy(ctx):
            pass
        """,
    )
    write(
        data_dir,
        "plugins.yaml",
        """
        - id: acme.broken
          local: true
        - id: acme.nameless
          local: true
        - id: acme.greedy
          local: true
        - id: acme.missing
          local: true
        """,
    )
    app, client = start_app()
    with client:
        assert client.get("/api/v1/health").status_code == 200
        by_id = plugins_by_id(client)
        assert by_id["acme.broken"]["state"] == "failed"
        assert "导入失败" in by_id["acme.broken"]["error"]
        assert "没有名为 acme.nameless 的插件" in by_id["acme.nameless"]["error"]
        assert "找不到" in by_id["acme.missing"]["error"]
        # 本地插件按第三方对待：内部契约（数据库）不能用
        assert by_id["acme.greedy"]["state"] == "incompatible"
        assert "仅供内置插件使用" in by_id["acme.greedy"]["incompatible"]
        assert by_id["core.database"]["state"] == "active"


def test_disabled_local_plugin_is_not_even_imported(data_dir) -> None:
    write(data_dir, "plugins/hello.py", HELLO)
    write(
        data_dir,
        "plugins.yaml",
        """
        - id: acme.hello
          local: true
          disabled: true
        """,
    )
    app, client = start_app()
    with client:
        hello = plugins_by_id(client)["acme.hello"]
        assert hello["state"] == "disabled" and hello["disabled_by"] == "patch"
        assert f"{PACKAGE}.hello" not in sys.modules


def test_package_plugins_and_relative_imports(data_dir) -> None:
    write(
        data_dir,
        "plugins/watch_list/__init__.py",
        """
        from movieclaw_kernel import plugin

        from .helpers import greeting

        @plugin("acme.watch-list", title="片单")
        async def watch_list(ctx):
            ctx.logger.info(greeting())
        """,
    )
    write(data_dir, "plugins/watch_list/helpers.py", "def greeting():\n    return 'hi'\n")
    write(data_dir, "plugins.yaml", "- id: acme.watch-list\n  local: true\n")
    app, client = start_app()
    with client:
        # 缺省模块名：id 最后一段把 - 换成 _
        assert plugins_by_id(client)["acme.watch-list"]["state"] == "active"
        host = app.state.kernel.service(HOST_OPS)
        assert host is not None

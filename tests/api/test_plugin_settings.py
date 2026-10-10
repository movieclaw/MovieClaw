"""插件通用设置（docs/design/plugin-phase4.md §3）。

本地插件在主进程里跑一遍、在独立进程里再跑一遍：
- 读 Schema；改设置后插件按新值重启（插件把收到的配置记进自己的数据，测试据此判断）；
- 敏感字段不回显、落盘加密、留空不改；填错报错且旧值保留；起不来的设置回滚；
- 配置超出子集的插件照常运行，只是界面上不能改。
"""

from __future__ import annotations

import json
import sys
import textwrap
from functools import partial

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events
from movieclaw_db.engine import get_database
from movieclaw_db.models.plugin_data import PluginData

ADMIN = {"username": "admin", "password": "s3cret-pass"}

PLUGIN = """
from enum import Enum

from pydantic import BaseModel, Field, SecretStr

from movieclaw_api.plugins.keys import PLUGIN_DATA
from movieclaw_sdk import plugin


class Mode(str, Enum):
    fast = "fast"
    slow = "slow"


class Config(BaseModel):
    interval: int = Field(30, ge=5, le=3600, title="同步间隔（秒）")
    mode: Mode = Mode.fast
    token: SecretStr | None = Field(None, title="访问令牌")
    tags: list[str] = Field(default_factory=list, title="标签")
    crash: bool = Field(False, title="启动时故意失败")


@plugin("acme-sync", title="同步（测试）", inject=(PLUGIN_DATA,), config=Config)
async def apply(ctx) -> None:
    cfg = ctx.config
    if cfg.crash:
        raise RuntimeError("按设置故意启动失败")
    seen = {
        "interval": cfg.interval,
        "mode": cfg.mode.value,
        "token": cfg.token.get_secret_value() if cfg.token else None,
        "tags": cfg.tags,
    }
    await ctx.use(PLUGIN_DATA).scoped(ctx).set("seen", seen)
"""

NESTED = """
from pydantic import BaseModel, Field

from movieclaw_sdk import plugin


class Rules(BaseModel):
    exclude: list[str] = Field(default_factory=list)


class Config(BaseModel):
    rules: dict[int, Rules] = Field(default_factory=dict)


@plugin("acme-rules", title="规则（测试）", config=Config)
async def apply(ctx) -> None:
    assert isinstance(ctx.config.rules, dict)
"""


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ps.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_sync.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins" / "acme_rules.py").write_text(NESTED, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: acme-sync
              local: true
              module: acme_sync
              runtime: {request.param}
              config:
                tags: [from-yaml]
            - id: acme-rules
              local: true
              module: acme_rules
              runtime: {request.param}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        test_client.data_dir = tmp_path  # type: ignore[attr-defined]
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


async def seen() -> dict | None:
    async with get_database().session() as session:
        row = (
            await session.execute(
                select(PluginData).where(
                    PluginData.entry_id == "acme-sync", PluginData.key == "seen"
                )
            )
        ).scalar_one_or_none()
        return None if row is None else row.value


URL = "/api/v1/app/plugins/acme-sync/settings"


def test_schema_and_values_come_from_the_plugin_model(client) -> None:
    resp = client.get(URL)
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["editable"] is True
    props = data["schema"]["properties"]
    assert props["interval"]["minimum"] == 5 and props["interval"]["title"] == "同步间隔（秒）"
    assert props["mode"]["enum"] == ["fast", "slow"]
    assert props["token"]["writeOnly"] is True
    # 清单配置（plugins.yaml）打底
    assert data["values"] == {"interval": 30, "mode": "fast", "tags": ["from-yaml"], "crash": False}
    assert data["secrets_set"] == []
    assert call(client, seen)["tags"] == ["from-yaml"]


def test_saving_restarts_the_plugin_with_new_values(client) -> None:
    resp = client.put(URL, json={"values": {"interval": 60, "token": "abc", "tags": ["x", "y"]}})
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["values"]["interval"] == 60 and data["values"]["tags"] == ["x", "y"]
    assert "token" not in data["values"] and data["secrets_set"] == ["token"]
    assert call(client, seen) == {
        "interval": 60,
        "mode": "fast",
        "token": "abc",
        "tags": ["x", "y"],
    }
    # 落盘加密：文件里没有明文
    stored = (client.data_dir / "plugins" / "settings" / "acme-sync.json").read_text("utf-8")
    assert "abc" not in stored and json.loads(stored)["secrets"]["token"].startswith("enc::")

    # 敏感字段留空 = 不改
    assert client.put(URL, json={"values": {"token": "", "mode": "slow"}}).status_code == 200
    assert call(client, seen)["token"] == "abc" and call(client, seen)["mode"] == "slow"


def test_bad_values_are_refused_and_the_old_ones_kept(client) -> None:
    assert client.put(URL, json={"values": {"interval": 60}}).status_code == 200
    resp = client.put(URL, json={"values": {"interval": 1}})
    # 进程内外同一种说法：字段用标题、中文原因；保存前就校验，不靠重启失败
    assert resp.status_code == 400 and "同步间隔（秒）：不能小于 5" in resp.text, resp.text
    assert client.get(URL).json()["data"]["values"]["interval"] == 60
    assert call(client, seen)["interval"] == 60, "插件仍按旧设置运行"
    assert client.put(URL, json={"values": {"nope": 1}}).status_code == 400


def test_a_setting_that_breaks_startup_is_rolled_back(client) -> None:
    """值本身合规，但插件用它起不来：恢复原设置、再起一次，报出原因。"""
    assert client.put(URL, json={"values": {"interval": 60}}).status_code == 200
    resp = client.put(URL, json={"values": {"crash": True}})
    assert resp.status_code == 400 and "已恢复原设置" in resp.text, resp.text
    assert "按设置故意启动失败" in resp.text
    assert client.get(URL).json()["data"]["values"]["crash"] is False
    plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
    assert plugins["acme-sync"]["state"] == "active", "恢复后插件照常运行"


def test_config_outside_the_subset_runs_but_is_not_editable(client) -> None:
    data = client.get("/api/v1/app/plugins/acme-rules/settings").json()["data"]
    assert data["editable"] is False and "rules" in data["reason"]
    plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
    assert plugins["acme-rules"]["state"] == "active"
    resp = client.put("/api/v1/app/plugins/acme-rules/settings", json={"values": {}})
    assert resp.status_code == 400


def test_plugins_without_config_have_nothing_to_edit(client) -> None:
    data = client.get("/api/v1/app/plugins/core.database/settings").json()["data"]
    assert data == {
        "editable": False,
        "reason": None,
        "schema": None,
        "values": {},
        "secrets_set": [],
    }

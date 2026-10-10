"""插件贡献定时任务：独立进程里也能用（处理函数留在插件进程，宿主登记代理，到点调回去）。

用户在「设置 → 定时任务」里调周期；插件不用在自己的设置里再放一个「间隔」。
"""

from __future__ import annotations

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
from movieclaw_api.plugins.keys import PLUGIN_DATA
from movieclaw_scheduler import SCHEDULED_TASKS, TaskDefinition, TriggerType
from movieclaw_sdk import plugin


@plugin("acme-tick", title="定时同步（测试）", inject=(PLUGIN_DATA,))
async def apply(ctx) -> None:
    store = ctx.use(PLUGIN_DATA).scoped(ctx)

    async def sync() -> None:
        await store.set("runs", (await store.get("runs", default=0)) + 1)

    ctx.contribute(SCHEDULED_TASKS, "sync", TaskDefinition(
        key=f"{ctx.entry_id}.sync", title="同步想看", handler=sync,
        default_trigger_type=TriggerType.INTERVAL, default_interval_seconds=3600,
        description="把想看同步成订阅",
    ))
"""


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'st.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "true")  # 定时任务页要调度器在跑
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_tick.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: acme-tick
              local: true
              module: acme_tick
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


async def runs() -> int | None:
    async with get_database().session() as session:
        row = (
            await session.execute(
                select(PluginData).where(
                    PluginData.entry_id == "acme-tick", PluginData.key == "runs"
                )
            )
        ).scalar_one_or_none()
        return None if row is None else row.value


def test_a_plugin_scheduled_task_is_registered_and_runs_in_the_plugin(client) -> None:
    from movieclaw_scheduler.registry import get_task

    plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
    assert plugins["acme-tick"]["state"] == "active", plugins["acme-tick"]
    task = get_task("acme-tick.sync")
    assert task is not None and task.title == "同步想看"
    assert task.default_interval_seconds == 3600 and task.description == "把想看同步成订阅"
    call(client, task.handler)  # 调度器到点就是这么调的
    call(client, task.handler)
    assert call(client, runs) == 2


def test_it_shows_up_in_the_scheduled_tasks_page_and_its_period_can_change(client) -> None:
    """用户在「设置 → 定时任务」里看得到插件的任务，能改周期（此前插件任务按贡献 id 查不到）。"""
    tasks = {t["key"]: t for t in client.get("/api/v1/scheduled-tasks").json()["data"]}
    assert "acme-tick.sync" in tasks, sorted(tasks)
    assert tasks["acme-tick.sync"]["title"] == "同步想看"
    resp = client.put(
        "/api/v1/scheduled-tasks/acme-tick.sync",
        json={"trigger_type": "interval", "interval_seconds": 7200, "enabled": True},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["interval_seconds"] == 7200

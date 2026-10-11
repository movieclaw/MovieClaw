"""插件的后台任务（docs/design/plugin-strm-prefetch.md §2）。

- 进程外插件在 apply 里用 ``PLUGIN_JOBS`` 建自己的任务：处理器就绪后被领取、在子进程里执行；
  任务类型写全前缀不会被重复加；任务中心拿到处理器给的名字（``job_type_label``）；
- 只能建自己的任务类型；去重键按插件隔离。
"""

from __future__ import annotations

import textwrap
import time
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events

PLUGIN = """
import os

from movieclaw_sdk import plugin
from movieclaw_sdk.jobs import JOB_HANDLERS, PLUGIN_JOBS, RegisteredJobHandler, ResourceRef


@plugin("acme.queue", title="队列插件", inject=(PLUGIN_JOBS,))
async def apply(ctx) -> None:
    async def work(context, data):
        await context.update_progress(mode="determinate", phase="work", message="干活")
        return {"n": data["n"], "pid": os.getpid()}

    # 写全前缀：不会变成 acme.queue:acme.queue:work
    handler = RegisteredJobHandler(work, frozenset({1}), title="排队干活")
    ctx.contribute(JOB_HANDLERS, "acme.queue:work", handler)
    # 不写前缀：照旧自动加上
    ctx.contribute(JOB_HANDLERS, "plain", RegisteredJobHandler(work, frozenset({1})))
    ref = await ctx.use(PLUGIN_JOBS).scoped(ctx).create(
        "acme.queue:work",
        input={"n": 7},
        subject="第一件",
        priority=-10,
        dedupe_key="first",
        resources=[ResourceRef("library", 1, "context")],
    )
    print("created", ref.id, ref.created, ref.status)
"""


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'jobs.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    yield tmp_path
    durable_events.reset_state()
    get_settings.cache_clear()


def make_client():
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    who = Principal(kind="admin", name="tester", is_admin=True)
    app.dependency_overrides[require_login] = lambda: who
    return app, TestClient(app)


def wait_for(predicate, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待超时")


def plugin_jobs(client) -> list[dict]:
    reply = client.get("/api/v1/jobs", params={"job_type": "acme.queue:work"})
    assert reply.status_code == 200, reply.text
    return reply.json()["data"]["items"]


def test_process_plugin_creates_and_runs_its_own_jobs(env) -> None:
    from movieclaw_api.services import jobs

    (env / "plugins").mkdir()
    (env / "plugins" / "acme_queue.py").write_text(PLUGIN, encoding="utf-8")
    (env / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: acme.queue
              local: true
              module: acme_queue
              runtime: process
            """
        ),
        encoding="utf-8",
    )
    app, client = make_client()
    with client:
        fiber = app.state.kernel.fiber("acme.queue")
        assert fiber.state.value == "active", fiber.error
        owned = sorted(app.state.kernel.registry(jobs.JOB_HANDLERS).owned_by("acme.queue"))
        assert owned == ["acme.queue:plain", "acme.queue:work"]

        wait_for(lambda: [j["status"] for j in plugin_jobs(client)] == ["succeeded"])
        [job] = plugin_jobs(client)
        assert job["result"]["n"] == 7
        assert job["subject"] == "第一件"
        assert job["job_type_label"] == "排队干活"
        assert job["actor_kind"] == "plugin" and job["actor_name"] == "acme.queue"
        assert job["resources"] == [
            {"resource_type": "library", "resource_id": "1", "relation": "context"}
        ]
        detail = client.get(f"/api/v1/jobs/{job['id']}").json()["data"]
        assert detail["job_type_label"] == "排队干活"

        # 停用插件：处理器撤下，名字仍记得（已结束的任务照样显示名字）
        reply = client.put("/api/v1/app/plugins/acme.queue/enabled", json={"enabled": False})
        assert reply.status_code == 400  # 本地插件不在插件页开关之列
        client.portal.call(app.state.kernel.unmount, "acme.queue")
        assert plugin_jobs(client)[0]["job_type_label"] == "排队干活"


def test_plugins_only_create_their_own_job_types_and_dedupe_per_plugin(env) -> None:
    from movieclaw_sdk.jobs import PLUGIN_JOBS

    app, client = make_client()
    with client:
        service = app.state.kernel.service(PLUGIN_JOBS)
        mine = service.scoped(SimpleNamespace(entry_id="acme.a"))
        other = service.scoped(SimpleNamespace(entry_id="acme.b"))

        with pytest.raises(PermissionError):
            client.portal.call(lambda: mine.create("acme.b:sync"))
        with pytest.raises(PermissionError):
            client.portal.call(lambda: mine.create("library.scan"))

        first = client.portal.call(lambda: mine.create("acme.a:sync", dedupe_key="all"))
        again = client.portal.call(lambda: mine.create("acme.a:sync", dedupe_key="all"))
        assert first.created and not again.created and again.id == first.id
        # 别的插件同名去重键互不影响
        theirs = client.portal.call(lambda: other.create("acme.b:sync", dedupe_key="all"))
        assert theirs.created and theirs.id != first.id
        # 处理器没登记的自家任务：排队等着，不被领走报「请更新」
        time.sleep(0.5)
        statuses = {
            j["id"]: j["status"] for j in client.get("/api/v1/jobs").json()["data"]["items"]
        }
        assert statuses[first.id] == "queued" and statuses[theirs.id] == "queued"

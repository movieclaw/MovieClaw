"""官方插件的停用 / 卸载（docs/design/plugin-strm-prefetch.md §1）。

走真实应用：插件页停用一个官方插件 → 当场停下、它的后台任务取消、状态落盘、重启后保持；
卸载 → 撤下、重启后不加载、列表里显示可恢复；恢复 → 当场加载；勾选删除数据时连数据一起清。
"""

from __future__ import annotations

import json
import time
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_kernel import State

PLUGINS = "/api/v1/app/plugins"
OFFICIAL = "telegram-channel"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    yield tmp_path
    get_settings.cache_clear()


def make_client() -> tuple[object, TestClient]:
    get_settings.cache_clear()
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    who = Principal(kind="admin", name="tester", is_admin=True)
    app.dependency_overrides[require_login] = lambda: who
    return app, TestClient(app)


def listing(client: TestClient) -> dict:
    reply = client.get(PLUGINS)
    assert reply.status_code == 200, reply.text
    return reply.json()["data"]


def plugin(client: TestClient, entry_id: str) -> dict | None:
    return next((p for p in listing(client)["plugins"] if p["id"] == entry_id), None)


def switch(client: TestClient, entry_id: str, enabled: bool):
    return client.put(f"{PLUGINS}/{entry_id}/enabled", json={"enabled": enabled})


def saved(env) -> dict:
    return json.loads((env / "plugins-switches.json").read_text("utf-8"))


def create_job(client: TestClient, job_type: str, *, dedupe: str) -> str:
    from movieclaw_api.services.jobs import create_job as create
    from movieclaw_db.engine import get_database

    async def run() -> str:
        async with get_database().session() as session:
            result = await create(session, job_type=job_type, input_data={}, dedupe_key=dedupe)
            return result.job.id

    return client.portal.call(run)


def job_status(client: TestClient, job_id: str) -> str:
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.job import Job

    async def run() -> str:
        async with get_database().session() as session:
            return (await session.get(Job, job_id)).status.value

    return client.portal.call(run)


def wait_for_cancelled(client: TestClient, job_id: str) -> None:
    # 任务可能已被 dispatcher 领取，取消请求需要等处理器的安全停止点。
    deadline = time.monotonic() + 10
    while (status := job_status(client, job_id)) != "cancelled":
        assert time.monotonic() < deadline, f"任务 {job_id} 未取消，当前状态：{status}"
        time.sleep(0.05)


def test_disable_cancels_jobs_survives_restart_and_enables_back(env) -> None:
    app, client = make_client()
    with client:
        view = plugin(client, OFFICIAL)
        assert view["switchable"] is True and view["removable"] is True
        assert view["locked_by"] is None
        # 系统模块不出开关
        assert plugin(client, "library.watch")["switchable"] is False

        mine = create_job(client, f"{OFFICIAL}:poll", dedupe="a")
        other = create_job(client, "someone-else:poll", dedupe="b")

        reply = switch(client, OFFICIAL, False)
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["state"] == "disabled"
        fiber = app.state.kernel.fiber(OFFICIAL)
        assert fiber.state is State.DISABLED and fiber.disabled_by == "switch"
        assert saved(env)["disabled"][OFFICIAL]["by"] == "tester"
        wait_for_cancelled(client, mine)
        assert job_status(client, other) != "cancelled"
        # 再停一次是无操作
        assert switch(client, OFFICIAL, False).status_code == 200

    app, client = make_client()
    with client:
        fiber = app.state.kernel.fiber(OFFICIAL)
        assert fiber.state is State.DISABLED and fiber.disabled_by == "switch"
        reply = switch(client, OFFICIAL, True)
        assert reply.status_code == 200, reply.text
        assert fiber.state is not State.DISABLED
        assert saved(env)["disabled"] == {}


def test_uninstall_restart_and_restore(env) -> None:
    app, client = make_client()
    with client:
        job = create_job(client, f"{OFFICIAL}:poll", dedupe="a")
        reply = client.delete(f"{PLUGINS}/{OFFICIAL}/bundled")
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"] == {"cancelled_jobs": 1, "purged_rows": 0}
        assert app.state.kernel.fiber(OFFICIAL) is None
        wait_for_cancelled(client, job)
        removed = listing(client)["removed"]
        assert [r["id"] for r in removed] == [OFFICIAL]
        assert removed[0]["title"] and removed[0]["removed_by"] == "tester"
        # 卸载了的不能再停用 / 卸载
        assert switch(client, OFFICIAL, False).status_code == 404

    # 重启：不加载
    app, client = make_client()
    with client:
        assert app.state.kernel.fiber(OFFICIAL) is None
        assert plugin(client, OFFICIAL) is None
        assert [r["id"] for r in listing(client)["removed"]] == [OFFICIAL]

        reply = client.post(f"{PLUGINS}/{OFFICIAL}/bundled/restore")
        assert reply.status_code == 200, reply.text
        assert app.state.kernel.fiber(OFFICIAL) is not None
        assert listing(client)["removed"] == []
        assert plugin(client, OFFICIAL)["removable"] is True
        # 没卸载过的恢复不了
        assert client.post(f"{PLUGINS}/{OFFICIAL}/bundled/restore").status_code == 404

    app, client = make_client()
    with client:
        assert app.state.kernel.fiber(OFFICIAL) is not None


def test_uninstall_with_purge_removes_data_settings_and_private_dir(env) -> None:
    from movieclaw_api.plugins import settings_store
    from movieclaw_api.plugins.keys import PLUGIN_DATA

    app, client = make_client()
    with client:
        kernel = app.state.kernel
        store = kernel.service(PLUGIN_DATA).scoped(SimpleNamespace(entry_id=OFFICIAL))
        client.portal.call(lambda: store.set("cursor", 42))
        settings_file = settings_store._path(get_settings(), OFFICIAL)
        settings_file.parent.mkdir(parents=True, exist_ok=True)
        settings_file.write_text("{}", encoding="utf-8")
        private = env / "plugins" / "data" / OFFICIAL
        private.mkdir(parents=True)
        (private / "state.bin").write_bytes(b"x")

        reply = client.delete(f"{PLUGINS}/{OFFICIAL}/bundled", params={"purge_data": "true"})
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["purged_rows"] == 1
        assert not settings_file.exists()
        assert not private.exists()


def test_admin_override_locks_and_system_modules_are_refused(env) -> None:
    (env / "plugins.yaml").write_text(f"- id: {OFFICIAL}\n  disabled: true\n", encoding="utf-8")
    app, client = make_client()
    with client:
        view = plugin(client, OFFICIAL)
        assert view["locked_by"] == "已在 data/plugins.yaml 中关闭"
        for enabled in (True, False):
            reply = switch(client, OFFICIAL, enabled)
            assert reply.status_code == 409, reply.text
            assert reply.json()["code"] == "PLUGIN_LOCKED"
        assert client.delete(f"{PLUGINS}/{OFFICIAL}/bundled").status_code == 409
        assert not (env / "plugins-switches.json").exists()

        reply = switch(client, "library.watch", False)
        assert reply.status_code == 400 and reply.json()["code"] == "PLUGIN_NOT_SWITCHABLE"
        assert switch(client, "no-such-plugin", False).status_code == 404
        reply = client.delete(f"{PLUGINS}/library.watch/bundled")
        assert reply.status_code == 400 and reply.json()["code"] == "PLUGIN_NOT_BUNDLED"


def test_disable_rolls_back_when_the_kernel_fails(env, monkeypatch) -> None:
    app, client = make_client()
    with client:
        kernel = app.state.kernel

        async def broken(entry_id, *, source="runtime"):
            raise RuntimeError("boom")

        monkeypatch.setattr(kernel, "disable", broken)
        with pytest.raises(RuntimeError):
            switch(client, OFFICIAL, False)
        assert saved(env)["disabled"] == {}


def test_removed_bundled_package_stays_away_when_a_replacement_is_uninstalled(env) -> None:
    from movieclaw_api.services import plugin_switches
    from movieclaw_api.services.plugin_packages import _restore_bundled

    app, client = make_client()
    with client:
        kernel = app.state.kernel
        settings = get_settings()
        assert client.delete(f"{PLUGINS}/{OFFICIAL}/bundled").status_code == 200
        client.portal.call(lambda: _restore_bundled(kernel, settings, OFFICIAL))
        assert kernel.fiber(OFFICIAL) is None

        # 停用的随带包被替换包卸下后回来：照旧停用
        client.portal.call(lambda: plugin_switches.restore_bundled(kernel, settings, OFFICIAL))
        assert switch(client, OFFICIAL, False).status_code == 200
        client.portal.call(lambda: kernel.unmount(OFFICIAL))
        client.portal.call(lambda: _restore_bundled(kernel, settings, OFFICIAL))
        fiber = kernel.fiber(OFFICIAL)
        assert fiber.state is State.DISABLED and fiber.disabled_by == "switch"

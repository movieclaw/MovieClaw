"""内置插件自举的等价性与容错（docs/design/plugin-kernel.md §7、§12.2、§12.3）。

走真实应用生命周期（TestClient 的 with 块），断言改造后：
- 全部内置插件正常启动，原 lifespan 初始化的每个单例都已就绪；
- 原 lifespan 注释里「谁先停」的每条约束都成立；
- 关闭调度器时只影响调度器及依赖它的部分；
- 非关键子系统启动失败只影响它自己，关键子系统失败中止启动。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_kernel import State


@pytest.fixture
def make_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    created: list = []

    def factory(*, scheduler: bool = True):
        monkeypatch.setenv("SCHEDULER_ENABLED", "true" if scheduler else "false")
        get_settings.cache_clear()
        from movieclaw_api.app import create_app

        app = create_app()
        created.append(app)
        return app, TestClient(app)

    yield factory
    get_settings.cache_clear()


def _states(app) -> dict[str, State]:
    return {f.id: f.state for f in app.state.kernel.fibers}


def test_all_builtin_plugins_start_and_singletons_are_ready(make_client) -> None:
    app, client = make_client()
    with client:
        states = _states(app)
        assert {k: v for k, v in states.items() if v is not State.ACTIVE} == {}
        assert "app-update.startup-check" in states

        from movieclaw_api.services import jobs
        from movieclaw_api.services.agent_runs import get_agent_run_registry
        from movieclaw_api.services.cloud.service import get_cloud_service
        from movieclaw_api.services.playback.remote_worker import get_remote_worker_registry
        from movieclaw_api.services.playback.session import get_session_manager
        from movieclaw_api.services.site_access import get_site_access
        from movieclaw_api.settings.store import get_setting_store
        from movieclaw_db.crypto import get_secret_box
        from movieclaw_db.engine import get_database
        from movieclaw_scheduler import get_scheduler

        for getter in (
            get_database,
            get_secret_box,
            get_setting_store,
            get_site_access,
            get_agent_run_registry,
            get_scheduler,
            get_cloud_service,
            get_session_manager,
            get_remote_worker_registry,
        ):
            assert getter() is not None, getter.__name__
        assert jobs._dispatcher is not None
        assert client.get("/api/v1/health").status_code == 200


def test_shutdown_order_keeps_lifespan_constraints(make_client) -> None:
    app, client = make_client()
    with client:
        pass
    order = app.state.kernel.dispose_log
    position = {entry_id: index for index, entry_id in enumerate(order)}

    def before(first: str, second: str) -> None:
        assert position[first] < position[second], f"{first} 应先于 {second} 释放：{order}"

    assert order[0] == "playback.transcode", "转码会话最先停（killpg 整组）"
    before("playback.transcode", "playback.remote-workers")
    before("channels.hub", "agent.runs")
    before("push.arrivals", "push.hub")
    before("push.channels-refresh", "cloud")
    before("library.skip-segments", "jobs")
    before("library.search-index", "jobs")
    before("boost.sentinel", "scheduler")
    before("app-update.startup-check", "scheduler")
    before("agent.runs", "core.http-clients")
    before("tracker.site-access", "core.http-clients")
    for entry_id in ("jobs", "agent.runs", "tracker.site-access", "scheduler", "library.watch"):
        before(entry_id, "core.database")
    assert order[-1] == "core.database", "最后刷统计、关数据库"


def test_scheduler_switch_only_affects_scheduler_and_its_dependents(make_client) -> None:
    app, client = make_client(scheduler=False)
    with client:
        states = _states(app)
        kernel = app.state.kernel
        assert states["scheduler"] is State.DISABLED
        assert kernel.fiber("scheduler").disabled_by == "env:SCHEDULER_ENABLED"
        assert states["boost.sentinel"] is State.PENDING
        assert states["app-update.startup-check"] is State.PENDING
        others = {
            k: v
            for k, v in states.items()
            if k not in {"scheduler", "boost.sentinel", "app-update.startup-check"}
        }
        assert all(v is State.ACTIVE for v in others.values()), others


def test_non_critical_failure_degrades_instead_of_aborting(make_client, monkeypatch) -> None:
    from movieclaw_plugins.weixin.weixin_channel import driver

    def broken(self) -> None:
        raise ConnectionError("weixin gateway down")

    monkeypatch.setattr(driver.WeixinDriver, "__init__", broken)
    app, client = make_client()
    with client:
        kernel = app.state.kernel
        weixin = kernel.fiber("weixin-channel")
        assert weixin.state is State.FAILED
        assert weixin.error == "ConnectionError: weixin gateway down"
        states = _states(app)
        assert [k for k, v in states.items() if v is not State.ACTIVE] == ["weixin-channel"]
        assert client.get("/api/v1/health").status_code == 200


def test_critical_failure_aborts_startup_and_releases(make_client, monkeypatch) -> None:
    from movieclaw_api.services import network_egress
    from movieclaw_kernel import KernelStartupError

    async def broken():
        raise RuntimeError("egress config corrupted")

    monkeypatch.setattr(network_egress, "load_network_egress", broken)
    app, client = make_client()
    with pytest.raises(KernelStartupError, match="core.egress"), client:
        pass
    kernel = app.state.kernel
    assert kernel.fiber("core.egress").state is State.FAILED
    # 已启动的关键插件被逆序释放，数据库最后关
    assert kernel.dispose_log[-1] == "core.database"
    assert kernel.fiber("core.database").state is State.DISPOSED

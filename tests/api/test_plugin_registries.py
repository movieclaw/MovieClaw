"""定时任务与后台任务处理器改为注册表贡献（docs/design/plugin-kernel.md §6、§12.2）。

走真实应用：运行中挂上 / 卸下插件，断言
- 处理器所属插件不在时，任务留在队列里等；插件一挂上立刻被领走执行；
- 调度器随插件增删 APScheduler job，撤下时保留库里的定义（用户改过的周期）；
- 内置领域插件同样遵守：禁用即撤下、启用即恢复；
- 声明只算本模块定义的函数。
"""

from __future__ import annotations

import asyncio
import time
from functools import partial

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs
from movieclaw_db.engine import get_database
from movieclaw_db.models import JobStatus
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_db.repositories.scheduled_task_repo import ScheduledTaskRepository
from movieclaw_kernel import Entry, plugin
from movieclaw_scheduler import SCHEDULED_TASKS, TaskDefinition, get_scheduler
from movieclaw_scheduler.registry import contribute_tasks, declared_tasks


@pytest.fixture
def make_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))

    def factory(*, scheduler: bool):
        monkeypatch.setenv("SCHEDULER_ENABLED", "true" if scheduler else "false")
        get_settings.cache_clear()
        from movieclaw_api.app import create_app

        app = create_app()
        return app, TestClient(app)

    yield factory
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


def wait_until(client: TestClient, check, timeout: float = 5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = call(client, check)
        if value:
            return value
        call(client, asyncio.sleep, 0.05)
    raise AssertionError("等待超时")


async def _create_job(n: int) -> str:
    async with get_database().session() as session:
        created = await jobs.create_job(session, job_type="test.plugin-job", input_data={"n": n})
    jobs.wake_job_dispatcher()
    return created.job.id


async def _status(job_id: str) -> str:
    async with get_database().session() as session:
        row = await jobs.get_job(session, job_id)
        return row.status


def test_jobs_wait_while_their_plugin_is_away_and_run_when_it_returns(make_client) -> None:
    ran: list[int] = []

    async def handler(context: jobs.JobContext, payload: dict):
        ran.append(payload["n"])
        return {"message": "ok"}

    @plugin("test.job-plugin", title="测试任务插件")
    async def job_plugin(ctx) -> None:
        ctx.contribute(
            jobs.JOB_HANDLERS,
            "test.plugin-job",
            jobs.RegisteredJobHandler(handler, frozenset({1})),
        )

    app, client = make_client(scheduler=False)
    with client:
        kernel = app.state.kernel
        call(client, kernel.mount, Entry("test.job-plugin", job_plugin))
        first = call(client, _create_job, 1)
        wait_until(client, lambda: _is(first, JobStatus.SUCCEEDED))

        # 插件卸下：这类任务留在队列里等，不会被领走报「请更新版本」
        call(client, kernel.unmount, "test.job-plugin")
        second = call(client, _create_job, 2)
        call(client, asyncio.sleep, 0.5)
        assert call(client, _status, second) == JobStatus.QUEUED.value

        # 插件回来：处理器表变化唤醒执行器，立即领走
        call(client, kernel.mount, Entry("test.job-plugin", job_plugin))
        wait_until(client, lambda: _is(second, JobStatus.SUCCEEDED))
        assert ran == [1, 2]


def test_unknown_job_type_still_blocks_with_update_hint(make_client) -> None:
    async def create_unknown() -> str:
        async with get_database().session() as session:
            created = await jobs.create_job(session, job_type="test.never-declared", input_data={})
        jobs.wake_job_dispatcher()
        return created.job.id

    async def blocked_code(job_id: str):
        async with get_database().session() as session:
            row = await jobs.get_job(session, job_id)
            return (row.error or {}).get("code") if row.status == JobStatus.BLOCKED.value else None

    app, client = make_client(scheduler=False)
    with client:
        job_id = call(client, create_unknown)
        code = wait_until(client, lambda: blocked_code(job_id))
        assert code == "JOB_HANDLER_UNAVAILABLE"


async def _is(job_id: str, status: JobStatus) -> bool:
    return await _status(job_id) == status.value


async def _row(task_key: str):
    async with get_database().session() as session:
        return await ScheduledTaskRepository(session).get_by_key(task_key)


async def _set_interval(task_key: str, seconds: int) -> None:
    async with get_database().session() as session:
        await ScheduledTaskRepository(session).update_schedule(
            task_key,
            enabled=True,
            trigger_type=TriggerType.INTERVAL,
            interval_seconds=seconds,
            cron_expr=None,
        )


def test_scheduler_follows_task_contributions_and_keeps_user_schedule(make_client) -> None:
    async def tick() -> None:
        return None

    definition = TaskDefinition(
        key="test_plugin_tick",
        title="测试任务",
        handler=tick,
        default_trigger_type=TriggerType.INTERVAL,
        default_interval_seconds=3600,
    )

    @plugin("test.task-plugin", title="测试定时任务插件")
    async def task_plugin(ctx) -> None:
        ctx.contribute(SCHEDULED_TASKS, definition.key, definition)

    app, client = make_client(scheduler=True)
    with client:
        kernel = app.state.kernel
        apscheduler = get_scheduler()._scheduler
        assert apscheduler.get_job("test_plugin_tick") is None

        call(client, kernel.mount, Entry("test.task-plugin", task_plugin))
        wait_until(client, _async(lambda: apscheduler.get_job("test_plugin_tick") is not None))
        assert call(client, _row, "test_plugin_tick").interval_seconds == 3600

        # 用户把周期改成 2 分钟；插件卸下：job 摘掉、库里的定义保留
        call(client, _set_interval, "test_plugin_tick", 120)
        call(client, kernel.unmount, "test.task-plugin")
        wait_until(client, _async(lambda: apscheduler.get_job("test_plugin_tick") is None))

        async def withdrawn() -> bool:
            row = await _row("test_plugin_tick")
            return row is not None and row.next_run_at is None

        wait_until(client, withdrawn)
        assert call(client, _row, "test_plugin_tick").interval_seconds == 120

        # 再挂上：按库里的定义（用户改过的 2 分钟）排上，而不是代码默认的 1 小时
        call(client, kernel.mount, Entry("test.task-plugin", task_plugin))
        job = wait_until(client, _async(lambda: apscheduler.get_job("test_plugin_tick")))
        assert job.trigger.interval.total_seconds() == 120


def _async(fn):
    async def run():
        return fn()

    return run


def test_disabling_builtin_domain_plugin_withdraws_its_tasks(make_client) -> None:
    app, client = make_client(scheduler=True)
    with client:
        kernel = app.state.kernel
        apscheduler = get_scheduler()._scheduler
        assert apscheduler.get_job("ratio_boost") is not None
        call(client, kernel.disable, "boost")
        wait_until(client, _async(lambda: apscheduler.get_job("ratio_boost") is None))
        call(client, kernel.enable, "boost")
        wait_until(client, _async(lambda: apscheduler.get_job("ratio_boost") is not None))


def test_effective_tables_follow_kernel_and_fall_back_after_stop(make_client) -> None:
    from movieclaw_scheduler.registry import iter_tasks

    app, client = make_client(scheduler=False)
    with client:
        effective = {d.key for d in iter_tasks()}
        # 调度器关闭时领域插件照常贡献；调度器自己的内置任务随它一起不在
        assert "library_reconcile" in effective
        assert "cleanup_task_runs" not in effective
        assert "library.duplicate-scan" in jobs.claimable_job_types()
    # 内核关闭后解绑，回落到模块声明目录、不按类型过滤
    assert jobs.claimable_job_types() is None


def test_declared_tasks_only_counts_functions_defined_in_the_module() -> None:
    from movieclaw_api.services.library import scan
    from movieclaw_scheduler import tasks as builtin

    assert [d.key for d in declared_tasks(scan)] == ["library_reconcile"]
    assert {d.key for d in declared_tasks(builtin)} == {
        "cleanup_task_runs",
        "cleanup_cache_entries",
    }

    class FakeCtx:
        def contribute(self, *args, **kwargs) -> None:
            raise AssertionError("不该贡献")

    import types

    empty = types.ModuleType("empty_module")
    with pytest.raises(ValueError, match="没有声明任何定时任务"):
        contribute_tasks(FakeCtx(), empty)


def test_declared_job_handlers_cover_stacked_decorators() -> None:
    from movieclaw_api.services.library import batch_transfer

    assert [t for t, _ in jobs.declared_job_handlers(batch_transfer)] == [
        "library.consolidate-roots",
        "library.transfer-batch",
    ]

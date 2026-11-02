"""插件的后台任务（docs/design/plugin-strm-prefetch.md §2）。

- 进程外插件在 apply 里用 ``PLUGIN_JOBS`` 建自己的任务：处理器就绪后被领取、在子进程里执行；
  任务类型写全前缀不会被重复加；任务中心拿到处理器给的名字（``job_type_label``）；
- 只能建自己的任务类型；去重键按插件隔离。
"""

from __future__ import annotations

import asyncio
import os
import textwrap
import time
from datetime import timedelta
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


def test_restart_waits_for_process_plugin_handlers_before_claiming_jobs(env, monkeypatch):
    """冷启动：存量任务在进程插件注册前保持排队，就绪后自动执行，未知类型仍阻塞。"""
    from movieclaw_api.services import jobs, plugin_runtime
    from movieclaw_db.engine import dispose_db, get_database, init_db
    from movieclaw_db.migrations import run_migrations
    from movieclaw_db.models import Job, JobStatus, utcnow

    job_type = "acme.startup:work"
    monkeypatch.setattr(jobs, "_known_types", set())

    async def seed():
        db = init_db(get_settings().database_url, echo=False)
        try:
            await run_migrations()
            async with db.session() as session:
                for status in (JobStatus.QUEUED, JobStatus.RETRY_WAIT, JobStatus.RUNNING):
                    session.add(
                        Job(
                            id=f"startup_{status.value}",
                            job_type=job_type,
                            input_data={"n": status.value},
                            status=status,
                            attempt=1 if status is JobStatus.RUNNING else 0,
                            lease_owner="previous-worker" if status is JobStatus.RUNNING else None,
                            lease_expires_at=utcnow() - timedelta(seconds=1),
                        )
                    )
                session.add(Job(id="startup_unknown", job_type="missing.plugin:work"))
                await session.commit()
        finally:
            await dispose_db()

    asyncio.run(seed())
    (env / "plugins").mkdir()
    (env / "plugins" / "startup_queue.py").write_text(
        textwrap.dedent("""
        import os
        from movieclaw_sdk import plugin
        from movieclaw_sdk.jobs import JOB_HANDLERS, RegisteredJobHandler

        @plugin("acme.startup", title="启动队列")
        async def apply(ctx):
            async def work(context, data):
                return {"n": data["n"], "pid": os.getpid()}
            ctx.contribute(JOB_HANDLERS, "work", RegisteredJobHandler(work, frozenset({1})))
        """),
        encoding="utf-8",
    )
    (env / "plugins.yaml").write_text(
        "- id: acme.startup\n  local: true\n  module: startup_queue\n  runtime: process\n",
        encoding="utf-8",
    )
    scanned = asyncio.Event()
    before_registration = []
    real_claim = jobs.JobDispatcher._claim_one
    real_start = plugin_runtime.Session.start

    async def observe_claim(self, *, job_ids=None):
        claimed = await real_claim(self, job_ids=job_ids)
        if claimed is None:
            scanned.set()
        return claimed

    async def delayed_start(self):
        if self.entry_id == "acme.startup":
            # 明确等执行器完成一次扫描，避免依赖机器速度或任意 sleep。
            await asyncio.wait_for(scanned.wait(), timeout=10)
            await asyncio.gather(*list(jobs._dispatcher._running.values()))
            async with get_database().session() as session:
                before_registration.extend(await jobs.list_jobs(session, job_type=job_type))
        return await real_start(self)

    monkeypatch.setattr(jobs.JobDispatcher, "_claim_one", observe_claim)
    monkeypatch.setattr(plugin_runtime.Session, "start", delayed_start)
    app, client = make_client()
    with client:
        fiber = app.state.kernel.fiber("acme.startup")
        assert fiber.state.value == "active", fiber.error
        assert len(before_registration) == 3
        assert all(
            j.status in (JobStatus.QUEUED, JobStatus.RETRY_WAIT) for j in before_registration
        ), [(j.status, j.error) for j in before_registration]
        assert all(j.attempt == 0 and j.error is None for j in before_registration)

        def completed():
            reply = client.get("/api/v1/jobs", params={"job_type": job_type})
            assert reply.status_code == 200, reply.text
            return reply.json()["data"]["items"]

        wait_for(lambda: all(j["status"] == "succeeded" for j in completed()))
        assert len(completed()) == 3
        assert all(j["attempt"] == 1 for j in completed())
        assert all(j["result"]["pid"] != os.getpid() for j in completed())
        wait_for(
            lambda: client.get("/api/v1/jobs/startup_unknown").json()["data"]["status"] == "blocked"
        )
        unknown = client.get("/api/v1/jobs/startup_unknown").json()["data"]
        assert unknown["status"] == "blocked"
        assert unknown["error"]["code"] == "JOB_HANDLER_UNAVAILABLE"


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


@pytest.mark.parametrize("interruption", ["lease", "settings"])
def test_in_flight_process_jobs_recover_without_restarting_dispatcher(
    env, monkeypatch, interruption
):
    """真实子进程 + SQLite + HTTP：四槽均等待时，回收租约或保存设置后队列继续走。"""
    from sqlalchemy import update

    from movieclaw_api.services import jobs, plugin_runtime
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Job, JobLock, JobStatus, utcnow

    recovered = asyncio.Event()
    real_heartbeat = jobs.JobDispatcher._heartbeat

    async def heartbeat_after_recovery(self, *args):
        await recovered.wait()
        await real_heartbeat(self, *args)

    if interruption == "lease":
        monkeypatch.setattr(jobs, "JOB_HEARTBEAT_SECONDS", 0.05)
        monkeypatch.setattr(jobs.JobDispatcher, "_heartbeat", heartbeat_after_recovery)
    (env / "plugins").mkdir()
    (env / "plugins" / "acme_queue.py").write_text(
        textwrap.dedent("""
        import asyncio
        import os
        from pydantic import BaseModel
        from movieclaw_sdk import plugin
        from movieclaw_sdk.jobs import JOB_HANDLERS, PLUGIN_JOBS, RegisteredJobHandler

        class Config(BaseModel):
            release: bool = False

        @plugin("acme.queue", title="队列插件", config=Config, inject=(PLUGIN_JOBS,))
        async def apply(ctx):
            seen = set()
            async def work(context, data):
                await context.update_progress(
                    mode="indeterminate", phase="entered", message="读取条目"
                )
                n = data["n"]
                if n < 4 and n not in seen and not ctx.config.release:
                    seen.add(n)
                    await asyncio.Event().wait()
                return {"n": n, "pid": os.getpid()}

            ctx.contribute(JOB_HANDLERS, "work", RegisteredJobHandler(work, frozenset({1})))
            for n in range(24):
                await ctx.use(PLUGIN_JOBS).scoped(ctx).create(
                    "acme.queue:work", input={"n": n}, dedupe_key=f"item-{n}"
                )
        """),
        encoding="utf-8",
    )
    (env / "plugins.yaml").write_text(
        "- id: acme.queue\n  local: true\n  module: acme_queue\n  runtime: process\n",
        encoding="utf-8",
    )
    app, client = make_client()
    with client:
        dispatcher = jobs._dispatcher
        loop = dispatcher._loop_task
        session = plugin_runtime.sessions["acme.queue"]
        pid = session.pid
        wait_for(lambda: sum(j["progress"]["phase"] == "entered" for j in plugin_jobs(client)) == 4)
        held = [j["id"] for j in plugin_jobs(client) if j["status"] == "running"]
        assert len(held) == 4

        if interruption == "lease":

            async def expire_and_recover():
                async with get_database().session() as db_session:
                    expired = utcnow() - timedelta(seconds=1)
                    await db_session.execute(
                        update(Job).where(Job.id.in_(held)).values(lease_expires_at=expired)
                    )
                    await db_session.execute(
                        update(JobLock)
                        .where(JobLock.job_id.in_(held))
                        .values(lease_expires_at=expired)
                    )
                    await db_session.commit()
                await dispatcher._recover_expired_jobs()
                async with get_database().session() as db_session:
                    rows = await jobs.list_jobs(db_session, job_type="acme.queue:work")
                assert all(row.status is JobStatus.QUEUED for row in rows)
                assert len(dispatcher._running) == 4
                recovered.set()

            client.portal.call(expire_and_recover)
        else:
            reply = client.put(
                "/api/v1/app/plugins/acme.queue/settings", json={"values": {"release": True}}
            )
            assert reply.status_code == 200, reply.text

        wait_for(lambda: all(j["status"] == "succeeded" for j in plugin_jobs(client)), timeout=60)
        completed = plugin_jobs(client)
        assert len(completed) == 24
        assert sorted(j["result"]["n"] for j in completed) == list(range(24))
        assert jobs._dispatcher is dispatcher and dispatcher._loop_task is loop
        assert not loop.done()
        if interruption == "lease":
            assert plugin_runtime.sessions["acme.queue"] is session and session.pid == pid
            assert session.jobs == {}
            assert all(j["attempt"] == 1 for j in completed)

        # 主程序任务也能继续领取，不能只证明插件自己的队列恢复。
        async def enqueue_core():
            async with get_database().session() as db_session:
                result = await jobs.create_job(
                    db_session, job_type="library.search-index.refresh", input_data={}
                )
            return result.job.id

        core_id = client.portal.call(enqueue_core)
        wait_for(
            lambda: (
                client.get(f"/api/v1/jobs/{core_id}").json()["data"]["status"]
                == JobStatus.SUCCEEDED.value
            )
        )


@pytest.mark.parametrize("refresh_times_out", [False, True])
def test_four_process_jobs_wait_for_metadata_refresh(env, monkeypatch, refresh_times_out):
    """process 插件 → 刷新 API → SQLite 执行器 → jobs.wait；四父任务加两条排队任务。"""
    from movieclaw_api.services import jobs, media_scrape, plugin_runtime
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Job, Library, MediaItem

    release_refresh = asyncio.Event()
    monkeypatch.setattr(jobs, "JOB_HEARTBEAT_SECONDS", 0.2)

    async def slow_scrape(*args, **kwargs):
        # 只替换外部刮削工作：刷新 handler、租约、资源锁、进度与收尾均走生产链路。
        await release_refresh.wait()
        return True

    monkeypatch.setattr(media_scrape, "scrape_media_item", slow_scrape)
    (env / "plugins").mkdir()
    (env / "plugins" / "cast_cn.py").write_text(
        textwrap.dedent("""
        import asyncio
        import os
        from movieclaw_sdk import plugin
        from movieclaw_sdk.jobs import JOB_HANDLERS, RegisteredJobHandler, JobFailed
        from movieclaw_sdk.ops import HOST_OPS

        @plugin("cast-cn", title="演职员测试插件", inject=(HOST_OPS,),
                permissions=("library.items.refresh-metadata", "jobs.wait"))
        async def apply(ctx):
            ops = await ctx.use(HOST_OPS).client(ctx)
            entered = 0
            ready = asyncio.Event()
            refresh_sem = asyncio.Semaphore(1)
            async def item(context, data):
                nonlocal entered
                entered += 1
                if entered == 4:
                    ready.set()
                await ready.wait()
                await context.update_progress(
                    mode="indeterminate", phase="refresh-wait", message="等待主程序重新吸收 NFO"
                )
                # 与报告者公开的 add-cast-cn 分支一致：闸门覆盖创建和整个等待。
                async with refresh_sem:
                    return await refresh(context, data)

            async def refresh(context, data):
                ref = await ops.call("library.items.refresh-metadata", {
                    "library_id": data["library_id"], "media_item_id": data["media_item_id"]
                })
                revision = 0
                try:
                    async with asyncio.timeout(data["timeout"]):
                        while True:
                            await context.raise_if_cancelled()
                            reply = await ops.call("jobs.wait", {
                                "job_id": ref["job_id"], "after_revision": revision,
                                "wait_seconds": 0.1
                            })
                            job = reply["job"]
                            revision = job["revision"]
                            if job["status"] == "succeeded":
                                return {"pid": os.getpid(), "refresh_id": job["id"]}
                except TimeoutError:
                    raise JobFailed("刷新等待超时", code="REFRESH_WAIT_TIMEOUT")
            ctx.contribute(JOB_HANDLERS, "item", RegisteredJobHandler(item, frozenset({1})))
        """),
        encoding="utf-8",
    )
    (env / "plugins.yaml").write_text(
        "- id: cast-cn\n  local: true\n  module: cast_cn\n  runtime: process\n"
        "  grants: [library.items.refresh-metadata, jobs.wait]\n",
        encoding="utf-8",
    )
    app, client = make_client()
    with client:
        session = plugin_runtime.sessions["cast-cn"]
        pid = session._proc.pid
        dispatcher = jobs._dispatcher
        loop_task = dispatcher._loop_task

        async def seed():
            async with get_database().session() as db_session:
                library = Library(name="动漫库", kind="tv", root_paths=[str(env / "media")])
                db_session.add(library)
                await db_session.commit()
                ids = []
                for n in range(6):
                    item = MediaItem(
                        kind="tv",
                        tmdb_id=100 + n,
                        title=f"测试剧 {n}",
                        original_title=f"Show {n}",
                        scrape_library_id=library.id,
                    )
                    db_session.add(item)
                    await db_session.commit()
                    ref = await jobs.create_job(
                        db_session,
                        job_type="cast-cn:item",
                        priority=-10,
                        input_data={
                            "library_id": library.id,
                            "media_item_id": item.id,
                            "timeout": 5 if refresh_times_out and n < 4 else 15,
                        },
                    )
                    ids.append(ref.job.id)
                return ids

        ids = client.portal.call(seed)

        def rows():
            reply = client.get("/api/v1/jobs", params={"job_type": "cast-cn:item"})
            assert reply.status_code == 200, reply.text
            indexed = {job["id"]: job for job in reply.json()["data"]["items"]}
            return [indexed[jid] for jid in ids]

        async def waiting():
            return len({parent for parent, _, _ in dispatcher._waits}) == 1

        wait_for(lambda: all(j["progress"]["phase"] == "refresh-wait" for j in rows()[:4]))
        wait_for(lambda: client.portal.call(waiting))
        assert [j["status"] for j in rows()[4:]] == ["queued", "queued"]

        # 慢刷新仍占库级锁；父任务保持续租，普通查询也继续响应。
        async def heartbeats():
            async with get_database().session() as db_session:
                return [(await db_session.get(Job, jid)).heartbeat_at for jid in ids[:4]]

        before = client.portal.call(heartbeats)
        wait_for(
            lambda: all(a > b for a, b in zip(client.portal.call(heartbeats), before, strict=True))
        )
        refreshes = client.get("/api/v1/jobs", params={"job_type": "media.metadata.refresh"})
        assert sum(j["status"] == "running" for j in refreshes.json()["data"]["items"]) == 1
        if refresh_times_out:
            wait_for(lambda: all(j["status"] == "failed" for j in rows()[:4]), timeout=45)
            assert all(j["error"]["code"] == "REFRESH_WAIT_TIMEOUT" for j in rows()[:4])
        client.portal.call(release_refresh.set)
        wait_for(lambda: all(j["status"] == "succeeded" for j in rows()[4:]), timeout=60)
        if not refresh_times_out:
            assert all(j["status"] == "succeeded" for j in rows())
        assert all(j["result"]["pid"] == pid for j in rows() if j["status"] == "succeeded")
        wait_for(lambda: not session.jobs and not session._contexts)
        assert jobs._dispatcher is dispatcher and dispatcher._loop_task is loop_task
        assert not loop_task.done() and session._proc.pid == pid
        wait_for(lambda: not dispatcher._waits)

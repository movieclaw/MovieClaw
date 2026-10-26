"""取消优先：任务被取消后，任何收尾路径都不能把状态改回 blocked / failed / retry_wait。

线上撞到的时序：dispatcher 已把任务领取成 running，处理器还没走到安全停止点（handler
解析、定义版本检查、刚起步）时用户点了取消——`request_cancel` 见状态是 running，只置
`cancelling` 等安全点。紧接着处理器抛 `JobBlocked` / `JobFailed` / 临时异常，各自的
收尾函数若无条件写终态，用户点过的取消就丢了，任务还会继续占着去重键与资源锁，
前端一直显示「取消中」。CI 4 核并行时才撞得到，本地单跑很难复现，所以在这里直接构造
那几条收尾路径。
"""

from __future__ import annotations

import pytest
import pytest_asyncio

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import Job, JobStatus

JOB_TYPE = "test.cancel.priority"


@pytest_asyncio.fixture
async def job_db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'cancel.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await jobs.close_job_dispatcher()
    await dispose_db()
    get_settings.cache_clear()


async def _claimed_cancelling(job_db) -> tuple[str, str]:
    """建一条任务、手动领取成 running，再请求取消 → 进入 cancelling。返回 (job_id, lease)。"""
    async with job_db.session() as session:
        created = await jobs.create_job(session, job_type=JOB_TYPE, input_data={})
        job_id = created.job.id
    lease = "test-lease"
    async with job_db.session() as session:
        job = await session.get(Job, job_id)
        job.status = JobStatus.RUNNING
        job.lease_owner = lease
        await session.commit()
    async with job_db.session() as session:
        job, requested = await jobs.request_cancel(
            session, job_id, requested_by="tester", reason="不想要了"
        )
        assert requested is True
        assert job.status is JobStatus.CANCELLING
    return job_id, lease


async def _status(job_db, job_id: str) -> JobStatus:
    async with job_db.session() as session:
        return (await session.get(Job, job_id)).status


@pytest.mark.asyncio
async def test_blocked_finish_keeps_the_cancellation(job_db):
    """处理器抛 JobBlocked（如「当前版本无法执行这类任务」）：取消仍要生效。"""
    job_id, lease = await _claimed_cancelling(job_db)

    dispatcher = jobs.JobDispatcher()
    exc = jobs.JobBlocked("当前版本无法执行这类任务", code="JOB_HANDLER_UNAVAILABLE")
    await dispatcher._finish_controlled(job_id, lease, JobStatus.BLOCKED, exc)

    assert await _status(job_db, job_id) is JobStatus.CANCELLED


@pytest.mark.asyncio
async def test_failed_finish_keeps_the_cancellation(job_db):
    """处理器抛 JobFailed：取消仍要生效，不留一条「失败」让用户以为要重试。"""
    job_id, lease = await _claimed_cancelling(job_db)

    dispatcher = jobs.JobDispatcher()
    exc = jobs.JobFailed("任务定义与当前版本不兼容", code="JOB_DEFINITION_UNSUPPORTED")
    await dispatcher._finish_controlled(job_id, lease, JobStatus.FAILED, exc)

    assert await _status(job_db, job_id) is JobStatus.CANCELLED


@pytest.mark.asyncio
async def test_retry_finish_keeps_the_cancellation(job_db):
    """处理器抛可重试错误：已请求取消的任务不该再排一次重试。"""
    job_id, lease = await _claimed_cancelling(job_db)

    dispatcher = jobs.JobDispatcher()
    with pytest.raises(jobs.JobRetry) as raised:
        raise jobs.JobRetry("稍后重试")
    await dispatcher._finish_retry(job_id, lease, raised.value)

    assert await _status(job_db, job_id) is JobStatus.CANCELLED


@pytest.mark.asyncio
async def test_unexpected_error_keeps_the_cancellation(job_db):
    """未知异常走的重试/失败路径同样不能盖掉取消。"""
    job_id, lease = await _claimed_cancelling(job_db)

    dispatcher = jobs.JobDispatcher()
    await dispatcher._finish_unexpected(job_id, lease)

    assert await _status(job_db, job_id) is JobStatus.CANCELLED


@pytest.mark.asyncio
async def test_the_cancel_also_frees_the_locks(job_db):
    """取消收尾要释放资源锁——否则任务没了、锁还在，同名任务再也建不出来。"""
    from movieclaw_db.models import JobLock

    job_id, lease = await _claimed_cancelling(job_db)
    from datetime import timedelta

    from movieclaw_api.services.jobs import utcnow

    async with job_db.session() as session:
        session.add(
            JobLock(
                lock_key="file:42",
                job_id=job_id,
                lease_expires_at=utcnow() + timedelta(seconds=60),
            )
        )
        await session.commit()

    dispatcher = jobs.JobDispatcher()
    exc = jobs.JobBlocked("放不出来", code="JOB_HANDLER_UNAVAILABLE")
    await dispatcher._finish_controlled(job_id, lease, JobStatus.BLOCKED, exc)

    async with job_db.session() as session:
        job = await session.get(Job, job_id)
        assert job.status is JobStatus.CANCELLED
        assert job.lease_owner is None
        from sqlalchemy import select as sa_select

        remaining = (await session.execute(sa_select(JobLock))).scalars().all()
        assert remaining == []

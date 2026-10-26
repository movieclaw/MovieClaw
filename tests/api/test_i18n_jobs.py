"""A real queued handler persists references, then two API readers see their own language."""

from __future__ import annotations

from movieclaw_api.services import jobs
from movieclaw_db.models import JobStatus

from . import test_jobs as original

job_db = original.job_db
job_client = original.job_client


async def test_legacy_progress_message_does_not_inherit_default_translation(job_db, job_client):
    @jobs.register_job_handler("test.i18n-legacy")
    async def legacy(context, _payload):
        await context.update_progress(
            mode="determinate", phase="working", message="Plugin progress", current=1
        )
        return {"message": "Plugin completed"}

    async with job_db.session() as session:
        created = await jobs.create_job(session, job_type="test.i18n-legacy", input_data={})
    await jobs.init_job_dispatcher(max_parallel=1)
    await original._wait_status(created.job.id, JobStatus.SUCCEEDED)
    data = (await job_client.get(f"/jobs/{created.job.id}")).json()["data"]
    assert data["progress"]["message"] == "Plugin completed"
    events = (await job_client.get(f"/jobs/{created.job.id}/events")).json()["data"]["items"]
    progress = next(event for event in events if event["event_type"] == "progress")
    assert progress["payload"]["message"] == "Plugin progress"


async def test_failed_job_progress_and_timeline_follow_reader_language(job_db, job_client):
    @jobs.register_job_handler("test.i18n-failure")
    async def fail(context, _payload):
        await context.update_progress(
            mode="indeterminate", phase="checking", message_key="activity.jobs.resumed"
        )
        raise jobs.JobFailed(message_key="activity.jobs.handlerUnavailable")

    async with job_db.session() as session:
        created = await jobs.create_job(session, job_type="test.i18n-failure", input_data={})
    await jobs.init_job_dispatcher(max_parallel=1)
    await original._wait_status(created.job.id, JobStatus.FAILED)
    for language, expected in (
        ("en", "This version cannot run this task type. Update MovieClaw and try again."),
        ("zh-Hans", "当前版本无法执行这类任务，请更新 MovieClaw 后重试"),
    ):
        response = await job_client.get(
            f"/jobs/{created.job.id}", headers={"Accept-Language": language}
        )
        assert response.status_code == 200
        data = response.json()["data"]
        assert data["error"]["message"] == expected
        assert data["progress"]["message"] == expected
        events = (
            await job_client.get(
                f"/jobs/{created.job.id}/events", headers={"Accept-Language": language}
            )
        ).json()["data"]["items"]
        assert events[-1]["payload"]["message"] == expected
    async with job_db.session() as session:
        row = await jobs.get_job(session, created.job.id)
        assert row.error["message"] == "当前版本无法执行这类任务，请更新 MovieClaw 后重试"
        assert row.error["message_key"] == "activity.jobs.handlerUnavailable"
        assert row.error["message_params"] == {}

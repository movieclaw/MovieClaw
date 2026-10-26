"""Real job action receipts follow request language without changing action semantics."""

from movieclaw_api.services import jobs
from movieclaw_db.models import JobStatus

from . import test_jobs_dismiss as original

job_db = original.job_db
job_client = original.job_client


async def test_dismiss_restore_receipts_and_idempotency_follow_reader(job_db, job_client):
    for locale in ("en", "zh-Hans", "en"):
        job_id = await original._failed_job(job_db, subject="原始任务名")
        headers = {"Accept-Language": locale}
        for action, expected in (
            ("dismiss", ("Dismissed; it no longer needs attention", "已忽略，不再计入需要处理")),
            ("dismiss", ("The task was already dismissed", "任务已经忽略过了")),
            ("undismiss", ("Dismissal undone", "已撤销忽略")),
            ("undismiss", ("The task was not dismissed", "任务并未被忽略")),
        ):
            response = await job_client.post(f"/jobs/{job_id}/{action}", headers=headers)
            assert response.status_code == 200, response.text
            body = response.json()
            assert body["message"] == expected[0 if locale == "en" else 1]
            assert body["data"]["job"]["id"] == job_id
            assert body["data"]["job"]["status"] == "failed"
            assert body["data"]["job"]["subject"] == "原始任务名"
            # Existing unmarked error text is preserved rather than guessed from its Chinese value.
            assert body["data"]["job"]["error"]["message"] == "翻译失败"
        async with job_db.session() as session:
            events = await jobs.job_events(session, job_id)
        assert [event.event_type for event in events].count("dismissed") == 1
        assert [event.event_type for event in events].count("undismissed") == 1


async def test_cancel_and_retry_receipts_keep_real_job_transitions(job_db, job_client):
    for locale in ("en", "zh-Hans"):
        headers = {"Accept-Language": locale}
        async with job_db.session() as session:
            created = await jobs.create_job(session, job_type="test.cancel-locale", input_data={})
        for expected in (
            ("Cancellation requested", "已请求取消"),
            ("The task has already finished", "任务已经结束"),
        ):
            response = await job_client.post(f"/jobs/{created.job.id}/cancel", headers=headers)
            assert response.status_code == 200, response.text
            assert response.json()["message"] == expected[0 if locale == "en" else 1]
            assert response.json()["data"]["job"]["status"] == "cancelled"

        source_id = await original._failed_job(job_db)
        response = await job_client.post(f"/jobs/{source_id}/retry", headers=headers)
        assert response.status_code == 200, response.text
        assert response.json()["message"] == (
            "The task was queued again" if locale == "en" else "任务已重新入队"
        )
        assert response.json()["data"]["created"] is True
        assert response.json()["data"]["job"]["retry_of_job_id"] == source_id
        assert response.json()["data"]["job"]["status"] == "queued"
        async with job_db.session() as session:
            source = await jobs.get_job(session, source_id)
        assert source.status == JobStatus.FAILED


async def test_bulk_dismiss_singular_plural_and_empty_receipts(job_db, job_client):
    for count in (1, 2):
        for _ in range(count):
            await original._failed_job(job_db)
        response = await job_client.post("/jobs/dismiss-all", headers={"Accept-Language": "en"})
        assert response.status_code == 200, response.text
        assert (
            response.json()["message"]
            == f"Dismissed {count} failed task{'s' if count != 1 else ''}"
        )
        assert response.json()["data"]["dismissed"] == count
        assert all(row["status"] == "failed" for row in response.json()["data"]["jobs"])
    response = await job_client.post("/jobs/dismiss-all", headers={"Accept-Language": "zh-Hans"})
    assert response.json()["message"] == "当前没有需要忽略的失败任务"

"""失败任务的「忽略」出口（issue #221）。

用户反馈：字幕翻译失败的任务只有重试 / 查看日志 / 交给 Agent 三条路，
"我不想再处理"时没有出口，任务就一直挂在那儿，侧栏红角标永不熄灭。

本文件锁住这个出口的三条约定：
1. 忽略**不改写** status——它仍然是一条失败记录，日志与重试入口都还在；
2. 只对失败任务开放——活跃任务（含 blocked）仍占着去重键与资源锁，
   要终结得走取消，不能靠"藏起来"；
3. 可以反悔——撤销忽略后任务回到「需要处理」。
"""

from __future__ import annotations

from datetime import timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from movieclaw_api.api.deps import require_admin
from movieclaw_api.app import create_app
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs
from movieclaw_api.services.auth import Principal
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import JobStatus
from movieclaw_db.models.base import utcnow


@pytest_asyncio.fixture
async def job_db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'dismiss.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await jobs.close_job_dispatcher()
    await dispose_db()
    get_settings.cache_clear()


@pytest_asyncio.fixture
async def job_client(job_db):
    app = create_app()
    app.dependency_overrides[require_admin] = lambda: Principal(kind="admin", name="tester")
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://testserver/api/v1"
    ) as client:
        yield client


async def _failed_job(job_db, *, job_type: str = "test.dismiss", subject: str = "Movie.mkv"):
    """建一条已经失败的任务：忽略只对失败任务开放，这是所有用例的前置。"""
    async with job_db.session() as session:
        created = await jobs.create_job(
            session,
            job_type=job_type,
            subject=subject,
            input_data={"value": 1},
        )
        row = await jobs.get_job(session, created.job.id)
        assert row is not None
        row.status = JobStatus.FAILED
        row.error = {"code": "TEST_FAILED", "message": "翻译失败"}
        await session.commit()
        return created.job.id


async def test_dismiss_marks_job_without_rewriting_status(job_db) -> None:
    """忽略只表达"不再处理"，不改写"这件事失败过"。"""
    job_id = await _failed_job(job_db)

    async with job_db.session() as session:
        row, changed = await jobs.dismiss_job(session, job_id, dismissed_by="admin:tester")

    assert changed is True
    assert row is not None
    # 关键不变量：状态没被动过，日志与重试链仍然建立在它上面
    assert row.status is JobStatus.FAILED
    assert row.dismissed_at is not None
    assert row.dismissed_by == "admin:tester"
    # 跟已取消任务同口径落一个保留期，最终由清理任务收走，不永久占着台账
    assert row.retention_until is not None

    async with job_db.session() as session:
        events = await jobs.job_events(session, job_id)
    assert events[-1].event_type == "dismissed"


async def test_dismiss_is_idempotent(job_db) -> None:
    """重复忽略不再改变状态，也不重复记事件。"""
    job_id = await _failed_job(job_db)

    async with job_db.session() as session:
        _, first = await jobs.dismiss_job(session, job_id, dismissed_by="admin:tester")
    async with job_db.session() as session:
        row, second = await jobs.dismiss_job(session, job_id, dismissed_by="admin:tester")

    assert first is True
    assert second is False
    assert row is not None
    async with job_db.session() as session:
        events = await jobs.job_events(session, job_id)
    assert [e.event_type for e in events].count("dismissed") == 1


async def test_dismiss_rejects_non_failed_jobs(job_db) -> None:
    """活跃任务仍占着去重键与资源锁，只能取消，不能靠"藏起来"了事。"""
    async with job_db.session() as session:
        created = await jobs.create_job(
            session, job_type="test.active", input_data={"value": 1}
        )

    async with job_db.session() as session:
        with pytest.raises(jobs.JobFailed, match="只有失败的任务可以忽略"):
            await jobs.dismiss_job(session, created.job.id, dismissed_by="admin:tester")


async def test_undismiss_restores_attention(job_db) -> None:
    """忽略是用户在信息不全时按下的，就必须能反悔。"""
    job_id = await _failed_job(job_db)

    async with job_db.session() as session:
        await jobs.dismiss_job(session, job_id, dismissed_by="admin:tester")
    async with job_db.session() as session:
        row, restored = await jobs.undismiss_job(session, job_id)

    assert restored is True
    assert row is not None
    assert row.dismissed_at is None
    assert row.dismissed_by is None
    assert row.retention_until is None
    assert row.status is JobStatus.FAILED

    async with job_db.session() as session:
        events = await jobs.job_events(session, job_id)
    assert events[-1].event_type == "undismissed"


async def test_dismiss_all_only_touches_currently_failed_jobs(job_db) -> None:
    """批量忽略收口的是"眼前这批"，不是从此对失败视而不见。"""
    failed_ids = [
        await _failed_job(job_db, subject=f"S01E{index:02d}.mkv") for index in range(1, 4)
    ]
    async with job_db.session() as session:
        active = await jobs.create_job(
            session, job_type="test.active", input_data={"value": 1}
        )

    async with job_db.session() as session:
        rows = await jobs.dismiss_failed_jobs(session, dismissed_by="admin:tester")

    assert sorted(row.id for row in rows) == sorted(failed_ids)

    async with job_db.session() as session:
        still_active = await jobs.get_job(session, active.job.id)
    assert still_active is not None
    assert still_active.dismissed_at is None

    # 之后再失败的任务照常提醒——批量忽略不是一个永久开关
    later_id = await _failed_job(job_db, subject="Later.mkv")
    async with job_db.session() as session:
        later = await jobs.get_job(session, later_id)
    assert later is not None
    assert later.dismissed_at is None


async def test_dismiss_all_filters_by_job_type(job_db) -> None:
    subtitle_id = await _failed_job(job_db, job_type="subtitle.generate")
    scan_id = await _failed_job(job_db, job_type="library.scan")

    async with job_db.session() as session:
        rows = await jobs.dismiss_failed_jobs(
            session, dismissed_by="admin:tester", job_type="subtitle.generate"
        )

    assert [row.id for row in rows] == [subtitle_id]
    async with job_db.session() as session:
        scan = await jobs.get_job(session, scan_id)
    assert scan is not None
    assert scan.dismissed_at is None


async def test_dismissed_job_can_still_be_retried(job_db) -> None:
    """忽略不封死重试：用户随时可以改主意再试一次。"""
    job_id = await _failed_job(job_db)
    async with job_db.session() as session:
        await jobs.dismiss_job(session, job_id, dismissed_by="admin:tester")

    async with job_db.session() as session:
        source = await jobs.get_job(session, job_id)
        assert source is not None
        retried = await jobs.retry_job(
            session, source, actor_kind="admin", actor_name="tester", origin="web"
        )

    assert retried.created is True
    assert retried.job.retry_of_job_id == job_id
    # 新任务是干净的，不继承忽略标记
    assert retried.job.dismissed_at is None


async def test_dismiss_api_round_trip(job_db, job_client) -> None:
    """HTTP 契约：忽略 / 撤销忽略都把最新任务体带回给前端。"""
    job_id = await _failed_job(job_db)

    response = await job_client.post(f"/jobs/{job_id}/dismiss", json={"mute_source": False})
    assert response.status_code == 200
    payload = response.json()["data"]
    assert payload["dismissed"] is True
    assert payload["muted"] is False
    assert payload["job"]["status"] == "failed"
    assert payload["job"]["dismissed_at"] is not None

    response = await job_client.post(f"/jobs/{job_id}/undismiss")
    assert response.status_code == 200
    assert response.json()["data"]["job"]["dismissed_at"] is None


async def test_dismiss_api_rejects_active_job(job_db, job_client) -> None:
    async with job_db.session() as session:
        created = await jobs.create_job(
            session, job_type="test.active", input_data={"value": 1}
        )

    response = await job_client.post(f"/jobs/{created.job.id}/dismiss", json={})
    assert response.status_code == 400


async def test_dismiss_all_api(job_db, job_client) -> None:
    for index in range(3):
        await _failed_job(job_db, subject=f"Batch{index}.mkv")

    response = await job_client.post("/jobs/dismiss-all", json={})
    assert response.status_code == 200
    assert response.json()["data"]["dismissed"] == 3

    # 幂等：再点一次没有任务可忽略，不报错
    response = await job_client.post("/jobs/dismiss-all", json={})
    assert response.json()["data"]["dismissed"] == 0


async def test_dismiss_and_undismiss_preserve_updated_at_order(job_db, job_client) -> None:
    """issue #1337：忽略/撤销忽略只改用户处置元数据，不能把旧失败的 updated_at 推到新成功之前。"""
    base = utcnow() - timedelta(hours=2)
    fail_time = base + timedelta(minutes=1)
    ok_time = base + timedelta(minutes=7)

    async with job_db.session() as session:
        failed_created = await jobs.create_job(
            session,
            job_type="subtitle.generate",
            subject="S06E01.mkv",
            input_data={"file_id": 5056, "target_language": "chs"},
            resources=[jobs.ResourceRef("library_file", 5056)],
        )
        failed = await jobs.get_job(session, failed_created.job.id)
        assert failed is not None
        failed.status = JobStatus.FAILED
        failed.error = {"code": "JOB_RETRY_EXHAUSTED", "message": "supplier timeout"}
        failed.created_at = base
        failed.finished_at = fail_time
        failed.updated_at = fail_time

        ok_created = await jobs.create_job(
            session,
            job_type="subtitle.generate",
            subject="S06E01.mkv",
            input_data={"file_id": 5056, "target_language": "chs"},
            resources=[jobs.ResourceRef("library_file", 5056)],
        )
        succeeded = await jobs.get_job(session, ok_created.job.id)
        assert succeeded is not None
        succeeded.status = JobStatus.SUCCEEDED
        succeeded.created_at = base + timedelta(minutes=5)
        succeeded.finished_at = ok_time
        succeeded.updated_at = ok_time
        await session.commit()
        failed_id, ok_id = failed.id, succeeded.id
        failed_rev_before = failed.revision

    # 批量忽略旧失败任务
    resp = await job_client.post("/jobs/dismiss-all", json={})
    assert resp.status_code == 200
    assert resp.json()["data"]["dismissed"] == 1

    listing = await job_client.get(
        "/jobs?job_type=subtitle.generate&resource_type=library_file&resource_id=5056&limit=5"
    )
    assert listing.status_code == 200
    items = listing.json()["data"]["items"]
    assert [item["id"] for item in items] == [ok_id, failed_id]
    by_id = {item["id"]: item for item in items}

    # revision 仍递增（供 SSE/wait 感知），但 updated_at 不能反超后面的成功任务
    assert by_id[failed_id]["dismissed_at"] is not None
    assert by_id[failed_id]["revision"] == failed_rev_before + 1
    assert by_id[failed_id]["updated_at"] < by_id[ok_id]["updated_at"]
    assert max(items, key=lambda item: item["updated_at"])["id"] == ok_id

    # 撤销忽略与单条忽略同样保持 updated_at 不反超
    undismiss = await job_client.post(f"/jobs/{failed_id}/undismiss")
    assert undismiss.status_code == 200
    undismissed_job = undismiss.json()["data"]["job"]
    assert undismissed_job["dismissed_at"] is None
    assert undismissed_job["revision"] == failed_rev_before + 2
    assert undismissed_job["updated_at"] < by_id[ok_id]["updated_at"]

    single = await job_client.post(f"/jobs/{failed_id}/dismiss", json={"mute_source": False})
    assert single.status_code == 200
    single_job = single.json()["data"]["job"]
    assert single_job["dismissed_at"] is not None
    assert single_job["revision"] == failed_rev_before + 3
    assert single_job["updated_at"] < by_id[ok_id]["updated_at"]


async def test_e2e_synthetic_dismiss_api_to_web_detail_entry_and_no_auto_close(
    job_db, job_client
) -> None:
    """端到端验证 #1337：真实 HTTP API 响应交给前端选择/入口判定，并确认不顺带改变 #1331。"""
    import json
    import shutil
    import subprocess
    from pathlib import Path

    node = shutil.which("node")
    assert node is not None, "node is required for end-to-end web contract verification"
    repo_root = Path(__file__).resolve().parents[2]
    web_attention = repo_root / "apps/web/lib/job-attention.ts"

    base = utcnow() - timedelta(hours=3)
    async with job_db.session() as session:
        # 1. 文件 5056：先失败 2 次，后成功 1 次（确认不顺带自动收尾旧失败，保留 #1331 原有行为）
        fail_ids: list[str] = []
        for idx in range(2):
            created = await jobs.create_job(
                session,
                job_type="subtitle.generate",
                subject="S06E01.mkv",
                input_data={"file_id": 5056, "target_language": "chs"},
                resources=[jobs.ResourceRef("library_file", 5056)],
            )
            row = await jobs.get_job(session, created.job.id)
            assert row is not None
            row.status = JobStatus.FAILED
            row.error = {"code": "JOB_RETRY_EXHAUSTED", "message": "supplier timeout"}
            row.created_at = base + timedelta(minutes=idx)
            row.finished_at = base + timedelta(minutes=idx + 1)
            row.updated_at = base + timedelta(minutes=idx + 1)
            fail_ids.append(row.id)

        ok_created = await jobs.create_job(
            session,
            job_type="subtitle.generate",
            subject="S06E01.mkv",
            input_data={"file_id": 5056, "target_language": "chs"},
            resources=[jobs.ResourceRef("library_file", 5056)],
        )
        ok_row = await jobs.get_job(session, ok_created.job.id)
        assert ok_row is not None
        ok_row.status = JobStatus.SUCCEEDED
        ok_row.created_at = base + timedelta(minutes=10)
        ok_row.finished_at = base + timedelta(minutes=12)
        ok_row.updated_at = base + timedelta(minutes=12)
        ok_id = ok_row.id

        # 2. 文件 5057：只有一条失败任务（验证单独忽略后详情页退回空闲与预检）
        only_fail_created = await jobs.create_job(
            session,
            job_type="subtitle.generate",
            subject="S06E02.mkv",
            input_data={"file_id": 5057, "target_language": "chs"},
            resources=[jobs.ResourceRef("library_file", 5057)],
        )
        only_fail_row = await jobs.get_job(session, only_fail_created.job.id)
        assert only_fail_row is not None
        only_fail_row.status = JobStatus.FAILED
        only_fail_row.error = {"code": "JOB_RETRY_EXHAUSTED", "message": "supplier timeout"}
        only_fail_row.created_at = base + timedelta(minutes=20)
        only_fail_row.finished_at = base + timedelta(minutes=21)
        only_fail_row.updated_at = base + timedelta(minutes=21)
        only_fail_id = only_fail_row.id
        await session.commit()

    # #1331 原有约定未改变：成功后旧失败仍未自动忽略
    before_dismiss = (
        await job_client.get(
            "/jobs?job_type=subtitle.generate&resource_type=library_file&resource_id=5056&limit=5"
        )
    ).json()["data"]["items"]
    assert all(
        item["dismissed_at"] is None for item in before_dismiss if item["id"] in fail_ids
    )

    # 活动页执行「全部忽略」
    dismiss_all = await job_client.post("/jobs/dismiss-all", json={})
    assert dismiss_all.status_code == 200
    assert dismiss_all.json()["data"]["dismissed"] == 3

    items_5056 = (
        await job_client.get(
            "/jobs?job_type=subtitle.generate&resource_type=library_file&resource_id=5056&limit=5"
        )
    ).json()["data"]["items"]
    items_5057 = (
        await job_client.get(
            "/jobs?job_type=subtitle.generate&resource_type=library_file&resource_id=5057&limit=5"
        )
    ).json()["data"]["items"]

    # 额外构造一条历史库里已被旧版服务端污染 updated_at 的快照，确认前端也能兜底
    polluted_5056 = [dict(item) for item in items_5056]
    for item in polluted_5056:
        if item["id"] in fail_ids:
            item["updated_at"] = "2099-01-01T00:00:00+00:00"

    script = f"""
import {{
  selectLatestResourceJob,
  subtitleGenShowsTerminalIssue,
  subtitleGenOpenMode,
}} from {json.dumps(web_attention.as_uri())};
const payload = JSON.parse(process.argv[1]);
const pick = (items, fileId) => {{
  const sortedByUpdated = [...items].sort(
    (a, b) => Date.parse(b.updated_at) - Date.parse(a.updated_at),
  );
  const selected = selectLatestResourceJob(
    sortedByUpdated,
    "library_file",
    fileId,
    "subtitle.generate",
  );
  return {{
    selectedId: selected?.id ?? null,
    selectedStatus: selected?.status ?? null,
    legacyUpdatedMaxId: sortedByUpdated[0]?.id ?? null,
    showsIssueGeneratedFalse: subtitleGenShowsTerminalIssue(selected, false),
    showsIssueGeneratedTrue: subtitleGenShowsTerminalIssue(selected, true),
    openModeGeneratedFalse: subtitleGenOpenMode(selected, false),
    openModeGeneratedTrue: subtitleGenOpenMode(selected, true),
  }};
}};
console.log(JSON.stringify({{
  fresh5056: pick(payload.items5056, 5056),
  polluted5056: pick(payload.polluted5056, 5056),
  onlyFail5057: pick(payload.items5057, 5057),
}}));
"""
    proc = subprocess.run(
        [
            node,
            "--input-type=module",
            "-e",
            script,
            json.dumps(
                {
                    "items5056": items_5056,
                    "polluted5056": polluted_5056,
                    "items5057": items_5057,
                }
            ),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    out = json.loads(proc.stdout)

    # 1. 新服务端数据：连旧客户端（max updated_at）与新客户端都选到 ok_id
    assert out["fresh5056"]["legacyUpdatedMaxId"] == ok_id
    assert out["fresh5056"]["selectedId"] == ok_id
    assert out["fresh5056"]["showsIssueGeneratedFalse"] is False
    assert out["fresh5056"]["openModeGeneratedFalse"] == "preview"
    assert out["fresh5056"]["openModeGeneratedTrue"] == "preview"

    # 2. 历史库已被旧服务端污染 updated_at：旧排序会选到旧失败，但新前端仍选到 ok_id
    assert out["polluted5056"]["legacyUpdatedMaxId"] in fail_ids
    assert out["polluted5056"]["selectedId"] == ok_id
    assert out["polluted5056"]["showsIssueGeneratedFalse"] is False
    assert out["polluted5056"]["openModeGeneratedFalse"] == "preview"
    assert out["polluted5056"]["openModeGeneratedTrue"] == "preview"

    # 3. 仅有失败任务被忽略：退回空闲与预检
    assert out["onlyFail5057"]["selectedId"] is None
    assert out["onlyFail5057"]["showsIssueGeneratedFalse"] is False
    assert out["onlyFail5057"]["openModeGeneratedFalse"] == "preview"

    # 4. 撤销 5057 的忽略：恢复选中该失败任务、显示未完成态并打开状态弹窗
    undismiss = await job_client.post(f"/jobs/{only_fail_id}/undismiss")
    assert undismiss.status_code == 200
    items_5057_restored = (
        await job_client.get(
            "/jobs?job_type=subtitle.generate&resource_type=library_file&resource_id=5057&limit=5"
        )
    ).json()["data"]["items"]
    proc2 = subprocess.run(
        [
            node,
            "--input-type=module",
            "-e",
            script,
            json.dumps(
                {
                    "items5056": items_5056,
                    "polluted5056": polluted_5056,
                    "items5057": items_5057_restored,
                }
            ),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    out2 = json.loads(proc2.stdout)
    assert out2["onlyFail5057"]["selectedId"] == only_fail_id
    assert out2["onlyFail5057"]["showsIssueGeneratedFalse"] is True
    assert out2["onlyFail5057"]["openModeGeneratedFalse"] == "status"
    assert out2["onlyFail5057"]["showsIssueGeneratedTrue"] is False
    assert out2["onlyFail5057"]["openModeGeneratedTrue"] == "preview"

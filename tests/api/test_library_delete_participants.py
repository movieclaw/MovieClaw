"""删除参与方（docs/design/library-boundary.md §3）：媒体库删除弹窗的附加选项，端到端。

真实应用 + 运行中挂上一个测试用的系统模块，它登记几个参与方（正常 / 超时 / 出错 / 只适用整部删除）
和勾选后要跑的后续任务处理器，然后走 HTTP：

- 删除预览：媒体库自己的计划、硬链接字节数、各选项的预览与不可用原因；
- 删除时勾选：不存在 / 不可用的选项拒绝且什么都不删；可用的选项在删除的同一次提交里建后续任务，
  任务收到的只是实际删掉的文件；
- 不勾：行为与原来一样，不建任务。
"""

from __future__ import annotations

import asyncio
import os
import time
from functools import partial

import pytest
from fastapi.testclient import TestClient
from sqlmodel import func, select
from tests.api.test_domain_events import seed_show

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events, jobs
from movieclaw_api.services.library import delete_participants as dp
from movieclaw_db.engine import get_database
from movieclaw_db.models import Job, JobStatus
from movieclaw_kernel import Entry, plugin

ADMIN = {"username": "admin", "password": "s3cret-pass"}
seen: list[dict] = []


async def ok_preview(request: dp.DeleteRequest) -> dp.Preview:
    return dp.Preview(
        available=True,
        lines=(
            dp.PreviewLine(text=f"会处理 {len(request.files)} 个文件"),
            dp.PreviewLine(text="不可恢复", tone="danger"),
        ),
    )


async def slow_preview(request: dp.DeleteRequest) -> dp.Preview:
    await asyncio.sleep(5)
    return dp.Preview(available=True)


async def broken_preview(request: dp.DeleteRequest) -> dp.Preview:
    raise RuntimeError("下载器炸了")


async def follow_up(context: jobs.JobContext, payload: dict) -> dict:
    seen.append(payload)
    return {"message": "处理完了"}


@plugin("test-participants", title="测试删除参与方")
async def participants_plugin(ctx) -> None:
    ctx.contribute(
        jobs.JOB_HANDLERS, "test.follow-up", jobs.RegisteredJobHandler(follow_up, frozenset({1}))
    )
    ctx.contribute(
        dp.LIBRARY_DELETE_PARTICIPANTS,
        "ok",
        dp.DeleteParticipant("同时处理一下", "处理了就回不去", ok_preview, "test.follow-up"),
    )
    ctx.contribute(
        dp.LIBRARY_DELETE_PARTICIPANTS,
        "slow",
        dp.DeleteParticipant("很慢的选项", "", slow_preview, "test.follow-up"),
    )
    ctx.contribute(
        dp.LIBRARY_DELETE_PARTICIPANTS,
        "broken",
        dp.DeleteParticipant("会出错的选项", "", broken_preview, "test.follow-up"),
    )
    ctx.contribute(
        dp.LIBRARY_DELETE_PARTICIPANTS,
        "whole",
        dp.DeleteParticipant(
            "只在删整部时出现", "", ok_preview, "test.follow-up", applies_to=frozenset({"item"})
        ),
    )


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'delete.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(dp, "PREVIEW_TIMEOUT", 0.3)
    get_settings.cache_clear()
    durable_events.reset_state()
    seen.clear()
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import reset_auth_state

    reset_auth_state()
    app = create_app()
    test_client = TestClient(app)
    with test_client:
        resp = test_client.post("/api/v1/auth/bootstrap", json=ADMIN)
        assert resp.status_code == 200, resp.text
        call(test_client, app.state.kernel.mount, Entry("test-participants", participants_plugin))
        yield test_client
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


def seed(client: TestClient, tmp_path) -> dict:
    seeded = call(client, seed_show, get_database(), tmp_path)
    # 第一集与库外的下载目录是同一份数据（硬链接入库）
    downloads = tmp_path / "downloads"
    downloads.mkdir()
    os.link(seeded["paths"][0], downloads / "e1.mkv")
    return seeded


async def job_count() -> int:
    async with get_database().session() as session:
        return await session.scalar(select(func.count()).select_from(Job)) or 0


async def job_status(job_id: str) -> str:
    async with get_database().session() as session:
        return (await jobs.get_job(session, job_id)).status


def wait_until(client: TestClient, check, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        call(client, asyncio.sleep, 0.05)
    raise AssertionError("等待超时")


def base(seeded: dict) -> str:
    return f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}"


def test_preview_lists_the_plan_linked_bytes_and_options(client, tmp_path) -> None:
    seeded = seed(client, tmp_path)
    resp = client.get(f"{base(seeded)}/delete-preview")
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["whole_item"] is True
    assert data["plan"]["dry_run"] is True and data["plan"]["rows_deleted"] == 2
    # 第一集是硬链接：只删库文件不会释放它
    assert data["linked_bytes"] == 2
    options = {o["key"]: o for o in data["options"]}
    assert set(options) == {
        "test-participants:ok",
        "test-participants:slow",
        "test-participants:broken",
        "test-participants:whole",
    }
    ok = options["test-participants:ok"]
    assert ok["available"] is True and ok["help"] == "处理了就回不去"
    assert [line["text"] for line in ok["lines"]] == ["会处理 2 个文件", "不可恢复"]
    assert ok["lines"][1]["tone"] == "danger"
    assert options["test-participants:slow"]["available"] is False
    assert "超时" in options["test-participants:slow"]["reason"]
    assert options["test-participants:broken"]["available"] is False
    assert "出错" in options["test-participants:broken"]["reason"]
    # 磁盘上什么都没动
    assert all(p.exists() for p in seeded["paths"])


def test_file_preview_only_asks_participants_for_files(client, tmp_path) -> None:
    seeded = seed(client, tmp_path)
    resp = client.get(f"{base(seeded)}/delete-preview", params={"file_id": seeded["file_ids"][1]})
    data = resp.json()["data"]
    assert data["whole_item"] is False and data["linked_bytes"] == 0
    keys = {o["key"] for o in data["options"]}
    assert "test-participants:whole" not in keys
    ok = next(o for o in data["options"] if o["key"] == "test-participants:ok")
    assert ok["lines"][0]["text"] == "会处理 1 个文件"


@pytest.mark.parametrize(
    ("option", "message"),
    [("nope:missing", "没有这个删除选项"), ("test-participants:broken", "这次不能勾选")],
)
def test_unknown_or_unavailable_option_deletes_nothing(client, tmp_path, option, message) -> None:
    seeded = seed(client, tmp_path)
    resp = client.delete(base(seeded), params={"options": option})
    assert resp.status_code == 400
    assert message in resp.text
    assert all(p.exists() for p in seeded["paths"])
    assert call(client, job_count) == 0


def test_checked_option_gets_a_follow_up_job_with_the_deleted_files(client, tmp_path) -> None:
    seeded = seed(client, tmp_path)
    resp = client.delete(base(seeded), params={"options": "test-participants:ok"})
    assert resp.status_code == 200, resp.text
    [follow] = resp.json()["data"]["follow_ups"]
    assert follow["option"] == "test-participants:ok" and follow["label"] == "同时处理一下"
    wait_until(
        client, lambda: call(client, job_status, follow["job_id"]) == JobStatus.SUCCEEDED.value
    )
    [payload] = seen
    request = payload["request"]
    assert payload["option"] == "test-participants:ok"
    assert request["whole_item"] is True and request["title"] == "测试剧集"
    assert sorted(f["id"] for f in request["files"]) == sorted(seeded["file_ids"])
    assert not seeded["paths"][0].exists()


def test_single_file_follow_up_only_carries_that_file(client, tmp_path) -> None:
    seeded = seed(client, tmp_path)
    target = seeded["file_ids"][0]
    resp = client.delete(
        f"{base(seeded)}/files/{target}", params={"options": "test-participants:ok"}
    )
    assert resp.status_code == 200, resp.text
    [follow] = resp.json()["data"]["follow_ups"]
    wait_until(
        client, lambda: call(client, job_status, follow["job_id"]) == JobStatus.SUCCEEDED.value
    )
    request = seen[0]["request"]
    assert request["whole_item"] is False
    assert [f["id"] for f in request["files"]] == [target]
    # 只适用整部删除的选项不能在删单文件时勾
    resp = client.delete(
        f"{base(seeded)}/files/{seeded['file_ids'][1]}",
        params={"options": "test-participants:whole"},
    )
    assert resp.status_code == 400


def test_without_options_nothing_changes(client, tmp_path) -> None:
    seeded = seed(client, tmp_path)
    resp = client.delete(base(seeded))
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["follow_ups"] == []
    assert call(client, job_count) == 0
    assert not seeded["paths"][0].exists()

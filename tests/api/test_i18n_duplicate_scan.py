"""Duplicate scan progress keeps Chinese rollback text and renders per reader."""

from copy import deepcopy

import pytest

from . import test_library_duplicates as duplicates

client = duplicates.client
db = duplicates.db


@pytest.mark.asyncio
@pytest.mark.parametrize("populated", [False, True])
async def test_duplicate_scan_messages_keep_facts_and_raw_storage(client, db, tmp_path, populated):
    from sqlmodel import select

    from movieclaw_api.services.library import duplicate_scan
    from movieclaw_db.models import Job

    if populated:
        await duplicates._seed(db, tmp_path)
    async with db.session() as session:
        created = await duplicate_scan.enqueue_duplicate_scan_job(session)
        job_id = created.job.id
    for language, expected, subject in (
        ("en", "Waiting to scan duplicate files", "Duplicate files"),
        ("zh-Hans", "等待扫描重复文件", "重复文件"),
    ):
        response = await client.get(f"/api/v1/jobs/{job_id}", headers={"Accept-Language": language})
        assert response.status_code == 200, response.text
        assert response.json()["data"]["progress"]["message"] == expected
        # 任务名按读者语言（库里仍存中文原文供旧客户端）
        assert response.json()["data"]["subject"] == subject
    outcome = await duplicates._scan(db)
    assert outcome["message_key"] == (
        "library.duplicateScan.completed" if populated else "library.duplicateScan.empty"
    )
    async with db.session() as session:
        row = (await session.execute(select(Job).where(Job.id == job_id))).scalar_one()
        stored = deepcopy(row.progress), deepcopy(row.result)
    assert stored[0]["message"] == "记录结论"
    assert stored[0]["message_key"] == "library.duplicateScan.persist"
    assert stored[1]["message"].startswith("重复扫描完成：")
    views = []
    for language in ("en", "zh-Hans", "en"):
        response = await client.get(f"/api/v1/jobs/{job_id}", headers={"Accept-Language": language})
        assert response.status_code == 200, response.text
        view = response.json()["data"]
        assert view["result"]["units"] == outcome["units"]
        assert view["result"]["files"] == outcome["files"]
        assert view["result"]["bytes"] == outcome["bytes"]
        views.append(view)
    assert views[0] == views[2]
    assert views[0]["progress"]["message"] == "Recording results"
    assert views[1]["progress"]["message"] == "记录结论"
    assert views[0]["result"]["message"].startswith("Duplicate scan complete:")
    async with db.session() as session:
        row = await session.get(Job, job_id)
        assert (row.progress, row.result) == stored

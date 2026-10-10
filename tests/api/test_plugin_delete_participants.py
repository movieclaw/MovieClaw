"""第三方插件登记删除参与方（docs/design/library-boundary.md §3、§9）。

本地插件在主进程里跑一遍、在独立进程里再跑一遍：登记一个删除选项和它的后续任务处理器，
走 HTTP 看删除预览里出现它的选项、预览由插件算；勾选删除后后续任务在插件里执行，
拿到的是实际删掉的文件。
"""

from __future__ import annotations

import asyncio
import sys
import textwrap
import time
from functools import partial

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select
from tests.api.test_domain_events import seed_show

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events, jobs
from movieclaw_db.engine import get_database
from movieclaw_db.models import JobStatus
from movieclaw_db.models.plugin_data import PluginData

ADMIN = {"username": "admin", "password": "s3cret-pass"}
KEY = "acme-backup:backup"

PLUGIN = """
from movieclaw_api.plugins.keys import PLUGIN_DATA
from movieclaw_api.services.jobs import JOB_HANDLERS, RegisteredJobHandler
from movieclaw_api.services.library.delete_participants import (
    LIBRARY_DELETE_PARTICIPANTS,
    DeleteParticipant,
    Preview,
    PreviewLine,
)
from movieclaw_sdk import plugin


@plugin("acme-backup", title="网盘备份清理", inject=(PLUGIN_DATA,))
async def apply(ctx) -> None:
    data = ctx.use(PLUGIN_DATA).scoped(ctx)

    async def preview(request):
        text = f"网盘里《{request.title}》的 {len(request.files)} 个备份会一起删除"
        return Preview(available=True, lines=(PreviewLine(text=text),))

    async def cleanup(context, payload):
        files = payload["request"]["files"]
        await data.set("removed", [f["id"] for f in files])
        return {"message": f"删掉了 {len(files)} 个网盘备份"}

    ctx.contribute(JOB_HANDLERS, "cleanup", RegisteredJobHandler(cleanup, frozenset({1})))
    ctx.contribute(
        LIBRARY_DELETE_PARTICIPANTS,
        "backup",
        DeleteParticipant(
            label="同时删除网盘备份",
            help="网盘里的备份删了找不回来",
            preview=preview,
            job_type=f"{ctx.entry_id}:cleanup",
        ),
    )
"""


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pdp.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_backup.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: acme-backup
              local: true
              module: acme_backup
              runtime: {request.param}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


async def job_status(job_id: str) -> str:
    async with get_database().session() as session:
        return (await jobs.get_job(session, job_id)).status


async def removed_ids() -> list[int] | None:
    async with get_database().session() as session:
        row = (
            await session.execute(select(PluginData).where(PluginData.key == "removed"))
        ).scalar_one_or_none()
        return None if row is None else row.value


def test_plugin_option_previews_and_runs_in_the_plugin(client, tmp_path) -> None:
    seeded = call(client, seed_show, get_database(), tmp_path)
    base = f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}"
    resp = client.get(f"{base}/delete-preview")
    assert resp.status_code == 200, resp.text
    [option] = [o for o in resp.json()["data"]["options"] if o["key"] == KEY]
    assert option["available"] is True and option["label"] == "同时删除网盘备份"
    assert option["lines"] == [{"text": "网盘里《测试剧集》的 2 个备份会一起删除", "tone": "info"}]

    resp = client.delete(base, params={"options": KEY})
    assert resp.status_code == 200, resp.text
    [follow] = resp.json()["data"]["follow_ups"]
    deadline = time.monotonic() + 20
    while call(client, job_status, follow["job_id"]) != JobStatus.SUCCEEDED.value:
        assert time.monotonic() < deadline, call(client, job_status, follow["job_id"])
        call(client, asyncio.sleep, 0.1)
    assert sorted(call(client, removed_ids)) == sorted(seeded["file_ids"])

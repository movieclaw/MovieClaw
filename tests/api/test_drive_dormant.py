"""没有插件提供网盘后端时网盘功能整体休眠（docs/design/cloud-storage.md §11.8）。

没用网盘的用户：不跑网盘定时任务、不留运行记录、定时任务列表里没有它们，接口不带网盘字段；
装上网盘插件就挂上，撤走就撤下。
"""

from __future__ import annotations

import asyncio

from tests.api.test_libraries import client  # noqa: F401 -- 复用它的应用夹具

from movieclaw_api.plugins.keys import DB
from movieclaw_api.plugins.playback import drive_uploads
from movieclaw_kernel import plugin
from movieclaw_kernel.testing import KernelHarness
from movieclaw_scheduler import SCHEDULED_TASKS
from movieclaw_sdk.drives import DRIVE_BACKENDS, DriveBackend

DRIVE_TASKS = {"drive_changes", "drive_probe_specs", "drive_release_sweep", "drive_upload_sweep"}


class _Fake(DriveBackend):
    type = "fake"
    title = "假网盘"


@plugin("test.fake-drive", title="假网盘")
async def fake_drive(ctx) -> None:
    ctx.contribute(DRIVE_BACKENDS, "fake", _Fake())


async def _settle() -> None:
    for _ in range(5):
        await asyncio.sleep(0)


async def test_drive_tasks_follow_the_drive_plugins():
    async with KernelHarness() as h:
        h.provide(DB, object())
        fiber = await h.mount(drive_uploads)
        assert fiber.state.value == "active", fiber.error
        await _settle()
        tasks = h.registry(SCHEDULED_TASKS)
        assert DRIVE_TASKS.isdisjoint(dict(tasks.items()))

        backend = await h.mount(fake_drive)
        await _settle()
        assert set(dict(tasks.items())) >= DRIVE_TASKS

        await h.unmount(backend)
        await _settle()
        assert DRIVE_TASKS.isdisjoint(dict(tasks.items()))

        # 再装回来：再挂上，不重复
        await h.mount(fake_drive)
        await _settle()
        assert set(dict(tasks.items())) >= DRIVE_TASKS


def test_api_without_drive_plugins_says_dormant_and_hides_drive_fields(client, tmp_path):  # noqa: F811
    status = client.get("/api/v1/drives/status")
    assert status.status_code == 200, status.text
    assert status.json()["data"] == {"active": False, "accounts": 0}

    root = tmp_path / "movies"
    root.mkdir()
    created = client.post(
        "/api/v1/libraries", json={"name": "电影", "kind": "movie", "root_paths": [str(root)]}
    )
    assert created.status_code == 200, created.text
    assert created.json()["data"]["cloud_folders"] is None
    listed = client.get("/api/v1/libraries").json()["data"]
    assert all(lib["cloud_folders"] is None and lib["cloud_upload"] is None for lib in listed)
    detail = client.get(f"/api/v1/libraries/{created.json()['data']['id']}").json()["data"]
    assert detail["cloud_folders"] is None

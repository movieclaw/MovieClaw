"""内置插件的可重载测试（docs/design/plugin-kernel.md §12.4）。

在真实应用里对每个标了 ``reloadable`` 的插件走一遍「禁用 → 启用」，断言：
- 禁用后它的后台任务、事件监听、注册表贡献、服务全部撤回；依赖它的插件随之暂停；
- 线程数、打开的文件描述符数不增长；
- 启用后它与依赖方都恢复运行，提供的服务与贡献的注册表项回到原样。

第二阶段的运行中启停只对通过这里的插件开放。非关键内置插件都必须能重载：
新增插件要么证明可重载，要么在 ``NOT_RELOADABLE`` 里写明原因。
"""

from __future__ import annotations

import asyncio
import os
import threading

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_kernel import State

#: 非关键但不能运行中重载的内置插件（条目 id → 原因）。目前没有。
NOT_RELOADABLE: dict[str, str] = {}


def _fd_count() -> int:
    try:
        return len(os.listdir("/dev/fd"))
    except OSError:  # pragma: no cover - 非类 Unix 平台
        return -1


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "true")
    # Jellyfin 自动发现默认绑固定的 UDP 7359：并行跑测试时别的进程可能正占着它，
    # 首次启用绑不上、重载时又绑上了，描述符数就「多出一个」。改绑随机端口，结果才确定
    from movieclaw_jellyfin import udp

    monkeypatch.setattr(udp, "DISCOVERY_PORT", 0)
    get_settings.cache_clear()
    from movieclaw_api.app import create_app

    app = create_app()
    yield app, TestClient(app)
    get_settings.cache_clear()


def test_every_non_critical_builtin_plugin_is_marked_reloadable() -> None:
    from movieclaw_api.plugins.manifest import BUILTIN_MANIFEST

    unmarked = [
        e.id
        for e in BUILTIN_MANIFEST
        if not e.plugin.critical and not e.plugin.reloadable and e.id not in NOT_RELOADABLE
    ]
    assert unmarked == [], "非关键插件须证明可重载（或在 NOT_RELOADABLE 写明原因）"


def test_reloadable_plugins_release_everything_and_come_back(app_client) -> None:
    app, client = app_client
    problems: list[str] = []

    async def snapshot(kernel):
        services = {name: holder[1].id for name, holder in kernel._services.items()}
        contributions = {
            name: sorted((c.id, c.entry_id) for c in reg.contributions())
            for name, reg in kernel._registries.items()
        }
        states = {f.id: f.state for f in kernel.fibers}
        return services, contributions, states

    async def cycle(entry_id: str) -> None:
        kernel = app.state.kernel
        await asyncio.sleep(0.05)
        before = await snapshot(kernel)
        threads, fds = threading.active_count(), _fd_count()

        await kernel.disable(entry_id)
        await asyncio.sleep(0.05)
        fiber = kernel.fiber(entry_id)
        live = [
            t.get_name()
            for t in asyncio.all_tasks()
            if t.get_name().startswith(f"plugin:{entry_id}:") and not t.done()
        ]
        if fiber.state is not State.DISABLED:
            problems.append(f"{entry_id}: 禁用后状态为 {fiber.state.value}")
        if live:
            problems.append(f"{entry_id}: 禁用后仍有后台任务 {live}")
        if kernel.bus.owned_by(entry_id):
            problems.append(f"{entry_id}: 禁用后仍有事件监听")
        for name, reg in kernel._registries.items():
            if reg.owned_by(entry_id):
                problems.append(f"{entry_id}: 禁用后仍有 {name} 贡献")
        if any(holder[1] is fiber for holder in kernel._services.values()):
            problems.append(f"{entry_id}: 禁用后服务仍在")
        dependents_left = [
            f.id
            for f in kernel.fibers
            if f.state is State.ACTIVE
            and any(k.name in fiber.provided or k in fiber.plugin.provides for k in f.plugin.inject)
        ]
        if dependents_left:
            problems.append(f"{entry_id}: 依赖方未暂停 {dependents_left}")

        await kernel.enable(entry_id)
        await asyncio.sleep(0.05)
        after = await snapshot(kernel)
        if after[2] != before[2]:
            changed = {k: v.value for k, v in after[2].items() if before[2].get(k) is not v}
            problems.append(f"{entry_id}: 启用后状态未复原 {changed}")
        if after[0] != before[0]:
            problems.append(f"{entry_id}: 启用后服务提供方变了")
        if after[1] != before[1]:
            problems.append(f"{entry_id}: 启用后注册表贡献变了")
        if threading.active_count() > threads:
            problems.append(f"{entry_id}: 线程从 {threads} 增到 {threading.active_count()}")
        if _fd_count() > fds:
            problems.append(f"{entry_id}: 文件描述符从 {fds} 增到 {_fd_count()}")

    with client:
        kernel = app.state.kernel
        targets = [f.id for f in kernel.fibers if f.parent is None and f.plugin.reloadable]
        assert len(targets) >= 30
        for entry_id in targets:
            client.portal.call(cycle, entry_id)  # type: ignore[attr-defined]

        # 冒烟：调度器重载后是一个新的、在运行的实例，任务齐全；执行器在
        from movieclaw_api.services import jobs
        from movieclaw_scheduler import get_scheduler, iter_tasks

        scheduler = get_scheduler()
        assert scheduler._scheduler.running
        job_ids = {job.id for job in scheduler._scheduler.get_jobs()}
        assert {d.key for d in iter_tasks()} <= job_ids
        assert jobs._dispatcher is not None
        assert client.get("/api/v1/health").status_code == 200

    assert problems == []

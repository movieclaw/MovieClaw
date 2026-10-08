"""调度与后台任务插件（plugin-kernel.md §6、§7）。

应用更新、定时任务调度器、刷流带宽哨兵、持久化任务执行器。

定时任务与后台任务处理器都是注册表贡献：领域插件把自己模块里声明的任务 / 处理器贡献进
``SCHEDULED_TASKS`` / ``JOB_HANDLERS``，调度器与执行器只认注册表——插件卸载即撤下，
不再靠「某个模块碰巧被 import 过」。
"""

from __future__ import annotations

import asyncio
import logging

from movieclaw_api.plugins.keys import DB, JOBS, SCHEDULER
from movieclaw_kernel import Context, RegistryChange, plugin

logger = logging.getLogger("movieclaw_api.plugins.scheduling")


@plugin("app-update.startup-check", title="启动后检查更新", inject=(SCHEDULER,))
async def app_update_startup_check(ctx: Context) -> None:
    from movieclaw_api.services.app_update import close_startup_check, start_startup_check

    # 启动后的更新首查（延迟数分钟）：容器重启后尽快感知新版；非 Docker 部署内部自动跳过。
    # 与调度器同开关：调度器禁用时这部分停在等待状态
    start_startup_check()
    ctx.effect(close_startup_check, label="close-startup-check")


@plugin("app-update", title="应用更新", inject=(DB,))
async def app_update(ctx: Context) -> None:
    from movieclaw_api.services import app_update as module
    from movieclaw_scheduler import contribute_tasks

    # 旧版更新提醒清场：更新提醒曾写进「待处理事项」，现已改为侧栏常驻徽标，存量告警行
    # 再无任何路径去消退它
    await module.clear_legacy_update_notices()
    # 镜像升级后残留的陈旧 overlay 就地清掉，否则状态页会一直显示「已安装但未在运行」
    await module.prune_stale_overlays()
    # 跑镜像基线时记下版本号：回退列表据此向用户明示「回落基线 = 回到 v 几」
    await module.record_baseline_version()
    contribute_tasks(ctx, module)  # 每日检查更新
    ctx.plugin(app_update_startup_check)


@plugin("scheduler", title="定时任务调度器", inject=(DB,), provides=(SCHEDULER,), disableable=True)
async def scheduler(ctx: Context) -> None:
    from movieclaw_scheduler import (
        SCHEDULED_TASKS,
        SchedulerConfig,
        contribute_tasks,
        get_scheduler,
        init_scheduler,
    )
    from movieclaw_scheduler import tasks as builtin_tasks

    contribute_tasks(ctx, builtin_tasks)  # 历史清理、缓存清理
    settings = ctx.settings
    init_scheduler(
        SchedulerConfig(
            timezone=settings.scheduler_timezone,
            task_run_retention_days=settings.task_run_retention_days,
        )
    )
    service = get_scheduler()
    # 启动时加载注册表里已有的全部任务（领域插件排在调度器之前，启动即齐）
    await service.start()
    ctx.effect(service.shutdown, label="shutdown-scheduler")
    ctx.provide(SCHEDULER, service)

    # 运行中挂上 / 卸下的插件：任务随之排上 / 撤下。注册表回调是同步的，这里排队串行处理
    changes: asyncio.Queue[RegistryChange] = asyncio.Queue()
    ctx.watch(SCHEDULED_TASKS, changes.put_nowait)

    async def apply_changes() -> None:
        while True:
            change = await changes.get()
            try:
                if change.kind == "added":
                    await service.add_task(change.item)
                else:
                    await service.remove_task(change.id)
            except Exception:
                logger.exception("同步定时任务 %s 的%s失败", change.id, change.kind)

    ctx.task(apply_changes(), name="sync-tasks")


@plugin("boost.sentinel", title="刷流带宽哨兵", inject=(SCHEDULER,), disableable=True)
async def boost_sentinel(ctx: Context) -> None:
    from movieclaw_api.services.boost_bandwidth import (
        close_boost_bandwidth_sentinel,
        init_boost_bandwidth_sentinel,
    )

    # 有刷流任务在下载时秒级保护上行；与刷流引擎同属调度器开关管辖
    init_boost_bandwidth_sentinel()
    ctx.effect(close_boost_bandwidth_sentinel, label="close-boost-sentinel")


@plugin("jobs", title="持久化任务执行器", inject=(DB,), provides=(JOBS,))
async def jobs(ctx: Context) -> None:
    from movieclaw_api.services.jobs import close_job_dispatcher, init_job_dispatcher

    # 只领取注册表里有处理器的任务类型；关闭时在安全边界暂停并退回数据库队列，须早于数据库释放
    ctx.effect(close_job_dispatcher, label="close-job-dispatcher")
    ctx.provide(JOBS, await init_job_dispatcher())

"""调度与后台任务插件（plugin-kernel.md §7）。

应用更新、定时任务调度器、刷流带宽哨兵、持久化任务执行器。
"""

from __future__ import annotations

from movieclaw_api.plugins.keys import DB, JOBS, SCHEDULER
from movieclaw_kernel import Context, plugin


@plugin("app-update.startup-check", title="启动后检查更新", inject=(SCHEDULER,))
async def app_update_startup_check(ctx: Context) -> None:
    from movieclaw_api.services.app_update import close_startup_check, start_startup_check

    # 启动后的更新首查（延迟数分钟）：容器重启后尽快感知新版；非 Docker 部署内部自动跳过。
    # 与调度器同开关：调度器禁用时这部分停在等待状态
    start_startup_check()
    ctx.effect(close_startup_check, label="close-startup-check")


@plugin("app-update", title="应用更新", inject=(DB,))
async def app_update(ctx: Context) -> None:
    from movieclaw_api.services.app_update import (
        clear_legacy_update_notices,
        prune_stale_overlays,
        record_baseline_version,
    )

    # 旧版更新提醒清场：更新提醒曾写进「待处理事项」，现已改为侧栏常驻徽标，存量告警行
    # 再无任何路径去消退它
    await clear_legacy_update_notices()
    # 镜像升级后残留的陈旧 overlay 就地清掉，否则状态页会一直显示「已安装但未在运行」
    await prune_stale_overlays()
    # 跑镜像基线时记下版本号：回退列表据此向用户明示「回落基线 = 回到 v 几」
    await record_baseline_version()
    ctx.plugin(app_update_startup_check)


def _import_task_modules() -> None:
    """领域任务模块经 import 触发 ``@register_task`` 注册（须在调度器 start 之前）。"""
    from movieclaw_api.services import (  # noqa: F401
        app_update,  # 应用更新每日检查
        download_progress,  # 下载完成检测与入库
        media_refresh,  # 媒体库对账
        ratio_boost,  # 自动刷分享率
        torrent_matcher,  # 订阅管线
        torrent_sync,  # 种子同步
    )
    from movieclaw_api.services.library import (  # noqa: F401
        ingest,  # 监听导入与对账
        nfo_backfill,  # 本地 NFO 吸收回填
        recycle,  # 回收站到期清理与孤儿清扫
        scan,  # 库对账
        series_backfill,  # 作品系列存量回填
    )
    from movieclaw_api.services.subscription import (  # noqa: F401
        smart_scheduler,  # 智能订阅定时
        upgrade,  # 洗版基线回填
        wanted_search,  # 缺口搜索
    )


@plugin(
    "scheduler",
    title="定时任务调度器",
    inject=(DB,),
    provides=(SCHEDULER,),
    disableable=True,
)
async def scheduler(ctx: Context) -> None:
    from movieclaw_scheduler import SchedulerConfig, get_scheduler, init_scheduler

    _import_task_modules()
    settings = ctx.settings
    init_scheduler(
        SchedulerConfig(
            timezone=settings.scheduler_timezone,
            task_run_retention_days=settings.task_run_retention_days,
        )
    )
    service = get_scheduler()
    await service.start()
    ctx.effect(service.shutdown, label="shutdown-scheduler")
    ctx.provide(SCHEDULER, service)


@plugin("boost.sentinel", title="刷流带宽哨兵", inject=(SCHEDULER,), disableable=True)
async def boost_sentinel(ctx: Context) -> None:
    from movieclaw_api.services.boost_bandwidth import (
        close_boost_bandwidth_sentinel,
        init_boost_bandwidth_sentinel,
    )

    # 有刷流任务在下载时秒级保护上行；与刷流引擎同属调度器开关管辖
    init_boost_bandwidth_sentinel()
    ctx.effect(close_boost_bandwidth_sentinel, label="close-boost-sentinel")


def _import_job_handler_modules() -> None:
    """领域模块经 import 完成后台任务处理器注册（不能依赖「某条路由碰巧加载过模块」）。"""
    from movieclaw_api.services import media_scrape  # noqa: F401
    from movieclaw_api.services.library import (  # noqa: F401
        ingest,
        organize,
        scan,
        transfer,
    )
    from movieclaw_api.services.subscription import cleanup  # noqa: F401  取消订阅联动清理
    from movieclaw_api.services.subtitle_gen import tasks  # noqa: F401


@plugin("jobs", title="持久化任务执行器", inject=(DB,), provides=(JOBS,))
async def jobs(ctx: Context) -> None:
    from movieclaw_api.services.jobs import close_job_dispatcher, init_job_dispatcher

    # 在所有业务依赖就绪后启动；关闭时在安全边界暂停并退回数据库队列，须早于数据库释放
    _import_job_handler_modules()
    ctx.effect(close_job_dispatcher, label="close-job-dispatcher")
    ctx.provide(JOBS, await init_job_dispatcher())

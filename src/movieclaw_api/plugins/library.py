"""媒体库插件（plugin-kernel.md §7）。

内置合集自愈、存量回填、实时监控、下载监听导入、搜索索引、片头补算。
"""

from __future__ import annotations

from movieclaw_api.plugins.keys import DB, JOBS
from movieclaw_kernel import Context, plugin


@plugin("library.builtin-collections", title="内置合集自愈", inject=(DB,))
async def builtin_collections(ctx: Context) -> None:
    """给每个库补齐内置合集（现在只有「我的收藏」），幂等。

    做成启动自愈而不是一次性迁移：迁移只补得到「迁移那一刻已经存在」的库，此后任何绕过
    建库接口写进来的库（导入、测试夹具、手工 SQL）都会缺这一行。每个库一次 SELECT，可忽略。
    """
    from sqlmodel import select

    from movieclaw_api.services.library.collections import ensure_builtin_collections
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Library

    async with get_database().session() as session:
        library_ids = (await session.execute(select(Library.id))).scalars().all()
        for library_id in library_ids:
            if library_id is not None:
                await ensure_builtin_collections(session, library_id)
        await session.commit()


@plugin("enrich.backfill", title="扩充属性重算", inject=(DB,))
async def enrich_backfill(ctx: Context) -> None:
    from movieclaw_api.services.enrich_backfill import (
        close_enrich_backfill,
        start_enrich_backfill,
    )

    # 提取器升级后把存量种子行按新逻辑重算；含 NER 推理、可达分钟级，排成后台任务不占启动窗口
    start_enrich_backfill()
    ctx.effect(close_enrich_backfill, label="close-enrich-backfill")


@plugin("library.disc-image-durations", title="光盘镜像片长修正", inject=(DB,))
async def disc_image_durations(ctx: Context) -> None:
    from movieclaw_api.services.library.disc_image_durations import (
        close_disc_image_duration_heal,
        start_disc_image_duration_heal,
    )

    # 存量光盘镜像的台账片长换成盘内正片时长（ffprobe 对镜像估得离谱，见模块注释）
    start_disc_image_duration_heal()
    ctx.effect(close_disc_image_duration_heal, label="close-disc-image-durations")


@plugin("library.dolby-vision-backfill", title="杜比视界 profile 补记", inject=(DB,))
async def dolby_vision_backfill(ctx: Context) -> None:
    from movieclaw_api.services.library.dolby_vision_backfill import (
        close_dolby_vision_backfill,
        start_dolby_vision_backfill,
    )

    # 存量杜比视界文件补记 profile（播放决策按 profile 分直通 / 基础层 / 转码）
    start_dolby_vision_backfill()
    ctx.effect(close_dolby_vision_backfill, label="close-dolby-vision-backfill")


@plugin("library.watch", title="媒体库实时监控", inject=(DB,), disableable=True)
async def library_watch(ctx: Context) -> None:
    from movieclaw_api.services.library.watch import close_library_watcher, init_library_watcher

    # 库根路径文件事件 → 去抖 → 增量扫描；watchdog 缺失 / 根路径未就绪时降级为对账任务兜底。
    # 建 watch 在监听器内部后台进行，这里立即返回（网络挂载上可达分钟级，issue #162）。
    # 观察者线程持有事件循环引用，释放须在循环关闭前完成
    await init_library_watcher()
    ctx.effect(close_library_watcher, label="close-library-watcher")


@plugin("library.ingest-watch", title="下载监听导入", inject=(DB,), disableable=True)
async def ingest_watch(ctx: Context) -> None:
    from movieclaw_api.services.library.ingest import close_ingest_watcher, init_ingest_watcher

    # 监听目录文件事件 → 去抖 → 完成检测 → 创建持久化 Job；watchdog 缺失时降级为兜底巡检
    await init_ingest_watcher()
    ctx.effect(close_ingest_watcher, label="close-ingest-watcher")


@plugin("library.search-index", title="媒体库搜索索引", inject=(JOBS,))
async def search_index(ctx: Context) -> None:
    from movieclaw_api.services.jobs import contribute_job_handlers
    from movieclaw_api.services.library import search_index as module

    # 搜索更新复用持久化 Job；增量触发器在迁移中安装，启动不等待全库拼音转换。
    # 释放先于任务执行器（激活晚于它）
    contribute_job_handlers(ctx, module)
    module.start_search_index()
    ctx.effect(module.close_search_index, label="close-search-index")


@plugin("library.skip-segments", title="片头识别启动补算", inject=(JOBS,))
async def skip_segments_recovery(ctx: Context) -> None:
    from movieclaw_api.services.library.skip_segments import enqueue_pending_libraries

    # 算法升级后旧识别结果须主动重算；后台只排持久化任务，不在启动期间读 NAS。
    # 释放时先取消排队，避免关闭任务执行器和数据库时仍在创建任务
    ctx.task(enqueue_pending_libraries(), name="startup-recovery")

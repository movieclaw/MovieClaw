"""领域贡献插件（plugin-kernel.md §6、§7）。

这些插件不初始化任何东西，只把领域模块里声明的定时任务与后台任务处理器贡献进注册表。
它们排在调度器与执行器之前：调度器启动时任务已齐，执行器启动时处理器已齐。
卸载任何一个，它的任务和处理器随之撤下；这正是第三方插件贡献任务的方式。
"""

from __future__ import annotations

from movieclaw_api.plugins.keys import DB, SITE_ACCESS
from movieclaw_kernel import Context, plugin


@plugin("downloads", title="下载与种子同步", inject=(SITE_ACCESS,), reloadable=True)
async def downloads(ctx: Context) -> None:
    """定时同步各站新种并匹配订阅，盯下载进度、死种自动换源，删片时可一并删除下载任务与源文件。"""
    from movieclaw_api.services import (
        download_progress,
        download_sources,
        media_refresh,
        torrent_matcher,
        torrent_sync,
    )
    from movieclaw_scheduler import contribute_tasks

    contribute_tasks(
        ctx, download_progress, torrent_sync, torrent_matcher, media_refresh, download_sources
    )

    # 删片时「同时删除下载任务和源文件」：媒体库删除参与方（library-boundary.md §4）
    from movieclaw_api.services import remove_source
    from movieclaw_api.services.jobs import contribute_job_handlers
    from movieclaw_api.services.library.delete_participants import LIBRARY_DELETE_PARTICIPANTS

    contribute_job_handlers(ctx, remove_source)
    # 媒体库与获取领域之间的接口（library-boundary.md §10）：媒体库经它要信息、发通知
    from movieclaw_api.services.acquisition_bridge import Acquisition
    from movieclaw_api.services.library import acquisition

    ctx.effect(acquisition.bind(Acquisition()), label="unbind-acquisition")
    ctx.contribute(
        LIBRARY_DELETE_PARTICIPANTS, remove_source.PARTICIPANT_ID, remove_source.PARTICIPANT
    )


@plugin("boost", title="自动刷分享率", inject=(SITE_ACCESS,), disableable=True, reloadable=True)
async def boost(ctx: Context) -> None:
    """自动刷分享率：盯住站点的免费种第一时间下载做种，在预算内自动汰换。"""
    from movieclaw_api.services import ratio_boost
    from movieclaw_scheduler import contribute_tasks

    contribute_tasks(ctx, ratio_boost)


@plugin("subscription", title="订阅", inject=(SITE_ACCESS,), reloadable=True)
async def subscription(ctx: Context) -> None:
    """定时为订阅搜索缺失内容、到期择优下载，并在取消订阅时清理相应的下载任务与文件。"""
    from movieclaw_api.services.jobs import contribute_job_handlers
    from movieclaw_api.services.subscription import (
        cleanup,
        smart_scheduler,
        upgrade,
        wanted_search,
    )
    from movieclaw_scheduler import contribute_tasks

    contribute_tasks(ctx, smart_scheduler, wanted_search, upgrade)
    contribute_job_handlers(ctx, cleanup)  # 取消订阅联动清理


@plugin("library.core", title="媒体库", inject=(DB,), reloadable=True)
async def library_core(ctx: Context) -> None:
    """媒体库后台工作：扫描对账、整理改名、条目转移、回收站清理、章节图、片头识别和查重复文件。"""
    from movieclaw_api.services.jobs import contribute_job_handlers
    from movieclaw_api.services.library import (
        batch_transfer,
        chapters,
        duplicate_scan,
        ingest,
        nfo_backfill,
        organize,
        recycle,
        scan,
        series_backfill,
        skip_segments,
        transfer,
    )
    from movieclaw_scheduler import contribute_tasks

    contribute_tasks(ctx, ingest, nfo_backfill, recycle, scan, series_backfill)
    # 批量转移、章节、重复文件三类处理器以前不在启动的 import 列表里，靠路由模块碰巧 import
    # 才注册上；现在显式贡献
    contribute_job_handlers(
        ctx,
        ingest,
        organize,
        scan,
        transfer,
        batch_transfer,
        chapters,
        skip_segments,
        duplicate_scan,
    )


@plugin("media.scrape", title="元数据刷新", inject=(DB,), reloadable=True)
async def media_scrape(ctx: Context) -> None:
    """执行元数据刷新任务（单个条目或整库），从 TMDB 重新拉取简介、演职员与图片。"""
    from movieclaw_api.services import media_scrape as module
    from movieclaw_api.services.jobs import contribute_job_handlers

    contribute_job_handlers(ctx, module)


@plugin("subtitle.gen", title="AI 字幕生成", inject=(DB,), reloadable=True)
async def subtitle_gen(ctx: Context) -> None:
    """执行 AI 字幕生成任务：挑选源字幕，用 AI 模型翻译并检查质量，生成新的字幕文件。"""
    from movieclaw_api.services.jobs import contribute_job_handlers
    from movieclaw_api.services.subtitle_gen import tasks

    contribute_job_handlers(ctx, tasks)

"""内置插件清单（docs/design/plugin-kernel.md §7）。

清单顺序沿用改造前 lifespan 的启动顺序。内核的排序规则：声明顺序 = 激活顺序（在依赖允许的
范围内）= 释放的逆序。原 lifespan 注释里「谁先停」的约束，用「真实依赖写进 inject」加
「清单顺序」表达，并由 tests/api/test_plugin_bootstrap.py 逐条断言：

- 转码会话最先停（killpg 整组）：清单最后一项，逆序第一个释放；
- 远程 Worker 在转码会话之后关：转码依赖 REMOTE_WORKERS；
- 先停微信 / IM 通道，再停 Agent 注册表：两个通道依赖 AGENT_RUNS；
- 先停「新片到达」，再停推送中枢：arrivals 依赖 PUSH_HUB；
- 片头补算、搜索索引先于任务执行器停：二者依赖 JOBS；
- 领域贡献插件排在调度器与执行器之前：二者启动时任务、处理器已齐；关闭时引擎先停，
  任务不会在关停过程中被逐个撤下写库；
- 任务执行器、Agent、站点客户端先于数据库释放：都依赖 DB；
- Agent 先于共享 HTTP 客户端释放：HTTP 客户端激活更早；
- 最后刷统计、关数据库：core.database 是根。
"""

from __future__ import annotations

from movieclaw_api.plugins import agent, core, delivery, domains, library, playback, scheduling
from movieclaw_kernel import Entry, Patch

BUILTIN_MANIFEST: tuple[Entry, ...] = tuple(
    Entry(p.name, p)
    for p in (
        core.database,
        core.registries,
        core.secrets,
        core.setting_store,
        core.egress,
        core.scrape_runtime,
        playback.remote_config,
        core.http_clients,
        core.sites,
        core.site_access,
        core.selfheal_credentials,
        library.builtin_collections,
        agent.agent_runs,
        agent.agent_session_index,
        agent.agent_attachments,
        library.enrich_backfill,
        library.disc_image_durations,
        library.dolby_vision_backfill,
        scheduling.app_update,
        domains.downloads,
        domains.boost,
        domains.subscription,
        domains.library_core,
        domains.media_scrape,
        domains.subtitle_gen,
        scheduling.scheduler,
        scheduling.boost_sentinel,
        library.library_watch,
        library.ingest_watch,
        delivery.weixin,
        delivery.im_channels,
        delivery.cloud,
        delivery.push_hub,
        delivery.push_channels_refresh,
        delivery.push_arrivals,
        delivery.jellyfin_discovery,
        scheduling.jobs,
        library.search_index,
        playback.storage_guard,
        playback.pgs_warm,
        library.skip_segments_recovery,
        playback.remote_workers,
        playback.transcode,
    )
)


def env_patches(settings: object) -> list[Patch]:
    """把环境变量开关映射成补丁层（诊断里显示 ``disabled_by``）。"""
    patches: list[Patch] = []
    if not getattr(settings, "scheduler_enabled", True):
        patches.append(Patch("scheduler", disabled=True, source="env:SCHEDULER_ENABLED"))
    return patches

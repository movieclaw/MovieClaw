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

import logging
from collections.abc import Sequence
from pathlib import Path

import yaml

from movieclaw_api.plugins import (
    agent,
    core,
    delivery,
    domains,
    events,
    library,
    notices,
    playback,
    scheduling,
)
from movieclaw_kernel import Entry, Patch

logger = logging.getLogger("movieclaw_api.plugins.manifest")

#: 内置插件按功能分组（设置 → 插件 → 内置）。按条目 id 匹配：``xxx.`` 是前缀，其余是整段名字
#: （自身或 ``名字.`` 开头的子条目）；先到先得。新增内置插件忘了归组，
#: tests/api/test_plugin_diagnostics.py 会失败。
BUILTIN_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("基础", ("core.", "jobs", "scheduler", "storage.", "app-update", "selfheal.")),
    (
        "资源站点与下载",
        ("tracker.", "downloads", "boost", "qbittorrent-downloader", "transmission-downloader"),
    ),
    ("订阅", ("subscription",)),
    ("媒体库", ("library.", "media.", "enrich.")),
    ("播放与字幕", ("playback.", "subtitle.", "jellyfin.")),
    (
        "通知与推送",
        (
            "channels.",
            "push.",
            "cloud",
            "weixin-channel",
            "telegram-channel",
            "discord-channel",
            "feishu-channel",
        ),
    ),
    ("AI 助手", ("agent.",)),
    ("插件系统", ("kernel.",)),
)


def builtin_group(entry_id: str) -> str | None:
    for label, patterns in BUILTIN_GROUPS:
        for pattern in patterns:
            if pattern.endswith("."):
                if entry_id.startswith(pattern):
                    return label
            elif entry_id == pattern or entry_id.startswith(f"{pattern}."):
                return label
    return None


#: 下载器适配插件（随带包 id 以此结尾）：要排在 ``downloads`` 等用到下载器的模块前面，
#: 否则启动那一刻（入库监控的首次扫描）找不到适配器
_DOWNLOADER_SUFFIX = "-downloader"


def with_bundled(bundled: Sequence[Entry]) -> tuple[Entry, ...]:
    """把随带插件包的内置条目插进清单：下载器适配插件插在 ``downloads`` 前面，其余插在通道中枢
    后面（微信通道原来的位置）。

    启动按清单顺序、停机反过来：放在末尾会让它们最先停，打乱「转码会话最先停」等停机约束。
    """
    downloaders = [e for e in bundled if e.id.endswith(_DOWNLOADER_SUFFIX)]
    others = [e for e in bundled if not e.id.endswith(_DOWNLOADER_SUFFIX)]
    entries = list(BUILTIN_MANIFEST)
    at = next(i for i, e in enumerate(entries) if e.id == "downloads")
    entries[at:at] = downloaders
    at = next(i for i, e in enumerate(entries) if e.id == "channels.hub") + 1
    return (*entries[:at], *others, *entries[at:])


#: 补丁文件（docs/design/plugin-kernel.md §10.3）：放在数据目录根下，随数据卷持久化
PATCH_FILE = "plugins.yaml"

BUILTIN_MANIFEST: tuple[Entry, ...] = tuple(
    Entry(p.name, p)
    for p in (
        core.database,
        core.registries,
        events.durable_events,
        events.host_ops,
        events.plugin_data,
        events.plugin_health,
        events.plugin_routes,
        events.plugin_callbacks,
        events.plugin_files,
        core.secrets,
        core.setting_store,
        notices.plugin_notices,
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
        delivery.channel_hub,
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


def load_patches(settings: object) -> list[Patch]:
    """补丁层：插件页停用的功能 + 环境变量开关 + ``data/plugins.yaml``。

    改 yaml / 环境变量需要重启生效；功能开关在运行中切换（services/plugin_features.py），
    这里只负责重启后保持。功能补丁排最前：同一插件被几处都关时，诊断显示管理员那一处。
    """
    from movieclaw_api.services.plugin_features import feature_patches

    return feature_patches(settings) + env_patches(settings) + file_patches(settings)


def patch_file(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data")) / PATCH_FILE


#: 补丁条目认识的字段：disabled 关掉一个条目；其余是本地受信插件的开启与批准（plugins/local.py）
_PATCH_FIELDS = frozenset(
    {"id", "disabled", "local", "module", "config", "grants", "act_as", "runtime", "paths"}
)


def read_patch_items(settings: object) -> list[dict]:
    """读 ``data/plugins.yaml`` 的条目：不存在即为空；格式不对只告警、整份忽略，不拦启动。"""
    path = patch_file(settings)
    if not path.is_file():
        return []
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        logger.warning("插件补丁文件 %s 读取失败，已忽略整份补丁：%s", path, exc)
        return []
    if data is None:
        return []
    if not isinstance(data, list):
        logger.warning("插件补丁文件 %s 须是列表（每项一个条目），已忽略整份补丁", path)
        return []
    items: list[dict] = []
    for index, item in enumerate(data):
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            logger.warning("插件补丁第 %d 项缺少 id，已跳过：%r", index + 1, item)
            continue
        items.append(item)
    return items


def file_patches(settings: object) -> list[Patch]:
    """``data/plugins.yaml`` 里的禁用补丁，例如::

        - id: jellyfin.discovery
          disabled: true

    只有允许禁用的插件能被禁用（关键插件永远不能），由内核在装载清单时检查。
    ``local`` / ``module`` / ``config`` / ``grants`` / ``act_as`` 是本地受信插件的字段，
    见 plugins/local.py。
    """
    patches: list[Patch] = []
    for item in read_patch_items(settings):
        unknown = set(item) - _PATCH_FIELDS
        if unknown:
            logger.warning(
                "插件补丁 %s 含不认识的字段 %s，已忽略这些字段", item["id"], sorted(unknown)
            )
        patches.append(Patch(item["id"], disabled=bool(item.get("disabled", False))))
    return patches


def env_patches(settings: object) -> list[Patch]:
    """把环境变量开关映射成补丁层（诊断里显示 ``disabled_by``）。"""
    patches: list[Patch] = []
    if not getattr(settings, "scheduler_enabled", True):
        patches.append(Patch("scheduler", disabled=True, source="env:SCHEDULER_ENABLED"))
    return patches

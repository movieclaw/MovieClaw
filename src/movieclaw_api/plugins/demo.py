"""公开演示站插件（docs/design/demo-site.md）。

只在 MOVIECLAW_DEMO_MODE 打开时做事；不是关键插件，失败不影响启动。
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from movieclaw_api.plugins.keys import DB, SETTING_STORE
from movieclaw_kernel import Context, plugin

logger = logging.getLogger("movieclaw_api.plugins.demo")


@plugin("core.demo-seed", title="演示站数据", inject=(DB, SETTING_STORE), reloadable=True)
async def demo_seed(ctx: Context) -> None:
    # 按今天重建订阅与观看数据（统计窗口相对当前时间，建站时造一次几天后就过期；
    # 每日还原会重启容器，于是每天都是新的，见 demo-site.md §6）
    if not ctx.settings.demo_mode:
        return
    from movieclaw_api.services.demo_activity import seed_demo_data

    try:
        await seed_demo_data()
    except Exception:
        logger.exception("演示站数据生成失败，活动页与订阅页会是空的，不影响启动")


@plugin("core.demo-site", title="演示资源站目录", reloadable=True)
async def demo_site(ctx: Context) -> None:
    # 按种子目录给演示资源站生成 .torrent 与目录清单（文件没变的跳过，首次约十几秒）
    if not ctx.settings.demo_mode:
        return
    from movieclaw_tracker.sites.custom.demo import build_catalog

    # 演示资源站与演示下载器在领域库里，不认识应用配置：按 data 目录补上默认位置
    data_dir = Path(ctx.settings.data_dir)
    os.environ.setdefault("MOVIECLAW_DEMO_SITE_DIR", str(data_dir / "demo-site"))
    os.environ.setdefault("MOVIECLAW_DEMO_DOWNLOADER_STATE", str(data_dir / "demo-downloader.json"))

    try:
        catalog = await asyncio.to_thread(build_catalog)
        logger.info("演示资源站目录就绪：%d 部影片", len(catalog))
    except Exception:
        logger.exception("演示资源站目录生成失败，站点资源搜索会是空的，不影响启动")

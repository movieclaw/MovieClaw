"""IM 推送的配图与测试推送。

推什么、推给谁不在这里：IM 是通知的一个渠道，和 App 推送一起由 ``services/push/notify``
按每个人在「账号 → 通知」的偏好发（services/push/im.py）。这里留下的是 IM 推送用到的
零件：

配图选横版剧照而非竖版海报:IM 客户端的图片气泡宽度随文案长短伸缩,
竖图会跟着缩放导致不同推送显示大小不一;横图天然顶满气泡最大宽度,
渲染规格恒定(Telegram 实测结论,2026-08)。取图优先本地母版,否则经 ImageCache
回源(复用图片代理的 SSRF 防护与代理出口);取图失败退纯文本——图可以丢,推送不能断。
微信 adapter 无发图能力,发送泵自动退回纯文本。

推送目标由各通道驱动给出(默认绑定人;群机器人是整个群),出站统一经各账号
dispatcher 的发送泵(顺序与限流集中一处),见 services/channel_hub.py。
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

logger = logging.getLogger("movieclaw_api.channel_push")


def tmdb_push_image_url(backdrop_path: str | None, poster_path: str | None) -> str | None:
    """推送配图 URL:优先横版剧照(w780,渲染规格恒定),无剧照回落海报(w500)。"""
    from movieclaw_api.services.network_egress import effective_tmdb_image_base_url
    from movieclaw_api.services.tmdb_images import remote_image_url

    base = effective_tmdb_image_base_url().rstrip("/")
    if backdrop_path:
        return remote_image_url(base, "w780", backdrop_path)
    if poster_path:
        return remote_image_url(base, "w500", poster_path)
    return None


async def push_to_all_channels(text: str, photo: bytes | None = None) -> int:
    """推送到所有通道账号（经通道中枢扇出），返回入队的账号数；中枢没运行时为 0。"""
    from movieclaw_api.services.channel_hub import get_hub

    hub = get_hub()
    if hub is None:
        return 0
    return await hub.push(text, photo=photo)


# 推送配图的统一宽度:手机通知大图约 360 点宽 × 3 倍屏
PUSH_IMAGE_WIDTH = 1280


async def local_push_image(image_url: str) -> Path | None:
    """推送配图优先用本地母版(docs/design/image-sizing.md §7):按地址里的 TMDB 路径反查条目,
    条目的背景 / 海报已落本地就用本地文件——TMDB 图床被墙或限流时推送照样带图。"""
    import re

    from sqlmodel import or_, select

    from movieclaw_api.services.media_scrape import resolve_asset_path
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import MediaItem, MediaMetadata

    match = re.search(r"/t/p/[a-z0-9]+(/[^/?#]+)$", image_url)
    if match is None:
        return None
    path = match.group(1)
    async with get_database().session() as session:
        row = (
            await session.execute(
                select(
                    MediaMetadata.backdrop_file,
                    MediaMetadata.poster_file,
                    MediaItem.backdrop_path,
                )
                .join(MediaItem, MediaItem.id == MediaMetadata.media_item_id)  # type: ignore[arg-type]
                .where(or_(MediaItem.backdrop_path == path, MediaItem.poster_path == path))
                .limit(1)
            )
        ).first()
    if row is None:
        return None
    backdrop_file, poster_file, backdrop_path = row
    rel = backdrop_file if backdrop_path == path else poster_file
    target = resolve_asset_path(rel) if rel else None
    return target if target is not None and target.is_file() else None


async def fetch_image(image_url: str) -> bytes | None:
    """取配图字节:本地母版优先(缩到推送宽度),否则经 ImageCache 回源。

    任何失败返回 None(推送退纯文本)。
    """
    try:
        from movieclaw_api.services.image_cache import get_image_cache
        from movieclaw_api.services.image_variants import (
            get_image_variant_service,
            local_source_version,
        )

        local = await local_push_image(image_url)
        if local is not None:
            cached = await get_image_variant_service().get_or_create(
                local,
                source_key=f"push:{local}",
                source_version=await asyncio.to_thread(local_source_version, local),
                width=PUSH_IMAGE_WIDTH,
            )
        else:
            cached = await get_image_cache().get_or_fetch(image_url)
        return await asyncio.to_thread(cached.path.read_bytes)
    except Exception:  # noqa: BLE001 -- 配图取不到只降级,不能拦住文本推送
        logger.info("推送配图获取失败,将发纯文本:%s", image_url)
        return None

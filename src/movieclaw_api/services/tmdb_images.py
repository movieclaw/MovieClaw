"""库内条目的 TMDB 图床兜底地址（docs/design/image-sizing.md §7）。

库内图片一律「条目目录图 → 本地母版 → 图床」，图床地址只在母版还没下好（刚入库、
下载失败）时才用。原先各接口各写一个档位（墙 w500、详情 w1280、「接着看」背景 w780、
剧照 w300……），兜底图与日后下好的母版清晰度不一，派生口径也乱。这里统一按**当前母版
档位**生成：客户端都带 ``w``，服务端从这张图现缩到需要的尺寸，与本地母版同一套规则。

未入库内容的预览（识别候选、订阅候选、发现页）不走这里：它们本来就只是远程小图。
"""

from __future__ import annotations

from typing import Literal

from movieclaw_media.fanart import is_absolute_image

ImageKind = Literal["poster", "backdrop", "still", "logo", "profile"]

# 片名 Logo 的资产档位固定取原图（见 media_scrape.LOGO_ASSET_SIZE）
_LOGO_SIZE = "original"


def tmdb_image_url(path: str | None, kind: ImageKind) -> str | None:
    """TMDB 图片路径 → 当前母版档位的图床地址（走设置页配的镜像）；没有路径返回 None。"""
    if not path:
        return None
    from movieclaw_api.services.network_egress import effective_tmdb_image_base_url
    from movieclaw_api.services.scrape_config import effective_asset_sizes, effective_profile_size

    if kind == "logo":
        size = _LOGO_SIZE
    elif kind == "profile":
        size = effective_profile_size()
    else:
        poster, backdrop, still = effective_asset_sizes()
        size = {"poster": poster, "backdrop": backdrop, "still": still}[kind]
    return remote_image_url(effective_tmdb_image_base_url().rstrip("/"), size, path)


def remote_image_url(base: str, size: str, path: str) -> str:
    """条目图片路径 → 远程地址。

    条目的 poster_path / backdrop_path / logo_path / 季 poster_path 有两种形态：
    TMDB 的相对路径（``/abc.jpg``，拼图床地址 + 档位）与 Fanart 的绝对地址
    （``https://assets.fanart.tv/...``，固定规格、原样使用，见
    docs/design/image-sources.md）。所有用条目路径拼地址的地方都走这里。
    """
    return path if is_absolute_image(path) else f"{base}/{size}{path}"


# 条目的本地图片资产：(海报, 背景, Logo) 的相对路径，没下好的是 None
MediaFiles = tuple[str | None, str | None, str | None]


def asset_url(rel: str) -> str:
    """本地资产相对路径 → 接口给的地址（带 mtime 版本，换图即换 URL）。"""
    from movieclaw_api.services.media_scrape import asset_version

    return f"/images/assets/{rel}?v={asset_version(rel)}"


async def local_media_files(session, item_ids) -> dict[int, MediaFiles]:  # noqa: ANN001
    """批量取条目的本地图片资产（订阅卡片、「刚刚入库」这类列表一次查完，不逐条查）。"""
    from sqlmodel import select

    from movieclaw_db.models import MediaMetadata

    ids = [i for i in item_ids if i is not None]
    if not ids:
        return {}
    rows = await session.execute(
        select(
            MediaMetadata.media_item_id,
            MediaMetadata.poster_file,
            MediaMetadata.backdrop_file,
            MediaMetadata.logo_file,
        ).where(MediaMetadata.media_item_id.in_(ids))  # type: ignore[attr-defined]
    )
    return {int(item_id): (poster, backdrop, logo) for item_id, poster, backdrop, logo in rows}


def item_poster_url(poster_path: str | None, poster_file: str | None) -> str | None:
    """库内条目的海报地址：本地母版优先（断网可用），没下好才是图床兜底。"""
    return asset_url(poster_file) if poster_file else tmdb_image_url(poster_path, "poster")

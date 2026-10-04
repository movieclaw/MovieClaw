"""海报行「选中展开」的展示信息（电视首页，同 Netflix 电视版的焦点卡）。

焦点停在一张海报上时，它展开成横版剧照卡（左下角片名 Logo），行下面写
「电影 · 剧情 · 2006 · 1 小时 49 分钟 · PG-13」与两行简介。这些字段海报墙列表
不带（墙上用不着，带上就是几千格的冗余），也不该逐张去拉详情——详情带全部
文件清单，一部剧上百集。所以由客户端拿一行的条目 id 整批取一次。

可见性与单条目接口同一套口径（``access.assert_item_visible``）：条目至少有一份
台账落在可浏览库里（没台账的按刮削归属库判），且在观看者的分级约束之内。
批量接口不逐个 404——看不见的直接略过，结果里没有它就是没有。
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.library import LibraryItemShowcaseView
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import content_limit_for, visible_library_ids
from movieclaw_api.services.media_scrape import asset_version
from movieclaw_db.models.library_file import LibraryFile
from movieclaw_db.models.media_item import MediaItem
from movieclaw_db.models.media_metadata import MediaMetadata

#: 一次最多取多少部：首页一行 20 部，留出余量；再多就是拿它当全库导出了
MAX_SHOWCASE_IDS = 60


def _asset_or_tmdb(asset_file: str | None, tmdb_path: str | None, size: str) -> str | None:
    """本地资产优先（带版本号，原地换图自动失效），没下载到就退回 TMDB 图床。"""
    if asset_file:
        return f"/images/assets/{asset_file}?v={asset_version(asset_file)}"
    if tmdb_path:
        base = get_settings().tmdb_image_base_url.rstrip("/")
        return f"{base}/{size}{tmdb_path}"
    return None


async def load_showcase(
    session: AsyncSession, principal: Principal, ids: list[int]
) -> list[LibraryItemShowcaseView]:
    """按传入顺序返回这些条目的展示信息；不存在或看不见的略过。"""
    wanted = list(dict.fromkeys(i for i in ids if i > 0))[:MAX_SHOWCASE_IDS]
    # 分享访客只看分享出去的那一部，用不着首页；一律不给，免得这里再抄一遍分享范围判定
    if not wanted or principal.share is not None:
        return []

    owners: dict[int, set[int]] = {}
    for item_id, library_id in (
        await session.execute(
            select(LibraryFile.media_item_id, LibraryFile.library_id)  # type: ignore[call-overload]
            .where(
                LibraryFile.media_item_id.in_(wanted),  # type: ignore[union-attr]
                LibraryFile.library_id.is_not(None),  # type: ignore[union-attr]
            )
            .distinct()
        )
    ).all():
        owners.setdefault(int(item_id), set()).add(int(library_id))

    rows = (
        await session.execute(
            select(
                MediaItem,
                MediaMetadata.backdrop_file,
                MediaMetadata.logo_file,
                MediaMetadata.overview,
                MediaMetadata.genres,
                MediaMetadata.runtime_minutes,
                MediaMetadata.content_rating,
            )
            .outerjoin(MediaMetadata, MediaMetadata.media_item_id == MediaItem.id)
            .where(MediaItem.id.in_(wanted))  # type: ignore[attr-defined]
        )
    ).all()

    visible = await visible_library_ids(session, principal)
    limit = await content_limit_for(session, principal)
    by_id: dict[int, LibraryItemShowcaseView] = {}
    for item, backdrop_file, logo_file, overview, genres, runtime, rating in rows:
        if item.id is None:
            continue
        libraries = owners.get(item.id) or (
            {item.scrape_library_id} if item.scrape_library_id is not None else set()
        )
        # 同 assert_item_visible：没台账、也没刮削归属库的条目不属于任何库，不受库可见范围约束
        if libraries and libraries.isdisjoint(visible):
            continue
        if not limit.allows(rating):
            continue
        by_id[item.id] = LibraryItemShowcaseView(
            media_item_id=item.id,
            backdrop_url=_asset_or_tmdb(backdrop_file, item.backdrop_path, "w1280"),
            # logo_path 为空串 = TMDB 确认没有合适的 Logo，同样按没有处理
            logo_url=_asset_or_tmdb(logo_file, item.logo_path or None, "w500"),
            overview=(overview or "").strip() or None,
            genres=[str(genre) for genre in genres or []],
            runtime_minutes=runtime,
            content_rating=rating or None,
        )
    return [by_id[i] for i in wanted if i in by_id]

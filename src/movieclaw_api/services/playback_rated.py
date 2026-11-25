"""媒体库首页「我的高分作品」的业务查询（docs/design/user-rating.md）。

形状与 ``playback_favorites.py`` 对齐：数据源是 ``playback_state.user_rating`` /
``rated_at``（按成员隔离，只认当前账号可见库内且仍有在位文件的作品），卡片本体复用
单库海报墙聚合视图 ``_aggregate_wall_views``。
"""

from __future__ import annotations

from typing import Literal

from sqlalchemy import nullslast
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.schemas.playback import RatedItemView
from movieclaw_api.services.library.items import (
    WallOrder,
    _aggregate_wall_views,
    _item_sentinel_cond,
    favorite_item_ids,
    landing_library_of,
    sort_item_ids,
)
from movieclaw_db.models import LibraryFile, MediaItem, PlaybackState

#: 「我的高分作品」默认最低门槛：8 = 4 星及以上
DEFAULT_MIN_RATING = 8

#: 「我的高分作品」可选排序档：默认 ``my_rating``（我的评分倒序，同分按 ``rated_at`` 倒序），
#: 另提供 ``rated_at``（最近评分在前）以及与单库海报墙对齐的其余档位。
RatedSort = Literal[
    "my_rating",
    "rated_at",
    "title",
    "added_at",
    "release_date",
    "rating",
    "runtime",
    "size",
    "last_played",
]


async def _rated_page(
    session: AsyncSession,
    *,
    member_id: int,
    visible_library_ids: set[int] | None,
    min_rating: int,
    limit: int,
    offset: int,
    sort: RatedSort = "my_rating",
    order: WallOrder | None = None,
) -> tuple[list[tuple[int, int]], int, dict[int, PlaybackState]]:
    """当前成员满足 ``user_rating >= min_rating`` 且在可见库有在位文件的作品分页名单。

    - 只读条目级哨兵行（电影 ``(0,0)``、整剧 ``(-1,-1)``），与 ``item_favorite_unit`` 同源，
      保证一部作品只出现一次；
    - 默认排序（``sort="my_rating"``）：``user_rating DESC`` → ``rated_at DESC NULLS LAST``
      → ``media_item_id DESC``；``order="asc"`` 时同步翻转并保持 ``NULLS LAST``，在 SQLite
      与 PostgreSQL 上顺序完全一致。
    """
    if visible_library_ids == set():
        return [], 0, {}

    ascending = order == "asc"
    if sort == "rated_at":
        order_clauses = (
            (
                nullslast(PlaybackState.rated_at.asc()),  # type: ignore[union-attr]
                PlaybackState.user_rating.asc(),  # type: ignore[union-attr]
                PlaybackState.media_item_id.asc(),  # type: ignore[union-attr]
            )
            if ascending
            else (
                nullslast(PlaybackState.rated_at.desc()),  # type: ignore[union-attr]
                PlaybackState.user_rating.desc(),  # type: ignore[union-attr]
                PlaybackState.media_item_id.desc(),  # type: ignore[union-attr]
            )
        )
    else:
        order_clauses = (
            (
                PlaybackState.user_rating.asc(),  # type: ignore[union-attr]
                nullslast(PlaybackState.rated_at.asc()),  # type: ignore[union-attr]
                PlaybackState.media_item_id.asc(),  # type: ignore[union-attr]
            )
            if ascending
            else (
                PlaybackState.user_rating.desc(),  # type: ignore[union-attr]
                nullslast(PlaybackState.rated_at.desc()),  # type: ignore[union-attr]
                PlaybackState.media_item_id.desc(),  # type: ignore[union-attr]
            )
        )

    rows = (
        (
            await session.execute(
                select(PlaybackState)
                .join(MediaItem, MediaItem.id == PlaybackState.media_item_id)  # type: ignore[arg-type]
                .where(
                    PlaybackState.member_id == member_id,
                    PlaybackState.user_rating.is_not(None),  # type: ignore[union-attr]
                    PlaybackState.user_rating >= min_rating,  # type: ignore[operator]
                    _item_sentinel_cond(),
                )
                .order_by(*order_clauses)
            )
        )
        .scalars()
        .all()
    )
    by_item: dict[int, PlaybackState] = {}
    for row in rows:
        by_item.setdefault(row.media_item_id, row)
    if not by_item:
        return [], 0, {}

    library_of = await landing_library_of(
        session, list(by_item), library_ids=visible_library_ids, files=LibraryFile.in_place()
    )
    ordered = [item_id for item_id in by_item if item_id in library_of]
    if sort not in ("my_rating", "rated_at"):
        ordered = await sort_item_ids(
            session, ordered, sort, order, member_id=member_id, library_ids=visible_library_ids
        )
    total = len(ordered)
    page = [(item_id, library_of[item_id]) for item_id in ordered[offset : offset + limit]]
    return page, total, by_item


async def rated_items(
    session: AsyncSession,
    *,
    member_id: int,
    visible_library_ids: set[int] | None,
    min_rating: int = DEFAULT_MIN_RATING,
    limit: int = 20,
    offset: int = 0,
    sort: RatedSort = "my_rating",
    order: WallOrder | None = None,
    badges: frozenset[str] = frozenset(),
) -> tuple[list[RatedItemView], int]:
    """返回当前成员满足最低分门槛的高分作品与去重后的总数。

    ``user_rating`` 与 ``rated_at`` 直接复用 ``_rated_page`` 已取回的 ``PlaybackState`` 行，
    不额外查询；同时向 ``_aggregate_wall_views`` 剔除 ``my_rating`` 避免重复查表。
    """
    page, total, by_item = await _rated_page(
        session,
        member_id=member_id,
        visible_library_ids=visible_library_ids,
        min_rating=min_rating,
        limit=limit,
        offset=offset,
        sort=sort,
        order=order,
    )
    if not page:
        return [], total

    ids = [item_id for item_id, _library_id in page]
    views = {
        view.media_item_id: view
        for view in await _aggregate_wall_views(
            session,
            None,
            ids,
            ids,
            landing_pairs=list(page),
            member_id=member_id,
            badges=badges - {"my_rating"},
        )
    }
    favorites = await favorite_item_ids(session, ids, member_id=member_id)

    result: list[RatedItemView] = []
    for item_id, _landing_library_id in page:
        view = views.get(item_id)
        if view is None:
            continue
        state = by_item[item_id]
        result.append(
            RatedItemView(
                **view.model_dump(exclude={"is_favorite", "user_rating"}),
                is_favorite=item_id in favorites,
                user_rating=state.user_rating,
                rated_at=state.rated_at,
            )
        )
    return result, total

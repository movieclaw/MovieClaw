"""刷片筛选菜单：各维度的候选值与计数（docs/design/reels.md §4）。

**与媒体库筛选同一套口径**：维度、取值、收窄都用 ``LibraryFilter`` 与媒体库唯一的
收窄点 ``_narrow``（docs/design/library-filtering.md）。这里只换了「数谁」——媒体库数
一个库的海报墙，刷片数本人可见、能抽的电影库与剧集库（``_playable_file_filter``）。
「菜单上写几部、点下去刷的就是这几部」因此是结构保证的：计数与 ``GET /reels`` 的抽样池
是同一个 WHERE。

每一维的计数都排除本维自身的条件（``skip``）：否则勾了「动画」之后其他类型全变 0，
多选就废了。年代、评分、片长、观看这类人定的档位逐档带「本档条件」数一次（``_narrow``
的探针），不在这里重写一遍档位的判定。

二十来条 COUNT 每条 25～40 ms，串行要一秒多；各用独立会话限 ``FACET_CONCURRENCY`` 路并发
（SQLite WAL 下读可以并行），NAS 实测 19 条串行 0.57 秒、4 路 0.29 秒、6 路反而 0.4 秒。

取值文案按发现页的写法（「8 分以上」「90 分钟以内」），与发现页菜单读起来是一套东西。
"""

from __future__ import annotations

import asyncio
from typing import Any

from sqlalchemy import func, select, true
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.i18n import t
from movieclaw_api.i18n.media_labels import country_label, genre_label
from movieclaw_api.schemas.library import FacetValueView
from movieclaw_api.schemas.reels import ReelFacetsView
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import content_limit_for
from movieclaw_api.services.library.items import LibraryFilter, _narrow
from movieclaw_api.services.reels.feed import (
    _playable_file_filter,
    _playable_library_kinds,
    only_kind,
    pool_libraries,
    watch_only,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile, MediaMetadata
from movieclaw_media.genres import MOVIE_GENRES

#: 计数查询同时跑几路（见模块注释的实测）
FACET_CONCURRENCY = 4

# 档位名是消息键，出响应时按读者语言渲染
_KINDS = (("movie", "media.kind.movie"), ("tv", "media.kind.tv"))
#: 「其他」单列：它是独立的池（不混进默认），且没有 TMDB 档案，计数口径与电影 / 剧集不同
_OTHER = ("video", "library.reels.other")
_DECADES = (
    ("2020s", "library.reels.decade2020s"),
    ("2010s", "library.reels.decade2010s"),
    ("2000s", "library.reels.decade2000s"),
    ("1990s", "library.reels.decade1990s"),
    ("earlier", "library.facets.earlier"),
)
_RATINGS = (9, 8, 7, 6)
_RUNTIMES = (
    ("lte60", "library.reels.runtimeLte60"),
    ("60to90", "library.reels.runtime60to90"),
    ("90to120", "library.reels.runtime90to120"),
    ("gt120", "library.reels.runtimeGt120"),
)


def _genre_label(genre_id: int) -> str:
    """刷片里电影、剧集混着抽，两套 TMDB 类型表都认（同一个 id 两边叫法相同）。"""
    if genre_id in MOVIE_GENRES:
        return genre_label("movie", genre_id)
    return genre_label("tv", genre_id)


async def build_reel_facets(
    session: AsyncSession,
    principal: Principal,
    filters: LibraryFilter | None,
    kind: str | None,
) -> ReelFacetsView:
    """当前条件下，菜单每一维各取值还剩几部。"""
    libraries = await _playable_library_kinds(session, principal)
    if not libraries:
        return ReelFacetsView(total=0)
    content_limit = await content_limit_for(session, principal)
    member_id = principal.member_id if principal.member_id is not None else 0
    # 抽样池与 GET /reels 同一个函数定，「其他」池的回落规则不会两边各写一遍
    pool = await pool_libraries(session, principal, kind)
    effective = watch_only(filters) if pool.video else filters

    def scope(
        skip: str | None = None,
        libs: dict[int, str] = pool.libraries,
        flt: LibraryFilter | None = effective,
    ) -> tuple[Any, ...]:
        """与抽样池同一个 WHERE：可抽的文件 + 筛选（排除 skip 这一维）+ 分级约束。"""
        return (
            *_playable_file_filter(list(libs)),
            *_narrow(flt, member_id, skip=skip, content_limit=content_limit),
        )

    def kind_scope(value: str) -> tuple[Any, ...]:
        """「电影 / 剧集 / 其他」各自的计数口径。

        电影 / 剧集带着当前的全部筛选；「其他」只带观看状态——点它就会清掉别的条件，
        按当前条件数，用户勾了「动作」之后它会显示 0 并置灰，点不进去。
        """
        libs = only_kind(libraries, value)
        return scope(libs=libs, flt=watch_only(filters) if value == "video" else effective)

    gate = asyncio.Semaphore(FACET_CONCURRENCY)

    async def fetch(stmt: Any) -> list[Any]:
        """每条查询用独立会话：同一个会话里的查询只能一条一条排队。"""
        async with gate, get_database().session() as own:
            return list((await own.execute(stmt)).all())

    async def count(*where: Any) -> int:
        stmt = select(func.count(func.distinct(LibraryFile.media_item_id))).where(*where)
        return int((await fetch(stmt))[0][0])

    async def probe(skip: str, value: str, label: str, one: LibraryFilter) -> FacetValueView:
        """一个档位：其他维度的条件都算上，再带上「本档条件」数一次。"""
        return FacetValueView(
            value=value, label=label, count=await count(*scope(skip), *_narrow(one, member_id))
        )

    async def spread(column: Any, skip: str, selected: tuple) -> list[tuple[str, int]]:
        """JSON 数组列（类型、地区）的取值分布；勾着的值数不到也补一条 0，免得取消不掉。"""
        # 先按条目去重再展开（同 library/items.py 的 _json_facet）：不然每个分集文件都展开一遍
        items = select(LibraryFile.media_item_id).where(*scope(skip)).distinct().subquery()
        each = func.json_each(column).table_valued("value")
        rows = await fetch(
            select(each.c.value, func.count(func.distinct(items.c.media_item_id)))
            .select_from(items)
            .join(MediaMetadata, MediaMetadata.media_item_id == items.c.media_item_id)  # type: ignore[arg-type]
            .join(each, true())
            .group_by(each.c.value)
        )
        counts = [(str(v), int(c)) for v, c in rows if v is not None]
        present = {v for v, _ in counts}
        counts += [(str(v), 0) for v in selected if str(v) not in present]
        return sorted(counts, key=lambda r: (-r[1], r[0]))

    async def nothing() -> list[Any]:
        return []

    selected = filters or LibraryFilter()
    # 「其他」池没有 TMDB 档案：这几维不查（查也是全 0），App 见 filterable=False 收起对应菜单
    rich = not pool.video
    kind_values = (*_KINDS, _OTHER)
    (total, kinds, genres, countries, decades, ratings, runtimes, watch) = await asyncio.gather(
        count(*scope()),
        asyncio.gather(*(count(*kind_scope(value)) for value, _ in kind_values)),
        spread(MediaMetadata.genre_ids, "genres", selected.genres) if rich else nothing(),
        spread(MediaMetadata.origin_countries, "countries", selected.countries)
        if rich
        else nothing(),
        asyncio.gather(
            *(probe("decades", v, t(key), LibraryFilter(decades=(v,))) for v, key in _DECADES)
        )
        if rich
        else nothing(),
        asyncio.gather(
            *(
                probe(
                    "rating_gte",
                    str(v),
                    t("library.reels.ratingAtLeast", rating=v),
                    LibraryFilter(rating_gte=v),
                )
                for v in _RATINGS
            )
        )
        if rich
        else nothing(),
        asyncio.gather(
            *(probe("runtimes", v, t(key), LibraryFilter(runtimes=(v,))) for v, key in _RUNTIMES)
        )
        if rich
        else nothing(),
        probe(
            "watch", "unwatched", t("library.facets.unwatched"), LibraryFilter(watch="unwatched")
        ),
    )
    other_count = kinds[-1]
    # 只有「其他」库的用户没有可切换的类型，整行不给；「其他」没有可刷的文件时也不给这一项
    # （选着的除外，得能取消）
    shown = [
        FacetValueView(value=value, label=t(key), count=n)
        for (value, key), n in zip(_KINDS, kinds[:-1], strict=True)
    ]
    if other_count > 0 or kind == _OTHER[0]:
        shown.append(FacetValueView(value=_OTHER[0], label=t(_OTHER[1]), count=other_count))
    return ReelFacetsView(
        total=total,
        filterable=rich,
        kinds=shown if pool.film_available else [],
        genres=[
            FacetValueView(value=v, label=_genre_label(int(v)) if v.isdigit() else v, count=c)
            for v, c in genres
        ],
        countries=[FacetValueView(value=v, label=country_label(v), count=c) for v, c in countries],
        decades=list(decades),
        ratings=list(ratings),
        runtimes=list(runtimes),
        watch=[watch],
    )

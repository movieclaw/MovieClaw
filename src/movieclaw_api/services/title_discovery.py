"""影视发现领域编排：统一 TMDB/豆瓣的片单、搜索、引用与详情。

底层两个 provider 仍保留各自的缓存、限流和数据转换实现；本服务只收口公开
能力边界：

- 片单统一用 ``collection_ref`` 定位；
- 影视条目统一用 ``title_ref`` 定位；
- 多来源搜索并发执行，单边失败不丢弃另一边结果；
- 旧的 Hero/行模型在这里转换为新的领域模型，不再泄漏到公开 API。

稳定引用的目的不是把业务塞进字符串，而是让调用方把上一步结果原样交给
下一步，避免模型或前端猜测数字 ID 属于哪家、电影还是剧集。
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from dataclasses import dataclass

from movieclaw_api.schemas.discover import (
    DiscoveredPersonDetailsView,
    DiscoveredTitleCollectionView,
    DiscoveredTitleDetailsView,
    DiscoveredTitleMetadata,
    DiscoveredTitleView,
    DiscoveryCollectionTitlesView,
    DiscoveryCollectionView,
    DiscoveryFilterOptionsView,
    DiscoveryGenreView,
    DiscoveryProviderSelection,
    DiscoverySort,
    DiscoveryTitlePageView,
    TitleSearchProviderStatus,
)
from movieclaw_api.services.discover_library import DiscoverLibraryProjectionService
from movieclaw_media import (
    DoubanDiscoverService,
    DoubanError,
    MediaCard,
    MediaDetail,
    MediaDiscoverService,
    MediaKind,
    MediaSearchItem,
    MediaSource,
    TmdbError,
)

_TMDB_FEATURED_ID = "featured-weekly"
_TMDB_FEATURED_LIMIT = 6
_DOUBAN_FULL_LIMITS = {
    "movie_top250": 250,
    "movie_high_score": 500,
}


@dataclass(frozen=True)
class TitleSearchOutcome:
    """统一搜索的领域结果；raw_items 供搜索历史继续复用既有快照结构。"""

    raw_items: list[MediaSearchItem]
    titles: list[DiscoveredTitleView]
    providers: list[TitleSearchProviderStatus]


class TitleDiscoveryService:
    """面向 API/CLI 的影视发现服务。

    provider 以工厂而非实例注入，确保只浏览豆瓣时不会因为 TMDB 未配置而
    失败；也方便测试精确替换单个来源。工厂返回的底层服务由现有装配层维护
    为进程级单例，本类自身无连接和缓存生命周期。
    """

    def __init__(
        self,
        tmdb_factory: Callable[[], MediaDiscoverService],
        douban_factory: Callable[[], DoubanDiscoverService],
    ) -> None:
        self._tmdb_factory = tmdb_factory
        self._douban_factory = douban_factory

    def list_collections(
        self, media_type: MediaKind, provider: MediaSource
    ) -> list[DiscoveryCollectionView]:
        """列出来源可浏览的片单，顺序就是发现页的产品编排顺序。"""
        service = self._provider(provider)
        layout = service.layout(media_type)
        collections: list[DiscoveryCollectionView] = []
        if provider is MediaSource.TMDB:
            collections.append(
                DiscoveryCollectionView(
                    collection_ref=make_collection_ref(provider, media_type, _TMDB_FEATURED_ID),
                    provider=provider,
                    media_type=media_type,
                    name="本周精选",
                    description="本周趋势中有宽幅剧照和中文简介的精选条目",
                    default_limit=_TMDB_FEATURED_LIMIT,
                )
            )
        for row in layout.rows:
            collection_id = _provider_collection_id(provider, row.id)
            full_limit = _DOUBAN_FULL_LIMITS.get(collection_id)
            collections.append(
                DiscoveryCollectionView(
                    collection_ref=make_collection_ref(provider, media_type, collection_id),
                    provider=provider,
                    media_type=media_type,
                    name=row.title,
                    is_ranked=row.ranked,
                    default_limit=30 if provider is MediaSource.DOUBAN else 20,
                    supports_full_listing=(
                        provider is MediaSource.TMDB or full_limit is not None
                    ),
                )
            )
        return collections

    async def browse_collection(
        self,
        collection_ref: str,
        *,
        limit: int,
        page: int = 1,
        projection: DiscoverLibraryProjectionService | None = None,
    ) -> DiscoveryCollectionTitlesView:
        """读取一个片单；白名单校验由 ``list_collections`` 的事实集合完成。"""
        provider, media_type, collection_id = parse_collection_ref(collection_ref)
        descriptor = next(
            (
                item
                for item in self.list_collections(media_type, provider)
                if item.collection_ref == collection_ref
            ),
            None,
        )
        if descriptor is None:
            raise LookupError("该片单不存在或当前来源未开放浏览")

        service = self._provider(provider)
        total_pages = 1
        total_results = 0
        current_page = 1
        if provider is MediaSource.TMDB:
            if collection_id == _TMDB_FEATURED_ID:
                cards = await service.discover_hero(media_type)
                total_results = len(cards)
            else:
                # 旧测试桩与第三方内嵌调用可能只实现 discover_row；生产服务优先
                # 使用 discover_page，兼容分支保持原单页语义且不会伪造后续页。
                discover_page = getattr(service, "discover_page", None)
                if discover_page is not None:
                    result_page = await discover_page(media_type, collection_id, page)
                    if result_page is None:
                        raise LookupError("该片单不存在或当前来源未开放浏览")
                    cards = result_page.items
                    current_page = result_page.page
                    total_pages = result_page.total_pages
                    total_results = result_page.total_results
                else:
                    row = await service.discover_row(media_type, collection_id)
                    if row is None:
                        raise LookupError("该片单不存在或当前来源未开放浏览")
                    cards = row.items
                    total_results = len(cards)
        else:
            full_limit = _DOUBAN_FULL_LIMITS.get(collection_id)
            if full_limit is not None and limit > descriptor.default_limit:
                row = await service.full_collection(collection_id)
            else:
                row = await service.discover_row(media_type, f"douban-{collection_id}")
                if row is None:
                    raise LookupError("该片单不存在或当前来源未开放浏览")
            cards = row.items
            total_results = len(cards)

        truncated = len(cards) > limit
        selected = cards[:limit]
        if projection is not None:
            await projection.apply_cards(selected)
        return DiscoveryCollectionTitlesView(
            collection=descriptor,
            titles=[title_from_card(card, provider=provider) for card in selected],
            returned_count=len(selected),
            truncated=truncated,
            page=current_page,
            total_pages=total_pages,
            total_results=total_results,
            has_more=current_page < total_pages,
        )

    async def filter_options(self, media_type: MediaKind) -> DiscoveryFilterOptionsView:
        """返回 TMDB 的本地化类型清单；其余筛选值由稳定枚举或数值范围表达。"""
        genres = await self._tmdb_factory().discovery_genres(media_type)
        return DiscoveryFilterOptionsView(
            media_type=media_type,
            genres=[
                DiscoveryGenreView(id=genre_id, name=name)
                for genre_id, name in genres.items()
            ],
        )

    async def discover_titles(
        self,
        media_type: MediaKind,
        *,
        genre_ids: list[int] | None = None,
        origin_country: str | None = None,
        year: int | None = None,
        rating_gte: float | None = None,
        runtime_lte: int | None = None,
        sort: DiscoverySort = DiscoverySort.POPULAR,
        page: int = 1,
        projection: DiscoverLibraryProjectionService | None = None,
    ) -> DiscoveryTitlePageView:
        """执行组合筛选，并在返回前补齐当前主体可见的本地库存状态。"""
        result = await self._tmdb_factory().discover_filtered(
            media_type,
            genre_ids=genre_ids,
            origin_country=origin_country,
            year=year,
            rating_gte=rating_gte,
            runtime_lte=runtime_lte,
            sort=sort.value,
            page=page,
        )
        if projection is not None:
            await projection.apply_cards(result.items)
        return DiscoveryTitlePageView(
            media_type=media_type,
            titles=[title_from_card(card) for card in result.items],
            page=result.page,
            total_pages=result.total_pages,
            total_results=result.total_results,
            has_more=result.page < result.total_pages,
        )

    async def search_titles(
        self, query: str, provider: DiscoveryProviderSelection
    ) -> TitleSearchOutcome:
        """搜索一个或两个来源；全部失败才抛错，单边失败进入结构化状态。"""
        selected = (
            [MediaSource.DOUBAN, MediaSource.TMDB]
            if provider is DiscoveryProviderSelection.ALL
            else [MediaSource(provider.value)]
        )

        async def run(source: MediaSource):
            try:
                return source, await self._provider(source).search(query), None
            except (TmdbError, DoubanError) as exc:
                return source, [], exc

        results = await asyncio.gather(*(run(source) for source in selected))
        raw_items: list[MediaSearchItem] = []
        titles: list[DiscoveredTitleView] = []
        statuses: list[TitleSearchProviderStatus] = []
        errors: list[TmdbError | DoubanError] = []
        for source, items, error in results:
            if error is not None:
                errors.append(error)
                statuses.append(
                    TitleSearchProviderStatus(
                        provider=source,
                        success=False,
                        message=str(error),
                    )
                )
                continue
            raw_items.extend(items)
            titles.extend(title_from_search_item(item) for item in items)
            statuses.append(
                TitleSearchProviderStatus(
                    provider=source,
                    success=True,
                    result_count=len(items),
                )
            )
        if errors and len(errors) == len(selected):
            raise errors[0]
        return TitleSearchOutcome(raw_items=raw_items, titles=titles, providers=statuses)

    async def get_title_details(
        self,
        title_ref: str,
        *,
        projection: DiscoverLibraryProjectionService | None = None,
    ) -> DiscoveredTitleDetailsView:
        """按稳定引用读取详情，并把两个来源转换为同一公开结构。"""
        provider, media_type, external_id = parse_title_ref(title_ref)
        service = self._provider(provider)
        if provider is MediaSource.TMDB:
            assert media_type is not None  # parse_title_ref 已校验
            detail = await service.media_detail(media_type, int(external_id))
        else:
            detail = await service.media_detail(external_id)
        if projection is not None:
            await projection.apply_detail(detail)
        return title_details_from_legacy(detail, provider=provider)

    async def get_person_details(
        self,
        tmdb_person_id: int,
        *,
        projection: DiscoverLibraryProjectionService | None = None,
    ) -> DiscoveredPersonDetailsView:
        """读取 TMDB 影人的完整影视履历，并按当前主体可见库补齐库存状态。"""
        detail = await self._tmdb_factory().person_detail(tmdb_person_id)
        if projection is not None:
            await projection.apply_cards(detail.credits)
        return DiscoveredPersonDetailsView(
            tmdb_person_id=detail.tmdb_person_id,
            name=detail.name,
            avatar_url=detail.avatar_url,
            titles=[title_from_card(card) for card in detail.credits],
        )

    def _provider(
        self, provider: MediaSource
    ) -> MediaDiscoverService | DoubanDiscoverService:
        return self._tmdb_factory() if provider is MediaSource.TMDB else self._douban_factory()


def make_collection_ref(provider: MediaSource, media_type: MediaKind, collection_id: str) -> str:
    """构造片单稳定引用；collection_id 由服务端白名单产生，不接受冒号。"""
    return f"{provider.value}:{media_type.value}:{collection_id}"


def parse_collection_ref(value: str) -> tuple[MediaSource, MediaKind, str]:
    """解析 ``provider:media_type:collection_id``，错误信息直接面向 API 用户。"""
    parts = value.split(":", 2)
    if len(parts) != 3 or not parts[2]:
        raise ValueError(
            "collection_ref 格式无效；请使用 list-collections 返回的引用原样调用"
        )
    try:
        return MediaSource(parts[0]), MediaKind(parts[1]), parts[2]
    except ValueError:
        raise ValueError(
            "collection_ref 格式无效；请使用 list-collections 返回的引用原样调用"
        ) from None


def make_title_ref(provider: MediaSource, external_id: str, media_type: MediaKind | None) -> str:
    """构造影视条目稳定引用；TMDB 的电影/剧集号段独立，必须携带类型。"""
    if provider is MediaSource.TMDB:
        if media_type is None:
            raise ValueError("TMDB 条目缺少 movie/tv 类型，无法构造 title_ref")
        return f"tmdb:{media_type.value}:{external_id}"
    return f"douban:{external_id}"


def parse_title_ref(value: str) -> tuple[MediaSource, MediaKind | None, str]:
    """解析 TMDB 三段式或豆瓣两段式 title_ref。"""
    parts = value.split(":")
    try:
        if len(parts) == 3 and parts[0] == MediaSource.TMDB.value and parts[2].isdigit():
            return MediaSource.TMDB, MediaKind(parts[1]), parts[2]
        if len(parts) == 2 and parts[0] == MediaSource.DOUBAN.value and parts[1]:
            return MediaSource.DOUBAN, None, parts[1]
    except ValueError:
        pass
    raise ValueError("title_ref 格式无效；请使用搜索或片单接口返回的引用原样调用")


def title_from_card(card: MediaCard, *, provider: MediaSource | None = None) -> DiscoveredTitleView:
    """旧卡片模型转换为公开摘要；provider override 用于防御来源桩数据不完整。"""
    source = provider or card.source
    return DiscoveredTitleView(
        title_ref=make_title_ref(source, card.id, card.type),
        provider=source,
        external_id=card.id,
        media_type=card.type,
        title=card.title,
        original_title=card.original_title,
        release_year=card.year or None,
        provider_rating=card.rating,
        genres=card.genres,
        extent_label=card.extent,
        overview=card.overview,
        poster_url=card.poster_url,
        backdrop_url=card.backdrop_url,
        library_status=card.library_status,
    )


def title_from_search_item(item: MediaSearchItem) -> DiscoveredTitleView:
    """轻量搜索结果转换；豆瓣缺失的类型/年份保持为空，不做猜测。"""
    return DiscoveredTitleView(
        title_ref=make_title_ref(item.source, item.id, item.type),
        provider=item.source,
        external_id=item.id,
        media_type=item.type,
        title=item.title,
        release_year=item.year,
        provider_rating=item.rating,
        poster_url=item.poster_url,
    )


def title_details_from_legacy(
    detail: MediaDetail, *, provider: MediaSource
) -> DiscoveredTitleDetailsView:
    """旧详情模型转换为语义化公开契约。"""
    facts = detail.facts
    return DiscoveredTitleDetailsView(
        title=title_from_card(detail.card, provider=provider),
        metadata=DiscoveredTitleMetadata(
            directors=facts.directors,
            director_credits=facts.director_credits,
            cast=facts.cast,
            country=facts.country,
            language=facts.language,
            released=facts.released,
            network=facts.network,
            aliases=facts.aliases,
            source_url=facts.source_url,
            english_title=facts.english_title,
        ),
        backdrop_original_url=detail.backdrop_url,
        videos=detail.videos,
        backdrops=detail.backdrops,
        posters=detail.posters,
        collection=(
            DiscoveredTitleCollectionView(
                id=detail.collection.id,
                name=detail.collection.name,
                titles=[title_from_card(card) for card in detail.collection.items],
            )
            if detail.collection is not None
            else None
        ),
        recommendations=[title_from_card(card) for card in detail.related],
        library_links=detail.library_links,
    )


def _provider_collection_id(provider: MediaSource, legacy_row_id: str) -> str:
    if provider is MediaSource.DOUBAN and legacy_row_id.startswith("douban-"):
        return legacy_row_id.removeprefix("douban-")
    return legacy_row_id


def get_title_discovery_service() -> TitleDiscoveryService:
    """按现有进程级 provider 单例装配一次轻量领域编排器。"""
    from movieclaw_api.services.media_discover import (
        get_douban_media_service,
        get_media_service,
    )

    return TitleDiscoveryService(get_media_service, get_douban_media_service)

"""影视发现领域的公开 API 模型。

这里刻意不用 ``layout / hero / row`` 等页面实现词：公开契约只描述用户能
理解的「片单、影视条目、搜索、详情」。页面要把某个片单画成大横幅还是横滚
行，由 ``/ui/discovery`` 的展示协议单独决定。

``title_ref`` 与 ``collection_ref`` 是跨接口传递的稳定引用。调用方从列表或
搜索结果拿到后原样传给详情/片单接口，不再自行拼接 provider、媒体类型与 ID。
"""

from __future__ import annotations

from enum import StrEnum

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel
from movieclaw_media.models import (
    MediaCastMember,
    MediaImage,
    MediaKind,
    MediaLibraryLink,
    MediaLibraryStatus,
    MediaSource,
    MediaVideo,
)


class DiscoveryProviderSelection(StrEnum):
    """搜索时的数据来源范围；浏览片单仍要求指定单一来源。"""

    ALL = "all"
    TMDB = "tmdb"
    DOUBAN = "douban"


class DiscoverySort(StrEnum):
    """TMDB 组合筛选支持的稳定排序值。"""

    POPULAR = "popular"
    RATING = "rating"
    NEWEST = "newest"
    MOST_RATED = "most-rated"


class DiscoveryCollectionView(BaseModel):
    """一个可浏览的影视片单及其能力说明。"""

    collection_ref: str = Field(
        description="片单稳定引用；浏览内容时原样传给 browse-collection"
    )
    provider: MediaSource = Field(description="片单数据来源：tmdb / douban")
    media_type: MediaKind = Field(description="片单中的影视类型：movie / tv")
    name: str = Field(description="面向用户的片单名称")
    description: str = Field(default="", description="片单内容与选取口径说明")
    is_ranked: bool = Field(default=False, description="是否为有明确名次的排行榜")
    default_limit: int = Field(description="发现页预览该片单时的默认条数")
    supports_full_listing: bool = Field(
        default=False, description="是否支持请求完整榜单（可用较大的 limit）"
    )


class DiscoveryCollectionListView(BaseModel):
    """指定来源和媒体类型下，按产品编排顺序返回的全部片单。"""

    provider: MediaSource
    media_type: MediaKind
    collections: list[DiscoveryCollectionView]


class DiscoveredTitleView(BaseModel):
    """发现/搜索结果中的影视条目摘要。

    豆瓣轻量搜索不提供媒体类型、年份与原名，这些字段允许为空；进入详情后
    服务端会补齐。``external_id`` 只用于展示或排障，后续调用应使用
    ``title_ref``，避免不同来源的数字 ID 相互碰撞。
    """

    title_ref: str = Field(description="影视条目稳定引用；详情接口原样消费")
    provider: MediaSource
    external_id: str
    media_type: MediaKind | None = None
    title: str
    original_title: str = ""
    release_year: int | None = None
    provider_rating: float = Field(default=0, description="来源站评分，0 表示暂无评分")
    genres: list[str] = Field(default_factory=list)
    extent_label: str = Field(
        default="", description="规模展示文本：电影片长或剧集季数；列表结果可能为空"
    )
    overview: str = ""
    poster_url: str
    backdrop_url: str | None = None
    library_status: MediaLibraryStatus | None = Field(
        default=None, description="本地在位库存摘要；未匹配到本地条目时为空"
    )


class DiscoveryCollectionTitlesView(BaseModel):
    """一个片单及本次返回的影视条目。"""

    collection: DiscoveryCollectionView
    titles: list[DiscoveredTitleView]
    returned_count: int
    truncated: bool = Field(description="服务端当前取得的条目是否因本次 limit 被截断")
    page: int = Field(default=1, ge=1)
    total_pages: int = Field(default=1, ge=1)
    total_results: int = Field(default=0, ge=0)
    has_more: bool = False


class DiscoveryGenreView(BaseModel):
    """筛选器里一个本地化的 TMDB 类型。"""

    id: int
    name: str


class DiscoveryFilterOptionsView(BaseModel):
    """指定媒体类型可用于组合发现的动态选项。"""

    media_type: MediaKind
    genres: list[DiscoveryGenreView]


class DiscoveryTitlePageView(BaseModel):
    """一次组合筛选得到的一页影视条目。"""

    media_type: MediaKind
    titles: list[DiscoveredTitleView]
    page: int = Field(ge=1)
    total_pages: int = Field(ge=1)
    total_results: int = Field(ge=0)
    has_more: bool


class TitleSearchPayload(BaseModel):
    """执行一次影视条目搜索。"""

    query: str = Field(min_length=1, max_length=100, description="要搜索的影视片名")
    provider: DiscoveryProviderSelection = Field(
        default=DiscoveryProviderSelection.ALL,
        description="搜索来源：all 同时搜索 TMDB 和豆瓣，也可只指定 tmdb / douban",
    )
    save_history: bool = Field(
        default=False, description="是否把本次搜索及结果快照写入当前账号的搜索历史"
    )


class TitleSearchProviderStatus(BaseModel):
    """多来源搜索中单个来源的执行状态。"""

    provider: MediaSource
    success: bool
    result_count: int = 0
    message: str | None = None


class TitleSearchView(BaseModel):
    """一次统一影视搜索的结果；单个来源失败不会丢掉其他来源的结果。"""

    query: str
    titles: list[DiscoveredTitleView]
    providers: list[TitleSearchProviderStatus]
    history_id: int | None = Field(default=None, description="已记录历史时返回其 ID")


class DiscoveredTitleMetadata(BaseModel):
    """影视条目详情中的作品资料与演职员。"""

    directors: list[str] = Field(default_factory=list)
    director_credits: list[MediaCastMember] = Field(
        default_factory=list,
        description="带头像和人物 ID 的导演/主创；缺失时前端回退 directors 姓名",
    )
    cast: list[MediaCastMember] = Field(default_factory=list)
    country: str = ""
    language: str = ""
    released: str = ""
    network: str | None = None
    aliases: list[str] = Field(default_factory=list)
    source_url: str | None = None
    english_title: str | None = Field(
        default=None, description="国际英文名；豆瓣条目没有，为 null"
    )


class DiscoveredTitleCollectionView(BaseModel):
    """电影详情中的系列作品。"""

    id: str
    name: str
    titles: list[DiscoveredTitleView]


class DiscoveredTitleDetailsView(BaseModel):
    """影视条目的完整资料、预告片、图片、相关推荐与本地媒体库入口。"""

    title: DiscoveredTitleView
    metadata: DiscoveredTitleMetadata
    backdrop_original_url: str | None = Field(
        default=None,
        description="主横幅剧照的 original 原图；详情页沉浸背景的高清升级源，缺失时为 None",
    )
    videos: list[MediaVideo] = Field(
        default_factory=list,
        description="预告片与花絮（正式预告在前）；来源未提供时为空数组",
    )
    backdrops: list[MediaImage] = Field(default_factory=list)
    posters: list[MediaImage] = Field(default_factory=list)
    collection: DiscoveredTitleCollectionView | None = None
    recommendations: list[DiscoveredTitleView] = Field(default_factory=list)
    library_links: list[MediaLibraryLink] = Field(default_factory=list)


class DiscoveredPersonDetailsView(BaseModel):
    """发现页影人档案：TMDB 中的全部影视作品及本地库存状态。"""

    tmdb_person_id: int
    name: str
    avatar_url: str | None = None
    titles: list[DiscoveredTitleView] = Field(
        default_factory=list,
        description="参演与幕后作品合并去重后的完整 TMDB 影视履历",
    )


class DiscoveryPresentation(StrEnum):
    """发现页支持的展示形态；只在 Web 专用协议中出现。"""

    HERO = "hero"
    RANKED_ROW = "ranked-row"
    POSTER_ROW = "poster-row"


class DiscoveryPageSectionView(BaseModel):
    """发现页的一个展示分区，数据由 collection_ref 指向领域接口。"""

    collection_ref: str
    title: str
    presentation: DiscoveryPresentation
    preview_limit: int
    supports_full_listing: bool = False


class DiscoveryPageView(BaseModel):
    """Web 发现页编排；只声明分区，不携带片单条目。"""

    provider: MediaSource
    media_type: MediaKind
    sections: list[DiscoveryPageSectionView]

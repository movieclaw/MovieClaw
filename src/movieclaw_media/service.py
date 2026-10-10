"""发现页数据编排：把 TMDB 的榜单接口转换为前端可渲染的行数据。

页面构成（Netflix 式）
--------------------
- hero：本周趋势榜里挑「有宽幅剧照且有中文简介」的前几名做大横幅轮播；
- rows：每行对应一个 TMDB 榜单/发现查询（行定义见 _movie_rows / _tv_rows）。

发现页按「布局 + 单行」两级提供：布局（行清单）是纯配置即时返回，前端据此
撑起骨架后逐行拉数据渐进填充；单行失败只影响那一行（该行接口报错，前端
收起该行），不拖垮整页——错误隔离口径与站点搜索一致。

缓存口径
--------
行/Hero 30 分钟、类型表 24 小时、详情 6 小时——都是全站共享的只读榜单数据，
无个性化成分，进程内 TTL 缓存即可（见 cache.py 的说明）。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from movieclaw_cache import AsyncTTLCache
from movieclaw_media.models import (
    DiscoverLayout,
    DiscoverRowStub,
    MediaCard,
    MediaCastMember,
    MediaCollection,
    MediaDetail,
    MediaFacts,
    MediaImage,
    MediaKind,
    MediaPage,
    MediaPersonDetail,
    MediaRow,
    MediaSearchItem,
    MediaSource,
    MediaVideo,
)
from movieclaw_media.library import _english_title, _translation_index
from movieclaw_media.tmdb import TmdbClient, TmdbError

logger = logging.getLogger("movieclaw_media.service")

_PAGE_TTL = 30 * 60
_GENRE_TTL = 24 * 60 * 60
_DETAIL_TTL = 6 * 60 * 60
_PERSON_TTL = 6 * 60 * 60
_SEARCH_TTL = 10 * 60
# Hero 轮播的精选数量
_HERO_COUNT = 6
# 一行少于这个数就不值得占一行位置（如所选地区暂无「正在热映」数据）
_MIN_ROW_ITEMS = 4
# 相似推荐最多取多少部
_RELATED_LIMIT = 10
# 详情页剧照/海报各取多少张（TMDB 已按社区评分排好序，取前 N 即最佳 N 张）
_IMAGES_LIMIT = 20
# 详情页演职员条最多取多少位。TMDB 的 cast 已按 order 字段（剧组给的主次顺序）
# 排好，取前 N 即主要演员；条目页是横滚条，比原先「词条信息里一行文字」能放得下更多
_CAST_LIMIT = 16
# 详情页预告片最多展示多少段（热门大片的 videos 动辄几十条，多是重复的地区版本）
_VIDEOS_LIMIT = 8
# TMDB 的 video type → 中文标签。只保留「与看片本身有关」的几类，
# Opening Credits / Recap / Bloopers 之类对发现场景没有价值，直接丢弃。
# 字典顺序同时充当排序权重：正式预告排在先导预告前，花絮类垫底。
_VIDEO_KINDS = {
    "Trailer": "预告片",
    "Teaser": "先导预告",
    "Clip": "片段",
    "Featurette": "花絮",
    "Behind the Scenes": "幕后",
}
_VIDEO_KIND_ORDER = {kind: index for index, kind in enumerate(_VIDEO_KINDS)}

# TMDB 详情接口不随 language 参数翻译制片地区/语言字段，这里映射高频值，
# 映射不到的原样展示（英文/ISO 代码），不影响功能
_COUNTRY_NAMES = {
    "US": "美国", "CN": "中国大陆", "HK": "中国香港", "TW": "中国台湾",
    "JP": "日本", "KR": "韩国", "GB": "英国", "FR": "法国", "DE": "德国",
    "IT": "意大利", "ES": "西班牙", "CA": "加拿大", "AU": "澳大利亚",
    "IN": "印度", "TH": "泰国", "RU": "俄罗斯", "NZ": "新西兰",
    "IE": "爱尔兰", "DK": "丹麦", "SE": "瑞典", "NO": "挪威",
    "BE": "比利时", "NL": "荷兰", "BR": "巴西", "MX": "墨西哥",
}
_LANGUAGE_NAMES = {
    "en": "英语", "zh": "汉语普通话", "cn": "粤语", "ja": "日语", "ko": "韩语",
    "fr": "法语", "de": "德语", "es": "西班牙语", "it": "意大利语",
    "ru": "俄语", "pt": "葡萄牙语", "hi": "印地语", "th": "泰语",
    "sv": "瑞典语", "da": "丹麦语", "no": "挪威语", "nl": "荷兰语",
    "pl": "波兰语", "tr": "土耳其语",
}


@dataclass(frozen=True)
class _RowSpec:
    """一行榜单的声明式定义：行标识/中文标题/TMDB 端点/查询参数。"""

    row_id: str
    title: str
    path: str
    params: dict[str, Any] = field(default_factory=dict)
    ranked: bool = False
    limit: int = 20
    paginated: bool = True


def _movie_rows(region: str, today: date | None = None) -> tuple[_RowSpec, ...]:
    today = today or datetime.now(ZoneInfo("Asia/Shanghai")).date()
    # 行序参考 Netflix 发现页编排：趋势排名行打头，院线时效内容随后，热门与
    # 口碑居中，地区行与类型行垫后。discover 查询统一带 vote_count 下限挡住
    # 冷门残缺条目；类型 ID（878 科幻、28 动作等）是 TMDB 官方文档的稳定常量。
    return (
        _RowSpec(
            "trending-day", "今日热榜", "trending/movie/day",
            ranked=True, limit=10,
        ),
        _RowSpec("now-playing", "正在热映", "movie/now_playing", {"region": region}),
        _RowSpec("upcoming", "即将上映", "movie/upcoming", {"region": region}),
        _RowSpec("popular", "热门电影", "movie/popular"),
        _RowSpec(
            "recent-acclaimed", "近两年高口碑", "discover/movie",
            {
                "primary_release_date.gte": (today - timedelta(days=730)).isoformat(),
                "primary_release_date.lte": today.isoformat(),
                "sort_by": "vote_average.desc",
                "vote_count.gte": 300,
            },
        ),
        _RowSpec(
            "this-year", "今年新片", "discover/movie",
            {
                "primary_release_year": today.year,
                "primary_release_date.lte": today.isoformat(),
                "sort_by": "popularity.desc",
                "vote_count.gte": 20,
            },
        ),
        _RowSpec(
            "short-runtime", "90 分钟以内", "discover/movie",
            {
                "with_runtime.lte": 90,
                "sort_by": "popularity.desc",
                "vote_count.gte": 100,
            },
        ),
        _RowSpec("top-rated", "高分经典", "movie/top_rated"),
        _RowSpec(
            "chinese", "华语佳片", "discover/movie",
            {"with_original_language": "zh", "sort_by": "popularity.desc", "vote_count.gte": 50},
        ),
        _RowSpec(
            "japanese", "日本电影", "discover/movie",
            {"with_origin_country": "JP", "sort_by": "popularity.desc", "vote_count.gte": 100},
        ),
        _RowSpec(
            "korean", "韩国电影", "discover/movie",
            {"with_origin_country": "KR", "sort_by": "popularity.desc", "vote_count.gte": 100},
        ),
        _RowSpec(
            "scifi", "科幻巨制", "discover/movie",
            {"with_genres": "878", "sort_by": "popularity.desc", "vote_count.gte": 300},
        ),
        # with_genres 里的竖线是「或」（逗号才是「且」）：28|12 = 动作或冒险
        _RowSpec(
            "action", "动作与冒险", "discover/movie",
            {"with_genres": "28|12", "sort_by": "popularity.desc", "vote_count.gte": 300},
        ),
        _RowSpec(
            "thriller", "悬疑惊悚", "discover/movie",
            {"with_genres": "53|9648", "sort_by": "popularity.desc", "vote_count.gte": 300},
        ),
        _RowSpec(
            "comedy", "喜剧佳作", "discover/movie",
            {"with_genres": "35", "sort_by": "popularity.desc", "vote_count.gte": 200},
        ),
        _RowSpec(
            "romance", "爱情电影", "discover/movie",
            {"with_genres": "10749", "sort_by": "popularity.desc", "vote_count.gte": 200},
        ),
        _RowSpec(
            "horror", "恐怖片", "discover/movie",
            {"with_genres": "27", "sort_by": "popularity.desc", "vote_count.gte": 200},
        ),
        _RowSpec(
            "animation", "动画电影", "discover/movie",
            {"with_genres": "16", "sort_by": "popularity.desc", "vote_count.gte": 200},
        ),
        _RowSpec(
            "documentary", "纪录片", "discover/movie",
            {"with_genres": "99", "sort_by": "popularity.desc", "vote_count.gte": 50},
        ),
    )


def _tv_rows(
    today: date | None = None, timezone: str = "Asia/Shanghai"
) -> tuple[_RowSpec, ...]:
    today = today or datetime.now(ZoneInfo(timezone)).date()
    # 剧集侧同理：趋势与在播内容在前，热门/口碑居中，然后是地区行与播出平台
    # 品牌行（Netflix/HBO 是发现页里辨识度最高的两块金字招牌），类型行垫后。
    return (
        _RowSpec(
            "trending-day", "今日热榜", "trending/tv/day",
            ranked=True, limit=10,
        ),
        _RowSpec("airing-today", "今日更新", "tv/airing_today", {"timezone": timezone}),
        _RowSpec("on-the-air", "本周更新", "tv/on_the_air", {"timezone": timezone}),
        _RowSpec("popular", "热门剧集", "tv/popular"),
        _RowSpec(
            "recent-acclaimed", "近两年高口碑", "discover/tv",
            {
                "first_air_date.gte": (today - timedelta(days=730)).isoformat(),
                "first_air_date.lte": today.isoformat(),
                "sort_by": "vote_average.desc",
                "vote_count.gte": 100,
            },
        ),
        _RowSpec(
            "completed-miniseries", "已完结迷你剧", "discover/tv",
            {
                "with_type": 2,
                "with_status": 3,
                "sort_by": "vote_average.desc",
                "vote_count.gte": 50,
            },
        ),
        _RowSpec("top-rated", "高分神剧", "tv/top_rated"),
        _RowSpec(
            "chinese", "华语剧集", "discover/tv",
            {"with_original_language": "zh", "sort_by": "popularity.desc", "vote_count.gte": 20},
        ),
        _RowSpec(
            "us", "热门美剧", "discover/tv",
            {"with_origin_country": "US", "sort_by": "popularity.desc", "vote_count.gte": 50},
        ),
        _RowSpec(
            "japanese", "热门日剧", "discover/tv",
            {"with_origin_country": "JP", "sort_by": "popularity.desc", "vote_count.gte": 20},
        ),
        _RowSpec(
            "korean", "热门韩剧", "discover/tv",
            {"with_origin_country": "KR", "sort_by": "popularity.desc", "vote_count.gte": 20},
        ),
        # 播出平台行：with_networks 的 213=Netflix、49=HBO（TMDB network ID）
        _RowSpec(
            "netflix", "Netflix 出品", "discover/tv",
            {"with_networks": "213", "sort_by": "popularity.desc", "vote_count.gte": 50},
        ),
        _RowSpec(
            "hbo", "HBO 出品", "discover/tv",
            {"with_networks": "49", "sort_by": "popularity.desc", "vote_count.gte": 50},
        ),
        _RowSpec(
            "scifi-fantasy", "科幻与奇幻", "discover/tv",
            {"with_genres": "10765", "sort_by": "popularity.desc", "vote_count.gte": 100},
        ),
        _RowSpec(
            "crime-mystery", "悬疑罪案", "discover/tv",
            {"with_genres": "80|9648", "sort_by": "popularity.desc", "vote_count.gte": 50},
        ),
        _RowSpec(
            "comedy", "喜剧剧集", "discover/tv",
            {"with_genres": "35", "sort_by": "popularity.desc", "vote_count.gte": 100},
        ),
        _RowSpec(
            "animation", "动画剧集", "discover/tv",
            {"with_genres": "16", "sort_by": "popularity.desc", "vote_count.gte": 100},
        ),
        _RowSpec(
            "reality", "真人秀", "discover/tv",
            {"with_genres": "10764", "sort_by": "popularity.desc", "vote_count.gte": 20},
        ),
        _RowSpec(
            "documentary", "纪录片", "discover/tv",
            {"with_genres": "99", "sort_by": "popularity.desc", "vote_count.gte": 20},
        ),
    )


class MediaDiscoverService:
    """发现页/详情的编排服务：TMDB 原始数据 → 前端可渲染的模型。"""

    def __init__(
        self,
        client: TmdbClient,
        *,
        image_base_url: str,
        language: str = "zh-CN",
        region: str = "CN",
        timezone: str = "Asia/Shanghai",
    ) -> None:
        self._client = client
        self._image_base = image_base_url.rstrip("/")
        self._language = language
        self._region = region
        self._timezone = timezone
        self._cache = AsyncTTLCache()

    # ------------------------------------------------------------------
    # 发现页
    # ------------------------------------------------------------------

    def layout(self, kind: MediaKind) -> DiscoverLayout:
        """发现页布局：行清单来自静态配置，不触发任何 TMDB 请求。"""
        return DiscoverLayout(
            has_hero=True,
            rows=[
                DiscoverRowStub(id=s.row_id, title=s.title, ranked=s.ranked)
                for s in self._row_specs(kind)
            ],
        )

    async def discover_hero(self, kind: MediaKind) -> list[MediaCard]:
        """Hero 大横幅精选：本周趋势榜里挑「有宽幅剧照且有简介」的前几名。"""
        return await self._cache.get_or_set(
            f"hero:{kind.value}", _PAGE_TTL, lambda: self._build_hero(kind)
        )

    async def discover_row(self, kind: MediaKind, row_id: str) -> MediaRow | None:
        """拉取布局中的一行；row_id 不在布局里时返回 None（路由层译为 404）。"""
        page = await self.discover_page(kind, row_id, 1)
        if page is None:
            return None
        items = page.items[: next(s.limit for s in self._row_specs(kind) if s.row_id == row_id)]
        # 条目太少不值得占一行位置：清空 items，前端按「空行」统一收起。
        if len(items) < _MIN_ROW_ITEMS:
            items = []
        return MediaRow(id=page.id, title=page.title, ranked=page.ranked, items=items)

    async def discover_page(
        self, kind: MediaKind, row_id: str, page: int = 1
    ) -> MediaPage | None:
        """拉取榜单的一页；完整列表页用 TMDB 原生分页持续向后加载。"""
        spec = next((s for s in self._row_specs(kind) if s.row_id == row_id), None)
        if spec is None:
            return None
        requested_page = page if spec.paginated else 1
        return await self._cache.get_or_set(
            f"row-page:{kind.value}:{row_id}:{requested_page}",
            _PAGE_TTL,
            lambda: self._build_page(kind, spec, requested_page),
        )

    def _row_specs(self, kind: MediaKind) -> tuple[_RowSpec, ...]:
        timezone = self._timezone
        try:
            today = datetime.now(ZoneInfo(timezone)).date()
        except (ZoneInfoNotFoundError, ValueError):
            logger.warning("发现页时区 %s 无效，已回退到 Asia/Shanghai", self._timezone)
            timezone = "Asia/Shanghai"
            today = datetime.now(ZoneInfo(timezone)).date()
        return (
            _movie_rows(self._region, today)
            if kind is MediaKind.MOVIE
            else _tv_rows(today, timezone)
        )

    async def _build_hero(self, kind: MediaKind) -> list[MediaCard]:
        genre_map = await self._genre_map(kind)
        cards = await self._fetch_cards(f"trending/{kind.value}/week", {}, kind, genre_map)
        return [c for c in cards if c.backdrop_url and c.overview][:_HERO_COUNT]

    async def _build_page(self, kind: MediaKind, spec: _RowSpec, page: int) -> MediaPage:
        genre_map = await self._genre_map(kind)
        params = {**spec.params, **({"page": page} if spec.paginated else {})}
        data, items = await self._fetch_page(spec.path, params, kind, genre_map)
        return MediaPage(
            id=spec.row_id,
            title=spec.title,
            ranked=spec.ranked,
            items=items,
            page=max(1, int(data.get("page") or page)),
            total_pages=max(1, int(data.get("total_pages") or 1)),
            total_results=max(0, int(data.get("total_results") or len(items))),
        )

    async def _fetch_cards(
        self, path: str, params: dict[str, Any], kind: MediaKind, genre_map: dict[int, str]
    ) -> list[MediaCard]:
        _, cards = await self._fetch_page(path, params, kind, genre_map)
        return cards

    async def _fetch_page(
        self, path: str, params: dict[str, Any], kind: MediaKind, genre_map: dict[int, str]
    ) -> tuple[dict[str, Any], list[MediaCard]]:
        data = await self._client.get(path, {"language": self._language, **params})
        cards = (self._to_card(raw, kind, genre_map) for raw in data.get("results", []))
        return data, [c for c in cards if c is not None]

    async def discovery_genres(self, kind: MediaKind) -> dict[int, str]:
        """返回筛选器可用的本地化类型清单。"""
        return await self._genre_map(kind)

    async def discover_filtered(
        self,
        kind: MediaKind,
        *,
        genre_ids: list[int] | None = None,
        origin_country: str | None = None,
        year: int | None = None,
        rating_gte: float | None = None,
        runtime_lte: int | None = None,
        sort: str = "popular",
        page: int = 1,
    ) -> MediaPage:
        """组合 TMDB discover 参数，提供可分享 URL 对应的六维筛选结果。"""
        sort_map = {
            "popular": "popularity.desc",
            "rating": "vote_average.desc",
            "newest": (
                "primary_release_date.desc"
                if kind is MediaKind.MOVIE
                else "first_air_date.desc"
            ),
            "most-rated": "vote_count.desc",
        }
        params: dict[str, Any] = {
            "include_adult": "false",
            "sort_by": sort_map.get(sort, sort_map["popular"]),
            "page": page,
        }
        if kind is MediaKind.MOVIE:
            params["include_video"] = "false"
            params["region"] = self._region
        if genre_ids:
            params["with_genres"] = "|".join(str(value) for value in genre_ids)
        if origin_country:
            params["with_origin_country"] = origin_country
        if year:
            params[
                "primary_release_year" if kind is MediaKind.MOVIE else "first_air_date_year"
            ] = year
        if rating_gte is not None:
            params["vote_average.gte"] = rating_gte
        if runtime_lte is not None:
            params["with_runtime.lte"] = runtime_lte
        # 纯按均分排序会被少量投票的偶然满分占满，加入轻量门槛才有发现价值。
        if sort == "rating":
            params["vote_count.gte"] = 50

        cache_key = ":".join(
            [
                kind.value,
                ",".join(str(value) for value in genre_ids or []),
                origin_country or "",
                str(year or ""),
                str(rating_gte if rating_gte is not None else ""),
                str(runtime_lte or ""),
                sort,
                str(page),
            ]
        )

        async def load() -> MediaPage:
            genre_map = await self._genre_map(kind)
            data, items = await self._fetch_page(
                f"discover/{kind.value}", params, kind, genre_map
            )
            return MediaPage(
                id="filtered",
                title="筛选结果",
                items=items,
                page=max(1, int(data.get("page") or page)),
                total_pages=max(1, int(data.get("total_pages") or 1)),
                total_results=max(0, int(data.get("total_results") or len(items))),
            )

        return await self._cache.get_or_set(f"filtered:{cache_key}", _PAGE_TTL, load)

    def _to_card(
        self, raw: dict[str, Any], kind: MediaKind, genre_map: dict[int, str]
    ) -> MediaCard | None:
        """TMDB 列表条目 → 海报卡片；缺海报/标题/年份的条目没法上墙，返回 None 剔除。"""
        title = raw.get("title") or raw.get("name") or ""
        date = raw.get("release_date") or raw.get("first_air_date") or ""
        poster = raw.get("poster_path")
        if not poster or not title or len(date) < 4 or not date[:4].isdigit():
            return None
        # 详情接口给的是 genres 对象列表，列表接口给的是 genre_ids，两者兼容
        genre_ids = raw.get("genre_ids") or [g["id"] for g in raw.get("genres", [])]
        backdrop = raw.get("backdrop_path")
        return MediaCard(
            id=str(raw["id"]),
            type=kind,
            title=title,
            original_title=raw.get("original_title") or raw.get("original_name") or title,
            year=int(date[:4]),
            rating=round(float(raw.get("vote_average") or 0.0), 1),
            genres=[genre_map[g] for g in genre_ids if g in genre_map][:3],
            overview=(raw.get("overview") or "").strip(),
            poster_url=f"{self._image_base}/w500{poster}",
            backdrop_url=f"{self._image_base}/w1280{backdrop}" if backdrop else None,
        )

    async def _genre_map(self, kind: MediaKind) -> dict[int, str]:
        """TMDB 类型 ID → 中文名（如 878 → 科幻）。全站共享，缓存 24 小时。"""

        async def load() -> dict[int, str]:
            data = await self._client.get(
                f"genre/{kind.value}/list", {"language": self._language}
            )
            return {g["id"]: g["name"] for g in data.get("genres", [])}

        return await self._cache.get_or_set(f"genres:{kind.value}", _GENRE_TTL, load)

    # ------------------------------------------------------------------
    # 搜索
    # ------------------------------------------------------------------

    async def search(self, keyword: str) -> list[MediaSearchItem]:
        """TMDB multi 搜索 → 轻量候选（自带年份和 movie/tv 类型，豆瓣搜索没有）。

        用 search/multi 而非分别搜电影/剧集：一次请求，且两类条目按 TMDB
        的全局热度统一排序，不需要自己拼接排序。相同关键词缓存十分钟，
        口径与豆瓣搜索一致。
        """
        normalized = keyword.strip()

        async def load() -> list[MediaSearchItem]:
            data = await self._client.get(
                "search/multi", {"language": self._language, "query": normalized}
            )
            items = (self._to_search_item(raw) for raw in data.get("results", []))
            return [item for item in items if item is not None]

        return await self._cache.get_or_set(
            f"search:{normalized.casefold()}", _SEARCH_TTL, load
        )

    def _to_search_item(self, raw: dict[str, Any]) -> MediaSearchItem | None:
        """multi 搜索条目 → 轻量候选；人物条目和缺海报/标题的条目剔除。"""
        media_type = raw.get("media_type")
        if media_type not in (MediaKind.MOVIE.value, MediaKind.TV.value):
            return None
        title = raw.get("title") or raw.get("name") or ""
        poster = raw.get("poster_path")
        if not title or not poster:
            return None
        date = raw.get("release_date") or raw.get("first_air_date") or ""
        return MediaSearchItem(
            id=str(raw["id"]),
            source=MediaSource.TMDB,
            title=title,
            year=int(date[:4]) if date[:4].isdigit() else None,
            type=MediaKind(media_type),
            rating=round(float(raw.get("vote_average") or 0), 1),
            poster_url=f"{self._image_base}/w342{poster}",
        )

    # ------------------------------------------------------------------
    # 影人作品
    # ------------------------------------------------------------------

    async def person_detail(self, tmdb_person_id: int) -> MediaPersonDetail:
        """读取 TMDB 影人档案及完整 combined credits，缓存口径与条目详情一致。"""
        return await self._cache.get_or_set(
            f"person:{tmdb_person_id}",
            _PERSON_TTL,
            lambda: self._build_person_detail(tmdb_person_id),
        )

    async def _build_person_detail(self, tmdb_person_id: int) -> MediaPersonDetail:
        """一次读取影人与全部作品；电影/剧集类型表并发补齐中文类型名。"""
        data, movie_genres, tv_genres = await asyncio.gather(
            self._client.get(
                f"person/{tmdb_person_id}",
                {
                    "language": self._language,
                    "append_to_response": "combined_credits",
                },
            ),
            self._genre_map(MediaKind.MOVIE),
            self._genre_map(MediaKind.TV),
        )
        name = (data.get("name") or "").strip()
        if not name:
            raise TmdbError("该影人在 TMDB 中缺少姓名，无法展示")

        # 同一作品可能同时出现在 cast 与 crew，幕后也可能因多个 job 重复；
        # 人物页回答“有哪些作品”，所以只按媒体类型 + TMDB ID 保留一张海报。
        credits = data.get("combined_credits") or {}
        cards: dict[tuple[MediaKind, str], tuple[str, MediaCard]] = {}
        genre_maps = {MediaKind.MOVIE: movie_genres, MediaKind.TV: tv_genres}
        for raw in [*(credits.get("cast") or []), *(credits.get("crew") or [])]:
            mapped = self._person_credit_card(raw, genre_maps)
            if mapped is None:
                continue
            release_date, card = mapped
            key = (card.type, card.id)
            existing = cards.get(key)
            if existing is None or release_date > existing[0]:
                cards[key] = (release_date, card)

        ordered = [
            card
            for _release_date, card in sorted(
                cards.values(),
                key=lambda entry: (entry[0], entry[1].rating),
                reverse=True,
            )
        ]
        profile = data.get("profile_path")
        return MediaPersonDetail(
            tmdb_person_id=tmdb_person_id,
            name=name,
            avatar_url=f"{self._image_base}/w300{profile}" if profile else None,
            credits=ordered,
        )

    def _person_credit_card(
        self,
        raw: dict[str, Any],
        genre_maps: dict[MediaKind, dict[int, str]],
    ) -> tuple[str, MediaCard] | None:
        """combined credit → 海报卡；缺海报或日期仍保留，确保履历完整。"""
        media_type = raw.get("media_type")
        if media_type not in (MediaKind.MOVIE.value, MediaKind.TV.value):
            return None
        external_id = raw.get("id")
        title = (raw.get("title") or raw.get("name") or "").strip()
        if not external_id or not title:
            return None

        kind = MediaKind(media_type)
        release_date = raw.get("release_date") or raw.get("first_air_date") or ""
        poster = raw.get("poster_path")
        backdrop = raw.get("backdrop_path")
        genre_map = genre_maps[kind]
        return release_date, MediaCard(
            id=str(external_id),
            type=kind,
            title=title,
            original_title=raw.get("original_title") or raw.get("original_name") or title,
            year=int(release_date[:4]) if release_date[:4].isdigit() else 0,
            rating=round(float(raw.get("vote_average") or 0), 1),
            genres=[genre_map[g] for g in raw.get("genre_ids") or [] if g in genre_map][:3],
            overview=(raw.get("overview") or "").strip(),
            poster_url=f"{self._image_base}/w500{poster}" if poster else "",
            backdrop_url=f"{self._image_base}/w1280{backdrop}" if backdrop else None,
        )

    # ------------------------------------------------------------------
    # 条目详情
    # ------------------------------------------------------------------

    async def media_detail(self, kind: MediaKind, tmdb_id: int) -> MediaDetail:
        return await self._cache.get_or_set(
            f"detail:{kind.value}:{tmdb_id}",
            _DETAIL_TTL,
            lambda: self._build_detail(kind, tmdb_id),
        )

    async def _build_detail(self, kind: MediaKind, tmdb_id: int) -> MediaDetail:
        genre_map = await self._genre_map(kind)
        # append_to_response：演职员/相似推荐/图片集/预告片随详情一次请求带回，省四次往返；
        # translations 取英文名——「搜索资源」拿它和中文名、原名一起搜（同订阅召回词）。
        # include_image_language / include_video_language 必须显式给：默认按 language
        # 过滤会把素材滤到几乎没有——剧照大多不带语言标注（null），海报按语言分版本，
        # 而预告片九成只有英文版，只要 zh-CN 的话绝大多数影片会一条都没有。
        primary_language = self._language.split("-")[0]
        data = await self._client.get(
            f"{kind.value}/{tmdb_id}",
            {
                "language": self._language,
                "append_to_response": "credits,recommendations,images,videos,translations",
                "include_image_language": f"{primary_language},en,null",
                "include_video_language": f"{primary_language},en,null",
            },
        )
        card = self._to_card(data, kind, genre_map)
        if card is None:
            raise TmdbError("该条目在 TMDB 中缺少海报或标题等必要信息，无法展示")
        card.extent = self._extent(data, kind)

        related_raw = (data.get("recommendations") or {}).get("results", [])
        related = [
            c
            for c in (self._to_card(r, kind, genre_map) for r in related_raw)
            if c is not None
        ][:_RELATED_LIMIT]
        collection = await self._movie_collection(data, kind, genre_map)
        backdrops, posters = self._images(data)
        backdrop_path = data.get("backdrop_path")
        facts = self._facts(data, kind)
        facts.english_title = _english_title(data, _translation_index(data))
        return MediaDetail(
            card=card,
            facts=facts,
            videos=self._videos(data),
            backdrops=backdrops,
            posters=posters,
            # 沉浸背景要铺满整屏，列表用的 w1280 在大屏上拉伸发虚；这里给
            # 同一张主 backdrop 的 original 原图，前端详情页到达后无缝升级
            backdrop_url=(
                f"{self._image_base}/original{backdrop_path}" if backdrop_path else None
            ),
            collection=collection,
            related=related,
        )

    async def _movie_collection(
        self,
        detail: dict[str, Any],
        kind: MediaKind,
        genre_map: dict[int, str],
    ) -> MediaCollection | None:
        """按 belongs_to_collection 补齐系列作品，保持官方系列顺序的时间语义。"""
        if kind is not MediaKind.MOVIE:
            return None
        summary = detail.get("belongs_to_collection") or {}
        collection_id = summary.get("id")
        if not collection_id:
            return None
        try:
            data = await self._client.get(
                f"collection/{collection_id}", {"language": self._language}
            )
        except TmdbError:
            # 系列是详情增强信息，偶发失败不应让影片主详情和演职员一起不可用。
            logger.warning("TMDB 系列电影读取失败，已保留影片主详情", exc_info=True)
            return None
        parts = sorted(
            data.get("parts") or [],
            key=lambda raw: (raw.get("release_date") or "9999-12-31", raw.get("id") or 0),
        )
        cards = [
            card
            for card in (
                self._to_card(raw, MediaKind.MOVIE, genre_map)
                for raw in parts
            )
            if card is not None
        ]
        if not cards:
            return None
        return MediaCollection(
            id=str(collection_id),
            name=data.get("name") or summary.get("name") or "系列电影",
            items=cards,
        )

    @staticmethod
    def _videos(data: dict[str, Any]) -> list[MediaVideo]:
        """详情里的视频集 → 预告片列表。

        只保留 YouTube：TMDB 支持的另一个来源 Vimeo 在影视条目里近乎不存在，
        为它单独适配一套封面与内嵌地址不划算，宁可少展示也不给出播不了的卡片。

        排序为「类型权重 → 官方优先 → 发布时间倒序」，用户点开的第一条就是最新
        的官方正式预告。分两次稳定排序实现：先按时间倒序，再按类型与官方标记，
        比在一个 key 里同时表达正反两种方向可读得多。
        """
        results = [
            raw
            for raw in (data.get("videos") or {}).get("results", [])
            if raw.get("key") and raw.get("site") == "YouTube" and raw.get("type") in _VIDEO_KINDS
        ]
        results.sort(key=lambda raw: raw.get("published_at") or "", reverse=True)
        results.sort(key=lambda raw: (_VIDEO_KIND_ORDER[raw["type"]], not raw.get("official")))
        return [
            MediaVideo(
                key=raw["key"],
                # 少数条目的 name 为空，用类型标签兜底，卡片上不会出现无名视频
                name=(raw.get("name") or "").strip() or _VIDEO_KINDS[raw["type"]],
                kind=_VIDEO_KINDS[raw["type"]],
                thumbnail_url=f"https://i.ytimg.com/vi/{raw['key']}/hqdefault.jpg",
                embed_url=f"https://www.youtube-nocookie.com/embed/{raw['key']}",
                watch_url=f"https://www.youtube.com/watch?v={raw['key']}",
            )
            for raw in results[:_VIDEOS_LIMIT]
        ]

    def _images(self, data: dict[str, Any]) -> tuple[list[MediaImage], list[MediaImage]]:
        """详情里的图片集 → 剧照/海报列表（各取评分最高的前 N 张）。

        海报把配置语言（如中文版）排到最前——用户点开更可能想要本地化海报；
        剧照无语言之分，保持 TMDB 的评分排序。
        """
        images = data.get("images") or {}
        primary_language = self._language.split("-")[0]

        def build(raw: dict[str, Any], preview_size: str) -> MediaImage | None:
            path = raw.get("file_path")
            if not path:
                return None
            return MediaImage(
                preview_url=f"{self._image_base}/{preview_size}{path}",
                full_url=f"{self._image_base}/original{path}",
                width=raw.get("width") or 0,
                height=raw.get("height") or 0,
            )

        backdrops = [
            img
            for img in (build(r, "w780") for r in images.get("backdrops", []))
            if img is not None
        ][:_IMAGES_LIMIT]

        posters_raw = sorted(
            images.get("posters", []),
            key=lambda r: r.get("iso_639_1") != primary_language,  # 配置语言在前，组内保持原序
        )
        posters = [
            img
            for img in (build(r, "w342") for r in posters_raw)
            if img is not None
        ][:_IMAGES_LIMIT]
        return backdrops, posters

    @staticmethod
    def _extent(data: dict[str, Any], kind: MediaKind) -> str:
        if kind is MediaKind.MOVIE:
            runtime = data.get("runtime")
            return f"{runtime} 分钟" if runtime else ""
        seasons = data.get("number_of_seasons")
        return f"{seasons} 季" if seasons else ""

    def _cast(self, credits: dict[str, Any]) -> list[MediaCastMember]:
        """credits.cast → 演职员条。

        头像用 w185（横滚条里每格才 104px 宽，再大是白下载）；没有 profile_path
        的人照样保留——名字与角色本身就是信息，前端渲染占位块即可。
        """
        members: list[MediaCastMember] = []
        for person in credits.get("cast", [])[:_CAST_LIMIT]:
            name = (person.get("name") or "").strip()
            if not name:
                continue
            profile = person.get("profile_path")
            members.append(
                MediaCastMember(
                    name=name,
                    role=(person.get("character") or "").strip() or None,
                    avatar_url=f"{self._image_base}/w185{profile}" if profile else None,
                    tmdb_person_id=person.get("id"),
                )
            )
        return members

    def _director_credits(
        self, data: dict[str, Any], kind: MediaKind
    ) -> list[MediaCastMember]:
        """把电影导演或剧集主创转换为结构化人物，供详情页合并进演职员条。"""
        if kind is MediaKind.MOVIE:
            people = [
                person
                for person in (data.get("credits") or {}).get("crew", [])
                if person.get("job") == "Director"
            ]
        else:
            people = data.get("created_by") or []

        members: list[MediaCastMember] = []
        for person in people[:3]:
            name = (person.get("name") or "").strip()
            if not name:
                continue
            profile = person.get("profile_path")
            members.append(
                MediaCastMember(
                    name=name,
                    avatar_url=f"{self._image_base}/w185{profile}" if profile else None,
                    tmdb_person_id=person.get("id"),
                )
            )
        return members

    def _facts(self, data: dict[str, Any], kind: MediaKind) -> MediaFacts:
        credits = data.get("credits") or {}
        director_credits = self._director_credits(data, kind)
        if kind is MediaKind.MOVIE:
            country_codes = [c.get("iso_3166_1", "") for c in data.get("production_countries", [])]
        else:
            country_codes = data.get("origin_country") or [
                c.get("iso_3166_1", "") for c in data.get("production_countries", [])
            ]

        networks = data.get("networks") or []
        original_language = data.get("original_language") or ""
        return MediaFacts(
            directors=[person.name for person in director_credits],
            director_credits=director_credits,
            cast=self._cast(credits),
            country=" / ".join(_COUNTRY_NAMES.get(c, c) for c in country_codes if c),
            language=_LANGUAGE_NAMES.get(original_language, original_language),
            released=data.get("release_date") or data.get("first_air_date") or "",
            network=networks[0].get("name") if kind is MediaKind.TV and networks else None,
        )

    async def aclose(self) -> None:
        await self._client.aclose()

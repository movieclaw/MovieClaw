"""movieclaw_media 发现页编排的单元测试（TMDB 客户端用桩替身，不出网）。"""

from __future__ import annotations

from datetime import date
from typing import Any

import pytest

from movieclaw_media.models import MediaKind
from movieclaw_media.service import MediaDiscoverService, _movie_rows, _tv_rows
from movieclaw_media.tmdb import TmdbError

_IMAGE_BASE = "https://image.tmdb.org/t/p"

# 类型表响应（movie / tv 共用即可）
_GENRES = {
    "genres": [{"id": 878, "name": "科幻"}, {"id": 16, "name": "动画"}, {"id": 28, "name": "动作"}]
}


def _movie(idx: int, **overrides: Any) -> dict[str, Any]:
    """构造一个字段齐全的 TMDB 电影列表条目。"""
    item = {
        "id": idx,
        "title": f"电影{idx}",
        "original_title": f"Movie {idx}",
        "release_date": "2026-01-15",
        "vote_average": 7.84,
        "genre_ids": [878, 28],
        "overview": f"简介{idx}",
        "poster_path": f"/p{idx}.jpg",
        "backdrop_path": f"/b{idx}.jpg",
    }
    item.update(overrides)
    return item


class StubTmdbClient:
    """按路径返回预置响应的桩客户端；值为异常时抛出，模拟单榜单失败。"""

    def __init__(self, responses: dict[str, Any]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, dict[str, Any]]] = []

    async def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.calls.append((path, dict(params or {})))
        result = self.responses.get(path)
        if result is None:
            return {"results": []}
        if isinstance(result, Exception):
            raise result
        return result

    async def aclose(self) -> None:  # pragma: no cover - 接口兼容
        pass


def _service(responses: dict[str, Any]) -> MediaDiscoverService:
    return MediaDiscoverService(
        StubTmdbClient({"genre/movie/list": _GENRES, "genre/tv/list": _GENRES, **responses}),
        image_base_url=_IMAGE_BASE,
    )


# ---------------------------------------------------------------------------
# 条目映射
# ---------------------------------------------------------------------------


async def test_card_mapping_fields() -> None:
    """TMDB 原始条目 → MediaCard 的字段映射：图床拼接 / 年份截取 / 评分取整 / 类型翻译。"""
    svc = _service({"trending/movie/week": {"results": [_movie(1)]}})
    hero = await svc.discover_hero(MediaKind.MOVIE)

    card = hero[0]
    assert card.id == "1"
    assert card.title == "电影1"
    assert card.year == 2026
    assert card.rating == 7.8
    assert card.genres == ["科幻", "动作"]
    assert card.poster_url == f"{_IMAGE_BASE}/w500/p1.jpg"
    assert card.backdrop_url == f"{_IMAGE_BASE}/w1280/b1.jpg"
    assert card.extent == ""  # 列表接口拿不到片长，留空由详情回填


async def test_card_drops_items_missing_essentials() -> None:
    """缺海报 / 缺日期的条目没法上墙，应被剔除而非渲染残卡。"""
    rows = {
        "results": [
            _movie(1),
            _movie(2, poster_path=None),
            _movie(3, release_date=""),
            _movie(4),
            _movie(5),
            _movie(6),
        ]
    }
    svc = _service({"movie/popular": rows})
    popular = await svc.discover_row(MediaKind.MOVIE, "popular")

    assert popular is not None
    assert [c.id for c in popular.items] == ["1", "4", "5", "6"]


# ---------------------------------------------------------------------------
# 布局与逐行编排
# ---------------------------------------------------------------------------


async def test_hero_requires_backdrop_and_overview() -> None:
    """Hero 只收「有宽幅剧照且有简介」的条目，保证大横幅视觉完整。"""
    trending = {
        "results": [
            _movie(1, backdrop_path=None),
            _movie(2, overview=""),
            _movie(3),
        ]
    }
    svc = _service({"trending/movie/week": trending})
    hero = await svc.discover_hero(MediaKind.MOVIE)
    assert [c.id for c in hero] == ["3"]


async def test_ranked_row_limits_to_top10() -> None:
    """今日热榜预览是排名行，发现页最多展示 10 条。"""
    trending_day = {"results": [_movie(i) for i in range(1, 15)]}
    svc = _service({"trending/movie/day": trending_day})
    top = await svc.discover_row(MediaKind.MOVIE, "trending-day")

    assert top is not None
    assert top.title == "今日热榜"
    assert top.ranked is True
    assert len(top.items) == 10


async def test_layout_lists_all_configured_rows_in_order() -> None:
    """布局是纯配置：行序与行定义完整一致（含地区/平台/类型行），不触发请求。"""
    svc = _service({})

    movie_layout = svc.layout(MediaKind.MOVIE)
    assert movie_layout.has_hero is True
    assert [r.id for r in movie_layout.rows] == [s.row_id for s in _movie_rows("CN")]

    tv_layout = svc.layout(MediaKind.TV)
    assert [r.id for r in tv_layout.rows] == [s.row_id for s in _tv_rows()]
    assert tv_layout.rows[0].title == "今日热榜"
    assert tv_layout.rows[0].ranked

    client: StubTmdbClient = svc._client  # type: ignore[assignment]
    assert client.calls == []


async def test_row_failure_raises_and_other_rows_unaffected() -> None:
    """单行失败只让那一行的请求报错（前端收起该行），其余行照常返回。"""
    svc = _service(
        {
            "movie/popular": {"results": [_movie(i) for i in range(1, 8)]},
            "movie/top_rated": TmdbError("模拟失败"),
        }
    )
    with pytest.raises(TmdbError, match="模拟失败"):
        await svc.discover_row(MediaKind.MOVIE, "top-rated")
    popular = await svc.discover_row(MediaKind.MOVIE, "popular")
    assert popular is not None
    assert len(popular.items) == 7


async def test_sparse_row_returns_empty_items() -> None:
    """条目太少的行（如所选地区暂无热映数据）返回空 items，由前端收起。"""
    svc = _service({"movie/now_playing": {"results": [_movie(1), _movie(2)]}})
    row = await svc.discover_row(MediaKind.MOVIE, "now-playing")
    assert row is not None
    assert row.items == []


async def test_unknown_row_returns_none() -> None:
    """row_id 不在布局里返回 None（路由层译为 404），不打 TMDB。"""
    svc = _service({})
    assert await svc.discover_row(MediaKind.MOVIE, "nonexistent") is None
    client: StubTmdbClient = svc._client  # type: ignore[assignment]
    assert client.calls == []


async def test_row_and_hero_are_cached() -> None:
    """行与 Hero 结果有 TTL 缓存：第二次请求不再回源 TMDB。"""
    svc = _service(
        {
            "movie/popular": {"results": [_movie(i) for i in range(1, 8)]},
            "trending/movie/week": {"results": [_movie(i) for i in range(1, 8)]},
        }
    )
    await svc.discover_row(MediaKind.MOVIE, "popular")
    await svc.discover_hero(MediaKind.MOVIE)
    client: StubTmdbClient = svc._client  # type: ignore[assignment]
    calls_after_first = len(client.calls)

    await svc.discover_row(MediaKind.MOVIE, "popular")
    await svc.discover_hero(MediaKind.MOVIE)
    assert len(client.calls) == calls_after_first


def test_p0_dynamic_rows_and_tv_update_rows_have_expected_tmdb_params() -> None:
    """P0 专题必须是可随日期滚动的 discover 查询，今日/本周使用官方端点。"""
    today = date(2026, 8, 15)
    movies = {row.row_id: row for row in _movie_rows("CN", today)}
    assert movies["recent-acclaimed"].params["primary_release_date.gte"] == "2024-08-15"
    assert movies["this-year"].params["primary_release_year"] == 2026
    assert movies["short-runtime"].params["with_runtime.lte"] == 90

    tv = {row.row_id: row for row in _tv_rows(today, "Asia/Shanghai")}
    assert tv["airing-today"].path == "tv/airing_today"
    assert tv["airing-today"].params["timezone"] == "Asia/Shanghai"
    assert tv["on-the-air"].title == "本周更新"
    assert tv["completed-miniseries"].params["with_type"] == 2
    assert tv["completed-miniseries"].params["with_status"] == 3


def test_invalid_timezone_falls_back_for_tv_row_params() -> None:
    """非法部署时区不仅要让日期可算，还必须把 TMDB 查询参数同步回退。"""
    svc = MediaDiscoverService(
        StubTmdbClient({}),
        image_base_url=_IMAGE_BASE,
        timezone="Invalid/Timezone",
    )

    rows = {row.row_id: row for row in svc._row_specs(MediaKind.TV)}

    assert rows["airing-today"].params["timezone"] == "Asia/Shanghai"


async def test_collection_page_uses_tmdb_native_pagination_and_cache() -> None:
    svc = _service(
        {
            "movie/popular": {
                "page": 2,
                "total_pages": 9,
                "total_results": 171,
                "results": [_movie(i) for i in range(21, 25)],
            }
        }
    )
    page = await svc.discover_page(MediaKind.MOVIE, "popular", 2)
    assert page is not None
    assert (page.page, page.total_pages, page.total_results) == (2, 9, 171)
    client: StubTmdbClient = svc._client  # type: ignore[assignment]
    assert ("movie/popular", {"language": "zh-CN", "page": 2}) in client.calls
    calls_after_first = len(client.calls)
    await svc.discover_page(MediaKind.MOVIE, "popular", 2)
    assert len(client.calls) == calls_after_first


async def test_filtered_discovery_maps_all_six_dimensions() -> None:
    svc = _service(
        {
            "discover/movie": {
                "page": 3,
                "total_pages": 4,
                "total_results": 66,
                "results": [_movie(31)],
            }
        }
    )
    result = await svc.discover_filtered(
        MediaKind.MOVIE,
        genre_ids=[878, 28],
        origin_country="JP",
        year=2025,
        rating_gte=7,
        runtime_lte=90,
        sort="rating",
        page=3,
    )
    assert (result.page, result.total_pages, result.total_results) == (3, 4, 66)
    client: StubTmdbClient = svc._client  # type: ignore[assignment]
    _, params = next(call for call in client.calls if call[0] == "discover/movie")
    assert params["with_genres"] == "878|28"
    assert params["with_origin_country"] == "JP"
    assert params["primary_release_year"] == 2025
    assert params["vote_average.gte"] == 7
    assert params["with_runtime.lte"] == 90
    assert params["sort_by"] == "vote_average.desc"
    assert params["vote_count.gte"] == 50


# ---------------------------------------------------------------------------
# 搜索
# ---------------------------------------------------------------------------


async def test_search_maps_multi_results() -> None:
    """multi 搜索映射：人物条目和缺海报条目剔除；电影/剧集带年份与类型。"""
    svc = _service(
        {
            "search/multi": {
                "results": [
                    {"media_type": "person", "id": 1, "name": "某演员"},
                    _movie(2, media_type="movie"),
                    _movie(3, media_type="movie", poster_path=None),
                    {
                        "media_type": "tv",
                        "id": 4,
                        "name": "剧集4",
                        "first_air_date": "2024-04-01",
                        "vote_average": 8.44,
                        "poster_path": "/tv4.jpg",
                    },
                    {
                        "media_type": "tv",
                        "id": 5,
                        "name": "未定档剧集",
                        "first_air_date": "",
                        "poster_path": "/tv5.jpg",
                    },
                ]
            }
        }
    )
    items = await svc.search("测试")

    assert [i.id for i in items] == ["2", "4", "5"]
    movie = items[0]
    assert movie.source == "tmdb"
    assert movie.type == MediaKind.MOVIE
    assert movie.year == 2026
    assert movie.poster_url == f"{_IMAGE_BASE}/w342/p2.jpg"
    tv = items[1]
    assert tv.type == MediaKind.TV
    assert tv.rating == 8.4
    assert items[2].year is None  # 无首播日期不伪造年份


async def test_search_is_cached() -> None:
    """相同关键词（忽略首尾空白与大小写）十分钟内不重复回源。"""
    svc = _service({"search/multi": {"results": [_movie(1, media_type="movie")]}})
    await svc.search("Dune")
    client: StubTmdbClient = svc._client  # type: ignore[assignment]
    calls_after_first = len(client.calls)

    await svc.search(" dune ")
    assert len(client.calls) == calls_after_first


# ---------------------------------------------------------------------------
# 影人作品
# ---------------------------------------------------------------------------


async def test_person_detail_keeps_and_deduplicates_all_tmdb_credits() -> None:
    """参演与幕后履历合并去重；缺海报/日期的作品仍属于“全部作品”。"""
    movie = _movie(10, media_type="movie", release_date="2025-03-01")
    tv_without_artwork = {
        "id": 20,
        "media_type": "tv",
        "name": "未定档剧集",
        "original_name": "Coming Soon",
        "first_air_date": "",
        "poster_path": None,
        "genre_ids": [16],
        "vote_average": 8.24,
    }
    svc = _service(
        {
            "person/9340": {
                "id": 9340,
                "name": "示例影人",
                "profile_path": "/person.jpg",
                "combined_credits": {
                    "cast": [movie, tv_without_artwork],
                    # 同一部电影既参演又执导只展示一次；其他幕后岗位同样纳入履历。
                    "crew": [
                        {**movie, "job": "Director"},
                        _movie(30, media_type="movie", release_date="2024-01-01"),
                    ],
                },
            }
        }
    )

    detail = await svc.person_detail(9340)

    assert detail.name == "示例影人"
    assert detail.avatar_url == f"{_IMAGE_BASE}/w300/person.jpg"
    assert [(card.type.value, card.id) for card in detail.credits] == [
        ("movie", "10"),
        ("movie", "30"),
        ("tv", "20"),
    ]
    assert detail.credits[0].genres == ["科幻", "动作"]
    assert detail.credits[-1].year == 0
    assert detail.credits[-1].poster_url == ""

    client: StubTmdbClient = svc._client  # type: ignore[assignment]
    calls_after_first = len(client.calls)
    await svc.person_detail(9340)
    assert len(client.calls) == calls_after_first


# ---------------------------------------------------------------------------
# 条目详情
# ---------------------------------------------------------------------------

_MOVIE_DETAIL = {
    **_movie(603),
    "genres": [{"id": 878, "name": "科幻"}],
    "genre_ids": None,
    "runtime": 136,
    "original_language": "en",
    "production_countries": [{"iso_3166_1": "US", "name": "United States of America"}],
    "credits": {
        "crew": [
            {
                "id": 9340,
                "name": "莉莉·沃卓斯基",
                "job": "Director",
                "profile_path": "/director.jpg",
            },
            {"name": "某制片", "job": "Producer"},
        ],
        # 演职员：带头像与角色名，且刻意给一个缺 profile_path 的人（头像取不到
        # 也必须保留——名字与角色本身就是信息）
        "cast": [
            {"name": f"演员{i}", "character": f"角色{i}", "profile_path": f"/p{i}.jpg"}
            for i in range(8)
        ]
        + [{"name": "无头像演员", "character": "路人"}],
    },
    "images": {
        "backdrops": [
            {"file_path": f"/bd{i}.jpg", "width": 3840, "height": 2160, "iso_639_1": None}
            for i in range(25)
        ],
        "posters": [
            {"file_path": "/p-en.jpg", "width": 2000, "height": 3000, "iso_639_1": "en"},
            {"file_path": "/p-null.jpg", "width": 2000, "height": 3000, "iso_639_1": None},
            {"file_path": "/p-zh.jpg", "width": 2000, "height": 3000, "iso_639_1": "zh"},
        ],
    },
    "recommendations": {"results": [_movie(i) for i in range(700, 715)]},
}


async def test_movie_detail_fields() -> None:
    svc = _service({"movie/603": _MOVIE_DETAIL})
    detail = await svc.media_detail(MediaKind.MOVIE, 603)

    assert detail.card.extent == "136 分钟"
    assert detail.facts.directors == ["莉莉·沃卓斯基"]
    assert detail.facts.director_credits[0].avatar_url == (
        f"{_IMAGE_BASE}/w185/director.jpg"
    )
    assert detail.facts.director_credits[0].tmdb_person_id == 9340
    # 演职员条：按 TMDB 给的主次顺序整段带回（上限 16），姓名/角色/头像齐全
    assert len(detail.facts.cast) == 9
    assert detail.facts.cast[0].name == "演员0"
    assert detail.facts.cast[0].role == "角色0"
    assert detail.facts.cast[0].avatar_url == f"{_IMAGE_BASE}/w185/p0.jpg"
    # 缺 profile_path 的人保留，头像为空由前端渲染占位
    assert detail.facts.cast[-1].name == "无头像演员"
    assert detail.facts.cast[-1].avatar_url is None
    assert detail.facts.country == "美国"
    assert detail.facts.language == "英语"
    assert detail.facts.network is None
    assert len(detail.related) == 10  # 相似推荐截断到 10 部


async def test_movie_detail_loads_and_orders_full_collection() -> None:
    detail_response = {
        **_MOVIE_DETAIL,
        "belongs_to_collection": {"id": 2344, "name": "矩阵系列"},
    }
    svc = _service(
        {
            "movie/603": detail_response,
            "collection/2344": {
                "id": 2344,
                "name": "黑客帝国系列",
                "parts": [
                    _movie(605, release_date="2003-11-05"),
                    _movie(603, release_date="1999-03-30"),
                    _movie(604, release_date="2003-05-15"),
                ],
            },
        }
    )
    detail = await svc.media_detail(MediaKind.MOVIE, 603)
    assert detail.collection is not None
    assert detail.collection.name == "黑客帝国系列"
    assert [card.id for card in detail.collection.items] == ["603", "604", "605"]


async def test_detail_images_mapping() -> None:
    """图片集映射：剧照截断到 20 张、预览/原图两档 URL；海报中文版排最前。"""
    svc = _service({"movie/603": _MOVIE_DETAIL})
    detail = await svc.media_detail(MediaKind.MOVIE, 603)

    assert len(detail.backdrops) == 20
    first = detail.backdrops[0]
    assert first.preview_url == f"{_IMAGE_BASE}/w780/bd0.jpg"
    assert first.full_url == f"{_IMAGE_BASE}/original/bd0.jpg"
    assert (first.width, first.height) == (3840, 2160)

    # 配置语言（zh）的海报置顶，其余保持 TMDB 原序
    assert [p.preview_url.rsplit("/", 1)[-1] for p in detail.posters] == [
        "p-zh.jpg",
        "p-en.jpg",
        "p-null.jpg",
    ]
    assert detail.posters[0].preview_url.startswith(f"{_IMAGE_BASE}/w342/")


async def test_detail_videos_filtered_and_ordered() -> None:
    """预告片：只留 YouTube 的可用类型，按「类型 → 官方 → 发布时间倒序」排。"""
    svc = _service(
        {
            "movie/603": {
                **_MOVIE_DETAIL,
                "videos": {
                    "results": [
                        {"key": "f1", "name": "Featurette", "site": "YouTube",
                         "type": "Featurette", "official": True, "published_at": "2026-01-01"},
                        {"key": "t-old", "name": "Trailer 1", "site": "YouTube",
                         "type": "Trailer", "official": True, "published_at": "2025-11-01"},
                        {"key": "t-new", "name": "Trailer 2", "site": "YouTube",
                         "type": "Trailer", "official": True, "published_at": "2025-12-20"},
                        {"key": "t-fan", "name": "粉丝自制", "site": "YouTube",
                         "type": "Trailer", "official": False, "published_at": "2026-02-01"},
                        {"key": "teaser", "name": "", "site": "YouTube",
                         "type": "Teaser", "official": True, "published_at": "2025-08-01"},
                        # 非 YouTube 与无价值类型都不进列表
                        {"key": "vimeo", "name": "Vimeo 版", "site": "Vimeo",
                         "type": "Trailer", "official": True, "published_at": "2026-03-01"},
                        {"key": "recap", "name": "前情提要", "site": "YouTube",
                         "type": "Recap", "official": True, "published_at": "2026-03-01"},
                    ]
                },
            }
        }
    )
    detail = await svc.media_detail(MediaKind.MOVIE, 603)

    assert [v.key for v in detail.videos] == ["t-new", "t-old", "t-fan", "teaser", "f1"]
    first = detail.videos[0]
    assert first.kind == "预告片"
    assert first.thumbnail_url == "https://i.ytimg.com/vi/t-new/hqdefault.jpg"
    assert first.embed_url == "https://www.youtube-nocookie.com/embed/t-new"
    assert first.watch_url == "https://www.youtube.com/watch?v=t-new"
    # name 为空的条目用类型标签兜底，卡片上不会出现无名视频
    assert detail.videos[3].name == "先导预告"


async def test_detail_requests_multilingual_videos() -> None:
    """必须显式放开视频语言：只要 zh-CN 的话绝大多数影片一条预告都没有。"""
    client = StubTmdbClient({"genre/movie/list": _GENRES, "movie/603": _MOVIE_DETAIL})
    svc = MediaDiscoverService(client, image_base_url=_IMAGE_BASE)
    await svc.media_detail(MediaKind.MOVIE, 603)

    params = next(params for path, params in client.calls if path == "movie/603")
    assert "videos" in params["append_to_response"]
    assert params["include_video_language"] == "zh,en,null"


async def test_detail_carries_english_title_from_translations() -> None:
    """「搜索资源」要拿英文名同搜：译名随详情同一次请求带回（不多打一次 TMDB）。
    韩语片的原名是韩文，英文名只能从译名里取。"""
    detail_response = {
        **_MOVIE_DETAIL,
        "original_title": "악인전",
        "original_language": "ko",
        "translations": {
            "translations": [
                {"iso_639_1": "zh", "iso_3166_1": "CN", "data": {"title": "恶人传"}},
                {
                    "iso_639_1": "en",
                    "iso_3166_1": "US",
                    "data": {"title": "The Gangster, the Cop, the Devil"},
                },
            ]
        },
    }
    client = StubTmdbClient({"genre/movie/list": _GENRES, "movie/603": detail_response})
    svc = MediaDiscoverService(client, image_base_url=_IMAGE_BASE)
    detail = await svc.media_detail(MediaKind.MOVIE, 603)

    assert detail.facts.english_title == "The Gangster, the Cop, the Devil"
    params = next(params for path, params in client.calls if path == "movie/603")
    assert "translations" in params["append_to_response"].split(",")
    assert sum(1 for path, _ in client.calls if path == "movie/603") == 1


async def test_detail_without_translations_has_no_english_title() -> None:
    svc = _service({"movie/603": _MOVIE_DETAIL})
    detail = await svc.media_detail(MediaKind.MOVIE, 603)
    assert detail.facts.english_title is None


async def test_detail_without_videos_is_empty() -> None:
    """上游没有 videos 字段（豆瓣来源、老缓存）时安静返回空列表。"""
    svc = _service({"movie/603": _MOVIE_DETAIL})
    detail = await svc.media_detail(MediaKind.MOVIE, 603)
    assert detail.videos == []


async def test_tv_detail_fields() -> None:
    tv_detail = {
        "id": 1399,
        "name": "剧集X",
        "original_name": "Show X",
        "first_air_date": "2024-04-01",
        "vote_average": 8.4,
        "genres": [{"id": 16, "name": "动画"}],
        "poster_path": "/tv.jpg",
        "backdrop_path": "/tvb.jpg",
        "overview": "剧集简介",
        "number_of_seasons": 3,
        "original_language": "ja",
        "origin_country": ["JP"],
        "created_by": [
            {"id": 42, "name": "主创A", "profile_path": "/creator.jpg"}
        ],
        "networks": [{"name": "TV Tokyo"}],
        "credits": {"cast": [{"name": "声优1"}]},
        "recommendations": {"results": []},
    }
    svc = _service({"tv/1399": tv_detail})
    detail = await svc.media_detail(MediaKind.TV, 1399)

    assert detail.card.extent == "3 季"
    assert detail.card.year == 2024
    assert detail.facts.directors == ["主创A"]
    assert detail.facts.director_credits[0].avatar_url == (
        f"{_IMAGE_BASE}/w185/creator.jpg"
    )
    assert detail.facts.director_credits[0].tmdb_person_id == 42
    assert detail.facts.country == "日本"
    assert detail.facts.language == "日语"
    assert detail.facts.network == "TV Tokyo"

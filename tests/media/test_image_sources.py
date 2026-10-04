"""多来源选图（TMDB + Fanart.tv）的规则测试（docs/design/image-sources.md）。

核心规则：**先看语言，再看来源**——逐档找第一个有图的语言，同一档两个来源
都有图时才按各类图的来源顺序挑；没启用 Fanart 时结果与只用 TMDB 逐张一致。
TMDB 与 Fanart 都用 MockTransport 假装，不出网。
"""

from __future__ import annotations

import httpx

from movieclaw_media.fanart import FanartClient
from movieclaw_media.library import (
    ImagePrefs,
    fetch_media_profile,
    list_image_candidates,
    list_logo_candidates,
    pick_logo,
)
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_FA = "https://assets.fanart.tv/fanart"


def _img(path: str, lang: str | None, width: int = 2000, avg: float = 7.0, count: int = 50) -> dict:
    return {
        "file_path": path,
        "iso_639_1": lang,
        "width": width,
        "height": int(width * 1.5),
        "vote_average": avg,
        "vote_count": count,
    }


def _fa(kind: str, name: str, lang: str, likes: int = 1, **extra: str) -> dict:
    return {"id": name, "url": f"{_FA}/{kind}/{name}", "lang": lang, "likes": str(likes), **extra}


def _tmdb(routes: dict[str, dict], seen: list[httpx.Request] | None = None) -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request)
        payload = routes.get(request.url.path)
        return httpx.Response(200, json=payload) if payload is not None else httpx.Response(404)

    return TmdbClient("0" * 32, transport=httpx.MockTransport(handler))


def _fanart(routes: dict[str, dict | int], seen: list[str] | None = None) -> FanartClient:
    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request.url.path)
        payload = routes.get(request.url.path)
        if isinstance(payload, int):
            return httpx.Response(payload, json={"error": "x"})
        return httpx.Response(200, json=payload) if payload is not None else httpx.Response(404)

    return FanartClient("f" * 32, transport=httpx.MockTransport(handler), max_attempts=1)


def _movie(**overrides) -> dict:  # noqa: ANN003
    detail = {
        "id": 842675,
        "title": "流浪地球2",
        "original_title": "流浪地球2",
        "original_language": "zh",
        "release_date": "2023-01-22",
        "poster_path": "/tmdb-zh.jpg",
        "backdrop_path": "/tmdb-bg.jpg",
        "external_ids": {"imdb_id": "tt13539646"},
        "images": {
            "posters": [_img("/tmdb-zh.jpg", "zh"), _img("/tmdb-en.jpg", "en", avg=9, count=900)],
            "backdrops": [_img("/tmdb-bg.jpg", None, width=3840)],
            "logos": [_img("/tmdb-en.png", "en", width=800)],
        },
    }
    detail.update(overrides)
    return detail


_MOVIE_FA = {
    "hdmovielogo": [_fa("movies/842675/hdmovielogo", "zh.png", "zh", 7)],
    "movieposter": [_fa("movies/842675/movieposter", "zh.jpg", "zh", 9)],
    "moviebackground": [_fa("movies/842675/moviebackground", "bg.jpg", "", 6)],
}


async def _profile(detail: dict, fanart_payload, prefs: ImagePrefs | None = None, **kw):  # noqa: ANN001, ANN003, ANN202
    tmdb = _tmdb({"/3/movie/842675": detail})
    fanart = _fanart({"/v3/movies/842675": fanart_payload}) if fanart_payload is not None else None
    return await fetch_media_profile(
        tmdb, MediaKind.MOVIE, 842675, image_prefs=prefs, fanart=fanart, **kw
    )


async def test_without_fanart_results_are_unchanged() -> None:
    """不传 Fanart：与历史行为一致（海报 TMDB 默认、Logo 只能是英文的那张）。"""
    profile = await _profile(_movie(), None)
    assert profile.poster_path == "/tmdb-zh.jpg"
    assert profile.backdrop_path == "/tmdb-bg.jpg"
    assert profile.logo_path == "/tmdb-en.png"
    assert profile.fanart_failed is False


async def test_language_beats_source_order_for_logo() -> None:
    """Logo 来源顺序哪怕把 TMDB 排第一，中文档 TMDB 没有、Fanart 有 → 取 Fanart 中文。"""
    prefs = ImagePrefs(logo_sources=("tmdb", "fanart"))
    profile = await _profile(_movie(), _MOVIE_FA, prefs)
    assert profile.logo_path == f"{_FA}/movies/842675/hdmovielogo/zh.png"


async def test_same_tier_follows_source_order() -> None:
    """同一档语言两边都有：按来源顺序。海报（按语言模式）中文档两边都有。"""
    tmdb_first = ImagePrefs(poster_mode="language", poster_sources=("tmdb", "fanart"))
    fanart_first = ImagePrefs(poster_mode="language", poster_sources=("fanart", "tmdb"))
    assert (await _profile(_movie(), _MOVIE_FA, tmdb_first)).poster_path == "/tmdb-zh.jpg"
    assert (
        await _profile(_movie(), _MOVIE_FA, fanart_first)
    ).poster_path == f"{_FA}/movies/842675/movieposter/zh.jpg"


async def test_default_poster_mode_tmdb_only_offers_its_designated_poster() -> None:
    """「TMDB 默认」：TMDB 只拿出指定的那张参与比较。

    指定的是英文海报、Fanart 有中文 → 中文档先命中 → Fanart；
    指定的是中文海报 → 同档按来源顺序（默认 TMDB 在前）→ 仍是 TMDB 那张。
    """
    en_designated = _movie(poster_path="/tmdb-en.jpg")
    profile = await _profile(en_designated, _MOVIE_FA, ImagePrefs())
    assert profile.poster_path == f"{_FA}/movies/842675/movieposter/zh.jpg"
    profile = await _profile(_movie(), _MOVIE_FA, ImagePrefs())
    assert profile.poster_path == "/tmdb-zh.jpg"


async def test_default_poster_mode_unchanged_when_fanart_has_no_better_language() -> None:
    """Fanart 只有英文海报、TMDB 指定中文：结果与只用 TMDB 完全一样。"""
    payload = {"movieposter": [_fa("movies/842675/movieposter", "en.jpg", "en", 50)]}
    profile = await _profile(_movie(), payload, ImagePrefs(poster_sources=("fanart", "tmdb")))
    assert profile.poster_path == "/tmdb-zh.jpg"


async def test_width_threshold_applies_across_sources() -> None:
    """背景无文字档里 TMDB 排前但只有 1280 宽、Fanart 1920 达标 → 取 Fanart。"""
    detail = _movie(images={"backdrops": [_img("/small.jpg", None, width=1280, avg=9, count=900)]})
    profile = await _profile(detail, _MOVIE_FA, ImagePrefs())
    assert profile.backdrop_path == f"{_FA}/movies/842675/moviebackground/bg.jpg"


async def test_fanart_not_found_keeps_tmdb_and_is_not_failure() -> None:
    """Fanart 上没有这部片（404）不算失败：只用 TMDB，不标记 fanart_failed。"""
    tmdb = _tmdb({"/3/movie/842675": _movie()})
    profile = await fetch_media_profile(
        tmdb, MediaKind.MOVIE, 842675, fanart=_fanart({}), image_prefs=ImagePrefs()
    )
    assert profile.logo_path == "/tmdb-en.png"
    assert profile.fanart_failed is False


async def test_fanart_failure_falls_back_and_flags() -> None:
    """Fanart 出错（5xx/401/网络）不阻断档案：只用 TMDB 选图并标记 fanart_failed。"""
    tmdb = _tmdb({"/3/movie/842675": _movie()})
    for status in (500, 401):
        profile = await fetch_media_profile(
            tmdb, MediaKind.MOVIE, 842675, fanart=_fanart({"/v3/movies/842675": status})
        )
        assert profile.logo_path == "/tmdb-en.png"
        assert profile.fanart_failed is True


async def test_logo_language_priority_is_configurable() -> None:
    """片名 Logo 卡：只要无文字 → 中英文 Logo 都不要，结果为空串（显示文字标题）。"""
    profile = await _profile(_movie(), _MOVIE_FA, ImagePrefs(logo_langs=("null",)))
    assert profile.logo_path == ""
    # 把英文排第一：TMDB 英文 Logo 胜出
    profile = await _profile(_movie(), _MOVIE_FA, ImagePrefs(logo_langs=("en", "meta")))
    assert profile.logo_path == "/tmdb-en.png"


_TV_DETAIL = {
    "id": 204541,
    "name": "三体",
    "original_name": "三体",
    "original_language": "zh",
    "first_air_date": "2023-01-15",
    "poster_path": "/tv.jpg",
    "external_ids": {"imdb_id": "tt20242042", "tvdb_id": 421477},
    "images": {"posters": [_img("/tv.jpg", "en")], "logos": []},
    "seasons": [{"season_number": 1}],
}
_TV_FA = {
    "hdtvlogo": [_fa("tv/421477/hdtvlogo", "zh.png", "zh", 5)],
    "seasonposter": [
        _fa("tv/421477/seasonposter", "s1-zh.jpg", "zh", 4, season="1"),
        _fa("tv/421477/seasonposter", "all.jpg", "zh", 9, season="all"),
    ],
}


async def test_tv_uses_tvdb_id_and_picks_season_posters() -> None:
    """剧集按 TVDB 编号查 Fanart；季海报 TMDB 只有英文、Fanart 有中文 → 中文。

    启用 Fanart 时季详情顺带拉季海报候选（append_to_response=images，同一请求）。
    """
    tmdb_seen: list[httpx.Request] = []
    fa_seen: list[str] = []
    tmdb = _tmdb(
        {
            "/3/tv/204541": _TV_DETAIL,
            "/3/tv/204541/season/1": {
                "name": "第 1 季",
                "poster_path": "/s1-en.jpg",
                "episodes": [],
                "images": {"posters": [_img("/s1-en.jpg", "en", width=1000)]},
            },
        },
        tmdb_seen,
    )
    fanart = _fanart({"/v3/tv/421477": _TV_FA}, fa_seen)
    profile = await fetch_media_profile(tmdb, MediaKind.TV, 204541, fanart=fanart)

    assert fa_seen == ["/v3/tv/421477"]
    assert profile.logo_path == f"{_FA}/tv/421477/hdtvlogo/zh.png"
    assert profile.seasons[0].poster_path == f"{_FA}/tv/421477/seasonposter/s1-zh.jpg"
    season_request = next(r for r in tmdb_seen if r.url.path.endswith("/season/1"))
    assert season_request.url.params["append_to_response"] == "images"
    # 海报（TMDB 默认指定英文）vs Fanart 没有剧集海报 → 不变
    assert profile.poster_path == "/tv.jpg"


async def test_tv_without_tvdb_id_skips_fanart() -> None:
    fa_seen: list[str] = []
    detail = {**_TV_DETAIL, "external_ids": {"imdb_id": None}}
    tmdb = _tmdb({"/3/tv/204541": detail, "/3/tv/204541/season/1": {"episodes": []}})
    profile = await fetch_media_profile(tmdb, MediaKind.TV, 204541, fanart=_fanart({}, fa_seen))
    assert fa_seen == []
    assert profile.fanart_failed is False


async def test_season_requests_unchanged_without_fanart() -> None:
    """不启用 Fanart 时季详情请求与历史一致（不追加 images）。"""
    seen: list[httpx.Request] = []
    tmdb = _tmdb({"/3/tv/204541": _TV_DETAIL, "/3/tv/204541/season/1": {"episodes": []}}, seen)
    await fetch_media_profile(tmdb, MediaKind.TV, 204541)
    season_request = next(r for r in seen if r.url.path.endswith("/season/1"))
    assert "append_to_response" not in season_request.url.params


def test_candidates_mix_sources_and_lead_with_auto_pick() -> None:
    """换图弹层：Fanart 候选混入同一列表，首张就是自动规则会选的那张。"""
    from movieclaw_media.fanart import parse_movie_images

    fanart = parse_movie_images(_MOVIE_FA)
    data = {"images": _movie()["images"]}
    posters, backdrops = list_image_candidates(
        data,
        ["zh", "en", None],
        [None, "zh", "en"],
        fanart=fanart,
        poster_sources=("fanart", "tmdb"),
        backdrop_sources=("tmdb", "fanart"),
    )
    assert posters[0]["file_path"] == f"{_FA}/movies/842675/movieposter/zh.jpg"
    assert posters[1]["file_path"] == "/tmdb-zh.jpg"
    assert [b["file_path"] for b in backdrops] == [
        "/tmdb-bg.jpg",
        f"{_FA}/movies/842675/moviebackground/bg.jpg",
    ]
    kwargs = {
        "primary_language": "zh-CN",
        "original_language": "zh",
        "extra": fanart.logos,
        "sources": ("fanart", "tmdb"),
    }
    logos = list_logo_candidates(data, **kwargs)
    assert logos[0]["file_path"] == pick_logo(data, **kwargs)
    assert {logo.get("source", "tmdb") for logo in logos} == {"tmdb", "fanart"}

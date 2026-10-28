"""刮削时顺手存下的界面语言译文（docs/design/content-locale.md §4.1）：零额外请求、只存非主语种。"""

from __future__ import annotations

import httpx

from movieclaw_media.library import fetch_media_profile
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"


def _client(detail: dict, captured: list[httpx.Request]) -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        if request.url.path.endswith("/movie/95396") or request.url.path.endswith("/movie/1"):
            return httpx.Response(200, json=detail)
        return httpx.Response(404, json={})

    return TmdbClient(_KEY, transport=httpx.MockTransport(handler))


def _translation(lang: str, region: str, title: str, overview: str) -> dict:
    return {
        "iso_639_1": lang,
        "iso_3166_1": region,
        "data": {"title": title, "overview": overview, "tagline": ""},
    }


_SEVERANCE = {
    "id": 95396,
    "title": "人生切割术",
    "original_title": "Severance",
    "original_language": "en",
    "release_date": "2022-02-17",
    "overview": "马克领导着一个团队……",
    "translations": {
        "translations": [
            # 原声语言的译文 TMDB 常常不给片名
            _translation("en", "US", "", "Mark leads a team of office workers..."),
            _translation("zh", "CN", "人生切割术", "马克领导着一个团队……"),
            _translation("zh", "TW", "人生切割術", "馬克領導著……"),
            _translation("ja", "JP", "セヴェランス", "マークは……"),
        ]
    },
}


async def test_chinese_library_stores_only_english_and_needs_no_extra_request() -> None:
    captured: list[httpx.Request] = []
    profile = await fetch_media_profile(_client(_SEVERANCE, captured), MediaKind.MOVIE, 95396)

    assert len(captured) == 1  # translations 本来就在那一次详情请求里
    assert "translations" in captured[0].url.params["append_to_response"]
    # 主语言那份不存：中文读者走原列
    assert profile.title_translations == {"en-US": "Severance"}  # 英文片名回落原名
    assert profile.overview_translations == {"en-US": "Mark leads a team of office workers..."}


async def test_english_original_prefers_original_title_over_region_alias() -> None:
    """NAS 实测：《阿凡达》en 译名为空，english_title 回落到 US 别名「…IMAX 3D…」。"""
    captured: list[httpx.Request] = []
    detail = {
        **_SEVERANCE,
        "title": "阿凡达",
        "original_title": "Avatar",
        "alternative_titles": {
            "titles": [{"iso_3166_1": "US", "title": "Avatar: An IMAX 3D Experience"}]
        },
    }
    profile = await fetch_media_profile(_client(detail, captured), MediaKind.MOVIE, 95396)

    assert profile.english_title == "Avatar: An IMAX 3D Experience"  # 召回词的口径不动
    assert profile.title_translations == {"en-US": "Avatar"}


async def test_english_library_stores_simplified_chinese() -> None:
    captured: list[httpx.Request] = []
    detail = {**_SEVERANCE, "title": "Severance", "overview": "Mark leads a team..."}
    profile = await fetch_media_profile(
        _client(detail, captured), MediaKind.MOVIE, 95396, languages=["en-US"]
    )

    assert profile.title == "Severance"
    assert profile.title_translations == {"zh-CN": "人生切割术"}
    assert profile.overview_translations == {"zh-CN": "马克领导着一个团队……"}


async def test_other_primary_language_stores_both_and_skips_empty_fields() -> None:
    captured: list[httpx.Request] = []
    detail = {
        "id": 1,
        "title": "万引き家族",
        "original_title": "万引き家族",
        "original_language": "ja",
        "release_date": "2018-06-02",
        "translations": {
            "translations": [
                _translation("en", "US", "Shoplifters", ""),
                _translation("zh", "CN", "小偷家族", "一家人靠……"),
            ]
        },
    }
    profile = await fetch_media_profile(
        _client(detail, captured), MediaKind.MOVIE, 1, languages=["ja-JP"]
    )

    assert profile.title_translations == {"zh-CN": "小偷家族", "en-US": "Shoplifters"}
    # 英文没有简介就不存这一项，显示时回落原列
    assert profile.overview_translations == {"zh-CN": "一家人靠……"}


async def test_chinese_original_film_uses_original_title_for_chinese() -> None:
    captured: list[httpx.Request] = []
    detail = {
        "id": 1,
        "title": "Hero",
        "original_title": "英雄",
        "original_language": "cn",  # TMDB 的 cn 是粤语
        "release_date": "2002-12-19",
        "translations": {"translations": [_translation("en", "US", "Hero", "")]},
    }
    profile = await fetch_media_profile(
        _client(detail, captured), MediaKind.MOVIE, 1, languages=["en-US"]
    )

    assert profile.title_translations == {"zh-CN": "英雄"}
    assert profile.overview_translations == {}

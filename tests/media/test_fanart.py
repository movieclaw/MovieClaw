"""Fanart.tv 客户端与响应归一化（MockTransport，不出网）。

载荷按 Fanart v3 的真实形态构造（2026-10-04 用真实 Key 抓取核对）：likes 是
字符串、"无语言"有 "" / "00" / "xx" 三种写法、带 *_count 计数字段、图床地址
是扁平的 /fanart/<名字>-<哈希>、有 4K 背景类型、季图的 season 可能是 "all"、
查无此条目回 200 {}、Key 无效回 401。
"""

from __future__ import annotations

import httpx
import pytest

from movieclaw_media.fanart import (
    FanartAuthError,
    FanartClient,
    FanartNetworkError,
    fanart_preview_url,
    is_absolute_image,
    is_fanart_asset,
    parse_movie_images,
    parse_tv_images,
)

_ASSET = "https://assets.fanart.tv/fanart/movies/842675"

MOVIE_PAYLOAD = {
    "name": "The Wandering Earth II",
    "tmdb_id": "842675",
    "imdb_id": "tt13539646",
    "hdmovielogo": [
        {"id": "1", "url": f"{_ASSET}/hdmovielogo/zh-a.png", "lang": "zh", "likes": "7"},
        {"id": "2", "url": f"{_ASSET}/hdmovielogo/en-a.png", "lang": "en", "likes": "4"},
    ],
    "movielogo": [
        {"id": "3", "url": f"{_ASSET}/movielogo/sd.png", "lang": "zh", "likes": "9"},
    ],
    "movieposter": [
        {"id": "4", "url": f"{_ASSET}/movieposter/p.jpg", "lang": "zh", "likes": "2"},
        {"id": "5", "url": f"{_ASSET}/movieposter/p00.jpg", "lang": "00", "likes": "0"},
    ],
    "moviebackground": [
        # 老图：http 地址、语言空串
        {"id": "6", "url": "http://assets.fanart.tv/fanart/movies/842675/bg.jpg", "lang": ""},
        {"id": "7", "url": f"{_ASSET}/moviebackground/xx.jpg", "lang": "xx", "likes": "x"},
    ],
    # 一期不用的类型：不该出现在归一化结果里
    "moviedisc": [
        {"id": "8", "url": f"{_ASSET}/moviedisc/d.png", "lang": "en", "disc": "1"},
    ],
}

TV_PAYLOAD = {
    "name": "Three-Body",
    "thetvdb_id": "421477",
    "clearlogo": [
        {
            "id": "1",
            "url": "https://assets.fanart.tv/fanart/tv/421477/clearlogo/sd.png",
            "lang": "zh",
        },
    ],
    "tvposter": [
        {
            "id": "2",
            "url": "https://assets.fanart.tv/fanart/tv/421477/tvposter/a.jpg",
            "lang": "zh",
        },
    ],
    "seasonposter": [
        {
            "id": "3",
            "url": "https://assets.fanart.tv/fanart/tv/421477/seasonposter/s1.jpg",
            "lang": "zh",
            "likes": "4",
            "season": "1",
        },
        {
            "id": "4",
            "url": "https://assets.fanart.tv/fanart/tv/421477/seasonposter/all.jpg",
            "lang": "zh",
            "season": "all",
        },
        {
            "id": "5",
            "url": "https://assets.fanart.tv/fanart/tv/421477/seasonposter/s0.jpg",
            "lang": "en",
            "season": "0",
        },
    ],
}


def test_parse_movie_normalizes_language_likes_and_scheme() -> None:
    images = parse_movie_images(MOVIE_PAYLOAD)

    # HD Logo 有就只收 HD，SD 的 movielogo 不混进来（哪怕它点赞更多）
    assert [logo["file_path"].rsplit("/", 1)[-1] for logo in images.logos] == [
        "zh-a.png",
        "en-a.png",
    ]
    assert images.logos[0] == {
        "file_path": f"{_ASSET}/hdmovielogo/zh-a.png",
        "iso_639_1": "zh",
        "width": 800,
        "height": 310,
        "likes": 7,
        "source": "fanart",
    }
    # "00" / "" / "xx" 一律是无文字
    assert [p["iso_639_1"] for p in images.posters] == ["zh", None]
    assert [b["iso_639_1"] for b in images.backdrops] == [None, None]
    # http 升级为 https；likes 缺失或不是数字按 0
    assert images.backdrops[0]["file_path"].startswith("https://assets.fanart.tv/")
    assert [b["likes"] for b in images.backdrops] == [0, 0]
    assert images.backdrops[0]["width"] == 1920
    assert images.season_posters == {}


# 真实响应节选：《沙丘2》（/v3/movies/693134，2026-10-04 抓取，各类型取一张）
REAL_DUNE2 = {
    "name": "Dune: Part Two",
    "tmdb_id": "693134",
    "imdb_id": "tt15239678",
    "hdmovielogo_count": 12,
    "hdmovielogo": [
        {
            "id": "1",
            "url": "https://assets.fanart.tv/fanart/dune-part-two-64c938b8900a4.png",
            "lang": "zh",
            "likes": "8",
        }
    ],
    "movie4kbackground": [
        {
            "id": "2",
            "url": "https://assets.fanart.tv/fanart/dune-part-two-68c3617c112d0.jpg",
            "lang": "",
            "likes": "1",
        }
    ],
    "moviebackground": [
        {
            "id": "3",
            "url": "https://assets.fanart.tv/fanart/dune-part-two-65e4938b96898.jpg",
            "lang": "",
            "likes": "7",
        }
    ],
    "movieposter": [
        {
            "id": "4",
            "url": "https://assets.fanart.tv/fanart/dune-part-two-65b3898423285.jpg",
            "lang": "00",
            "likes": "6",
        }
    ],
}


def test_parse_real_response_shape() -> None:
    """真实响应：扁平图床地址原样保留、4K 背景按 3840 宽收进背景候选、计数字段忽略。"""
    images = parse_movie_images(REAL_DUNE2)
    assert [b["width"] for b in images.backdrops] == [3840, 1920]
    assert images.backdrops[0]["file_path"].endswith("dune-part-two-68c3617c112d0.jpg")
    assert images.logos[0]["iso_639_1"] == "zh" and images.logos[0]["likes"] == 8
    assert images.posters[0]["iso_639_1"] is None
    assert fanart_preview_url(images.logos[0]["file_path"]) == (
        "https://assets.fanart.tv/preview/dune-part-two-64c938b8900a4.png"
    )


async def test_client_empty_object_means_no_images() -> None:
    """查无此条目：Fanart 实测回 200 {}，归一化为空图集（不是错误）。"""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={})

    images = await _fanart(handler).movie_images(99999999)
    assert images is not None and images.is_empty()


def test_parse_movie_falls_back_to_sd_logo() -> None:
    images = parse_movie_images({"movielogo": MOVIE_PAYLOAD["movielogo"]})
    assert len(images.logos) == 1
    assert images.logos[0]["width"] == 400


def test_parse_tv_groups_season_posters_and_skips_all() -> None:
    images = parse_tv_images(TV_PAYLOAD)
    assert sorted(images.season_posters) == [0, 1]
    assert images.season_posters[1][0]["likes"] == 4
    # 没有 HD 的剧集 Logo 时收 SD clearlogo
    assert images.logos[0]["width"] == 400
    assert images.posters[0]["iso_639_1"] == "zh"


def test_url_helpers() -> None:
    url = "https://assets.fanart.tv/fanart/movies/1/movieposter/a.jpg"
    assert fanart_preview_url(url) == "https://assets.fanart.tv/preview/movies/1/movieposter/a.jpg"
    assert is_absolute_image(url) and is_fanart_asset(url)
    assert not is_absolute_image("/abc.jpg")
    assert not is_fanart_asset("https://evil.example/a.jpg")
    assert not is_absolute_image(None)


def _fanart(handler, **kwargs) -> FanartClient:  # noqa: ANN001
    return FanartClient("k" * 32, transport=httpx.MockTransport(handler), **kwargs)


async def test_client_fetches_movie_by_tmdb_id_with_api_key() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=MOVIE_PAYLOAD)

    images = await _fanart(handler).movie_images(842675)
    assert images is not None and len(images.posters) == 2
    assert seen[0].url.path == "/v3/movies/842675"
    # Key 走请求头，不进 URL（httpx 的请求日志会打出完整 URL）
    assert seen[0].headers["api-key"] == "k" * 32
    assert "api_key" not in seen[0].url.params


async def test_client_tv_uses_tvdb_id() -> None:
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.url.path)
        return httpx.Response(200, json=TV_PAYLOAD)

    images = await _fanart(handler).tv_images(421477)
    assert images is not None and 1 in images.season_posters
    assert seen == ["/v3/tv/421477"]


async def test_client_not_found_returns_none() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"status": "error", "error message": "Not found"})

    assert await _fanart(handler).movie_images(1) is None


async def test_client_error_status_in_body_returns_none() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"status": "error", "error message": "Not found"})

    assert await _fanart(handler).movie_images(1) is None


async def test_client_401_raises_and_notifies() -> None:
    calls: list[int] = []

    async def on_auth_failure() -> None:
        calls.append(1)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"error": "invalid API key"})

    client = _fanart(handler, on_auth_failure=on_auth_failure)
    with pytest.raises(FanartAuthError):
        await client.movie_images(550)
    assert calls == [1]
    # 设置页主动验证：只反馈给表单，不触发「标记失效」回调
    with pytest.raises(FanartAuthError):
        await client.verify()
    assert calls == [1]


async def test_client_network_error_is_translated() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("boom", request=request)

    client = _fanart(handler, max_attempts=1)
    with pytest.raises(FanartNetworkError) as exc_info:
        await client.movie_images(550)
    assert "网络与代理" in str(exc_info.value)

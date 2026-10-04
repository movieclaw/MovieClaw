"""代码审查发现的问题的回归测试（docs/design/image-sources.md §3「稳健性」）。

每条对应一个曾经存在的缺陷：旧 Key 晚到的 401 误伤新 Key、HD Logo 存在时丢掉
只有 SD 版的中文 Logo、Fanart 熔断连带 TMDB 图片下载、换图弹层被 TMDB 异常拖垮、
换 Key 后旧客户端被关闭、季详情失败留下无人等待的 Fanart 任务。
"""

from __future__ import annotations

import asyncio

import httpx
import pytest

import movieclaw_api.services.fanart as fanart_mod
from movieclaw_api.settings import FanartSetting
from movieclaw_media.fanart import FanartClient, FanartError, parse_movie_images
from movieclaw_media.library import fetch_media_profile
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient, TmdbError
from movieclaw_net import egress_transport, get_breaker, reset_all_breakers

_FA = "https://assets.fanart.tv/fanart"


def test_sd_logo_kept_for_languages_without_hd() -> None:
    """HD 只有英文、中文只有 SD 版：中文 SD 照收（语言先于清晰度），英文 SD 不收。"""
    images = parse_movie_images(
        {
            "hdmovielogo": [{"id": "1", "url": f"{_FA}/hd-en.png", "lang": "en", "likes": "3"}],
            "movielogo": [
                {"id": "2", "url": f"{_FA}/sd-zh.png", "lang": "zh", "likes": "1"},
                {"id": "3", "url": f"{_FA}/sd-en.png", "lang": "en", "likes": "9"},
            ],
        }
    )
    assert [(logo["iso_639_1"], logo["width"]) for logo in images.logos] == [
        ("en", 800),
        ("zh", 400),
    ]


async def test_late_401_of_old_key_does_not_invalidate_new_key(monkeypatch) -> None:
    """换 Key 的瞬间旧 Key 的请求晚到 401：不能把刚保存的新 Key 标成失效。"""
    saved: list[FanartSetting] = []

    class _Store:
        async def set(self, setting: FanartSetting) -> None:
            saved.append(setting)

    monkeypatch.setattr(fanart_mod, "get_setting_store", lambda: _Store())
    monkeypatch.setattr(fanart_mod, "_current", FanartSetting(api_key="new-key-1234"))
    await fanart_mod.mark_key_invalid("old-key-0000")
    assert saved == [] and fanart_mod.fanart_key_usable()
    await fanart_mod.mark_key_invalid("new-key-1234")
    assert saved[-1].key_invalid is True and not fanart_mod.fanart_key_usable()
    fanart_mod.reset_fanart_runtime()


async def test_fanart_breaker_is_isolated_from_image_breaker(monkeypatch) -> None:
    """Fanart 连不通只熔断 fanart，不连带 image（TMDB/豆瓣图片下载）。"""
    reset_all_breakers()

    class _DeadInner:
        async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("unreachable", request=request)

    transport = egress_transport("fanart")
    monkeypatch.setattr(transport, "_ensure_inner", lambda: _DeadInner())
    async with httpx.AsyncClient(transport=transport) as client:
        for _ in range(5):
            with pytest.raises(httpx.TransportError):
                await client.get("https://webservice.fanart.tv/v3/movies/1")
    assert get_breaker("fanart").is_open
    assert not get_breaker("image").is_open
    reset_all_breakers()


async def test_image_proxy_routes_fanart_assets_to_fanart_service() -> None:
    """图片代理按域名分流：assets.fanart.tv 走「Fanart.tv」出口，其余走「图片回源」。"""
    from movieclaw_api.services.image_proxy import _HostRoutedTransport

    hits: list[str] = []

    def route(name: str) -> httpx.MockTransport:
        return httpx.MockTransport(lambda request: hits.append(name) or httpx.Response(200))

    transport = _HostRoutedTransport(route("image"), {"assets.fanart.tv": route("fanart")})
    async with httpx.AsyncClient(transport=transport) as client:
        await client.get("https://assets.fanart.tv/fanart/a.png")
        await client.get("https://image.tmdb.org/t/p/original/a.jpg")
    assert hits == ["fanart", "image"]


def test_dns_check_follows_host_service_proxy() -> None:
    """本地 DNS 校验是否跳过，看图片域名归属的那一项：Fanart 图床看「Fanart.tv」。"""
    from movieclaw_api.services.image_proxy import egress_service_for_host

    assert egress_service_for_host("assets.fanart.tv") == "fanart"
    assert egress_service_for_host("image.tmdb.org") == "image"


async def test_closed_client_raises_fanart_error() -> None:
    """换 Key 后旧客户端被关闭：仍持有它的调用方拿到的是 FanartError（可被正常兜底）。"""
    client = FanartClient("k" * 32, transport=httpx.MockTransport(lambda r: httpx.Response(200)))
    await client.aclose()
    with pytest.raises(FanartError):
        await client.movie_images(1)


async def test_artwork_fanart_swallows_tmdb_errors(monkeypatch) -> None:
    """换图弹层：剧集现查 TVDB 编号的 TMDB 请求失败 → 状态 error，不外抛。"""
    from movieclaw_api.services.media_scrape import _artwork_fanart

    class _Tmdb:
        async def get(self, path, params):  # noqa: ANN001, ANN202
            raise TmdbError("TMDB 限流")

    monkeypatch.setattr(fanart_mod, "_current", FanartSetting(api_key="k" * 32))
    images, state = await _artwork_fanart(_Tmdb(), MediaKind.TV, 1)
    assert (images, state) == (None, "error")
    fanart_mod.reset_fanart_runtime()


async def test_season_failure_cancels_pending_fanart_task() -> None:
    """季详情失败整份档案作废：并发中的 Fanart 请求被取消，不留无人等待的任务。"""
    started = asyncio.Event()

    async def slow_fanart(request: httpx.Request) -> httpx.Response:
        started.set()
        await asyncio.sleep(30)
        return httpx.Response(200, json={})

    def tmdb_handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/3/tv/1":
            return httpx.Response(
                200,
                json={
                    "id": 1,
                    "name": "x",
                    "external_ids": {"tvdb_id": 9},
                    "seasons": [{"season_number": 1}],
                },
            )
        return httpx.Response(500, json={})

    tmdb = TmdbClient("0" * 32, transport=httpx.MockTransport(tmdb_handler))
    fanart = FanartClient("f" * 32, transport=httpx.MockTransport(slow_fanart))
    before = asyncio.all_tasks()
    with pytest.raises(TmdbError):
        await fetch_media_profile(tmdb, MediaKind.TV, 1, fanart=fanart)
    await asyncio.sleep(0)
    leftover = [t for t in asyncio.all_tasks() - before if not t.done()]
    assert started.is_set()
    assert leftover == []

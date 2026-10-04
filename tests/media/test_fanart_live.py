"""Fanart.tv 真实接口的集成测试（出网，CI 跳过）。

守的是「解析器对得上真实响应」这件事——Fanart 的响应形态没有正式文档，
2026-10 实测就发现图床地址早已从按条目分目录变成扁平路径、查无此条目回
200 {}、多了 4K 背景类型。手动跑：

    FANART_API_KEY=xxx python -m pytest -m integration tests/media/test_fanart_live.py
"""

from __future__ import annotations

import os

import pytest

from movieclaw_media.fanart import FanartAuthError, FanartClient, is_fanart_asset

pytestmark = pytest.mark.integration

_KEY = os.environ.get("FANART_API_KEY", "")
needs_key = pytest.mark.skipif(not _KEY, reason="未设置 FANART_API_KEY")


@needs_key
async def test_live_movie_images_parse() -> None:
    """《沙丘2》（TMDB 693134）：图多且稳定，各类图都应解析出来、地址都在 Fanart 图床。"""
    client = FanartClient(_KEY)
    try:
        await client.verify()
        images = await client.movie_images(693134)
    finally:
        await client.aclose()
    assert images is not None
    assert images.posters and images.backdrops and images.logos
    for image in images.posters + images.backdrops + images.logos:
        assert is_fanart_asset(image["file_path"])
        assert isinstance(image["likes"], int)
    assert any(b["width"] == 3840 for b in images.backdrops)  # 4K 背景
    assert any(b["iso_639_1"] is None for b in images.backdrops)


@needs_key
async def test_live_tv_images_by_tvdb_id() -> None:
    """《龙之家族》（TVDB 371572）：季海报按季号分组。"""
    client = FanartClient(_KEY)
    try:
        images = await client.tv_images(371572)
    finally:
        await client.aclose()
    assert images is not None and images.season_posters
    assert all(number >= 0 for number in images.season_posters)


@needs_key
async def test_live_unknown_movie_is_empty() -> None:
    client = FanartClient(_KEY)
    try:
        images = await client.movie_images(99999999)
    finally:
        await client.aclose()
    assert images is None or images.is_empty()


async def test_live_invalid_key_is_rejected() -> None:
    client = FanartClient("definitely-not-a-valid-key")
    try:
        with pytest.raises(FanartAuthError):
            await client.verify()
    finally:
        await client.aclose()

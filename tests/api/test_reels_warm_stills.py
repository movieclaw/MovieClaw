"""刷片接口返回一页时在后台预压剧照（services/reels/feed.py ``_warm_stills``）。

预压的缓存键必须与客户端请求 ``/images/assets/...?variant=reel-still`` 时完全一致，
否则压了也白压——所以这里钉死本地资产走 ``asset:<相对路径>`` + 文件版本，
远程图床走与 ``/images/proxy`` 同一个只认 URL 的派生入口，且坏图、空值不会让整批中断。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import image_variants, media_scrape
from movieclaw_api.services.image_variants import ImageVariant, source_version_of
from movieclaw_api.services.reels import feed


@pytest.fixture(autouse=True)
def _isolated_assets(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()
    media_scrape._resolved_assets_root.cache_clear()
    media_scrape._ASSET_PATHS.clear()
    root = media_scrape.assets_root()
    root.mkdir(parents=True, exist_ok=True)
    yield root
    media_scrape._ASSET_PATHS.clear()
    media_scrape._resolved_assets_root.cache_clear()
    get_settings.cache_clear()


class _Recorder:
    def __init__(self, fail_on: str | None = None) -> None:
        self.calls: list[tuple[Path, str, str, ImageVariant]] = []
        self.remote_calls: list[tuple[str, ImageVariant]] = []
        self.fail_on = fail_on

    async def get_or_create(self, path, *, source_key, source_version, variant):
        if self.fail_on and self.fail_on in source_key:
            raise OSError("坏图")
        self.calls.append((path, source_key, source_version, variant))

    async def get_or_create_remote(self, url, *, variant):
        self.remote_calls.append((url, variant))


async def _drain() -> None:
    await asyncio.gather(*list(feed._warm_tasks))


async def test_local_assets_are_warmed_with_client_cache_key(_isolated_assets: Path, monkeypatch):
    for item in ("7", "8"):
        (_isolated_assets / item).mkdir()
        (_isolated_assets / item / "backdrop.jpg").write_bytes(b"jpeg")
    recorder = _Recorder(fail_on="7/")
    monkeypatch.setattr(image_variants, "get_image_variant_service", lambda: recorder)

    feed._warm_stills(
        [
            "/images/assets/7/backdrop.jpg?v=1",  # 压失败：不影响后面的
            None,
            "/images/assets/missing/backdrop.jpg?v=1",  # 资产不在：跳过
            "/images/assets/8/backdrop.jpg?v=2",
        ]
    )
    await _drain()

    target = (_isolated_assets / "8" / "backdrop.jpg").resolve()
    assert recorder.calls == [
        (target, "asset:8/backdrop.jpg", source_version_of(target.stat()), ImageVariant.REEL_STILL)
    ]


async def test_remote_backdrop_uses_proxy_cache_key(monkeypatch):
    """远程剧照走与 ``/images/proxy?variant=`` 同一个入口：派生只认 URL，预压的就是客户端要的。"""
    recorder = _Recorder()
    monkeypatch.setattr(image_variants, "get_image_variant_service", lambda: recorder)

    url = "https://image.tmdb.org/t/p/original/x.jpg"
    feed._warm_stills([url])
    await _drain()

    assert recorder.remote_calls == [(url, ImageVariant.REEL_STILL)]
    assert recorder.calls == []

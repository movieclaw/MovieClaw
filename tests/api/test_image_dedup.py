"""刮削图片的防重复下载（docs/design/image-dedup.md）。

链路全真：真实建库、扫描挂锚（收尾即下载资产 + 镜像写目录）、真实刮削刷新；TMDB
走 MockTransport，图床换成按 URL 现造**真实 JPEG/PNG** 的假代理（档位决定尺寸），
并记下每一次 GET 与 HEAD——断言落在「发没发下载请求」、磁盘上的图与溯源记录上。
"""

from __future__ import annotations

import io
import json
import shutil

import httpx
import pytest_asyncio
from PIL import Image
from sqlmodel import select

import movieclaw_api.services.library.scan as scan_mod
import movieclaw_api.services.media_discover as discover_mod
import movieclaw_api.services.scrape_config as cfg
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.asset_reuse import derivable, derive, tier_rank
from movieclaw_api.services.library.scan import scan_library
from movieclaw_api.services.media_scrape import (
    AssetTally,
    assets_root,
    download_item_assets,
    mirror_media_dir_assets,
    scrape_media_item,
)
from movieclaw_api.services.scrape_config import reset_scrape_config
from movieclaw_api.settings import MetadataScrapeSetting
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import MediaItem
from movieclaw_db.repositories import MediaItemRepository
from movieclaw_db.repositories.library_repo import LibraryRepository

_KEY = "0123456789abcdef0123456789abcdef"
# 各图「原图」的尺寸：档位 wN 时按宽等比缩
_ORIGINAL = {"/poster.jpg": (2000, 3000), "/backdrop.jpg": (3840, 2160), "/logo.png": (800, 310)}
_COLOR = {"/poster.jpg": (200, 40, 40), "/backdrop.jpg": (40, 160, 40), "/logo.png": (40, 40, 220)}


def _movie_payload() -> dict:
    return {
        "id": 300,
        "title": "某电影",
        "original_title": "Some Movie",
        "original_language": "zh",
        "release_date": "2020-05-01",
        "status": "Released",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
        "poster_path": "/poster.jpg",
        "backdrop_path": "/backdrop.jpg",
        "images": {
            "posters": [],
            "backdrops": [],
            "logos": [
                {
                    "file_path": "/logo.png",
                    "iso_639_1": "zh",
                    "width": 800,
                    "height": 310,
                    "vote_average": 5,
                    "vote_count": 3,
                }
            ],
        },
    }


def _render(path: str, tier: str) -> bytes:
    """按 URL 现造图片：同一路径同一档位永远是同一份字节（图床的一图一址）。"""
    width, height = _ORIGINAL[path]
    if tier != "original":
        target = int(tier[1:])
        if target < width:
            width, height = target, round(height * target / width)
    png = path.endswith(".png")
    image = Image.new("RGBA" if png else "RGB", (width, height), _COLOR[path])
    buffer = io.BytesIO()
    image.save(buffer, "PNG" if png else "JPEG", quality=95)
    return buffer.getvalue()


def _split(url: str) -> tuple[str, str]:
    tier, name = url.rsplit("/", 2)[-2:]
    return tier, f"/{name}"


class _Proxy:
    """假图床：记下 GET 与 HEAD；字节按 (路径, 档位) 现造。"""

    def __init__(self) -> None:
        self.gets: list[str] = []
        self.heads: list[str] = []

    async def fetch(self, url: str, *, accept: str | None = None):
        self.gets.append(url)
        tier, path = _split(url)
        return _render(path, tier), "image/png" if path.endswith(".png") else "image/jpeg"

    async def content_length(self, url: str, *, accept: str | None = None):
        self.heads.append(url)
        tier, path = _split(url)
        return len(_render(path, tier))


@pytest_asyncio.fixture
async def env(tmp_path, monkeypatch):
    from movieclaw_media.tmdb import TmdbClient

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'dedup.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    monkeypatch.setenv("PEOPLE_IMAGES_DIR", str(tmp_path / "metadata" / "people"))
    get_settings.cache_clear()
    reset_scrape_config()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/3/movie/300":
            return httpx.Response(200, json=_movie_payload())
        if request.url.path.startswith("/3/search/"):
            return httpx.Response(200, json={"results": []})
        return httpx.Response(404, json={})

    client = TmdbClient(_KEY, transport=httpx.MockTransport(handler))
    monkeypatch.setattr(discover_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    proxy = _Proxy()
    monkeypatch.setattr("movieclaw_api.services.image_proxy.get_image_proxy", lambda: proxy)
    yield proxy
    await dispose_db()
    reset_scrape_config()
    get_settings.cache_clear()


async def _scan_movie(tmp_path):
    root = tmp_path / "media" / "movies"
    entry = root / "某电影 (2020)"
    entry.mkdir(parents=True)
    (entry / "某电影.2020.1080p.mkv").write_bytes(b"m")
    (entry / "movie.nfo").write_text(
        "<movie><title>某电影</title><tmdbid>300</tmdbid></movie>", encoding="utf-8"
    )
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
    await scan_library(library.id)
    async with get_database().session() as session:
        item = (
            (await session.execute(select(MediaItem).where(MediaItem.tmdb_id == 300)))
            .scalars()
            .one()
        )
    return item.id, entry


def _sources(item_id: int) -> dict:
    return json.loads((assets_root() / str(item_id) / "sources.json").read_text())


def _width(path) -> int:  # noqa: ANN001
    with Image.open(path) as image:
        return image.size[0]


def _item_gets(proxy: _Proxy) -> list[str]:
    """条目图（海报/背景/Logo）的 GET；头像另算。"""
    return [u for u in proxy.gets if _split(u)[1] in _ORIGINAL]


async def test_manual_refresh_does_not_redownload_unchanged_images(env, tmp_path) -> None:
    """手动「刷新元数据」（force）：图片地址与档位没变 → 一张都不重下，全部沿用。"""
    proxy = env
    item_id, _entry = await _scan_movie(tmp_path)
    assert len(_item_gets(proxy)) == 3
    before = len(proxy.gets)

    assert await scrape_media_item(item_id, force=True)
    assert proxy.gets[before:] == []
    assert proxy.heads == []  # 沿用连 HEAD 都不发


async def test_lower_quality_is_derived_locally(env, tmp_path) -> None:
    """画质从原图降到「节省空间」（海报 w500、背景 w1280）：从本地原图缩，不重下；
    Logo 固定原图不变；溯源更新成新档位，再刷新就是沿用。"""
    proxy = env
    item_id, entry = await _scan_movie(tmp_path)
    before = len(proxy.gets)

    cfg._current_scrape = MetadataScrapeSetting(image_quality="compact")
    tally = AssetTally()
    await download_item_assets(item_id, tally=tally)
    assert all(_split(u)[1] not in _ORIGINAL for u in proxy.gets[before:])  # 没有条目图 GET
    assert tally.derived == 2 and tally.downloaded == 0
    item_dir = assets_root() / str(item_id)
    assert _width(item_dir / "poster.jpg") == 500
    assert _width(item_dir / "backdrop.jpg") == 1280
    assert _sources(item_id)["poster"] == "w500/poster.jpg"

    # 升档回原图：本地缩不出原图，但媒体目录里还留着当初镜像的原图 → 收编，不下载
    cfg._current_scrape = MetadataScrapeSetting(image_quality="original")
    tally = AssetTally()
    await download_item_assets(item_id, tally=tally)
    assert tally.adopted == 2 and tally.downloaded == 0
    assert _width(item_dir / "poster.jpg") == 2000

    # 媒体目录里也没有原图了：升档只能下载
    cfg._current_scrape = MetadataScrapeSetting(image_quality="compact")
    await download_item_assets(item_id)
    (entry / "poster.jpg").unlink()
    (entry / "fanart.jpg").unlink()
    cfg._current_scrape = MetadataScrapeSetting(image_quality="original")
    tally = AssetTally()
    await download_item_assets(item_id, tally=tally)
    assert tally.downloaded == 2
    assert _width(item_dir / "poster.jpg") == 2000


async def test_rebuilt_data_dir_adopts_images_from_media_dir(env, tmp_path) -> None:
    """数据目录重建（资产全丢、媒体目录里还留着当初镜像的图）：HEAD 字节数比对
    一致就收编，不发 GET；收编后再镜像不会把同一份字节写回媒体目录。"""
    proxy = env
    item_id, entry = await _scan_movie(tmp_path)
    poster_mtime = (entry / "poster.jpg").stat().st_mtime
    shutil.rmtree(assets_root() / str(item_id))
    gets_before = len(proxy.gets)

    tally = AssetTally()
    await download_item_assets(item_id, tally=tally)
    assert all(_split(u)[1] not in _ORIGINAL for u in proxy.gets[gets_before:])
    assert tally.adopted == 3 and tally.downloaded == 0
    assert len(proxy.heads) == 3
    item_dir = assets_root() / str(item_id)
    assert (item_dir / "poster.jpg").read_bytes() == (entry / "poster.jpg").read_bytes()
    assert _sources(item_id)["logo"] == "original/logo.png"
    async with get_database().session() as session:
        meta = await MediaItemRepository(session).get_metadata(item_id)
    assert meta.poster_file and meta.backdrop_file and meta.logo_file

    await mirror_media_dir_assets(item_id)
    assert (entry / "poster.jpg").stat().st_mtime == poster_mtime


async def test_different_image_in_media_dir_is_not_adopted(env, tmp_path) -> None:
    """媒体目录里是用户自己的另一张图：字节数对不上 → 照常下载，不错收编。"""
    proxy = env
    item_id, entry = await _scan_movie(tmp_path)
    shutil.rmtree(assets_root() / str(item_id))
    other = Image.new("RGB", (1000, 1500), (1, 2, 3))
    buffer = io.BytesIO()
    other.save(buffer, "JPEG", quality=70)
    (entry / "poster.jpg").write_bytes(buffer.getvalue())
    gets_before = len(proxy.gets)

    tally = AssetTally()
    await download_item_assets(item_id, tally=tally)
    assert "original/poster.jpg" in "".join(proxy.gets[gets_before:])
    assert tally.downloaded == 1 and tally.adopted == 2
    item_dir = assets_root() / str(item_id)
    assert (item_dir / "poster.jpg").read_bytes() == _render("/poster.jpg", "original")


async def test_original_from_other_scraper_is_adopted_then_shrunk(env, tmp_path) -> None:
    """别的刮削软件存的是原图、我们要的是 w500：先问 w500 字节数对不上，再问原图对上
    → 收编后本地缩到 500 宽，不下载。"""
    proxy = env
    item_id, entry = await _scan_movie(tmp_path)
    shutil.rmtree(assets_root() / str(item_id))
    cfg._current_scrape = MetadataScrapeSetting(image_quality="compact")
    gets_before = len(proxy.gets)

    tally = AssetTally()
    await download_item_assets(item_id, tally=tally)
    assert all(_split(u)[1] not in _ORIGINAL for u in proxy.gets[gets_before:])
    assert tally.adopted == 3
    assert _width(assets_root() / str(item_id) / "poster.jpg") == 500
    assert any(u.endswith("/w500/poster.jpg") for u in proxy.heads)
    assert any(u.endswith("/original/poster.jpg") for u in proxy.heads)


async def test_avatar_lower_tier_is_derived_from_larger_tier(env, tmp_path) -> None:
    """头像换小档位：原图层里已有这个人 → 缩出来，不重下。"""
    from movieclaw_api.services.media_scrape import _sync_avatar
    from movieclaw_api.services.people_images import avatar_file

    proxy = env
    _ORIGINAL["/face.jpg"] = (600, 900)
    _COLOR["/face.jpg"] = (90, 90, 90)
    try:
        tally = AssetTally()
        await _sync_avatar("https://img.test/t/p", "original", "/face.jpg", tally)
        assert tally.downloaded == 1
        gets = len(proxy.gets)
        tally = AssetTally()
        await _sync_avatar("https://img.test/t/p", "w185", "/face.jpg", tally)
        assert tally.derived == 1 and len(proxy.gets) == gets
        assert _width(avatar_file("/face.jpg", "w185")) == 185
    finally:
        _ORIGINAL.pop("/face.jpg")
        _COLOR.pop("/face.jpg")


def test_tier_rules() -> None:
    assert tier_rank("original") > tier_rank("w1280") > tier_rank("w500")
    assert derivable("original", "w500") and derivable("h632", "w185")
    assert not derivable("w500", "original")  # 缩不出原图
    assert not derivable("w300", "w500")  # 不放大
    assert not derivable("w500", "w500")
    data = _render("/poster.jpg", "original")
    with Image.open(io.BytesIO(derive(data, "w342", png=False))) as image:
        assert image.size == (342, 513)
    small = _render("/poster.jpg", "w300")
    assert derive(small, "w500", png=False) == small  # 源不比目标大：原样

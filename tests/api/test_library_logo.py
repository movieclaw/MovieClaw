"""片名 Logo（clearlogo）的本地资产、目录镜像与选图锁（issue #472）。

链路全真：真实建库、扫描挂锚（收尾即下载资产 + 镜像写目录）、真实刮削刷新；
TMDB 走 MockTransport，图床换成按路径现造图片的假代理——Logo 是真正带透明
通道的 PNG，断言直接看磁盘上的文件与像素，不看接口回显。
"""

from __future__ import annotations

import io
import json

import httpx
import pytest
import pytest_asyncio
from PIL import Image
from pydantic import ValidationError
from sqlmodel import select

import movieclaw_api.services.library.scan as scan_mod
import movieclaw_api.services.media_discover as discover_mod
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library.scan import scan_library
from movieclaw_api.services.media_scrape import (
    assets_root,
    mirror_media_dir_assets,
    scrape_media_item,
    select_artwork,
)
from movieclaw_api.services.scrape_config import reset_scrape_config
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import MediaItem
from movieclaw_db.repositories import MediaItemRepository
from movieclaw_db.repositories.library_repo import LibraryRepository

_KEY = "0123456789abcdef0123456789abcdef"


def _logo(path: str, lang: str | None, *, votes: int = 10) -> dict:
    return {
        "file_path": path,
        "iso_639_1": lang,
        "width": 800,
        "height": 310,
        "vote_average": 5.5,
        "vote_count": votes,
    }


def _movie_payload() -> dict:
    return {
        "id": 300,
        "title": "某电影",
        "original_title": "Some Movie",
        "original_language": "en",
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
            # 主语言 zh 档有图 → 自动选中文 Logo；SVG 版客户端图片管线不认，永远不选
            "logos": [
                _logo("/logo-en.png", "en", votes=99),
                _logo("/logo-zh.png", "zh"),
                _logo("/logo-zh.svg", "zh", votes=500),
            ],
        },
    }


class _Tmdb:
    """可变的假 TMDB：用例改 ``movie`` 模拟上游换图/撤图。"""

    def __init__(self) -> None:
        self.movie = _movie_payload()

    def client(self):
        from movieclaw_media.tmdb import TmdbClient

        def handler(request: httpx.Request) -> httpx.Response:
            path = request.url.path
            if path == "/3/movie/300":
                return httpx.Response(200, json=self.movie)
            if path == "/3/movie/300/images":
                return httpx.Response(200, json=self.movie["images"])
            if path.startswith("/3/search/"):
                return httpx.Response(200, json={"results": []})
            return httpx.Response(404, json={})

        return TmdbClient(_KEY, transport=httpx.MockTransport(handler))


# 每个 Logo 路径一种颜色：断言时能认出磁盘上的是哪一张
_COLORS = {"/logo-zh.png": (220, 40, 40), "/logo-en.png": (40, 90, 220)}


def _transparent_logo(rgb: tuple[int, int, int], fmt: str = "PNG") -> bytes:
    """40×16 的透明底字标图，中间一块不透明色条（模拟片名字标）。"""
    image = Image.new("RGBA", (40, 16), (0, 0, 0, 0))
    for x in range(8, 32):
        for y in range(4, 12):
            image.putpixel((x, y), (*rgb, 255))
    buffer = io.BytesIO()
    image.save(buffer, fmt, **({"lossless": True} if fmt == "WEBP" else {}))
    return buffer.getvalue()


class _Proxy:
    """假图床：记下请求的 URL 与 Accept；Logo 回透明底 PNG，其余回占位字节。

    ``webp=True`` 模拟不认 Accept 的图床镜像：Logo 一律回 WebP。
    """

    def __init__(self) -> None:
        self.fetched: list[str] = []
        self.accepts: list[str | None] = []
        self.webp = False

    async def fetch(self, url: str, *, accept: str | None = None):
        self.fetched.append(url)
        self.accepts.append(accept)
        for path, rgb in _COLORS.items():
            if url.endswith(path):
                if self.webp:
                    return _transparent_logo(rgb, "WEBP"), "image/webp"
                return _transparent_logo(rgb), "image/png"
        return b"jpeg:" + url.encode(), "image/jpeg"


@pytest_asyncio.fixture
async def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'logo.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()
    reset_scrape_config()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    tmdb = _Tmdb()
    client = tmdb.client()
    monkeypatch.setattr(discover_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    proxy = _Proxy()
    monkeypatch.setattr("movieclaw_api.services.image_proxy.get_image_proxy", lambda: proxy)
    yield tmdb, proxy
    await dispose_db()
    reset_scrape_config()
    get_settings.cache_clear()


async def _scan_movie(tmp_path, **library_kw):
    """电影库样本（目录 NFO 钉死 tmdbid=300）→ 扫描挂锚；返回 (条目 id, 条目目录)。"""
    root = tmp_path / "media" / "movies"
    entry = root / "某电影 (2020)"
    entry.mkdir(parents=True)
    (entry / "某电影.2020.1080p.mkv").write_bytes(b"m")
    (entry / "movie.nfo").write_text(
        "<movie><title>某电影</title><tmdbid>300</tmdbid></movie>", encoding="utf-8"
    )
    db = get_database()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)], **library_kw
        )
    await scan_library(library.id)
    async with db.session() as session:
        item = (
            (await session.execute(select(MediaItem).where(MediaItem.tmdb_id == 300)))
            .scalars()
            .one()
        )
    return item.id, entry


async def _state(item_id: int):
    async with get_database().session() as session:
        item = await session.get(MediaItem, item_id)
        meta = await MediaItemRepository(session).get_metadata(item_id)
    return item, meta


def _rgba_at(data: bytes, xy: tuple[int, int]) -> tuple[int, int, int, int]:
    with Image.open(io.BytesIO(data)) as image:
        return image.convert("RGBA").getpixel(xy)


async def test_scan_downloads_logo_and_mirrors_clearlogo(env, tmp_path) -> None:
    """入库即落 Logo 资产（原图档、透明通道原样保留）并镜像成条目目录的
    clearlogo.png——外部播放器（Kodi/Jellyfin）直接读这个文件名。"""
    _tmdb, proxy = env
    item_id, entry = await _scan_movie(tmp_path)

    item, meta = await _state(item_id)
    assert item.logo_path == "/logo-zh.png"  # 主语言档优先，SVG 不参选
    assert meta.logo_file == f"{item_id}/logo.png"
    asset = assets_root() / str(item_id) / "logo.png"
    logo_fetch = next(i for i, url in enumerate(proxy.fetched) if url.endswith("/logo-zh.png"))
    assert proxy.fetched[logo_fetch].endswith("/original/logo-zh.png")
    # 点名要 PNG：默认的浏览器式 Accept 会被 TMDB 的 CDN 协商成有损 WebP
    assert proxy.accepts[logo_fetch] == "image/png"
    # 透明底原样落盘：四角全透明，色条不透明（没有被转成 JPEG 压成黑底）
    data = asset.read_bytes()
    assert data.startswith(b"\x89PNG")
    assert _rgba_at(data, (0, 0))[3] == 0
    assert _rgba_at(data, (20, 8)) == (220, 40, 40, 255)
    sources = json.loads((asset.parent / "sources.json").read_text(encoding="utf-8"))
    assert sources["logo"] == "original/logo-zh.png"

    assert (entry / "clearlogo.png").read_bytes() == data


async def test_logo_saved_as_real_png_even_if_mirror_answers_webp(env, tmp_path) -> None:
    """图床镜像不认 Accept、照样回 WebP 时：落盘前转成真 PNG，透明通道保留——
    clearlogo.png 里装的必须是 PNG，外部播放器按扩展名认格式的不在少数。"""
    _tmdb, proxy = env
    proxy.webp = True
    item_id, entry = await _scan_movie(tmp_path)

    data = (assets_root() / str(item_id) / "logo.png").read_bytes()
    assert data.startswith(b"\x89PNG")
    assert _rgba_at(data, (0, 0))[3] == 0
    assert _rgba_at(data, (20, 8)) == (220, 40, 40, 255)
    assert (entry / "clearlogo.png").read_bytes() == data


async def test_logo_asset_dropped_when_tmdb_has_no_logo(env, tmp_path) -> None:
    """TMDB 撤掉 Logo（logo_path 变空串）：资产作废，镜像不再写出旧图。
    媒体目录里已有的 clearlogo.png 按铁律不删（绝不删除媒体目录的文件）。"""
    tmdb, _proxy = env
    item_id, entry = await _scan_movie(tmp_path)
    asset = assets_root() / str(item_id) / "logo.png"
    assert asset.is_file()

    tmdb.movie["images"]["logos"] = []
    assert await scrape_media_item(item_id)

    item, meta = await _state(item_id)
    assert item.logo_path == ""
    assert meta.logo_file is None
    assert not asset.exists()
    sources = json.loads((asset.parent / "sources.json").read_text(encoding="utf-8"))
    assert "logo" not in sources
    assert (entry / "clearlogo.png").is_file()  # 绝不删除

    # 资产目录里就算残留一张旧图（例如删除失败），镜像也只认档案里在用的
    (entry / "clearlogo.png").unlink()
    asset.write_bytes(b"stale")
    await mirror_media_dir_assets(item_id, force=True)
    assert not (entry / "clearlogo.png").exists()


async def test_locked_logo_survives_forced_refresh(env, tmp_path) -> None:
    """手动锁定的 Logo：自动选图与 force 刷新都不覆盖，也不重下资产。

    走真实的选图入口（选定即当场落盘）：锁不再无条件跳过下载，而是按溯源
    比对——资产与选定的那张对得上、档位也没变，才不重下。
    """
    _tmdb, proxy = env
    item_id, _entry = await _scan_movie(tmp_path)
    assert await select_artwork(item_id, kind="logo", file_path="/logo-en.png")
    proxy.fetched.clear()

    assert await scrape_media_item(item_id, force=True)

    item, meta = await _state(item_id)
    assert item.logo_path == "/logo-en.png"
    assert meta.logo_locked
    # 锁定的资产 force 也不重下：档位与溯源都没变，那张图就是用户要的
    assert not any("logo" in url for url in proxy.fetched)


# ---------------------------------------------------------------------------
# 「更换图片」徽标页：候选、选定即锁、恢复自动
# ---------------------------------------------------------------------------


async def _library_id() -> int:
    from movieclaw_db.models import Library

    async with get_database().session() as session:
        return (await session.execute(select(Library.id))).scalars().one()


async def test_logo_candidates_follow_auto_pick_order(env, tmp_path) -> None:
    """候选排序与自动选图同源：首张就是自动策略选中的中文徽标，英文其次；
    SVG 不进候选（客户端图片管线不认）。「当前」按在用路径标出。"""
    from movieclaw_api.api.routes.libraries import list_artwork_candidates_route

    item_id, _entry = await _scan_movie(tmp_path)
    async with get_database().session() as session:
        resp = await list_artwork_candidates_route(await _library_id(), item_id, session)
    view = resp.data
    assert [c.file_path for c in view.logos] == ["/logo-zh.png", "/logo-en.png"]
    assert view.current_logo == "/logo-zh.png"
    assert view.logo_locked is False
    assert view.logos[0].preview_url.endswith("/w300/logo-zh.png")


async def test_select_logo_locks_and_syncs_only_the_logo(env, tmp_path) -> None:
    """选定徽标：当场下载并覆盖 clearlogo.png、加锁（force 刷新不覆盖），
    只动徽标这一张；恢复自动后下次刷新按策略换回中文徽标。"""
    from movieclaw_api.api.routes.libraries import select_artwork_route
    from movieclaw_api.schemas.library import ArtworkSelectPayload

    _tmdb, proxy = env
    item_id, entry = await _scan_movie(tmp_path)
    asset = assets_root() / str(item_id) / "logo.png"
    assert _rgba_at(asset.read_bytes(), (20, 8))[:3] == (220, 40, 40)  # 自动选的中文徽标
    proxy.fetched.clear()

    async with get_database().session() as session:
        resp = await select_artwork_route(
            await _library_id(),
            item_id,
            ArtworkSelectPayload(kind="logo", file_path="/logo-en.png"),
            session,
        )
    assert resp.message == "徽标已更换，此后刷新不会覆盖"
    assert proxy.fetched == [f"{get_settings().tmdb_image_base_url}/original/logo-en.png"]
    item, meta = await _state(item_id)
    assert (item.logo_path, meta.logo_locked) == ("/logo-en.png", True)
    assert meta.poster_locked is False and meta.backdrop_locked is False
    blue = (40, 90, 220)
    assert _rgba_at(asset.read_bytes(), (20, 8))[:3] == blue
    assert _rgba_at((entry / "clearlogo.png").read_bytes(), (20, 8))[:3] == blue

    assert await scrape_media_item(item_id, force=True)
    item, _meta = await _state(item_id)
    assert item.logo_path == "/logo-en.png"
    assert _rgba_at(asset.read_bytes(), (20, 8))[:3] == blue

    async with get_database().session() as session:
        resp = await select_artwork_route(
            await _library_id(), item_id, ArtworkSelectPayload(kind="logo"), session
        )
    assert resp.data == {"locked": False}
    assert await scrape_media_item(item_id)
    item, meta = await _state(item_id)
    assert (item.logo_path, meta.logo_locked) == ("/logo-zh.png", False)
    assert _rgba_at(asset.read_bytes(), (20, 8))[:3] == (220, 40, 40)


def test_select_payload_rejects_empty_path() -> None:
    """空串不是"恢复自动"（那是 null），也不是合法的图片路径：直接拒掉，
    免得写进一个"锁定但没有图"的状态。"""
    from movieclaw_api.schemas.library import ArtworkSelectPayload

    with pytest.raises(ValidationError):
        ArtworkSelectPayload(kind="logo", file_path="")
    assert ArtworkSelectPayload(kind="logo").file_path is None

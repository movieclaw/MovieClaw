"""Fanart.tv 图片来源的全链路测试（docs/design/image-sources.md）。

链路全真：真实建库、扫描挂锚（收尾即下载资产 + 镜像写目录）、真实刮削刷新、
真实配置存储（Key 加密落库）；TMDB 与 Fanart 走 MockTransport，图床换成按 URL
现造图片的假代理。断言落在库字段、磁盘文件与配置存储上——接口回显对了而
落盘没变，正是这类功能最典型的假通过。
"""

from __future__ import annotations

import io
import json

import httpx
import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from PIL import Image
from pydantic import ValidationError
from sqlmodel import select

import movieclaw_api.services.fanart as fanart_mod
import movieclaw_api.services.library.scan as scan_mod
import movieclaw_api.services.media_discover as discover_mod
import movieclaw_api.services.scrape_config as cfg
from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.library import ArtworkSelectPayload
from movieclaw_api.services.library.scan import scan_library
from movieclaw_api.services.media_scrape import (
    assets_root,
    list_artwork_candidates,
    scrape_media_item,
    select_artwork,
)
from movieclaw_api.services.scrape_config import (
    merge_for_library,
    profile_fetch_kwargs,
    reset_scrape_config,
)
from movieclaw_api.settings import FanartSetting, MetadataScrapeSetting
from movieclaw_api.settings.store import get_setting_store, init_setting_store, reset_setting_store
from movieclaw_db.crypto import init_secret_box, reset_secret_box
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import MediaItem
from movieclaw_db.repositories import MediaItemRepository
from movieclaw_db.repositories.library_repo import LibraryRepository

_TMDB_KEY = "0123456789abcdef0123456789abcdef"
_FANART_KEY = "fanartkey0123456789abcd"
_FA = "https://assets.fanart.tv/fanart/movies/300"
FA_LOGO_ZH = f"{_FA}/hdmovielogo/zh.png"
FA_POSTER_ZH = f"{_FA}/movieposter/zh.jpg"


def _movie_payload() -> dict:
    """TMDB 侧：中文海报（指定）、无文字背景、**只有英文 Logo**。"""
    logo = {"file_path": "/logo-en.png", "iso_639_1": "en", "width": 800, "height": 310}
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
        "poster_path": "/poster-en.jpg",
        "backdrop_path": "/backdrop.jpg",
        "images": {
            "posters": [
                {"file_path": "/poster-en.jpg", "iso_639_1": "en", "width": 2000, "height": 3000}
            ],
            "backdrops": [],
            "logos": [{**logo, "vote_average": 5.0, "vote_count": 10}],
        },
    }


_FANART_MOVIE = {
    "name": "Some Movie",
    "tmdb_id": "300",
    "hdmovielogo": [
        {"id": "1", "url": FA_LOGO_ZH, "lang": "zh", "likes": "5"},
        {"id": "2", "url": f"{_FA}/hdmovielogo/en.png", "lang": "en", "likes": "9"},
    ],
    "movieposter": [{"id": "3", "url": FA_POSTER_ZH, "lang": "zh", "likes": "2"}],
}


class _Upstreams:
    """可变的假上游：用例改 ``fanart_status`` 模拟 Fanart 出错/Key 被撤销。"""

    def __init__(self) -> None:
        self.movie = _movie_payload()
        self.fanart_status = 200
        self.fanart_calls: list[str] = []

    def tmdb(self):
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

        return TmdbClient(_TMDB_KEY, transport=httpx.MockTransport(handler))

    def fanart_transport(self, *_args, **_kwargs) -> httpx.MockTransport:
        def handler(request: httpx.Request) -> httpx.Response:
            self.fanart_calls.append(request.url.path)
            if request.headers.get("api-key") != _FANART_KEY:
                return httpx.Response(401, json={"error": "invalid API key"})
            if self.fanart_status != 200:
                return httpx.Response(self.fanart_status, json={"error": "x"})
            if request.url.path in ("/v3/movies/300", "/v3/movies/550"):
                return httpx.Response(200, json=_FANART_MOVIE)
            return httpx.Response(404, json={})

        return httpx.MockTransport(handler)


def _png(rgb: tuple[int, int, int]) -> bytes:
    image = Image.new("RGBA", (40, 16), (0, 0, 0, 0))
    for x in range(8, 32):
        image.putpixel((x, 8), (*rgb, 255))
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


class _Proxy:
    """假图床：Fanart 中文 Logo 是红色、TMDB 英文 Logo 是蓝色，其余回占位 JPEG 字节。"""

    def __init__(self) -> None:
        self.fetched: list[str] = []

    async def fetch(self, url: str, *, accept: str | None = None):
        self.fetched.append(url)
        if url == FA_LOGO_ZH:
            return _png((220, 40, 40)), "image/png"
        if url.endswith("/logo-en.png"):
            return _png((40, 90, 220)), "image/png"
        return b"\xff\xd8\xff" + url.encode(), "image/jpeg"


@pytest_asyncio.fixture
async def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'fanart.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()
    reset_scrape_config()
    reset_setting_store()
    reset_secret_box()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_secret_box(None, tmp_path / ".secret_key")
    init_setting_store()
    upstreams = _Upstreams()
    client = upstreams.tmdb()
    monkeypatch.setattr(discover_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    monkeypatch.setattr(fanart_mod, "egress_transport", upstreams.fanart_transport)
    proxy = _Proxy()
    monkeypatch.setattr("movieclaw_api.services.image_proxy.get_image_proxy", lambda: proxy)
    yield upstreams, proxy
    await dispose_db()
    reset_scrape_config()
    reset_setting_store()
    reset_secret_box()
    get_settings.cache_clear()


async def _enable_fanart(enabled: bool = True) -> None:
    """等价于用户在设置页填 Key、打开开关并保存。"""
    await fanart_mod.verify_and_save_key(_FANART_KEY)
    await cfg.save_scrape_setting(MetadataScrapeSetting(fanart_enabled=enabled))


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
    return item.id, entry, library


async def _state(item_id: int):
    async with get_database().session() as session:
        item = await session.get(MediaItem, item_id)
        meta = await MediaItemRepository(session).get_metadata(item_id)
    return item, meta


def _red(data: bytes) -> bool:
    with Image.open(io.BytesIO(data)) as image:
        return image.convert("RGBA").getpixel((10, 8))[:3] == (220, 40, 40)


async def test_scan_with_fanart_picks_and_mirrors_chinese_logo(env, tmp_path) -> None:
    """启用 Fanart 后入库：中文 Logo 来自 Fanart（TMDB 只有英文），资产、溯源、
    媒体目录 clearlogo.png 全部是 Fanart 那张；海报（TMDB 默认指定英文）被
    Fanart 中文海报替换（语言先于来源）。"""
    upstreams, proxy = env
    await _enable_fanart()
    item_id, entry, _library = await _scan_movie(tmp_path)

    item, meta = await _state(item_id)
    assert item.logo_path == FA_LOGO_ZH
    assert item.poster_path == FA_POSTER_ZH
    assert item.backdrop_path == "/backdrop.jpg"  # Fanart 没背景，TMDB 照旧
    assert FA_LOGO_ZH in proxy.fetched  # 绝对地址原样下载，不拼 TMDB 档位
    logo_file = assets_root() / str(item_id) / "logo.png"
    assert _red(logo_file.read_bytes())
    assert _red((entry / "clearlogo.png").read_bytes())
    sources = json.loads((assets_root() / str(item_id) / "sources.json").read_text())
    assert sources["logo"] == FA_LOGO_ZH
    assert upstreams.fanart_calls == ["/v3/movies/550", "/v3/movies/300"]  # 验证 + 刮削


async def test_disabled_by_default_and_enabling_switches_on_refresh(env, tmp_path) -> None:
    """默认关：只用 TMDB（英文 Logo）、不打 Fanart；打开后刷新即换成 Fanart 中文
    Logo 并重下资产——存量条目「刷新元数据」后生效。"""
    upstreams, proxy = env
    item_id, _entry, _library = await _scan_movie(tmp_path)
    item, _meta = await _state(item_id)
    assert item.logo_path == "/logo-en.png"
    assert upstreams.fanart_calls == []

    await _enable_fanart()
    assert await scrape_media_item(item_id)
    item, meta = await _state(item_id)
    assert item.logo_path == FA_LOGO_ZH
    assert _red((assets_root() / str(item_id) / "logo.png").read_bytes())


async def test_fanart_outage_keeps_current_fanart_images(env, tmp_path) -> None:
    """Fanart 偶发失败：条目现用的 Fanart 图原样保留，不来回跳也不重下。"""
    upstreams, proxy = env
    await _enable_fanart()
    item_id, _entry, _library = await _scan_movie(tmp_path)
    fetched = len(proxy.fetched)

    upstreams.fanart_status = 503
    assert await scrape_media_item(item_id)
    item, _meta = await _state(item_id)
    assert item.logo_path == FA_LOGO_ZH
    assert item.poster_path == FA_POSTER_ZH
    assert FA_LOGO_ZH not in proxy.fetched[fetched:]  # 溯源一致，复用不重下


async def test_revoked_key_is_marked_invalid_and_scrape_falls_back(env, tmp_path) -> None:
    """刮削时 Fanart 回 401：Key 标记失效（落库）、之后不再打 Fanart，刮削照常。"""
    upstreams, _proxy = env
    await _enable_fanart()
    # 模拟 Key 在 Fanart 侧被撤销：存的 Key 不再被接受
    stored = await get_setting_store().get(FanartSetting)
    await get_setting_store().set(stored.model_copy(update={"api_key": "revoked-key-xxxx"}))
    await fanart_mod.load_fanart_runtime()

    item_id, _entry, _library = await _scan_movie(tmp_path)
    item, _meta = await _state(item_id)
    assert item.logo_path == "/logo-en.png"  # 回落 TMDB
    get_setting_store().invalidate()
    assert (await get_setting_store().get(FanartSetting)).key_invalid is True
    assert fanart_mod.fanart_status()["key_invalid"] is True
    assert profile_fetch_kwargs()["fanart"] is None
    calls = len(upstreams.fanart_calls)
    assert await scrape_media_item(item_id)
    assert len(upstreams.fanart_calls) == calls  # 失效后不再请求

    # 重新填一次有效 Key：失效标记清除，恢复可用
    await fanart_mod.verify_and_save_key(_FANART_KEY)
    assert fanart_mod.fanart_status() == {
        "configured": True,
        "key_invalid": False,
        "key_hint": _FANART_KEY[-4:],
    }


async def test_key_is_encrypted_at_rest(env, tmp_path) -> None:
    from movieclaw_db.repositories.setting_repo import SettingRepository

    await fanart_mod.verify_and_save_key(_FANART_KEY)
    async with get_database().session() as session:
        row = await SettingRepository(session).get("metadata.fanart")
    assert row is not None and _FANART_KEY not in row.value_json


async def test_invalid_key_is_not_saved(env, tmp_path) -> None:
    from movieclaw_media.fanart import FanartAuthError

    await fanart_mod.verify_and_save_key(_FANART_KEY)
    with pytest.raises(FanartAuthError):
        await fanart_mod.verify_and_save_key("wrong-key-0000")
    assert fanart_mod.current_fanart_setting().api_key == _FANART_KEY


async def test_library_override_can_disable_fanart(env, tmp_path) -> None:
    """按库覆盖：全局开、某库关 → 该库的条目只用 TMDB。"""
    await _enable_fanart()
    _item_id, _entry, library = await _scan_movie(tmp_path)
    library.scrape_overrides = {"fanart_enabled": False, "logo_source_order": ["tmdb", "fanart"]}
    merged = merge_for_library(library)
    assert merged.fanart_enabled is False
    assert merged.logo_source_order == ["tmdb", "fanart"]
    assert profile_fetch_kwargs(merged)["fanart"] is None
    assert profile_fetch_kwargs(MetadataScrapeSetting(fanart_enabled=True))["fanart"] is not None


async def test_artwork_candidates_and_select_fanart(env, tmp_path) -> None:
    """换图弹层：没 Key 时状态 not_configured、只有 TMDB；填了 Key（开关关着也算）
    Fanart 候选混入并标来源；选定 Fanart 图即锁定并落盘。"""
    _upstreams, _proxy = env
    item_id, entry, _library = await _scan_movie(tmp_path)

    candidates = await list_artwork_candidates(item_id)
    assert candidates.fanart == "not_configured"
    assert {c["source"] for c in candidates.logos} == {"tmdb"}

    # 没 Key 时在用的 Fanart 图不在候选里：补在首位、标 unlisted（语言未知，不显示成无文字）
    async with get_database().session() as session:
        row = await session.get(MediaItem, item_id)
        row.logo_path = FA_LOGO_ZH
        session.add(row)
        await session.commit()
    candidates = await list_artwork_candidates(item_id)
    assert candidates.logos[0]["file_path"] == FA_LOGO_ZH
    assert candidates.logos[0]["unlisted"] is True and candidates.logos[0]["source"] == "fanart"
    assert all(not c.get("unlisted") for c in candidates.logos[1:])

    await _enable_fanart(enabled=False)  # 有 Key、自动选图不用 Fanart
    candidates = await list_artwork_candidates(item_id)
    assert candidates.fanart == "ok"
    fanart_logos = [c for c in candidates.logos if c["source"] == "fanart"]
    assert fanart_logos[0]["file_path"] == FA_LOGO_ZH
    assert fanart_logos[0]["preview_url"] == FA_LOGO_ZH.replace("/fanart/", "/preview/")
    assert fanart_logos[0]["likes"] == 5

    assert await select_artwork(item_id, kind="logo", file_path=FA_LOGO_ZH)
    item, meta = await _state(item_id)
    assert item.logo_path == FA_LOGO_ZH and meta.logo_locked
    assert _red((entry / "clearlogo.png").read_bytes())


def test_select_payload_only_accepts_tmdb_or_fanart_paths() -> None:
    assert ArtworkSelectPayload(kind="logo", file_path=FA_LOGO_ZH).file_path == FA_LOGO_ZH
    assert ArtworkSelectPayload(kind="poster", file_path="/abc.jpg").file_path == "/abc.jpg"
    with pytest.raises(ValidationError):
        ArtworkSelectPayload(kind="poster", file_path="https://evil.example/a.jpg")


def test_setting_validation() -> None:
    setting = MetadataScrapeSetting()
    assert setting.fanart_enabled is False
    assert setting.logo_language_priority == ["meta", "en", "orig", "null"]
    assert setting.logo_source_order == ["fanart", "tmdb"]
    with pytest.raises(ValidationError):
        MetadataScrapeSetting(poster_source_order=["tmdb"])
    with pytest.raises(ValidationError):
        MetadataScrapeSetting(logo_source_order=["tmdb", "douban"])
    with pytest.raises(ValidationError):
        MetadataScrapeSetting(logo_language_priority=[])
    assert MetadataScrapeSetting(
        backdrop_source_order=["Fanart", "TMDB"]
    ).backdrop_source_order == [
        "fanart",
        "tmdb",
    ]


# ---------------------------------------------------------------------------
# 接口层：Key 状态 / 验证保存 / 配置读写
# ---------------------------------------------------------------------------


@pytest.fixture
def api(tmp_path, monkeypatch):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.services.media_discover import reset_media_service

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'api.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    reset_media_service()
    reset_scrape_config()
    upstreams = _Upstreams()
    monkeypatch.setattr(fanart_mod, "egress_transport", upstreams.fanart_transport)

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as client:
        client.post("/api/v1/auth/bootstrap", json={"username": "admin", "password": "s3cret-pass"})
        yield client

    reset_media_service()
    reset_scrape_config()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def test_fanart_key_endpoints(api: TestClient) -> None:
    assert api.get("/api/v1/scrape/fanart").json()["data"] == {
        "configured": False,
        "key_invalid": False,
        "key_hint": "",
    }
    bad = api.put("/api/v1/scrape/fanart", json={"api_key": "wrong-key-0000"})
    assert bad.status_code == 400
    assert "401" in bad.json()["message"]
    assert api.get("/api/v1/scrape/fanart").json()["data"]["configured"] is False

    ok = api.put("/api/v1/scrape/fanart", json={"api_key": _FANART_KEY})
    assert ok.status_code == 200
    assert ok.json()["data"] == {
        "configured": True,
        "key_invalid": False,
        "key_hint": _FANART_KEY[-4:],
    }
    # 刮削配置里不会出现 Key
    assert _FANART_KEY not in api.get("/api/v1/scrape/config").text


def test_scrape_config_roundtrip_with_source_fields(api: TestClient) -> None:
    resp = api.put(
        "/api/v1/scrape/config",
        json={
            "fanart_enabled": True,
            "poster_source_order": ["fanart", "tmdb"],
            "logo_language_priority": ["meta", "null"],
        },
    )
    assert resp.status_code == 200
    setting = resp.json()["data"]["setting"]
    assert setting["fanart_enabled"] is True
    assert setting["poster_source_order"] == ["fanart", "tmdb"]
    assert setting["logo_language_priority"] == ["meta", "null"]
    assert setting["logo_source_order"] == ["fanart", "tmdb"]  # 没给的保持原样

    bad = api.put("/api/v1/scrape/config", json={"poster_source_order": ["tmdb"]})
    assert bad.status_code in (400, 422)

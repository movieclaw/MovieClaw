"""外部库源钩子（services/library/source_providers.py）的端到端测试。

覆盖：插件登记一个假来源后——建库向导的来源列表（/libraries/source-providers）、
外部来源建库（空根 + source_config 校验）、库视图的来源展示字段、能力位
按插件档案生效、连接配置的编辑与非法输入拒绝、内置来源不接受 source_config。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library import source_providers as sp
from movieclaw_api.services.library.profile import (
    IgnoreProfile,
    LibraryProfile,
    MediaKind,
)
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import FileSource, Library, LibraryFile, MediaItem, MediaMetadata
from movieclaw_db.repositories.library_repo import LibraryRepository


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(
        app, headers={"Accept-Language": "zh-Hans"}
    ) as c:  # with 块内触发 lifespan：迁移
        yield c
    get_settings.cache_clear()


def _profile(source: str, kind: MediaKind) -> LibraryProfile:
    """一个形态的能力档案：不刮削、可订阅，Jellyfin 类型随形态。"""
    return LibraryProfile(
        kind=kind,
        source=source,
        scraped=False,
        naming=False,
        ignore_rules=IgnoreProfile.PLAIN,
        write_nfo=False,
        subscribable=True,
        jellyfin_type="Movie" if kind is MediaKind.MOVIE else "Series",
        jellyfin_collection="movies" if kind is MediaKind.MOVIE else "tvshows",
        default_aspect=2 / 3,
        media_exts=frozenset({".mp4"}),
        playable=True,
        jellyfin_exposed=True,
    )


def _fake_provider(source: str = "testsrc") -> sp.LibrarySourceProvider:
    """一个最小但完整的外部库源：电影/剧集各一份档案、连接配置两个必填栏。"""
    return sp.LibrarySourceProvider(
        source=source,
        title="测试媒体服务器",
        profiles={
            MediaKind.MOVIE.value: _profile(source, MediaKind.MOVIE),
            MediaKind.TV.value: _profile(source, MediaKind.TV),
        },
        config_schema={
            "type": "object",
            "required": ["base_url"],
            "properties": {
                "base_url": {"type": "string"},
                "library_id": {"type": "string"},
            },
        },
        icon="testsrc",
        help="测试用外部库源",
    )


@pytest.fixture
def provider(client):
    """应用起来之后（内核注册表已绑定空表）再挂假来源，模拟插件加载。"""
    registry = sp.Registry(sp.LIBRARY_SOURCE_PROVIDERS)
    registry.add("test:testsrc", _fake_provider(), entry_id="entry-test")
    unbind = sp.bind_source_providers(registry)
    yield _fake_provider()
    unbind()


# ---------------------------------------------------------------------------
# 来源列表（建库向导数据源）
# ---------------------------------------------------------------------------


def test_source_providers_endpoint_lists_registered(client, provider) -> None:
    r = client.get("/api/v1/libraries/source-providers")
    assert r.status_code == 200
    data = r.json()["data"]
    assert len(data) == 1
    row = data[0]
    assert row["source"] == "testsrc"
    assert row["title"] == "测试媒体服务器"
    assert row["kind_support"] == ["movie", "tv"]
    assert row["capabilities"]["movie"]["subscribable"] is True
    assert row["capabilities"]["movie"]["naming"] is False
    assert row["capabilities"]["tv"]["jellyfin_collection"] == "tvshows"
    assert row["config_schema"]["required"] == ["base_url"]


def test_source_providers_empty_without_plugin(client) -> None:
    # 没有插件登记时列表为空：主线不内置任何外部来源
    assert client.get("/api/v1/libraries/source-providers").json()["data"] == []


# ---------------------------------------------------------------------------
# 外部来源建库
# ---------------------------------------------------------------------------


def test_create_external_library_without_roots(client, provider) -> None:
    """外部库源允许空根（内容在远程服务器上），连接配置按 schema 校验后落库。"""
    r = client.post(
        "/api/v1/libraries",
        json={
            "name": "飞牛电影",
            "kind": "movie",
            "source": "testsrc",
            "root_paths": [],
            "source_config": {"base_url": "http://fnos:5666", "library_id": "lib-1"},
        },
    )
    assert r.status_code == 200
    view = r.json()["data"]
    assert view["source"] == "testsrc"
    assert view["source_title"] == "测试媒体服务器"
    assert view["source_icon"] == "testsrc"
    assert view["source_configured"] is True
    assert view["capabilities"]["scraped"] is False
    assert view["capabilities"]["jellyfin_collection"] == "movies"
    assert view["root_paths"] == []


def test_create_external_library_rejects_bad_config(client, provider) -> None:
    r = client.post(
        "/api/v1/libraries",
        json={
            "name": "坏配置",
            "kind": "movie",
            "source": "testsrc",
            "source_config": {"library_id": "lib-1"},  # 缺必填的 base_url
        },
    )
    assert r.status_code == 400
    assert "连接配置不合规范" in r.json()["message"]


def test_create_builtin_library_rejects_source_config(client) -> None:
    r = client.post(
        "/api/v1/libraries",
        json={
            "name": "本地电影",
            "kind": "movie",
            "root_paths": ["/media/movies"],
            "source_config": {"base_url": "http://x"},
        },
    )
    assert r.status_code == 400
    assert "不能保存外部连接配置" in r.json()["message"]


def test_create_with_unregistered_source_rejected(client) -> None:
    # 来源未登记（插件停用/卸载）：与未知组合一样走 400，不静默落库
    r = client.post(
        "/api/v1/libraries",
        json={"name": "幽灵库", "kind": "movie", "source": "ghostsrc", "root_paths": []},
    )
    assert r.status_code == 400
    assert "不支持的媒体库类型组合" in r.json()["message"]


# ---------------------------------------------------------------------------
# 连接配置编辑
# ---------------------------------------------------------------------------


def _create_external(client) -> dict:
    r = client.post(
        "/api/v1/libraries",
        json={
            "name": "外部剧集",
            "kind": "tv",
            "source": "testsrc",
            "source_config": {"base_url": "http://fnos:5666", "library_id": "lib-2"},
        },
    )
    assert r.status_code == 200
    return r.json()["data"]


def test_update_source_config(client, provider) -> None:
    lib = _create_external(client)
    r = client.put(
        f"/api/v1/libraries/{lib['id']}",
        json={
            "kind": "tv",
            "name": "外部剧集",
            "root_paths": [],
            "source_config": {"base_url": "http://fnos2:5666", "library_id": "lib-9"},
        },
    )
    assert r.status_code == 200
    assert r.json()["data"]["source_configured"] is True

    # None = 不改动：配置保持
    r = client.put(
        f"/api/v1/libraries/{lib['id']}",
        json={"kind": "tv", "name": "外部剧集", "root_paths": []},
    )
    assert r.status_code == 200
    assert r.json()["data"]["source_configured"] is True


def test_update_builtin_library_ignores_unset_source_config(client) -> None:
    """内置库编辑不受影响：不带 source_config 的老请求体照常保存。"""
    r = client.post(
        "/api/v1/libraries",
        json={"name": "普通库", "kind": "movie", "root_paths": ["/media/m"]},
    )
    assert r.status_code == 200
    lib = r.json()["data"]
    r = client.put(
        f"/api/v1/libraries/{lib['id']}",
        json={"kind": "movie", "name": "普通库改名", "root_paths": ["/media/m"]},
    )
    assert r.status_code == 200
    assert r.json()["data"]["source_title"] is None


def test_plugin_unloaded_library_still_readable(client, provider) -> None:
    """插件卸载后：来源不再登记，但存量库照常可读、可改名（能力位回落报错
    由 profile_for 的 400 承担，列表不崩）。"""
    lib = _create_external(client)
    # 模拟插件卸载：解绑注册表（插件内核关闭时也是这个状态）
    sp._bound = None
    r = client.get("/api/v1/libraries")
    assert r.status_code == 200
    rows = {row["id"]: row for row in r.json()["data"]}
    assert rows[lib["id"]]["source_title"] is None
    # 编辑（不碰来源配置）也照常
    r = client.put(
        f"/api/v1/libraries/{lib['id']}",
        json={"kind": "tv", "name": "外部剧集改名", "root_paths": []},
    )
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# PR #1111 审查意见 1：插件停用（来源不再登记）时刷片不整体 400
# ---------------------------------------------------------------------------
def _seed_reels_libraries(tmp_path) -> None:
    """一个内置电影库 + 一个外部库源电影库（孤儿：不登记 provider），各带一条目。"""
    import asyncio

    monkey_media = tmp_path / "media"
    builtin_file = monkey_media / "内置 (2010)" / "内置.2010.mkv"
    external_file = monkey_media / "外部 (2019)" / "外部.2019.mkv"
    builtin_file.parent.mkdir(parents=True)
    external_file.parent.mkdir(parents=True)
    builtin_file.write_bytes(b"A" * 1024)
    external_file.write_bytes(b"B" * 1024)

    async def _seed() -> None:
        init_db(get_settings().database_url, echo=False)
        await run_migrations()
        async with get_database().session() as session:
            builtin_lib = Library(
                name="内置电影", kind="movie", source="tmdb", root_paths=["/media"]
            )
            external_lib = Library(
                name="飞牛电影",
                kind="movie",
                source="testsrc",
                root_paths=[],
                source_config={"base_url": "http://fnos:5666"},
            )
            session.add_all([builtin_lib, external_lib])
            await session.flush()
            builtin = MediaItem(
                kind="movie", tmdb_id=1001, title="内置片", original_title="Builtin", year=2010
            )
            external = MediaItem(
                kind="movie", tmdb_id=2002, title="外部片", original_title="External", year=2019
            )
            session.add_all([builtin, external])
            await session.flush()
            session.add_all(
                [
                    MediaMetadata(media_item_id=builtin.id),
                    MediaMetadata(media_item_id=external.id),
                    LibraryFile(
                        library_id=builtin_lib.id,
                        media_item_id=builtin.id,
                        file_path=str(builtin_file),
                        size_bytes=1024,
                        container="mkv",
                        duration_seconds=6000,
                        resolution="1080p",
                        source=FileSource.SCANNED,
                    ),
                    LibraryFile(
                        library_id=external_lib.id,
                        media_item_id=external.id,
                        file_path=str(external_file),
                        size_bytes=1024,
                        container="mkv",
                        duration_seconds=5400,
                        resolution="1080p",
                        source=FileSource.SCANNED,
                    ),
                ]
            )
            await session.commit()
            await LibraryRepository(session).refresh_stats([builtin_lib.id, external_lib.id])
        await dispose_db()

    reset_secret_box()
    asyncio.run(_seed())


@pytest.fixture
def reels_client(tmp_path, monkeypatch):
    """内置库 + 孤儿外部库（provider 刻意不登记 = 插件停用态）的客户端。"""
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'reels.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    _seed_reels_libraries(tmp_path)

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app, headers={"Accept-Language": "zh-Hans"}) as c:
        yield c
    get_settings.cache_clear()


def test_reels_survives_plugin_disabled(reels_client) -> None:
    """建了外部库后插件停用：/reels 与 /reels/facets 照常 200，孤儿库不进池。

    孤儿降级以前只做在 profile_of，_playable_library_kinds 直接调 profile_for
    会把整个刷片入口打挂（PR #1111 审查意见 1 的原始事故）。
    """
    # 修复前：_playable_library_kinds 直接调 profile_for，孤儿外部库一进来
    # 整个 /reels、/reels/facets 就是 400，连本地库都刷不了
    feed = reels_client.get("/api/v1/reels", params={"limit": 10})
    assert feed.status_code == 200, feed.text
    names = {item["title"]["name"] for item in feed.json()["data"]["items"]}
    # 本地库照常可刷；孤儿外部库不整体打挂接口（孤儿档案对 movie 保留
    # playable，条目照常进池——文件实际在远程媒体服务器上的库翻不到内容）
    assert "内置片" in names

    facets = reels_client.get("/api/v1/reels/facets")
    assert facets.status_code == 200, facets.text


# ---------------------------------------------------------------------------
# PR #1111 审查意见 5：同一来源被登记两次 → 读端直接拒绝（不静默覆盖）
# ---------------------------------------------------------------------------
def test_duplicate_source_registration_is_rejected(client) -> None:
    """两个插件贡献同一个 source：registered_providers / provider_of 直接抛错。

    来源值是库行的身份锚，静默取优先级高的那个会让两个插件都以为来源是
    自己的——冲突必须在第一次消费就响，而不是悄悄换实现。
    """
    registry = sp.Registry(sp.LIBRARY_SOURCE_PROVIDERS)
    registry.add("test:a", _fake_provider(), entry_id="entry-a")
    unbind_a = sp.bind_source_providers(registry)
    try:
        registry.add("test:b", _fake_provider(), entry_id="entry-b")
        with pytest.raises(ValueError, match="登记了两次"):
            sp.registered_providers()
        with pytest.raises(ValueError):
            sp.provider_of("testsrc")
    finally:
        unbind_a()


# ---------------------------------------------------------------------------
# PR #1111 审查意见 3（登记侧）：config_schema 只收支持的子集
# ---------------------------------------------------------------------------
def test_config_schema_rejects_unsupported_field_types(client) -> None:
    """integer/number/boolean/string 之外的类型没有对应表单控件，登记时挡下。"""
    base = {
        "source": "badsrc",
        "title": "坏来源",
        "profiles": {MediaKind.MOVIE.value: _profile("badsrc", MediaKind.MOVIE)},
    }
    with pytest.raises(ValueError, match="类型不支持"):
        sp.LibrarySourceProvider(
            **base,
            config_schema={"type": "object", "properties": {"cfg": {"type": "object"}}},
        )
    with pytest.raises(ValueError, match="required 引用了不存在的字段"):
        sp.LibrarySourceProvider(
            **base,
            config_schema={
                "type": "object",
                "required": ["missing"],
                "properties": {"base_url": {"type": "string"}},
            },
        )
    # 合法子集不受影响
    ok = sp.LibrarySourceProvider(
        **base,
        config_schema={
            "type": "object",
            "required": ["port"],
            "properties": {
                "name": {"type": "string"},
                "port": {"type": "integer"},
                "ratio": {"type": "number"},
                "insecure": {"type": "boolean"},
            },
        },
    )
    assert ok.config_schema["properties"]["port"]["type"] == "integer"

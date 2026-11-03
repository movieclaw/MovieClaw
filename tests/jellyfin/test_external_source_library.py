"""外部库源（插件登记来源）在 Jellyfin 兼容层的输出。

证明「齐平共存」不只发生在建库接口与前端：插件登记的外部来源一旦落到库行上，
Jellyfin 兼容层（Infuse 等客户端走的就是它）**零改动**把库当成本地库输出——
CollectionType 取自插件给的能力档案，条目照常可浏览。

另含降级面：插件停用（来源不再登记）时，孤儿档案对 Jellyfin 不暴露，库从
客户端列表里消失而不是报错——插件的可用性不该把别人的列表打挂。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from jellyfin.helpers import ADMIN, jf_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.library import source_providers as sp
from movieclaw_api.services.library.profile import IgnoreProfile, LibraryProfile
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import FileSource, Library, LibraryFile, MediaItem, MediaMetadata
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_jellyfin.ids import library_guid
from movieclaw_media.models import MediaKind

SOURCE = "testsrc"


def _provider() -> sp.LibrarySourceProvider:
    return sp.LibrarySourceProvider(
        source=SOURCE,
        title="测试媒体服务器",
        profiles={
            MediaKind.MOVIE.value: LibraryProfile(
                kind=MediaKind.MOVIE,
                source=SOURCE,
                scraped=False,
                naming=False,
                ignore_rules=IgnoreProfile.PLAIN,
                write_nfo=False,
                subscribable=True,
                jellyfin_type="Movie",
                jellyfin_collection="movies",
                default_aspect=2 / 3,
                media_exts=frozenset({".mkv"}),
                playable=True,
                jellyfin_exposed=True,
            )
        },
        config_schema={"type": "object", "properties": {"base_url": {"type": "string"}}},
        icon="testsrc",
    )


@pytest.fixture
def seeded_external(tmp_path: Path, monkeypatch) -> dict:
    """播种：一个内置电影库 + 一个外部库源电影库（各一个条目/文件）。"""
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'jf-ext.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()

    root = tmp_path / "media"
    builtin_file = root / "内置 (2010)" / "内置.2010.mkv"
    external_file = root / "外部 (2019)" / "外部.2019.mkv"
    builtin_file.parent.mkdir(parents=True)
    external_file.parent.mkdir(parents=True)
    builtin_file.write_bytes(b"A" * 1024)
    external_file.write_bytes(b"B" * 1024)

    ids: dict = {}

    async def _seed() -> None:
        init_db(get_settings().database_url, echo=False)
        await run_migrations()
        async with get_database().session() as session:
            builtin_lib = Library(name="内置电影", kind="movie", root_paths=[str(root)])
            external_lib = Library(
                name="飞牛电影",
                kind="movie",
                source=SOURCE,
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
                        source=FileSource.SCANNED,
                    ),
                    LibraryFile(
                        library_id=external_lib.id,
                        media_item_id=external.id,
                        file_path=str(external_file),
                        size_bytes=1024,
                        container="mkv",
                        duration_seconds=5400,
                        source=FileSource.SCANNED,
                    ),
                ]
            )
            await session.commit()
            await LibraryRepository(session).refresh_stats([builtin_lib.id, external_lib.id])
            ids.update(
                {
                    "builtin_lib": builtin_lib.id,
                    "external_lib": external_lib.id,
                    "external": external.id,
                }
            )
        await dispose_db()

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    asyncio.run(_seed())
    return ids


@pytest.fixture
def client(seeded_external, monkeypatch):
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as c:
        resp = c.post("/api/v1/auth/bootstrap", json=ADMIN)
        assert resp.status_code == 200, resp.text
        yield c
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


@pytest.fixture
def provider(client):
    """应用起来后挂插件（与真实插件加载同一条注册表路径），用例结束解绑。"""
    registry = sp.Registry(sp.LIBRARY_SOURCE_PROVIDERS)
    registry.add("test:testsrc", _provider(), entry_id="entry-test")
    unbind = sp.bind_source_providers(registry)
    yield _provider()
    unbind()


def test_external_library_shows_up_in_user_views(
    client: TestClient, seeded_external: dict, provider
) -> None:
    """外部库源库在客户端看来就是一个普通电影库：类型与条目都取自插件档案。"""
    auth = {"ApiKey": jf_login(client)}
    body = client.get("/UserViews", params=auth).json()
    by_name = {v["Name"]: v for v in body["Items"]}
    assert by_name["飞牛电影"]["CollectionType"] == "movies"
    assert by_name["飞牛电影"]["ChildCount"] == 1
    assert by_name["内置电影"]["CollectionType"] == "movies"


def test_external_library_items_are_browsable(
    client: TestClient, seeded_external: dict, provider
) -> None:
    auth = {"ApiKey": jf_login(client)}
    body = client.get(
        "/Items",
        params={
            **auth,
            "parentId": library_guid(seeded_external["external_lib"]),
            "fields": "ProviderIds,Path,MediaSources",
        },
    ).json()
    assert body["TotalRecordCount"] == 1
    item = body["Items"][0]
    assert item["Name"] == "外部片"
    assert item["Type"] == "Movie"
    assert item["MediaSources"][0]["Path"].endswith("外部.2019.mkv")


def test_external_library_hidden_when_plugin_disabled(
    client: TestClient, seeded_external: dict
) -> None:
    """插件不可用：来源不再登记 → 孤儿档案不暴露给 Jellyfin，列表不崩。"""
    auth = {"ApiKey": jf_login(client)}
    body = client.get("/UserViews", params=auth).json()
    names = {v["Name"] for v in body["Items"]}
    assert "内置电影" in names
    assert "飞牛电影" not in names



def test_plugin_disabled_entries_leave_the_whole_scope(
    client: TestClient, seeded_external: dict
) -> None:
    """插件不可用：孤儿库条目从全部出口消失（PR #1111 审查意见 4）。

    ``list_libraries`` 只挡住库视图列举；搜索、``/Items/Latest``、按库 GUID
    直接浏览走 ``viewer_scope.visible``——暴露条件并入可见集后这些口子一起
    收窄，内置库条目不受影响。
    """
    auth = {"ApiKey": jf_login(client)}
    # 最新媒体：内置条目在、外部条目不在
    latest = client.get("/Items/Latest", params=auth).json()
    latest_names = [i["Name"] for i in latest]
    assert "内置片" in latest_names
    assert "外部片" not in latest_names
    # 搜索：外部条目搜不到
    search = client.get(
        "/Items", params={**auth, "Recursive": "true", "SearchTerm": "外部片"}
    ).json()
    assert search["TotalRecordCount"] == 0
    found = client.get(
        "/Items", params={**auth, "Recursive": "true", "SearchTerm": "内置片"}
    ).json()
    assert found["TotalRecordCount"] == 1
    # 按库 GUID 直接浏览：外部库整个不可见（Jellyfin 风格 404，不是空列表——
    # 库从设备视野里消失而不是报错），内置库照常 1 条
    ext = client.get(
        "/Items", params={**auth, "parentId": library_guid(seeded_external["external_lib"])}
    )
    assert ext.status_code == 404
    builtin = client.get(
        "/Items", params={**auth, "parentId": library_guid(seeded_external["builtin_lib"])}
    ).json()
    assert builtin["TotalRecordCount"] == 1

"""个人评分第二期（PR 2 后端列表）测试（issue #1292，docs/design/user-rating.md）。

覆盖：
- 五面墙（单库墙、kind 墙、收藏、合集、相似）按 ``badges=my_rating`` 返回 ``user_rating``，
  不传 ``badges`` 时不跑评分 SQL 且返回 ``null``；
- 查询数上界断言：条目从 2 部增至 12 部时查询数恒定（无 N+1），``my_rating`` 单独请求仅 +1，
  与 ``progress`` / ``unwatched`` 同开时共用同一条 ``playback_state`` 查询；
- ``sort=my_rating``（有评分 / 未评分 / 同分）：未评分双方向沉底、``media_item_id`` 稳定收尾、
  跨页不重不漏，并含 SQLite + PostgreSQL 双库参数化用例与方言 SQL 断言；
- 筛选 ``w=rated`` 与 ``my_rating_gte``（含边界值、成员隔离、非法值返回 400）；
- 首页数据源 ``GET /api/v1/playback/rated``（默认 4 星门槛、同分按 ``rated_at`` 倒序、
  ``min_rating`` 覆盖与 400 校验、可见库与成员隔离、分页、查询数 O(1)、``x-cli-hidden``）。
"""

from __future__ import annotations

import asyncio
import itertools
import os
import uuid
from datetime import timedelta
from functools import partial
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event, text
from sqlalchemy.dialects import postgresql, sqlite
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from movieclaw_api.app import create_app
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.library.items import (
    WALL_BADGE_GROUPS,
    LibraryFilter,
    _sorted_ids_query,
    _wall_page_ids,
    _wall_scope,
    build_library_wall,
)
from movieclaw_api.services.playback_rated import rated_items
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import Database, get_database
from movieclaw_db.models import (
    Collection,
    CollectionItem,
    FileSource,
    FileState,
    Library,
    LibraryFile,
    MediaEpisode,
    MediaItem,
    MediaMetadata,
    PlaybackState,
    utcnow,
)
from movieclaw_db.repositories.library_repo import LibraryRepository

_PB = "/api/v1/playback"
_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}
_PG_URL = os.environ.get("MOVIECLAW_TEST_POSTGRES_URL")


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'rating_lists.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    monkeypatch.setattr("movieclaw_api.api.routes.playback.available_backends", lambda: ())

    with TestClient(create_app()) as c:
        c.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


_seed_counter = itertools.count(1)


async def _seed_walls(tmp_path: Path) -> dict[str, int]:
    """三部同类型科幻电影（互相满足相似推荐）+ 一部三集剧 + 一个手动合集。"""
    n = next(_seed_counter)
    root = tmp_path / f"walls{n}"
    root.mkdir(exist_ok=True)

    def _file(item_id: int, library_id: int, season: int, episode: int, name: str) -> LibraryFile:
        path = root / name
        path.write_bytes(b"FAKE" * 16)
        return LibraryFile(
            library_id=library_id,
            media_item_id=item_id,
            season_number=season,
            episode_number=episode,
            file_path=str(path),
            size_bytes=path.stat().st_size,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            duration_seconds=600,
            hdr="Dolby Vision",
        )

    async with get_database().session() as session:
        repo = LibraryRepository(session)
        movies = await repo.create(name=f"电影库{n}", kind="movie", root_paths=[str(root)])
        shows = await repo.create(name=f"剧集库{n}", kind="tv", root_paths=[str(root)])
        m1 = MediaItem(kind="movie", tmdb_id=5000 + n * 10 + 1, title="甲片", original_title="M1")
        m2 = MediaItem(kind="movie", tmdb_id=5000 + n * 10 + 2, title="乙片", original_title="M2")
        m3 = MediaItem(kind="movie", tmdb_id=5000 + n * 10 + 3, title="丙片", original_title="M3")
        show = MediaItem(kind="tv", tmdb_id=5000 + n * 10 + 4, title="丁剧", original_title="S1")
        session.add_all([m1, m2, m3, show])
        await session.flush()
        assert m1.id and m2.id and m3.id and show.id and movies.id and shows.id

        for item, fname in ((m1, f"m1-{n}.mkv"), (m2, f"m2-{n}.mkv"), (m3, f"m3-{n}.mkv")):
            session.add(_file(item.id, movies.id, 0, 0, fname))
            session.add(
                MediaMetadata(
                    media_item_id=item.id,
                    genre_ids=[878, 12],
                    origin_countries=["US"],
                    vote_average=8.2,
                )
            )
        for e in (1, 2, 3):
            session.add(_file(show.id, shows.id, 1, e, f"S01E0{e}-{n}.mkv"))
            session.add(MediaEpisode(media_item_id=show.id, season_number=1, episode_number=e))
        session.add(
            MediaMetadata(
                media_item_id=show.id,
                genre_ids=[18],
                origin_countries=["US"],
                vote_average=8.8,
            )
        )

        col = Collection(name=f"精选{n}", kind="manual", library_id=None)
        session.add(col)
        await session.flush()
        assert col.id
        for pos, item in enumerate((m1, m2, show)):
            session.add(CollectionItem(collection_id=col.id, media_item_id=item.id, position=pos))

        await session.commit()
        return {
            "movies_library": movies.id,
            "shows_library": shows.id,
            "m1": m1.id,
            "m2": m2.id,
            "m3": m3.id,
            "show": show.id,
            "collection": col.id,
        }


def seed_walls(client: TestClient, tmp_path: Path) -> dict[str, int]:
    return client.portal.call(partial(_seed_walls, tmp_path))  # type: ignore[attr-defined]


def _capture_sql(client: TestClient, fn) -> tuple[object, list[str]]:
    statements: list[str] = []

    def capture(_conn, _cursor, statement, *_args) -> None:
        statements.append(statement)

    engine = get_database().engine.sync_engine
    event.listen(engine, "before_cursor_execute", capture)
    try:
        result = fn()
    finally:
        event.remove(engine, "before_cursor_execute", capture)
    return result, statements


# ---------------------------------------------------------------------------
# 1. 五面墙：badges=my_rating 按需返回 user_rating，不传不查
# ---------------------------------------------------------------------------


def test_all_five_walls_return_user_rating_only_when_badged(client, tmp_path):
    ids = seed_walls(client, tmp_path)
    # m1=9、m2=6、m3 未评、show=10，且收藏 m1 / m2 / show
    for item_id, rating in ((ids["m1"], 9), (ids["m2"], 6), (ids["show"], 10)):
        resp = client.post(
            f"{_PB}/marks", json={"media_item_id": item_id, "favorite": True, "rating": rating}
        )
        assert resp.status_code == 200, resp.text

    endpoints = [
        (
            "library_wall",
            f"/api/v1/libraries/{ids['movies_library']}/items",
            {ids["m1"]: 9, ids["m2"]: 6, ids["m3"]: None},
        ),
        (
            "kind_wall",
            "/api/v1/libraries/kinds/movie/items",
            {ids["m1"]: 9, ids["m2"]: 6, ids["m3"]: None},
        ),
        ("favorites", f"{_PB}/favorites", {ids["m1"]: 9, ids["m2"]: 6, ids["show"]: 10}),
        (
            "collections",
            f"/api/v1/collections/{ids['collection']}/items",
            {ids["m1"]: 9, ids["m2"]: 6, ids["show"]: 10},
        ),
        (
            "similar",
            f"/api/v1/libraries/{ids['movies_library']}/items/{ids['m1']}/similar",
            {ids["m2"]: 6, ids["m3"]: None},
        ),
    ]

    for label, path, expected in endpoints:
        # 不带 badges：所有条目 user_rating 均为 None，且不跑角标评分查询
        resp_off, sql_off = _capture_sql(client, lambda p=path: client.get(p))
        assert resp_off.status_code == 200, (label, resp_off.text)
        data_off = resp_off.json()["data"]
        items_off = data_off["items"] if isinstance(data_off, dict) else data_off
        by_id_off = {row["media_item_id"]: row["user_rating"] for row in items_off}
        for item_id in expected:
            assert by_id_off[item_id] is None, (label, item_id)
        assert not any("playback_state.user_rating IS NOT NULL" in s for s in sql_off), label

        # 带 badges=my_rating：返回当前成员自己的个人评分，且整页仅 1 条角标评分查询
        resp_on, sql_on = _capture_sql(
            client, lambda p=path: client.get(p, params={"badges": "my_rating"})
        )
        assert resp_on.status_code == 200, (label, resp_on.text)
        data_on = resp_on.json()["data"]
        items_on = data_on["items"] if isinstance(data_on, dict) else data_on
        by_id_on = {row["media_item_id"]: row["user_rating"] for row in items_on}
        for item_id, rating in expected.items():
            assert by_id_on[item_id] == rating, (label, item_id, by_id_on)
        assert sum("playback_state.user_rating IS NOT NULL" in s for s in sql_on) == 1, label


# ---------------------------------------------------------------------------
# 2. 查询数上界断言：不随条目数增长，合并查表保持固定上界
# ---------------------------------------------------------------------------


def test_my_rating_badge_and_rated_endpoint_query_count_is_constant(client, tmp_path):
    async def _seed_bulk(count: int, tag: str) -> int:
        root = tmp_path / f"bulk-{tag}"
        root.mkdir(exist_ok=True)
        async with get_database().session() as session:
            lib = await LibraryRepository(session).create(
                name=f"库-{tag}", kind="tv", root_paths=[str(root)]
            )
            assert lib.id
            now = utcnow()
            for i in range(count):
                item = MediaItem(
                    kind="tv",
                    tmdb_id=90_000 + (0 if tag == "small" else 100) + i,
                    title=f"剧{tag}-{i}",
                    original_title=f"S-{tag}-{i}",
                )
                session.add(item)
                await session.flush()
                assert item.id
                for e in (1, 2):
                    p = root / f"{item.id}-S01E0{e}.mkv"
                    p.write_bytes(b"X" * 8)
                    session.add(
                        LibraryFile(
                            library_id=lib.id,
                            media_item_id=item.id,
                            season_number=1,
                            episode_number=e,
                            file_path=str(p),
                            size_bytes=8,
                            source=FileSource.SCANNED,
                            state=FileState.IN_PLACE,
                            duration_seconds=600,
                        )
                    )
                session.add(
                    PlaybackState(
                        member_id=0,
                        media_item_id=item.id,
                        season_number=-1,
                        episode_number=-1,
                        user_rating=9,
                        rated_at=now - timedelta(minutes=i),
                    )
                )
            await session.commit()
            return lib.id

    small_lib = client.portal.call(partial(_seed_bulk, 2, "small"))  # type: ignore[attr-defined]
    large_lib = client.portal.call(partial(_seed_bulk, 12, "large"))  # type: ignore[attr-defined]

    async def _measure_wall(lib_id: int, badges: frozenset[str]) -> tuple[list, list[str]]:
        stmts: list[str] = []

        def capture(_conn, _cursor, statement, *_args) -> None:
            stmts.append(statement)

        engine = get_database().engine.sync_engine
        event.listen(engine, "before_cursor_execute", capture)
        try:
            async with get_database().session() as session:
                views = await build_library_wall(session, lib_id, member_id=0, badges=badges)
        finally:
            event.remove(engine, "before_cursor_execute", capture)
        return views, stmts

    # 两个库均先热身（消除 prepare_titles 对未见标题的一次性 cache_entry 查询），再同口径测量
    client.portal.call(partial(_measure_wall, small_lib, frozenset({"my_rating"})))  # type: ignore[attr-defined]
    client.portal.call(partial(_measure_wall, large_lib, frozenset({"my_rating"})))  # type: ignore[attr-defined]
    small_views, small_sql = client.portal.call(
        partial(_measure_wall, small_lib, frozenset({"my_rating"}))
    )  # type: ignore[attr-defined]
    large_views, large_sql = client.portal.call(
        partial(_measure_wall, large_lib, frozenset({"my_rating"}))
    )  # type: ignore[attr-defined]
    _, off_sql = client.portal.call(partial(_measure_wall, large_lib, frozenset()))  # type: ignore[attr-defined]
    all_views, all_sql = client.portal.call(
        partial(_measure_wall, large_lib, frozenset(WALL_BADGE_GROUPS))
    )  # type: ignore[attr-defined]

    assert len(small_views) == 2 and len(large_views) == 12
    assert all(v.user_rating == 9 for v in large_views)
    assert all(v.user_rating == 9 for v in all_views)
    # 2 部与 12 部查询条数完全相同（无 N+1）
    assert len(small_sql) == len(large_sql)
    # 单开 my_rating 比全关恰好多 1 条查询，且不碰 json_each / position_ms
    assert len(large_sql) == len(off_sql) + 1
    assert sum("playback_state.user_rating" in s for s in large_sql) == 1
    assert sum("playback_state.position_ms" in s for s in large_sql) == 0
    assert sum("json_each" in s for s in large_sql) == 0
    # 全开（含 my_rating + progress + unwatched）与既有上界持平：仅 +4 条
    assert len(all_sql) == len(off_sql) + 4

    # /playback/rated 同样 O(1)：limit=2 与 limit=12 查询数一致
    async def _measure_rated(limit: int, badges: frozenset[str]) -> tuple[int, list[str]]:
        stmts: list[str] = []

        def capture(_conn, _cursor, statement, *_args) -> None:
            stmts.append(statement)

        engine = get_database().engine.sync_engine
        event.listen(engine, "before_cursor_execute", capture)
        try:
            async with get_database().session() as session:
                items, _total = await rated_items(
                    session,
                    member_id=0,
                    visible_library_ids={large_lib},
                    limit=limit,
                    badges=badges,
                )
        finally:
            event.remove(engine, "before_cursor_execute", capture)
        return len(items), stmts

    n2, sql2 = client.portal.call(partial(_measure_rated, 2, frozenset({"my_rating"})))  # type: ignore[attr-defined]
    n12, sql12 = client.portal.call(partial(_measure_rated, 12, frozenset({"my_rating"})))  # type: ignore[attr-defined]
    assert n2 == 2 and n12 == 12
    assert len(sql2) == len(sql12)


# ---------------------------------------------------------------------------
# 3. 排序 sort=my_rating：有分 / 同分 / 未评分沉底 + 稳定分页 + 双库 SQL 验证
# ---------------------------------------------------------------------------


def test_sort_my_rating_order_ties_nulls_last_and_pagination(client, tmp_path):
    async def _seed_six() -> tuple[int, dict[str, int]]:
        root = tmp_path / "sort6"
        root.mkdir(exist_ok=True)
        async with get_database().session() as session:
            lib = await LibraryRepository(session).create(
                name="排序库", kind="movie", root_paths=[str(root)]
            )
            assert lib.id
            names = ["u1", "r5", "r8a", "r10", "u2", "r8b"]
            ids: dict[str, int] = {}
            for idx, name in enumerate(names):
                item = MediaItem(
                    kind="movie", tmdb_id=70_000 + idx, title=name, original_title=name
                )
                session.add(item)
                await session.flush()
                assert item.id
                ids[name] = item.id
                p = root / f"{name}.mkv"
                p.write_bytes(b"X" * 8)
                session.add(
                    LibraryFile(
                        library_id=lib.id,
                        media_item_id=item.id,
                        file_path=str(p),
                        size_bytes=8,
                        source=FileSource.SCANNED,
                        state=FileState.IN_PLACE,
                    )
                )
            for name, score in (("r5", 5), ("r8a", 8), ("r10", 10), ("r8b", 8)):
                session.add(
                    PlaybackState(
                        member_id=0,
                        media_item_id=ids[name],
                        season_number=0,
                        episode_number=0,
                        user_rating=score,
                        rated_at=utcnow(),
                    )
                )
            # 另一个成员给未评分的 u1 打 10 分，不应影响超管排序
            session.add(
                PlaybackState(
                    member_id=99,
                    media_item_id=ids["u1"],
                    season_number=0,
                    episode_number=0,
                    user_rating=10,
                    rated_at=utcnow(),
                )
            )
            await session.commit()
            return lib.id, ids

    lib_id, ids = client.portal.call(_seed_six)  # type: ignore[attr-defined]
    assert ids["r8b"] > ids["r8a"] and ids["u2"] > ids["u1"]

    # 默认倒序：10 → 同分 8（id 大的在前）→ 5 → 未评分沉底（id 大的在前）
    expected_desc = [ids["r10"], ids["r8b"], ids["r8a"], ids["r5"], ids["u2"], ids["u1"]]
    full = client.get(
        f"/api/v1/libraries/{lib_id}/items",
        params={"sort": "my_rating", "badges": "my_rating"},
    )
    assert full.status_code == 200, full.text
    assert [row["media_item_id"] for row in full.json()["data"]] == expected_desc

    # 跨页翻页：limit=2 走完 3 页，拼接与全量完全一致，不重不漏
    paged: list[int] = []
    for offset in (0, 2, 4):
        page = client.get(
            f"/api/v1/libraries/{lib_id}/items",
            params={"sort": "my_rating", "limit": 2, "offset": offset},
        )
        assert page.status_code == 200, page.text
        paged.extend(row["media_item_id"] for row in page.json()["data"])
    assert paged == expected_desc
    assert len(set(paged)) == len(expected_desc)

    # 反向升序：5 → 同分 8（id 小的在前）→ 10 → 未评分依然沉底（id 小的在前）
    expected_asc = [ids["r5"], ids["r8a"], ids["r8b"], ids["r10"], ids["u1"], ids["u2"]]
    asc_resp = client.get(
        f"/api/v1/libraries/{lib_id}/items",
        params={"sort": "my_rating", "order": "asc"},
    )
    assert asc_resp.status_code == 200, asc_resp.text
    assert [row["media_item_id"] for row in asc_resp.json()["data"]] == expected_asc

    # 校验 SQLite 与 PostgreSQL 两种方言编译出的 SQL 都显式含 NULLS LAST 且走外连接聚合
    for order in (None, "asc"):
        stmt = _sorted_ids_query(_wall_scope(lib_id), "my_rating", order, 0)
        for dialect in (sqlite.dialect(), postgresql.dialect()):
            sql = str(stmt.compile(dialect=dialect))
            assert "LEFT OUTER JOIN playback_state" in sql
            assert "max(playback_state.user_rating)" in sql
            assert "NULLS LAST" in sql


@pytest.fixture(params=["sqlite", "postgresql"])
def dual_db(request, tmp_path):
    """按仓库既有约定（test_playback_continue_dismiss_concurrency.py）在 SQLite 与
    PostgreSQL 上各跑一遍排序 / 筛选核心 SQL；未配置 MOVIECLAW_TEST_POSTGRES_URL 或
    未装 asyncpg 时仅跳过 PostgreSQL 份。"""
    loop = asyncio.new_event_loop()
    teardown = []
    if request.param == "sqlite":
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'dual.db'}")
        engine = database.engine
    else:
        if not _PG_URL:
            pytest.skip("MOVIECLAW_TEST_POSTGRES_URL 未配置")
        pytest.importorskip("asyncpg")
        name = f"mc_rating_{uuid.uuid4().hex[:12]}"
        admin_url = make_url(_PG_URL)

        async def admin(sql: str) -> None:
            admin_engine = create_async_engine(admin_url, isolation_level="AUTOCOMMIT")
            async with admin_engine.connect() as conn:
                await conn.execute(text(sql))
            await admin_engine.dispose()

        loop.run_until_complete(admin(f'CREATE DATABASE "{name}"'))
        teardown.append(lambda: admin(f'DROP DATABASE "{name}" WITH (FORCE)'))
        engine = create_async_engine(admin_url.set(database=name))

    async def setup():
        async with engine.begin() as conn:
            await conn.run_sync(SQLModel.metadata.create_all)
        return async_sessionmaker(
            bind=engine, class_=AsyncSession, expire_on_commit=False, autoflush=False
        )

    sessions = loop.run_until_complete(setup())
    try:
        yield loop, sessions, tmp_path
    finally:
        loop.run_until_complete(engine.dispose())
        for fn in teardown:
            loop.run_until_complete(fn())
        loop.close()


def test_sort_and_filter_my_rating_dual_backend(dual_db):
    loop, sessions, tmp_path = dual_db

    async def run():
        async with sessions() as session:
            lib = Library(name="双库", kind="movie", root_paths=[str(tmp_path)])
            tv_lib = Library(name="双剧", kind="tv", root_paths=[str(tmp_path)])
            session.add_all([lib, tv_lib])
            await session.flush()
            assert lib.id and tv_lib.id

            m_unrated = MediaItem(kind="movie", tmdb_id=1, title="U", original_title="U")
            m_low = MediaItem(kind="movie", tmdb_id=2, title="L", original_title="L")
            m_tie1 = MediaItem(kind="movie", tmdb_id=3, title="T1", original_title="T1")
            m_tie2 = MediaItem(kind="movie", tmdb_id=4, title="T2", original_title="T2")
            show = MediaItem(kind="tv", tmdb_id=5, title="S", original_title="S")
            session.add_all([m_unrated, m_low, m_tie1, m_tie2, show])
            await session.flush()
            assert m_unrated.id and m_low.id and m_tie1.id and m_tie2.id and show.id

            for item in (m_unrated, m_low, m_tie1, m_tie2):
                session.add(
                    LibraryFile(
                        library_id=lib.id,
                        media_item_id=item.id,
                        file_path=f"{tmp_path}/{item.id}.mkv",
                        size_bytes=10,
                        source=FileSource.SCANNED,
                        state=FileState.IN_PLACE,
                    )
                )
            for ep in (1, 2):
                session.add(
                    LibraryFile(
                        library_id=tv_lib.id,
                        media_item_id=show.id,
                        season_number=1,
                        episode_number=ep,
                        file_path=f"{tmp_path}/s1e{ep}.mkv",
                        size_bytes=10,
                        source=FileSource.SCANNED,
                        state=FileState.IN_PLACE,
                    )
                )
            now = utcnow()
            session.add_all(
                [
                    PlaybackState(member_id=0, media_item_id=m_low.id, user_rating=5, rated_at=now),
                    PlaybackState(
                        member_id=0, media_item_id=m_tie1.id, user_rating=9, rated_at=now
                    ),
                    PlaybackState(
                        member_id=0,
                        media_item_id=m_tie2.id,
                        user_rating=9,
                        rated_at=now + timedelta(seconds=10),
                    ),
                    PlaybackState(
                        member_id=0,
                        media_item_id=show.id,
                        season_number=-1,
                        episode_number=-1,
                        user_rating=8,
                        rated_at=now,
                    ),
                ]
            )
            await session.commit()

            desc_ids = await _wall_page_ids(session, lib.id, "my_rating", None, 0, member_id=0)
            assert desc_ids == [m_tie2.id, m_tie1.id, m_low.id, m_unrated.id]

            asc_ids = await _wall_page_ids(
                session, lib.id, "my_rating", None, 0, member_id=0, order="asc"
            )
            assert asc_ids == [m_low.id, m_tie1.id, m_tie2.id, m_unrated.id]

            rated_only = await _wall_page_ids(
                session,
                lib.id,
                "my_rating",
                None,
                0,
                filters=LibraryFilter(watch="rated"),
                member_id=0,
            )
            assert rated_only == [m_tie2.id, m_tie1.id, m_low.id]

            gte_ids = await _wall_page_ids(
                session,
                lib.id,
                "my_rating",
                None,
                0,
                filters=LibraryFilter(my_rating_gte=9),
                member_id=0,
            )
            assert gte_ids == [m_tie2.id, m_tie1.id]

            # /playback/rated 跨电影 + 整剧，默认 min_rating=8，同分按 rated_at 倒序
            items, total = await rated_items(
                session, member_id=0, visible_library_ids={lib.id, tv_lib.id}
            )
            assert total == 3
            assert [i.media_item_id for i in items] == [m_tie2.id, m_tie1.id, show.id]

    loop.run_until_complete(run())


# ---------------------------------------------------------------------------
# 4. 筛选 w=rated / my_rating_gte 与非法参数 400
# ---------------------------------------------------------------------------


def test_filter_w_rated_and_my_rating_gte_and_validation(client, tmp_path):
    ids = seed_walls(client, tmp_path)
    client.post(f"{_PB}/marks", json={"media_item_id": ids["m1"], "rating": 9})
    client.post(f"{_PB}/marks", json={"media_item_id": ids["m2"], "rating": 7})
    client.post(f"{_PB}/marks", json={"media_item_id": ids["show"], "rating": 8})

    # w=rated 只命中评过分的电影（m3 未评不出现）
    resp = client.get(f"/api/v1/libraries/{ids['movies_library']}/items", params={"w": "rated"})
    assert resp.status_code == 200, resp.text
    assert {r["media_item_id"] for r in resp.json()["data"]} == {ids["m1"], ids["m2"]}

    # 剧集库 w=rated 命中整剧哨兵 (-1, -1)
    tv_resp = client.get(f"/api/v1/libraries/{ids['shows_library']}/items", params={"w": "rated"})
    assert tv_resp.status_code == 200, tv_resp.text
    assert [r["media_item_id"] for r in tv_resp.json()["data"]] == [ids["show"]]

    # my_rating_gte 边界：>=8 只含 m1(9)，>=7 含 m1(9)+m2(7)，>=10 为空
    for threshold, expected in ((8, {ids["m1"]}), (7, {ids["m1"], ids["m2"]}), (10, set())):
        r = client.get(
            f"/api/v1/libraries/{ids['movies_library']}/items",
            params={"my_rating_gte": threshold},
        )
        assert r.status_code == 200, r.text
        assert {row["media_item_id"] for row in r.json()["data"]} == expected

    # kind wall 同样支持 w=rated 与 my_rating_gte
    kind_resp = client.get(
        "/api/v1/libraries/kinds/movie/items",
        params={"my_rating_gte": 8, "badges": "my_rating"},
    )
    assert kind_resp.status_code == 200, kind_resp.text
    assert [(r["media_item_id"], r["user_rating"]) for r in kind_resp.json()["data"]] == [
        (ids["m1"], 9)
    ]

    # relax 对 w=rated 与 my_rating_gte=10 均给出放宽建议
    relax = client.get(
        f"/api/v1/libraries/{ids['movies_library']}/relax", params={"my_rating_gte": 10}
    ).json()["data"]
    assert relax["total"] == 0
    assert any(s["dim"] == "my_rating_gte" and s["count"] == 3 for s in relax["suggestions"])
    relax_watch = client.get(
        f"/api/v1/libraries/{ids['movies_library']}/relax",
        params={"w": "rated", "my_rating_gte": 10},
    ).json()["data"]
    assert relax_watch["total"] == 0
    assert any(s["dim"] == "my_rating_gte" and s["count"] == 2 for s in relax_watch["suggestions"])

    # 非法 my_rating_gte 返回 400（而非 422）
    for bad in (-5, 0, 11, 99):
        for path in (
            f"/api/v1/libraries/{ids['movies_library']}/items",
            "/api/v1/libraries/kinds/movie/items",
        ):
            r = client.get(path, params={"my_rating_gte": bad})
            assert r.status_code == 400, (path, bad, r.text)
            assert r.json()["message_key"] == "errors.playback.ratingFilterInvalid"


# ---------------------------------------------------------------------------
# 5. 首页数据源 GET /api/v1/playback/rated
# ---------------------------------------------------------------------------


def test_playback_rated_default_threshold_tiebreak_paging_and_isolation(client, tmp_path):
    ids = seed_walls(client, tmp_path)

    # 精确控制 rated_at：m1=9（较早）、m2=9（较晚）、m3=7（低于默认 4 星门槛）、show=10
    async def _seed_ratings() -> None:
        base = utcnow() - timedelta(hours=1)
        async with get_database().session() as session:
            session.add_all(
                [
                    PlaybackState(
                        member_id=0,
                        media_item_id=ids["m1"],
                        season_number=0,
                        episode_number=0,
                        user_rating=9,
                        rated_at=base + timedelta(minutes=1),
                        is_favorite=True,
                    ),
                    PlaybackState(
                        member_id=0,
                        media_item_id=ids["m2"],
                        season_number=0,
                        episode_number=0,
                        user_rating=9,
                        rated_at=base + timedelta(minutes=10),
                    ),
                    PlaybackState(
                        member_id=0,
                        media_item_id=ids["m3"],
                        season_number=0,
                        episode_number=0,
                        user_rating=7,
                        rated_at=base + timedelta(minutes=20),
                    ),
                    PlaybackState(
                        member_id=0,
                        media_item_id=ids["show"],
                        season_number=-1,
                        episode_number=-1,
                        user_rating=10,
                        rated_at=base + timedelta(minutes=5),
                    ),
                ]
            )
            await session.commit()

    client.portal.call(_seed_ratings)  # type: ignore[attr-defined]

    # 默认 min_rating=8：show(10) → m2(9, 较晚) → m1(9, 较早)；m3(7) 被过滤
    body = client.get(f"{_PB}/rated").json()["data"]
    assert body["total"] == 3
    assert [i["media_item_id"] for i in body["items"]] == [ids["show"], ids["m2"], ids["m1"]]
    assert [i["user_rating"] for i in body["items"]] == [10, 9, 9]
    assert all(i["rated_at"] is not None for i in body["items"])
    assert body["items"][2]["is_favorite"] is True and body["items"][1]["is_favorite"] is False

    # 覆盖 min_rating=1：包含 m3(7)
    all_rated = client.get(f"{_PB}/rated", params={"min_rating": 1}).json()["data"]
    assert all_rated["total"] == 4
    assert [i["media_item_id"] for i in all_rated["items"]] == [
        ids["show"],
        ids["m2"],
        ids["m1"],
        ids["m3"],
    ]

    # sort=rated_at：按最近评分倒序
    by_time = client.get(f"{_PB}/rated", params={"min_rating": 1, "sort": "rated_at"}).json()[
        "data"
    ]
    assert [i["media_item_id"] for i in by_time["items"]] == [
        ids["m3"],
        ids["m2"],
        ids["show"],
        ids["m1"],
    ]

    # 分页：limit=2 时 total 仍为全量 3，翻第二页拿第 3 条
    p1 = client.get(f"{_PB}/rated", params={"limit": 2, "offset": 0}).json()["data"]
    p2 = client.get(f"{_PB}/rated", params={"limit": 2, "offset": 2}).json()["data"]
    assert p1["total"] == 3 and p2["total"] == 3
    assert [i["media_item_id"] for i in p1["items"]] == [ids["show"], ids["m2"]]
    assert [i["media_item_id"] for i in p2["items"]] == [ids["m1"]]

    # badges 透传生效（例如 hdr）
    with_hdr = client.get(f"{_PB}/rated", params={"badges": "hdr"}).json()["data"]
    assert all(i["dynamic_range"] == "Dolby Vision" for i in with_hdr["items"])

    # 非法 min_rating 返回 400
    for bad in (-1, 0, 11):
        r = client.get(f"{_PB}/rated", params={"min_rating": bad})
        assert r.status_code == 400, (bad, r.text)
        assert r.json()["message_key"] == "errors.playback.ratingFilterInvalid"

    # 成员隔离与可见库过滤：新建只看得到剧集库的成员
    created = client.post(
        "/api/v1/members",
        json={"username": "viewer", "password": "viewer-pass-1", "nickname": "观众"},
    )
    assert created.status_code == 200, created.text
    member_id = created.json()["data"]["id"]
    client.put(
        f"/api/v1/members/{member_id}",
        json={"all_libraries": False, "library_ids": [ids["shows_library"]]},
    )

    # 即使库里有一条该成员对不可见电影库的评分，也绝不能露出
    async def _seed_member_hidden_rating() -> None:
        async with get_database().session() as session:
            session.add(
                PlaybackState(
                    member_id=member_id,
                    media_item_id=ids["m1"],
                    season_number=0,
                    episode_number=0,
                    user_rating=10,
                    rated_at=utcnow(),
                )
            )
            await session.commit()

    client.portal.call(_seed_member_hidden_rating)  # type: ignore[attr-defined]
    client.post("/api/v1/auth/logout")
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "viewer", "password": "viewer-pass-1"}
        ).status_code
        == 200
    )

    # 成员看不到超管的评分，也看不到不可见电影库里的评分
    assert client.get(f"{_PB}/rated").json()["data"] == {"items": [], "total": 0}
    # 成员给可见的剧打 9 分后只看到这一部
    client.post(f"{_PB}/marks", json={"media_item_id": ids["show"], "rating": 9})
    member_body = client.get(f"{_PB}/rated").json()["data"]
    assert member_body["total"] == 1
    assert [(i["media_item_id"], i["user_rating"]) for i in member_body["items"]] == [
        (ids["show"], 9)
    ]


def test_playback_rated_openapi_and_cli_guard():
    spec = create_app().openapi()
    op = spec["paths"]["/api/v1/playback/rated"]["get"]
    assert op["operationId"] == "playback.rated"
    assert op["x-cli-hidden"] is True
    params = {p["name"]: p for p in op["parameters"]}
    assert {"limit", "offset", "min_rating", "sort", "order", "badges"} <= params.keys()

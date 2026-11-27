"""海报墙角标数据：中文字幕 / Atmos / 动态范围 / 观看进度 / 未看集数 + 详情页播出状态。

这些字段随 ``GET /libraries/{id}/items`` 批量返回，前端不再为每格单独拉详情或
``/playback/marks``。每组角标都要客户端用 ``badges`` 点名才算（没点名为 null，
不跑对应 SQL）。这里验证判定口径、按需执行，以及「整页固定几条查询、与条目数无关」。
"""

from __future__ import annotations

import itertools
from datetime import timedelta

import pytest
import pytest_asyncio
from sqlalchemy import event

from movieclaw_api.api.deps import wall_badges
from movieclaw_api.api.routes.libraries import get_library_item, list_library_items
from movieclaw_api.app import create_app
from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.library import LibraryItemView
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.items import (
    WALL_BADGE_GROUPS,
    _best_dynamic_range,
    build_library_wall,
    parse_wall_badges,
)
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    PlaybackState,
    utcnow,
)
from movieclaw_db.repositories.library_repo import LibraryRepository

_ADMIN = Principal(kind="admin", name="tester")
_ALL = frozenset(WALL_BADGE_GROUPS)
_TMDB_IDS = itertools.count(9000)


def _item(**fields) -> MediaItem:
    return MediaItem(tmdb_id=next(_TMDB_IDS), **fields)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'badges.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path / "data"))
    get_settings.cache_clear()
    reset_setting_store()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store(get_database())
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


def _file(
    library_id: int,
    item_id: int,
    season: int = 0,
    episode: int = 0,
    *,
    subtitles: list | None = None,
    external: list | None = None,
    audio: list | None = None,
    hdr: str | None = None,
    duration: int | None = None,
    missing: bool = False,
    root: str = "/lib",
) -> LibraryFile:
    return LibraryFile(
        library_id=library_id,
        media_item_id=item_id,
        season_number=season,
        episode_number=episode,
        file_path=f"{root}/{item_id}/S{season:02d}E{episode:02d}.mkv",
        size_bytes=1,
        source=FileSource.SCANNED,
        subtitle_streams=subtitles,
        external_subtitles=external,
        audio_streams=audio,
        hdr=hdr,
        duration_seconds=duration,
        missing_since=utcnow() if missing else None,
        state=FileState.MISSING if missing else FileState.IN_PLACE,
    )


async def _wall(
    session,
    library_id: int,
    principal: Principal = _ADMIN,
    badges: frozenset[str] = _ALL,
    limit: int | None = None,
) -> dict:
    resp = await list_library_items(
        library_id, limit=limit, badges=badges, session=session, principal=principal
    )
    return {row.media_item_id: row for row in resp.data}


class _Statements:
    """记下一段代码里发到数据库的全部 SQL（断言「没请求就没跑」用）。"""

    def __init__(self, db) -> None:
        self.engine = db.engine.sync_engine
        self.all: list[str] = []

    def _capture(self, _conn, _cursor, statement, *_args) -> None:
        self.all.append(statement)

    def __enter__(self) -> _Statements:
        event.listen(self.engine, "before_cursor_execute", self._capture)
        return self

    def __exit__(self, *_exc) -> None:
        event.remove(self.engine, "before_cursor_execute", self._capture)

    def count(self, needle: str) -> int:
        return sum(1 for sql in self.all if needle in sql)

    @property
    def json_each(self) -> int:
        return self.count("json_each")

    @property
    def watch_states(self) -> int:
        # 观看状态查询是唯一取续播点的；收藏态那条（favorite_item_ids）不取它
        return self.count("playback_state.position_ms")


async def test_chinese_subtitle_detection_covers_codes_titles_and_external_files(db) -> None:
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=["/lib"]
        )
        titles = ["码", "标题", "外挂", "英文", "未探测", "缺失", "粤语", "zh-Hant"]
        items = [_item(kind="movie", title=t, original_title=t) for t in titles]
        session.add_all(items)
        await session.flush()
        by_code, by_title, by_external, english, unprobed, missing, cantonese, bcp47 = (
            i.id for i in items
        )
        assert library.id
        session.add_all(
            [
                _file(library.id, by_code, subtitles=[{"language": "chi", "title": None}]),
                # 语言码缺失 / und，只能靠标题认
                _file(library.id, by_title, subtitles=[{"language": "und", "title": "简体中文"}]),
                # 外挂字幕台账：文件名 token 已在扫描时归一为 chi
                _file(
                    library.id,
                    by_external,
                    subtitles=[{"language": "eng", "title": "English"}],
                    external=[{"filename": "x.chs.srt", "language": "chi", "title": None}],
                ),
                _file(library.id, english, subtitles=[{"language": "eng", "title": "SDH"}]),
                _file(library.id, unprobed),  # 字幕列 NULL：未探测
                # 文件已失联：放不了的字幕不算
                _file(
                    library.id,
                    missing,
                    subtitles=[{"language": "zho", "title": None}],
                    missing=True,
                ),
                _file(library.id, cantonese, subtitles=[{"language": "yue", "title": None}]),
                _file(library.id, bcp47, subtitles=[{"language": "zh-Hant", "title": None}]),
            ]
        )
        await session.flush()

        rows = await _wall(session, library.id)

    zh = {item_id for item_id, row in rows.items() if row.has_chinese_subtitle}
    assert zh == {by_code, by_title, by_external, cantonese, bcp47}
    assert not rows[english].has_chinese_subtitle
    assert not rows[unprobed].has_chinese_subtitle
    assert not rows[missing].has_chinese_subtitle


async def test_series_counts_chinese_subtitle_on_any_episode(db) -> None:
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=["/lib"]
        )
        show = _item(kind="tv", title="剧", original_title="S", status="Ended")
        session.add(show)
        await session.flush()
        assert library.id and show.id
        session.add_all(
            [
                _file(library.id, show.id, 1, 1, subtitles=[{"language": "eng"}]),
                _file(library.id, show.id, 1, 2, subtitles=[]),
                _file(library.id, show.id, 1, 3, subtitles=[{"language": None, "title": "繁中"}]),
            ]
        )
        await session.flush()
        rows = await _wall(session, library.id)
    assert rows[show.id].has_chinese_subtitle is True


async def test_format_badges_atmos_and_best_dynamic_range(db) -> None:
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=["/lib"]
        )
        items = [_item(kind="movie", title=t, original_title=t) for t in "ABCD"]
        session.add_all(items)
        await session.flush()
        dv_atmos, hdr_title_atmos, sdr, dv_missing = (i.id for i in items)
        assert library.id
        session.add_all(
            [
                # 同一部两个版本：最好的是杜比视界
                _file(library.id, dv_atmos, hdr="HDR10", root="/a"),
                _file(
                    library.id,
                    dv_atmos,
                    hdr="Dolby Vision",
                    audio=[{"codec": "truehd", "profile": "Dolby TrueHD + Dolby Atmos"}],
                    root="/b",
                ),
                # 探不出 Atmos 层时字幕组常把它写在音轨标题里
                _file(
                    library.id,
                    hdr_title_atmos,
                    hdr="HDR10+",
                    audio=[{"codec": "eac3", "profile": None, "title": "DDP 5.1 ATMOS"}],
                ),
                _file(library.id, sdr, audio=[{"codec": "aac", "profile": "LC"}]),
                # 杜比视界那份文件失联了：只剩 SDR 在位
                _file(library.id, dv_missing, hdr="Dolby Vision", missing=True, root="/a"),
                _file(library.id, dv_missing, root="/b"),
            ]
        )
        await session.flush()
        rows = await _wall(session, library.id)

    assert (rows[dv_atmos].dynamic_range, rows[dv_atmos].has_atmos) == ("Dolby Vision", True)
    assert (rows[hdr_title_atmos].dynamic_range, rows[hdr_title_atmos].has_atmos) == (
        "HDR10+",
        True,
    )
    assert (rows[sdr].dynamic_range, rows[sdr].has_atmos) == (None, False)
    assert rows[dv_missing].dynamic_range is None


def test_best_dynamic_range_ranking() -> None:
    assert _best_dynamic_range([None, "HLG", "HDR10", None]) == "HDR10"
    assert _best_dynamic_range(["HDR", "HDR10+"]) == "HDR10+"
    assert _best_dynamic_range(["奇怪的标签", "HLG"]) == "HLG"
    assert _best_dynamic_range([None, None]) is None


async def test_watch_progress_and_unplayed_count_per_viewer(db) -> None:
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="混合", kind="tv", root_paths=["/lib"]
        )
        show = _item(kind="tv", title="剧", original_title="S", status="Returning Series")
        fresh = _item(kind="tv", title="新剧", original_title="N", status="Ended")
        movie = _item(kind="movie", title="电影", original_title="M")
        done = _item(kind="movie", title="看完", original_title="D")
        session.add_all([show, fresh, movie, done])
        await session.flush()
        assert library.id and show.id and fresh.id and movie.id and done.id
        session.add_all(
            [
                *(_file(library.id, show.id, 1, e, duration=1000) for e in (1, 2, 3, 4)),
                # 第 5 集文件失联：不算「本墙在位的未看集」
                _file(library.id, show.id, 1, 5, missing=True),
                *(_file(library.id, fresh.id, 1, e) for e in (1, 2)),
                _file(library.id, movie.id, duration=7200),
                _file(library.id, done.id, duration=7200),
            ]
        )
        now = utcnow()
        session.add_all(
            [
                # 超管：剧看完 E1，E2 看了 25%，更早的 E3 停在 90%——进度取最近的那集
                PlaybackState(
                    member_id=0,
                    media_item_id=show.id,
                    season_number=1,
                    episode_number=1,
                    played=True,
                    last_played_at=now - timedelta(days=3),
                ),
                PlaybackState(
                    member_id=0,
                    media_item_id=show.id,
                    season_number=1,
                    episode_number=2,
                    position_ms=250_000,
                    last_played_at=now - timedelta(hours=1),
                ),
                PlaybackState(
                    member_id=0,
                    media_item_id=show.id,
                    season_number=1,
                    episode_number=3,
                    position_ms=900_000,
                    last_played_at=now - timedelta(days=2),
                ),
                # 收藏哨兵单元不是播放事实
                PlaybackState(
                    member_id=0,
                    media_item_id=show.id,
                    season_number=-1,
                    episode_number=-1,
                    is_favorite=True,
                ),
                PlaybackState(
                    member_id=0,
                    media_item_id=movie.id,
                    position_ms=3_600_000,
                    last_played_at=now,
                ),
                PlaybackState(member_id=0, media_item_id=done.id, played=True, last_played_at=now),
                # 另一个成员把整部剧都看完了
                *(
                    PlaybackState(
                        member_id=7,
                        media_item_id=show.id,
                        season_number=1,
                        episode_number=e,
                        played=True,
                        last_played_at=now,
                    )
                    for e in (1, 2, 3, 4)
                ),
            ]
        )
        await session.flush()

        admin = await _wall(session, library.id)
        member = await _wall(
            session, library.id, Principal(kind="member", name="m", member_id=7, is_admin=False)
        )

    assert (admin[show.id].progress_percent, admin[show.id].unplayed_count) == (25, 3)
    assert (admin[fresh.id].progress_percent, admin[fresh.id].unplayed_count) == (None, 2)
    assert (admin[movie.id].progress_percent, admin[movie.id].unplayed_count) == (50, None)
    assert (admin[done.id].progress_percent, admin[done.id].unplayed_count) == (None, None)
    assert (member[show.id].progress_percent, member[show.id].unplayed_count) == (None, 0)
    assert member[movie.id].progress_percent is None


async def test_badge_fields_cost_a_fixed_number_of_queries(db) -> None:
    """整页的角标数据是批量查询：条目从 2 部涨到 12 部，查询条数不变（没有 N+1）。"""

    async def seed(library_id: int, count: int, offset: int) -> None:
        items = [
            _item(kind="tv", title=f"剧{offset + n}", original_title=f"S{offset + n}")
            for n in range(count)
        ]
        session.add_all(items)
        await session.flush()
        for item in items:
            assert item.id
            session.add_all(
                [
                    _file(
                        library_id,
                        item.id,
                        1,
                        e,
                        subtitles=[{"language": "chi"}],
                        audio=[{"profile": "Atmos"}],
                        root=f"/lib{library_id}",
                    )
                    for e in (1, 2, 3)
                ]
            )
            session.add(
                PlaybackState(
                    member_id=0,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=1,
                    position_ms=10,
                    last_played_at=utcnow(),
                )
            )
        await session.flush()

    async def count_queries(library_id: int) -> tuple[int, dict]:
        statements: list[str] = []

        def capture(_conn, _cursor, statement, *_args) -> None:
            statements.append(statement)

        engine = db.engine.sync_engine
        event.listen(engine, "before_cursor_execute", capture)
        try:
            rows = await _wall(session, library_id)
        finally:
            event.remove(engine, "before_cursor_execute", capture)
        return len(statements), rows

    async with db.session() as session:
        repo = LibraryRepository(session)
        small = await repo.create(name="小", kind="tv", root_paths=["/lib1"])
        large = await repo.create(name="大", kind="tv", root_paths=["/lib2"])
        assert small.id and large.id
        await seed(small.id, 2, 0)
        await seed(large.id, 12, 100)

        small_count, small_rows = await count_queries(small.id)
        large_count, large_rows = await count_queries(large.id)
        # 首次调用多一条进程内缓存的查询：全开 / 全关各在热身之后量
        with _Statements(db) as on:
            await _wall(session, large.id)
        with _Statements(db) as off:
            await _wall(session, large.id, badges=frozenset())

    assert len(small_rows) == 2 and len(large_rows) == 12
    assert all(r.has_chinese_subtitle and r.has_atmos for r in large_rows.values())
    assert all(r.unplayed_count == 3 for r in large_rows.values())
    assert large_count == small_count
    # 全开比全关恰好多 4 条：中文字幕 2（内封 + 外挂）、Atmos 1、观看状态 1
    assert len(off.all) == len(on.all) - 4
    assert (off.json_each, off.watch_states) == (0, 0)


@pytest.mark.parametrize(
    ("kind", "status", "expected"),
    [("tv", "Ended", "ended"), ("tv", "Returning Series", "airing"), ("movie", "Released", None)],
)
async def test_item_detail_carries_air_status(db, tmp_path, kind, status, expected) -> None:
    root = tmp_path / "media"
    root.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="库", kind=kind, root_paths=[str(root)]
        )
        item = _item(kind=kind, title="条目", original_title="X", status=status)
        session.add(item)
        await session.flush()
        assert library.id and item.id
        session.add(
            _file(library.id, item.id, *((1, 1) if kind == "tv" else (0, 0)), root=str(root))
        )
        await session.flush()
        detail = (await get_library_item(library.id, item.id, _ADMIN, session)).data
    assert detail.air_status == expected


async def _seed_mixed(session) -> tuple[int, int, int]:
    """一部带全套角标数据的电影 + 一部看了一集的剧，返回 (库, 电影, 剧)。"""
    library = await LibraryRepository(session).create(name="混合", kind="tv", root_paths=["/lib"])
    movie = _item(kind="movie", title="电影", original_title="M")
    show = _item(kind="tv", title="剧", original_title="S", status="Ended")
    session.add_all([movie, show])
    await session.flush()
    assert library.id and movie.id and show.id
    session.add_all(
        [
            _file(
                library.id,
                movie.id,
                subtitles=[{"language": "chi", "title": None}],
                audio=[{"codec": "truehd", "profile": "Dolby TrueHD + Dolby Atmos"}],
                hdr="Dolby Vision",
                duration=1000,
            ),
            *(
                _file(library.id, show.id, 1, e, subtitles=[{"language": "eng"}], duration=1000)
                for e in (1, 2, 3)
            ),
            PlaybackState(
                member_id=0, media_item_id=movie.id, position_ms=400_000, last_played_at=utcnow()
            ),
            PlaybackState(
                member_id=0,
                media_item_id=show.id,
                season_number=1,
                episode_number=1,
                played=True,
                last_played_at=utcnow(),
            ),
        ]
    )
    await session.flush()
    return library.id, movie.id, show.id


_BADGE_FIELDS = (
    "has_chinese_subtitle",
    "has_atmos",
    "dynamic_range",
    "progress_percent",
    "unplayed_count",
)


@pytest.mark.parametrize("limit", [None, 60], ids=["unpaged", "paged"])
async def test_no_badges_requested_runs_no_badge_sql_and_returns_null(db, limit) -> None:
    """不带 badges（老客户端、手机 / 电视）：不展开 JSON、不查观看状态、不取角标列，
    五个角标字段全是 null——分页与整库两条路都一样。"""
    async with db.session() as session:
        library_id, movie_id, show_id = await _seed_mixed(session)
        with _Statements(db) as sql:
            rows = await _wall(session, library_id, badges=frozenset(), limit=limit)

    assert set(rows) == {movie_id, show_id}
    for row in rows.values():
        assert {name: getattr(row, name) for name in _BADGE_FIELDS} == dict.fromkeys(_BADGE_FIELDS)
    assert sql.json_each == 0
    assert sql.watch_states == 0
    assert sql.count("library_file.hdr") == 0
    assert sql.count("library_file.duration_seconds") == 0
    # 墙本来就带的字段不受影响
    assert rows[show_id].air_status == "ended"


@pytest.mark.parametrize(
    ("groups", "json_each", "watch_states", "expected_movie", "expected_show"),
    [
        (
            {"zh"},
            2,
            0,
            {"has_chinese_subtitle": True},
            {"has_chinese_subtitle": False},
        ),
        ({"atmos"}, 1, 0, {"has_atmos": True}, {"has_atmos": False}),
        ({"hdr"}, 0, 0, {"dynamic_range": "Dolby Vision"}, {"dynamic_range": None}),
        ({"progress"}, 0, 1, {"progress_percent": 40}, {"progress_percent": None}),
        ({"unwatched"}, 0, 1, {"unplayed_count": None}, {"unplayed_count": 2}),
        # 进度与未看集数共用一次观看状态查询
        (
            {"progress", "unwatched"},
            0,
            1,
            {"progress_percent": 40, "unplayed_count": None},
            {"progress_percent": None, "unplayed_count": 2},
        ),
    ],
    ids=["zh", "atmos", "hdr", "progress", "unwatched", "progress+unwatched"],
)
async def test_each_badge_group_runs_only_its_own_query(
    db, groups, json_each, watch_states, expected_movie, expected_show
) -> None:
    async with db.session() as session:
        library_id, movie_id, show_id = await _seed_mixed(session)
        with _Statements(db) as sql:
            rows = await _wall(session, library_id, badges=frozenset(groups))

    assert (sql.json_each, sql.watch_states) == (json_each, watch_states)
    for item_id, expected in ((movie_id, expected_movie), (show_id, expected_show)):
        row = rows[item_id]
        for name in _BADGE_FIELDS:
            # 请求了的字段给出确定值；没请求的一律 null（未知）
            assert getattr(row, name) == expected.get(name), (item_id, name)


async def test_watch_badges_need_a_viewer(db) -> None:
    """不认人的内部调用（member_id=None）点名要进度 / 未看集数也不查观看状态，
    给 null；与观看者无关的角标照常算。"""
    async with db.session() as session:
        library_id, movie_id, show_id = await _seed_mixed(session)
        with _Statements(db) as sql:
            views = await build_library_wall(session, library_id, member_id=None, badges=_ALL)

    rows = {view.media_item_id: view for view in views}
    assert sql.watch_states == 0
    assert all(r.progress_percent is None and r.unplayed_count is None for r in rows.values())
    assert rows[movie_id].has_chinese_subtitle is True
    assert rows[movie_id].has_atmos is True
    assert rows[movie_id].dynamic_range == "Dolby Vision"
    assert rows[show_id].has_chinese_subtitle is False


def test_badges_param_parsing() -> None:
    assert parse_wall_badges(None) == frozenset()
    assert parse_wall_badges("") == frozenset()
    # 空格、重复、空段、认不出的分组（更新的网页连旧服务端）都容忍
    assert parse_wall_badges(" zh,atmos,,zh,bogus") == {"zh", "atmos"}
    assert parse_wall_badges(",".join(WALL_BADGE_GROUPS)) == _ALL
    assert wall_badges("progress,unwatched") == {"progress", "unwatched"}


def test_wall_routes_declare_the_badges_query_param() -> None:
    """画角标的网页要用的五面墙都接受 badges；生成客户端（安卓 / Apple）据 OpenAPI
    看到的是一个可选的字符串参数。"""
    spec = create_app().openapi()
    walls = [
        ("/api/v1/libraries/{library_id}/items", "get"),
        ("/api/v1/libraries/kinds/{kind}/items", "get"),
        ("/api/v1/libraries/{library_id}/items/{media_item_id}/similar", "get"),
        ("/api/v1/collections/{collection_id}/items", "get"),
        ("/api/v1/playback/favorites", "get"),
    ]
    for path, method in walls:
        params = {p["name"]: p for p in spec["paths"][path][method]["parameters"]}
        assert "badges" in params, path
        assert params["badges"]["required"] is False


def test_new_boolean_badge_fields_are_nullable() -> None:
    """Apple 生成器按「序列化」口径读 Pydantic schema，只有可空的字段才出 Swift 可选
    （apps/apple/scripts/gen_api.py）。两个布尔必须可空、默认 null，新客户端连旧服务端
    （没有这两个字段）才不会整墙解码失败。"""
    for name in ("has_atmos", "has_chinese_subtitle"):
        field = LibraryItemView.model_fields[name]
        assert field.annotation == bool | None
        assert field.default is None

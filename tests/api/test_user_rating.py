"""个人评分第一期后端测试（issue #1292，docs/design/user-rating.md）。

覆盖：
- Alembic 迁移升级 / 回退及存量默认 NULL；
- 电影与整剧评分的设置 / 改分 / 清除及哨兵单元约定；
- 越界值返回 400、带季 / 集参数返回 400；
- 成员之间互不可见、不可见库 404、条目详情接口携带 user_rating；
- set_rating 发出 library.item.rated / unrated（sensitive=True）且不写播放进度；
- 取消已看（mark_unplayed）不影响已存评分；
- Webhook Jellyfin 映射（UserDataSaved）。
"""

from __future__ import annotations

import itertools
import sqlite3
from datetime import UTC, datetime
from functools import partial
from pathlib import Path

import pytest
from alembic import command
from fastapi.testclient import TestClient
from sqlalchemy import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.playback import marks as playback_marks
from movieclaw_api.services.webhook.catalog import JELLYFIN_TYPES
from movieclaw_api.services.webhook.jellyfin_formatter import targets, variables
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.migrations import _build_config
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaEpisode,
    MediaItem,
    PlaybackLog,
    PlaybackState,
)
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_jellyfin.ids import item_guid
from movieclaw_playback import state as playback_state
from movieclaw_playback.events import ClientInfo
from movieclaw_sdk.events import (
    LIBRARY_ITEM_RATED,
    LIBRARY_ITEM_UNRATED,
    ItemRating,
    MediaRef,
)

_PB = "/api/v1/playback"
_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'rating.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    monkeypatch.setattr("movieclaw_api.api.routes.playback.available_backends", lambda: ())

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


@pytest.fixture
def emitted(monkeypatch) -> list:
    """捕获领域事件（替换唯一入口 events.publish）。"""
    import inspect
    from types import SimpleNamespace

    from movieclaw_api import events

    captured: list = []

    async def publish(session, event, build, *, occurred_at=None):  # type: ignore[no-untyped-def]
        payload = build()
        if inspect.isawaitable(payload):
            payload = await payload
        if payload is not None:
            captured.append(
                SimpleNamespace(event=event.name, sensitive=event.sensitive, data=payload)
            )

    monkeypatch.setattr(events, "publish", publish)
    return captured


_seed_counter = itertools.count(1)


async def _seed(tmp_path: Path) -> dict[str, int]:
    """一部电影 + 一部三集剧，各落在位文件。"""
    n = next(_seed_counter)
    root = tmp_path / f"media{n}"
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
        )

    async with get_database().session() as session:
        repo = LibraryRepository(session)
        movies = await repo.create(name=f"电影库{n}", kind="movie", root_paths=[str(root)])
        shows = await repo.create(name=f"剧集库{n}", kind="tv", root_paths=[str(root)])
        movie = MediaItem(kind="movie", tmdb_id=3000 + n, title="电影", original_title="Movie")
        show = MediaItem(kind="tv", tmdb_id=4000 + n, title="剧集", original_title="Series")
        session.add_all([movie, show])
        await session.flush()
        assert movie.id and show.id and movies.id and shows.id
        session.add(_file(movie.id, movies.id, 0, 0, f"movie{n}.mkv"))
        for e in (1, 2, 3):
            session.add(_file(show.id, shows.id, 1, e, f"S01E0{e}-{n}.mkv"))
            session.add(MediaEpisode(media_item_id=show.id, season_number=1, episode_number=e))
        await session.commit()
        return {
            "movie": movie.id,
            "show": show.id,
            "movies_library": movies.id,
            "shows_library": shows.id,
        }


def seed(client: TestClient, tmp_path: Path) -> dict[str, int]:
    return client.portal.call(partial(_seed, tmp_path))  # type: ignore[attr-defined]


def get_marks(client: TestClient, **params) -> dict:
    resp = client.get(f"{_PB}/marks", params=params)
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def set_marks(client: TestClient, **body) -> dict:
    resp = client.post(f"{_PB}/marks", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def get_detail(client: TestClient, library_id: int, media_item_id: int) -> dict:
    resp = client.get(f"/api/v1/libraries/{library_id}/items/{media_item_id}")
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


async def _rows(item_id: int) -> dict[tuple[int, int, int], PlaybackState]:
    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(PlaybackState).where(PlaybackState.media_item_id == item_id)
            )
        ).scalars()
        return {(r.member_id, r.season_number, r.episode_number): r for r in rows}


def rows(client: TestClient, item_id: int) -> dict[tuple[int, int, int], PlaybackState]:
    return client.portal.call(partial(_rows, item_id))  # type: ignore[attr-defined]


async def _logs(item_id: int) -> list[PlaybackLog]:
    async with get_database().session() as session:
        return list(
            (
                await session.execute(
                    select(PlaybackLog).where(PlaybackLog.media_item_id == item_id)
                )
            ).scalars()
        )


def logs(client: TestClient, item_id: int) -> list[PlaybackLog]:
    return client.portal.call(partial(_logs, item_id))  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# 迁移：存量默认 NULL，升降级可逆
# ---------------------------------------------------------------------------


def test_user_rating_migration_upgrade_downgrade_defaults_null(tmp_path, monkeypatch):
    path = tmp_path / "migration.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    try:
        config = _build_config()
        command.upgrade(config, "be3b7498a20c")
        with sqlite3.connect(path) as db:
            required = [
                (r[1], r[2])
                for r in db.execute("pragma table_info(media_item)")
                if r[3] and r[4] is None and not r[5]
            ]
            values = {
                name: (1 if "INT" in type_.upper() or "BOOL" in type_.upper() else "x")
                for name, type_ in required
            }
            values.update(id=1, kind="movie", source="local", external_id="x")
            values.update(created_at="2026-01-01", updated_at="2026-01-01")
            if "aliases" in values:
                values["aliases"] = "[]"
            db.execute(
                f"insert into media_item ({', '.join(values)})"
                f" values ({', '.join('?' * len(values))})",
                list(values.values()),
            )
            db.execute(
                "insert into playback_state (member_id, media_item_id, season_number,"
                " episode_number, position_ms, played, play_count, is_favorite,"
                " last_played_at, created_at, updated_at)"
                " values (0, 1, 0, 0, 5000, 0, 2, 1, '2026-01-02', '2026-01-01', '2026-01-02')"
            )

        command.upgrade(config, "head")
        with sqlite3.connect(path) as db:
            row = db.execute(
                "select position_ms, played, play_count, is_favorite, last_played_at,"
                " user_rating, rated_at from playback_state"
            ).fetchone()
            assert row == (5000, 0, 2, 1, "2026-01-02", None, None)

        command.downgrade(config, "be3b7498a20c")
        with sqlite3.connect(path) as db:
            cols = {r[1] for r in db.execute("pragma table_info(playback_state)")}
            assert not {"user_rating", "rated_at"} & cols
            assert db.execute("select play_count from playback_state").fetchone() == (2,)

        command.upgrade(config, "head")
    finally:
        get_settings.cache_clear()


# ---------------------------------------------------------------------------
# 设置 / 改分 / 清除 + 哨兵单元 + 条目详情
# ---------------------------------------------------------------------------


def test_movie_and_series_rating_set_update_clear_and_detail(client, tmp_path):
    ids = seed(client, tmp_path)

    # 初始未评分
    assert get_marks(client, media_item_id=ids["movie"])["user_rating"] is None
    assert get_detail(client, ids["movies_library"], ids["movie"])["user_rating"] is None

    # 电影评分：落在 (0, 0)
    res = set_marks(client, media_item_id=ids["movie"], rating=7)
    assert res["user_rating"] == 7
    assert get_marks(client, media_item_id=ids["movie"])["user_rating"] == 7
    assert get_detail(client, ids["movies_library"], ids["movie"])["user_rating"] == 7
    movie_rows = rows(client, ids["movie"])
    assert movie_rows[(0, 0, 0)].user_rating == 7
    first_rated_at = movie_rows[(0, 0, 0)].rated_at
    assert first_rated_at is not None

    # 改分：更新 user_rating 与 rated_at
    res = set_marks(client, media_item_id=ids["movie"], rating=10)
    assert res["user_rating"] == 10
    movie_rows = rows(client, ids["movie"])
    assert movie_rows[(0, 0, 0)].user_rating == 10
    assert movie_rows[(0, 0, 0)].rated_at is not None
    assert movie_rows[(0, 0, 0)].rated_at >= first_rated_at

    # 不传 rating 仅改收藏：不改评分
    res = set_marks(client, media_item_id=ids["movie"], favorite=True)
    assert res["is_favorite"] is True and res["user_rating"] == 10

    # 清除评分（rating=0）：user_rating 与 rated_at 均置 NULL
    res = set_marks(client, media_item_id=ids["movie"], rating=0)
    assert res["user_rating"] is None and res["is_favorite"] is True
    assert get_detail(client, ids["movies_library"], ids["movie"])["user_rating"] is None
    movie_rows = rows(client, ids["movie"])
    assert movie_rows[(0, 0, 0)].user_rating is None
    assert movie_rows[(0, 0, 0)].rated_at is None

    # 整剧评分：复用收藏哨兵 (-1, -1)，绝不污染 (0, 0)
    res = set_marks(client, media_item_id=ids["show"], rating=9)
    assert res["user_rating"] == 9
    assert get_detail(client, ids["shows_library"], ids["show"])["user_rating"] == 9
    show_rows = rows(client, ids["show"])
    assert show_rows[(0, -1, -1)].user_rating == 9
    assert show_rows[(0, -1, -1)].rated_at is not None
    assert (0, 0, 0) not in show_rows


# ---------------------------------------------------------------------------
# 参数校验：越界返回 400、带季 / 集参数返回 400
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bad_rating", [-5, -1, 11, 100])
def test_out_of_range_rating_returns_400(client, tmp_path, bad_rating):
    ids = seed(client, tmp_path)
    resp = client.post(f"{_PB}/marks", json={"media_item_id": ids["movie"], "rating": bad_rating})
    assert resp.status_code == 400, resp.text
    assert resp.json()["message_key"] == "errors.playback.ratingInvalid"


@pytest.mark.parametrize(
    "extra",
    [
        {"season_number": 1},
        {"season_number": 1, "episode_number": 1},
        {"episode_number": 1},
        {"season_number": 0, "episode_number": 0},
    ],
)
def test_rating_with_season_or_episode_returns_400(client, tmp_path, extra):
    ids = seed(client, tmp_path)
    resp = client.post(f"{_PB}/marks", json={"media_item_id": ids["show"], "rating": 8, **extra})
    assert resp.status_code == 400, resp.text
    assert resp.json()["message_key"] == "errors.playback.ratingItemOnly"

    clear_resp = client.post(
        f"{_PB}/marks", json={"media_item_id": ids["show"], "rating": 0, **extra}
    )
    assert clear_resp.status_code == 400, clear_resp.text
    assert clear_resp.json()["message_key"] == "errors.playback.ratingItemOnly"


def test_state_set_rating_rejects_invalid_values(client, tmp_path):
    ids = seed(client, tmp_path)

    async def _check() -> None:
        async with get_database().session() as session:
            for bad in (0, -1, 11, True):
                with pytest.raises(ValueError):
                    await playback_state.set_rating(
                        session, (ids["movie"], 0, 0), member_id=0, rating=bad
                    )

    client.portal.call(_check)  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# 成员隔离：互不可见
# ---------------------------------------------------------------------------


def test_ratings_are_isolated_per_member(client, tmp_path):
    ids = seed(client, tmp_path)
    set_marks(client, media_item_id=ids["movie"], rating=9)
    set_marks(client, media_item_id=ids["show"], rating=8)

    created = client.post(
        "/api/v1/members",
        json={"username": "family", "password": "family-pass-1", "nickname": "家人"},
    )
    assert created.status_code == 200, created.text
    member_id = created.json()["data"]["id"]
    updated = client.put(
        f"/api/v1/members/{member_id}",
        json={"all_libraries": False, "library_ids": [ids["shows_library"]]},
    )
    assert updated.status_code == 200, updated.text
    client.post("/api/v1/auth/logout")
    login = client.post(
        "/api/v1/auth/login", json={"username": "family", "password": "family-pass-1"}
    )
    assert login.status_code == 200, login.text

    # 不可见库：404
    assert (
        client.post(f"{_PB}/marks", json={"media_item_id": ids["movie"], "rating": 5}).status_code
        == 404
    )
    # 同一部剧看不到超管的评分
    assert get_marks(client, media_item_id=ids["show"])["user_rating"] is None
    assert get_detail(client, ids["shows_library"], ids["show"])["user_rating"] is None

    # 成员打自己的分，不覆盖超管的
    assert set_marks(client, media_item_id=ids["show"], rating=4)["user_rating"] == 4
    assert get_detail(client, ids["shows_library"], ids["show"])["user_rating"] == 4
    show_rows = rows(client, ids["show"])
    assert show_rows[(0, -1, -1)].user_rating == 8
    assert show_rows[(member_id, -1, -1)].user_rating == 4


# ---------------------------------------------------------------------------
# 事件产生且不写播放进度
# ---------------------------------------------------------------------------


def test_set_rating_emits_events_and_does_not_write_playback_progress(client, tmp_path, emitted):
    ids = seed(client, tmp_path)

    # 首次打分
    set_marks(client, media_item_id=ids["movie"], rating=7, device_id="browser-1")
    # 改分
    set_marks(client, media_item_id=ids["movie"], rating=10, device_id="browser-1")
    # 清除
    set_marks(client, media_item_id=ids["movie"], rating=0, device_id="browser-1")
    # 整剧打分
    set_marks(client, media_item_id=ids["show"], rating=8)

    assert [e.event for e in emitted] == [
        "library.item.rated",
        "library.item.rated",
        "library.item.unrated",
        "library.item.rated",
    ]
    assert all(e.sensitive is True for e in emitted)

    first, second, cleared, series = emitted
    assert first.data.member_id == 0
    assert first.data.media.id == ids["movie"]
    assert first.data.level == "movie"
    assert first.data.rating == 7 and first.data.previous_rating is None
    assert first.data.season is None and first.data.episode is None
    assert first.data.client.name == "MovieClaw Web"

    assert second.data.rating == 10 and second.data.previous_rating == 7
    assert cleared.data.rating is None and cleared.data.previous_rating == 10
    assert series.data.media.id == ids["show"] and series.data.level == "series"
    assert series.data.rating == 8 and series.data.previous_rating is None

    # 评分不写播放进度、已看、播放次数、最近播放时间或播放日志
    movie_row = rows(client, ids["movie"])[(0, 0, 0)]
    assert movie_row.position_ms == 0
    assert movie_row.played is False
    assert movie_row.play_count == 0
    assert movie_row.last_played_at is None
    assert logs(client, ids["movie"]) == []

    # 服务层 marks.set_rating 直接调用也遵循同样契约
    emitted.clear()

    async def _direct() -> None:
        async with get_database().session() as session:
            await playback_marks.set_rating(
                session,
                playback_marks.MarkTarget(ids["movie"]),
                member_id=0,
                client=ClientInfo(name="Direct"),
                rating=6,
            )

    client.portal.call(_direct)  # type: ignore[attr-defined]
    assert len(emitted) == 1
    assert emitted[0].event == "library.item.rated"
    assert emitted[0].data.rating == 6 and emitted[0].data.previous_rating is None
    assert rows(client, ids["movie"])[(0, 0, 0)].play_count == 0


# ---------------------------------------------------------------------------
# 取消已看不影响已存评分
# ---------------------------------------------------------------------------


def test_mark_unplayed_preserves_user_rating(client, tmp_path):
    ids = seed(client, tmp_path)

    # 电影：先标已看 + 评分，再取消已看
    set_marks(client, media_item_id=ids["movie"], played=True, rating=8)
    rated_at = rows(client, ids["movie"])[(0, 0, 0)].rated_at
    assert rated_at is not None

    after_unplayed = set_marks(client, media_item_id=ids["movie"], played=False)
    assert after_unplayed["played"] is False
    assert after_unplayed["user_rating"] == 8
    movie_row = rows(client, ids["movie"])[(0, 0, 0)]
    assert movie_row.played is False
    assert movie_row.play_count == 0
    assert movie_row.position_ms == 0
    assert movie_row.last_played_at is None
    assert movie_row.user_rating == 8
    assert movie_row.rated_at == rated_at

    # 整剧：先标已看 + 评分，再取消已看
    set_marks(client, media_item_id=ids["show"], played=True, rating=9)
    show_rated_at = rows(client, ids["show"])[(0, -1, -1)].rated_at
    assert show_rated_at is not None

    after_show_unplayed = set_marks(client, media_item_id=ids["show"], played=False)
    assert after_show_unplayed["played"] is False
    assert after_show_unplayed["user_rating"] == 9
    assert rows(client, ids["show"])[(0, -1, -1)].user_rating == 9
    assert rows(client, ids["show"])[(0, -1, -1)].rated_at == show_rated_at


# ---------------------------------------------------------------------------
# 事件定义敏感标记 & Webhook Jellyfin 映射
# ---------------------------------------------------------------------------


def test_rating_events_metadata_and_jellyfin_webhook_mapping():
    assert LIBRARY_ITEM_RATED.sensitive is True
    assert LIBRARY_ITEM_UNRATED.sensitive is True
    assert JELLYFIN_TYPES["library.item.rated"] == "UserDataSaved"
    assert JELLYFIN_TYPES["library.item.unrated"] == "UserDataSaved"

    server = {
        "id": "srv01",
        "name": "MovieClaw",
        "version": "0.52.0",
        "url": "http://mc.lan:3000",
        "username": "admin",
    }
    occurred = datetime(2026, 11, 26, 12, 0, tzinfo=UTC)
    movie = MediaRef(id=42, kind="movie", title="星际穿越", year=2014, tmdb_id=157336)
    data = ItemRating(
        member_id=0, media=movie, level="movie", rating=9, previous_rating=7
    ).model_dump(mode="json")
    [target] = targets("library.item.rated", data)
    values = variables(
        JELLYFIN_TYPES["library.item.rated"],
        data,
        target,
        occurred_at=occurred,
        server=server,
        username="admin",
        episode_title=None,
        completed=False,
        favorite=False,
    )
    assert values["NotificationType"] == "UserDataSaved"
    assert values["ItemType"] == "Movie"
    assert values["ItemId"] == item_guid(42)
    assert values["Name"] == "星际穿越"

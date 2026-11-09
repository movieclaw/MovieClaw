"""真实 HTTP + SQLite：「接下来继续」隐藏（``dismiss_continue`` / ``continue_dismissed``）。

真实播放走 ``/playback/progress``（落 playback_state + playback_log），隐藏走
``/playback/sync/state``，结果从 ``/playback/up-next``（含 ``this_device``）、
``/playback/resume`` 与 sync catalog 读回——不直接摆状态行。
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from movieclaw_api.api.deps import require_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import DeviceRef, Principal, reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    Member,
    PlaybackLog,
    PlaybackState,
)
from movieclaw_db.repositories.library_repo import LibraryRepository

SYNC = "/api/v1/playback/sync"
ADMIN = Principal(kind="admin", name="admin")


@pytest.fixture
def env(tmp_path, monkeypatch):
    for key, value in {
        "DATABASE_URL": f"sqlite+aiosqlite:///{tmp_path / 'dismiss.db'}",
        "SECRET_KEY_FILE": str(tmp_path / ".secret_key"),
        "MOVIECLAW_DATA_DIR": str(tmp_path),
        "SITE_CONFIGS_DIR": str(tmp_path / "sites"),
        "SCHEDULER_ENABLED": "false",
    }.items():
        monkeypatch.setenv(key, value)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    from movieclaw_api.app import create_app

    app = create_app()
    who = {"p": ADMIN}
    app.dependency_overrides[require_login] = lambda: who["p"]
    with TestClient(app) as c:

        async def seed():
            async with get_database().session() as s:
                library = await LibraryRepository(s).create(
                    name="库", kind="movie", root_paths=[str(tmp_path)]
                )
                members = [
                    Member(id=1, username="one", password_hash="unused"),
                    Member(id=2, username="two", password_hash="unused"),
                ]
                s.add_all(members)
                movie = MediaItem(kind="movie", title="电影", original_title="M", tmdb_id=100)
                show = MediaItem(kind="tv", title="剧", original_title="T", tmdb_id=200)
                video = MediaItem(
                    source="local",
                    kind="video",
                    external_id="local-video-1",
                    tmdb_id=None,
                    imdb_id=None,
                    title="视频",
                    original_title="V",
                )
                s.add_all([movie, show, video])
                await s.flush()
                units = [(movie.id, 0, 0), (video.id, 0, 0)] + [(show.id, 1, e) for e in (1, 2, 3)]
                for item, season, episode in units:
                    s.add(
                        LibraryFile(
                            library_id=library.id,
                            media_item_id=item,
                            season_number=season,
                            episode_number=episode,
                            file_path=str(tmp_path / f"{item}-{season}-{episode}.mkv"),
                            size_bytes=1,
                            source=FileSource.SCANNED,
                            state=FileState.IN_PLACE,
                            duration_seconds=600,
                        )
                    )
                await s.commit()
                return {"movie": movie.id, "tv": show.id, "video": video.id}, {
                    m.id: m for m in members
                }

        ids, members = c.portal.call(seed)

        def as_member(member_id: int, device: int | None = None) -> Principal:
            ref = (
                DeviceRef(id=device, kind="ios", scope="full", name=f"d{device}")
                if device is not None
                else None
            )
            if member_id == 0:
                return Principal(kind="admin", name="admin", device=ref)
            return Principal(
                kind="member",
                name=members[member_id].username,
                member_id=member_id,
                is_admin=False,
                member=members[member_id],
                device=ref,
            )

        def call(principal, method, path, **kw):
            who["p"] = principal
            try:
                return getattr(c, method)(path, **kw)
            finally:
                who["p"] = ADMIN

        yield SimpleNamespace(c=c, ids=ids, as_member=as_member, call=call)
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


UNITS = {"movie": (0, 0), "video": (0, 0), "tv": (1, 2)}


def play(env, member, item, season, episode, position, *, device=5):
    p = env.as_member(member, device)
    body = {"media_item_id": item, "season_number": season, "episode_number": episode}
    r = env.call(p, "post", "/api/v1/playback/progress", json={**body, "event": "start"})
    assert r.status_code == 200, r.text
    r = env.call(
        p,
        "post",
        "/api/v1/playback/progress",
        json={**body, "event": "stop", "position_ms": position},
    )
    assert r.status_code == 200, r.text
    return r.json()["data"]


def up_next(env, member, *, device=None):
    params = {"this_device": "true"} if device is not None else {}
    r = env.call(env.as_member(member, device), "get", "/api/v1/playback/up-next", params=params)
    assert r.status_code == 200, r.text
    return [
        (i["media_item_id"], i["season_number"], i["episode_number"])
        for i in r.json()["data"]["items"]
    ]


def resume(env, member, item, season, episode):
    r = env.call(
        env.as_member(member),
        "get",
        "/api/v1/playback/resume",
        params={"media_item_id": item, "season_number": season, "episode_number": episode},
    )
    assert r.status_code == 200, r.text
    return r.json()["data"]


def catalog_unit(env, member, item, season, episode):
    r = env.c.get(
        SYNC + "/catalog", params={"member_id": member, "kinds": ["movie", "tv", "video"]}
    )
    assert r.status_code == 200, r.text
    items = r.json()["data"]["items"]
    assert all("continue_dismissed" in u for u in items)
    return next(
        u for u in items if (u["media"]["id"], u["season"], u["episode"]) == (item, season, episode)
    )


def write(env, member, unit, **fields):
    media = unit["media"]
    change = {
        "media_item_id": media["id"],
        "kind": media["kind"],
        "expected_updated_at": unit["updated_at"],
        **fields,
    }
    if media["tmdb_id"] is None and media["imdb_id"] is None:
        change["identity"] = media["identity"]
    else:
        change["tmdb_id"] = media["tmdb_id"]
    if media["kind"] == "tv":
        change.update(season=unit["season"], episode=unit["episode"])
    r = env.c.post(SYNC + "/state", json={"member_id": member, "changes": [change]})
    assert r.status_code == 200, r.text
    return r.json()["data"]["outcomes"][0]


def facts(env, member, item):
    async def run():
        async with get_database().session() as s:
            states = (
                await s.execute(
                    select(PlaybackState)
                    .where(PlaybackState.member_id == member, PlaybackState.media_item_id == item)
                    .order_by(PlaybackState.id)
                )
            ).scalars()
            logs = (
                await s.execute(
                    select(PlaybackLog)
                    .where(PlaybackLog.member_id == member, PlaybackLog.media_item_id == item)
                    .order_by(PlaybackLog.id)
                )
            ).scalars()
            return (
                [
                    (
                        r.season_number,
                        r.episode_number,
                        r.played,
                        r.play_count,
                        r.is_favorite,
                        r.favorited_at,
                        r.last_played_at,
                    )
                    for r in states
                ],
                [
                    (
                        r.id,
                        r.device_id,
                        r.last_seen_at,
                        r.end_position_ms,
                        r.watched_ms,
                        r.completed,
                    )
                    for r in logs
                ],
            )

    return env.c.portal.call(run)


@pytest.mark.parametrize("kind", ["movie", "tv", "video"])
def test_dismiss_hides_whole_title_keeps_facts_and_replay_brings_it_back(env, kind, monkeypatch):
    item = env.ids[kind]
    season, episode = UNITS[kind]
    if kind == "tv":
        play(env, 1, item, 1, 1, None)  # E1 看完
    play(env, 1, item, season, episode, 120_000)
    play(env, 2, item, season, episode, 60_000, device=9)  # 另一成员同一单元
    key = (item, season, episode)
    assert key in up_next(env, 1) and key in up_next(env, 1, device=5)
    unit = catalog_unit(env, 1, item, season, episode)
    assert unit["continue_dismissed"] is False and unit["position_ms"] == 120_000
    # 收藏一下，证明隐藏不碰收藏
    assert write(env, 1, unit, is_favorite=True)["status"] == "applied"
    unit = catalog_unit(env, 1, item, season, episode)
    before = facts(env, 1, item)
    before_resume = resume(env, 1, item, season, episode)

    from movieclaw_api import events

    published = []

    async def spy(*args, **kwargs):
        published.append(args)

    monkeypatch.setattr(events, "publish", spy)
    out = write(env, 1, unit, position_ms=0, dismiss_continue=True)
    assert out["status"] == "applied"
    assert published == []

    after = resume(env, 1, item, season, episode)
    assert after["position_ms"] == 0
    assert (after["played"], after["play_count"]) == (
        before_resume["played"],
        before_resume["play_count"],
    )
    # 整部作品不出卡：剧集不跳到 E3，本设备也一样
    assert [k for k in up_next(env, 1) if k[0] == item] == []
    assert [k for k in up_next(env, 1, device=5) if k[0] == item] == []
    # played / play_count / 收藏 / 收藏时间 / last_played_at / 播放日志都没动
    assert facts(env, 1, item) == before
    dismissed = catalog_unit(env, 1, item, season, episode)
    assert dismissed["continue_dismissed"] is True
    assert dismissed["updated_at"] == out["state_version"]
    assert dismissed["last_played_at"] == unit["last_played_at"]
    # 成员隔离：另一成员照旧
    assert key in up_next(env, 2) and key in up_next(env, 2, device=9)
    assert catalog_unit(env, 2, item, season, episode)["continue_dismissed"] is False
    monkeypatch.undo()

    # 真正再播放：标记清掉，卡片回来；之后还能再隐藏
    play(env, 1, item, season, episode, 200_000)
    again = catalog_unit(env, 1, item, season, episode)
    assert again["continue_dismissed"] is False
    assert key in up_next(env, 1) and key in up_next(env, 1, device=5)
    assert write(env, 1, again, position_ms=0, dismiss_continue=True)["status"] == "applied"
    assert [k for k in up_next(env, 1) if k[0] == item] == []


def test_dismiss_works_when_position_is_already_zero_and_can_be_undone(env):
    item = env.ids["movie"]
    play(env, 1, item, 0, 0, 0)  # 拖回开头停：position 0、未看完，卡片仍在
    unit = catalog_unit(env, 1, item, 0, 0)
    assert (unit["position_ms"], unit["played"]) == (0, False)
    assert (item, 0, 0) in up_next(env, 1)

    out = write(env, 1, unit, dismiss_continue=True)  # 只隐藏，不给 position
    assert out["status"] == "applied"
    assert (item, 0, 0) not in up_next(env, 1)
    dismissed = catalog_unit(env, 1, item, 0, 0)
    # 重复隐藏：unchanged，不动版本
    assert write(env, 1, dismissed, dismiss_continue=True) == {
        "status": "unchanged",
        "state_version": dismissed["updated_at"],
    }
    # 撤销（显式 false）回来
    assert write(env, 1, dismissed, dismiss_continue=False)["status"] == "applied"
    assert (item, 0, 0) in up_next(env, 1)
    assert catalog_unit(env, 1, item, 0, 0)["continue_dismissed"] is False


def test_dismiss_respects_cas_identity_and_shape(env):
    item = env.ids["video"]
    play(env, 1, item, 0, 0, 90_000)
    unit = catalog_unit(env, 1, item, 0, 0)
    # 过期版本：conflict，不写
    stale = {**unit, "updated_at": "2020-01-01T00:00:00Z"}
    assert write(env, 1, stale, position_ms=0, dismiss_continue=True)["status"] == "conflict"
    # 令牌不对：mismatch，不写
    forged = {**unit, "media": {**unit["media"], "identity": "local-video-other"}}
    assert write(env, 1, forged, dismiss_continue=True)["status"] == "mismatch"
    assert catalog_unit(env, 1, item, 0, 0)["continue_dismissed"] is False
    assert (item, 0, 0) in up_next(env, 1)
    # 播放把版本推走后，旧预览的隐藏被 CAS 拦下
    play(env, 1, item, 0, 0, 100_000)
    assert write(env, 1, unit, dismiss_continue=True)["status"] == "conflict"

    show = env.ids["tv"]

    def status(change):
        return env.c.post(SYNC + "/state", json={"member_id": 1, "changes": [change]}).status_code

    base = {"media_item_id": show, "kind": "tv", "tmdb_id": 200, "expected_updated_at": None}
    assert status({**base, "season": 1, "dismiss_continue": True}) == 422  # 整季不收
    assert status({**base, "dismiss_continue": True}) == 422  # 整剧不收
    assert status({**base, "season": 1, "episode": 1, "dismiss_continue": "x"}) == 422


def test_this_device_respects_title_level_dismiss(env):
    """本设备锚点（E1）与跨设备最近一行（E2）不同：隐藏按人、作品级，本设备条也拿掉。"""
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000, device=5)
    play(env, 1, show, 1, 2, 100_000, device=6)
    assert (show, 1, 1) in up_next(env, 1, device=5)
    unit = catalog_unit(env, 1, show, 1, 2)
    assert write(env, 1, unit, position_ms=0, dismiss_continue=True)["status"] == "applied"
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    assert [k for k in up_next(env, 1, device=5) if k[0] == show] == []
    # 本设备再播 E1：E1 成了最近一行且未隐藏，卡片回来
    play(env, 1, show, 1, 1, 150_000, device=5)
    assert (show, 1, 1) in up_next(env, 1, device=5)
    assert (show, 1, 1) in up_next(env, 1)


def test_dismissing_an_older_episode_does_not_hide_the_current_one(env):
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000)
    play(env, 1, show, 1, 2, 100_000)
    older = catalog_unit(env, 1, show, 1, 1)
    assert write(env, 1, older, position_ms=0, dismiss_continue=True)["status"] == "applied"
    assert (show, 1, 2) in up_next(env, 1)


def test_continue_dismissed_migration_upgrade_downgrade_keeps_rows(tmp_path, monkeypatch):
    import sqlite3

    from alembic import command

    from movieclaw_db.migrations import _build_config

    path = tmp_path / "migration.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    try:
        config = _build_config()
        command.upgrade(config, "c5f1a8e3b724")
        with sqlite3.connect(path) as db:
            # 旧库的一行条目：NOT NULL 且无默认值的列一律填占位值
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
                " continue_dismissed from playback_state"
            ).fetchone()
            assert row == (5000, 0, 2, 1, "2026-01-02", 0)
        command.downgrade(config, "c5f1a8e3b724")
        with sqlite3.connect(path) as db:
            cols = {r[1] for r in db.execute("pragma table_info(playback_state)")}
            assert "continue_dismissed" not in cols
            assert db.execute("select play_count from playback_state").fetchone() == (2,)
        command.upgrade(config, "head")
    finally:
        get_settings.cache_clear()

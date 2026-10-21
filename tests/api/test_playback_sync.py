"""真实 HTTP + SQLite：分页、成员隔离、日期、重放、并发预览和插件授权。"""

from __future__ import annotations

from datetime import datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from movieclaw_api.api.deps import require_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import Principal, reset_auth_state
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
    WatchRecord,
)
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_sdk.ops import OpsError

BASE = "/api/v1/playback/sync"


@pytest.fixture
def client(tmp_path, monkeypatch):
    for key, value in {
        "DATABASE_URL": f"sqlite+aiosqlite:///{tmp_path / 'sync.db'}",
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
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="admin")
    with TestClient(app) as c:

        async def seed():
            async with get_database().session() as s:
                library = await LibraryRepository(s).create(
                    name="电影", kind="movie", root_paths=[str(tmp_path)]
                )
                s.add_all(
                    [
                        Member(id=1, username="one", password_hash="unused"),
                        Member(id=2, username="two", password_hash="unused"),
                    ]
                )
                media = [
                    MediaItem(kind="movie", title=f"电影 {i}", original_title="M", tmdb_id=100 + i)
                    for i in range(3)
                ]
                s.add_all(media)
                await s.flush()
                for m in media:
                    s.add(
                        LibraryFile(
                            library_id=library.id,
                            media_item_id=m.id,
                            file_path=str(tmp_path / f"{m.id}.mkv"),
                            size_bytes=1,
                            source=FileSource.SCANNED,
                            state=FileState.IN_PLACE,
                            duration_seconds=600,
                        )
                    )
                await s.commit()
                return [m.id for m in media]

        ids = c.portal.call(seed)
        yield c, app, ids
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def snapshot(c, member=0, **params):
    r = c.get(BASE + "/catalog", params={"member_id": member, **params})
    assert r.status_code == 200, r.text
    return r.json()["data"]


def record(item, source="one", **extra):
    return {
        "media_item_id": item,
        "kind": "movie",
        "tmdb_id": 100,
        "source_id": source,
        "watched_at": "2020-01-01T12:00:00Z",
        "expected_updated_at": None,
        **extra,
    }


def post(c, member, records):
    r = c.post(BASE + "/import", json={"member_id": member, "records": records})
    assert r.status_code == 200, r.text
    return r.json()["data"]["outcomes"]


async def facts():
    async with get_database().session() as s:
        return (
            list((await s.execute(select(PlaybackState))).scalars()),
            list((await s.execute(select(PlaybackLog))).scalars()),
            list((await s.execute(select(WatchRecord))).scalars()),
        )


def test_paging_member_isolation_and_import_idempotency(client):
    c, app, ids = client
    page = snapshot(c, 2, limit=1)
    assert len(page["items"]) == 1 and page["next_cursor"]
    next_page = snapshot(c, 2, cursor=page["next_cursor"], limit=1)
    assert next_page["items"][0]["media"]["id"] != page["items"][0]["media"]["id"]
    item = record(ids[0])
    first = post(c, 2, [item])[0]
    assert first["status"] == "applied"
    assert post(c, 2, [item])[0] == {**first, "status": "already"}
    states, logs, records = c.portal.call(facts)
    assert len(states) == len(records) == 1 and not logs
    assert states[0].member_id == 2 and states[0].last_played_at.year == 2020
    assert records[0].watched_at == datetime(2020, 1, 1, 12)
    assert not snapshot(c, 0)["items"][0]["played"]
    assert snapshot(c, 2)["items"][0]["watches"][0]["basis"] == "import"
    assert post(c, 2, [record(ids[1], tmdb_id=101)])[0]["status"] == "mismatch"
    app.dependency_overrides[require_login] = lambda: Principal(
        kind="member", name="one", member_id=1, is_admin=False
    )
    assert c.get(BASE + "/catalog?member_id=2").status_code == 403
    assert c.post(BASE + "/import", json={"member_id": 2, "records": [item]}).status_code == 403


def test_rewatches_versions_and_non_playback_fields_are_preserved(client):
    c, _, ids = client

    async def initial():
        async with get_database().session() as s:
            s.add(
                PlaybackState(
                    member_id=2,
                    media_item_id=ids[0],
                    played=False,
                    position_ms=120000,
                    is_favorite=True,
                    subtitle_track="off",
                    play_count=5,
                    updated_at=datetime(2021, 1, 1),
                )
            )
            await s.commit()

    c.portal.call(initial)
    version = snapshot(c, 2)["items"][0]["updated_at"]
    entries = [
        record(ids[0], str(i), watched_at=f"2020-01-0{i}T12:00:00Z", expected_updated_at=version)
        for i in (1, 2, 3)
    ]
    outcomes = post(c, 2, entries)
    assert [r["status"] for r in outcomes] == ["applied"] * 3
    states, logs, records = c.portal.call(facts)
    assert len(records) == 3 and not logs
    assert (
        states[0].position_ms == 120000
        and states[0].is_favorite
        and states[0].subtitle_track == "off"
    )
    assert states[0].play_count == 5
    assert len(snapshot(c, 2)["items"][0]["watches"]) == 3
    assert (
        post(c, 2, [record(ids[0], "late", expected_updated_at=version)])[0]["status"] == "conflict"
    )
    # 一次响应丢失后重放，回执给的是当时的版本，而非后来用户操作的版本。
    assert post(c, 2, [entries[0]])[0]["state_version"] == outcomes[0]["state_version"]
    assert (
        post(c, 2, [record(ids[0], "next", expected_updated_at=outcomes[-1]["state_version"])])[0][
            "status"
        ]
        == "applied"
    )


def test_manual_state_time_and_multiple_native_viewings_are_exported(client):
    c, _, ids = client
    now = datetime(2020, 1, 1)

    async def initial():
        async with get_database().session() as s:
            s.add(PlaybackState(member_id=2, media_item_id=ids[0], played=True, last_played_at=now))
            s.add(PlaybackState(member_id=2, media_item_id=ids[1], played=True, last_played_at=now))
            for i in range(3):
                t = now + timedelta(days=i)
                s.add(
                    PlaybackLog(
                        member_id=2,
                        media_item_id=ids[1],
                        title="重看",
                        started_at=t,
                        last_seen_at=t + timedelta(minutes=10),
                        ended_at=t + timedelta(minutes=10),
                        start_position_ms=0,
                        end_position_ms=570000,
                        watched_ms=570000,
                        completed=i == 0,
                    )
                )
            await s.commit()

    c.portal.call(initial)
    rows = snapshot(c, 2)["items"]
    assert rows[0]["watches"][0]["watched_at"].startswith("2020-01-01")
    assert rows[0]["watches"][0]["basis"] == "state"
    assert len(rows[1]["watches"]) == 3
    assert all(w["basis"] == "playback" for w in rows[1]["watches"])


def test_invalid_records_hidden_libraries_and_source_contract(client):
    c, _, ids = client
    assert (
        c.post(
            BASE + "/import", json={"records": [record(ids[0], watched_at="2020-01-01")]}
        ).status_code
        == 422
    )
    assert (
        c.post(
            BASE + "/import", json={"records": [record(ids[0], watched_at="2099-01-01T00:00:00Z")]}
        ).status_code
        == 422
    )
    assert c.get(BASE + "/catalog?cursor=bad").status_code == 400
    assert c.get(BASE + "/catalog?member_id=999").status_code == 404
    assert post(c, 0, [record(ids[0], tmdb_id=999)])[0]["status"] == "mismatch"
    assert post(c, 0, [record(ids[0], season=1)])[0]["status"] == "mismatch"

    async def hide():
        from movieclaw_db.models import Library

        async with get_database().session() as s:
            library = (await s.execute(select(Library))).scalars().first()
            library.admin_visible = False
            s.add(library)
            await s.commit()

    c.portal.call(hide)
    assert snapshot(c)["items"] == []
    assert post(c, 0, [record(ids[0])])[0]["status"] == "not_found"


def test_actual_host_ops_read_write_grants_are_separate(client):
    c, app, ids = client
    from movieclaw_api.services.host_ops import HostOps

    # 使用真实网关凭据，不用测试身份覆盖绕过插件操作授权。
    app.dependency_overrides.clear()
    ops = HostOps(app)
    ctx = SimpleNamespace(
        entry_id="test-sync",
        third_party=True,
        permissions=("playback.sync.catalog", "playback.sync.import"),
        effect=lambda *a, **kw: None,
    )
    ops.configure("test-sync", grants=["playback.sync.catalog"])

    async def probe():
        reader = await ops.client(ctx)
        data = await reader.call("playback.sync.catalog", {"member_id": 2})
        assert len(data["items"]) == 3
        with pytest.raises(OpsError, match="PLUGIN_OPERATION_DENIED"):
            await reader.call("playback.sync.import", {"member_id": 2, "records": [record(ids[0])]})
        ops.configure("test-sync", grants=ctx.permissions)
        writer = await ops.client(ctx)
        result = await writer.call(
            "playback.sync.import", {"member_id": 2, "records": [record(ids[0])]}
        )
        assert result["outcomes"][0]["status"] == "applied"

    c.portal.call(probe)
    _, _, records = c.portal.call(facts)
    assert records[0].source == "plugin:test-sync"


def test_episode_units_hidden_member_data_and_content_limits(client):
    c, _, ids = client

    async def initial():
        from movieclaw_db.models import Library

        async with get_database().session() as s:
            lib = (await s.execute(select(Library))).scalars().first()
            show = MediaItem(kind="tv", title="Series", original_title="Series", tmdb_id=200)
            s.add(show)
            await s.flush()
            for season, episode in ((1, 1), (1, 2), (2, 1)):
                s.add(
                    LibraryFile(
                        library_id=lib.id,
                        media_item_id=show.id,
                        season_number=season,
                        episode_number=episode,
                        file_path=f"/fixture/s{season}e{episode}.mkv",
                        size_bytes=1,
                        source=FileSource.SCANNED,
                        state=FileState.IN_PLACE,
                    )
                )
            await s.commit()
            return show.id

    show_id = c.portal.call(initial)
    rows, cursor = [], None
    while True:
        page = snapshot(c, 2, limit=1, **({"cursor": cursor} if cursor else {}))
        rows.extend(page["items"])
        cursor = page["next_cursor"]
        if not cursor:
            break
    assert [(r["season"], r["episode"]) for r in rows if r["media"]["id"] == show_id] == [
        (1, 1),
        (1, 2),
        (2, 1),
    ]
    episode = record(show_id, kind="tv", tmdb_id=200, season=1, episode=1)
    assert post(c, 2, [episode])[0]["status"] == "applied"
    assert (
        post(c, 2, [record(show_id, "absent", kind="tv", tmdb_id=200, season=4, episode=2)])[0][
            "status"
        ]
        == "not_found"
    )

    async def restrict():
        async with get_database().session() as s:
            member = await s.get(Member, 2)
            member.all_libraries = False
            s.add(member)
            await s.commit()

    c.portal.call(restrict)
    assert snapshot(c, 2)["items"] == []
    assert len(snapshot(c, 0)["items"]) == 6
    assert post(c, 2, [record(ids[0], "hidden")])[0]["status"] == "not_found"

    async def content_limit():
        async with get_database().session() as s:
            member = await s.get(Member, 2)
            member.all_libraries = True
            member.content_age_limit = 7
            member.allow_unrated = False
            s.add(member)
            await s.commit()

    c.portal.call(content_limit)
    assert snapshot(c, 2)["items"] == []  # all fixtures are unrated
    assert post(c, 2, [record(ids[0], "restricted")])[0]["status"] == "not_found"


def test_watch_record_migration_upgrade_downgrade(tmp_path, monkeypatch):
    import sqlite3

    from alembic import command

    from movieclaw_db.migrations import _build_config

    path = tmp_path / "migration.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    try:
        config = _build_config()
        command.upgrade(config, "d7a2e4f9c615")
        command.upgrade(config, "f9b42d6a8e10")
        with sqlite3.connect(path) as db:
            columns = {r[1] for r in db.execute("pragma table_info(watch_record)")}
            assert {"member_id", "watched_at", "source_id", "state_version"} <= columns
            assert db.execute("pragma foreign_key_list(watch_record)").fetchone()[6] == "CASCADE"
            assert any(r[2] for r in db.execute("pragma index_list(watch_record)"))
        command.downgrade(config, "d7a2e4f9c615")
        with sqlite3.connect(path) as db:
            assert not db.execute(
                "select name from sqlite_master where name='watch_record'"
            ).fetchall()
        command.upgrade(config, "head")
    finally:
        get_settings.cache_clear()

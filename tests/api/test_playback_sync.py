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
                    last_played_at=datetime(2021, 1, 1),
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


@pytest.mark.parametrize("kind", ["movie", "tv"])
@pytest.mark.parametrize("local_day,expected_position", [(None, 0), (1, 0), (3, 0), (5, 120000)])
def test_import_only_clears_resume_when_not_older_than_local_playback(
    client, kind, local_day, expected_position
):
    c, _, ids = client
    item_id = ids[0]
    season, episode = (0, 0) if kind == "movie" else (1, 2)

    async def initial():
        async with get_database().session() as s:
            m = await s.get(MediaItem, item_id)
            m.kind = kind
            f = (
                await s.execute(select(LibraryFile).where(LibraryFile.media_item_id == item_id))
            ).scalar_one()
            f.season_number, f.episode_number = season, episode
            s.add_all(
                [
                    m,
                    f,
                    PlaybackState(
                        member_id=2,
                        media_item_id=item_id,
                        season_number=season,
                        episode_number=episode,
                        position_ms=120000,
                        last_played_at=datetime(2020, 1, local_day, 12) if local_day else None,
                        is_favorite=True,
                        audio_track="1",
                        subtitle_track="off",
                        play_count=5,
                    ),
                ]
            )
            await s.commit()

    c.portal.call(initial)
    version = snapshot(c, 2)["items"][0]["updated_at"]
    entry = record(
        item_id,
        kind=kind,
        season=season,
        episode=episode,
        watched_at="2020-01-03T12:00:00Z",
        expected_updated_at=version,
    )
    outcome = post(c, 2, [entry])[0]
    assert outcome["status"] == "applied"
    current = snapshot(c, 2)["items"][0]
    assert current["played"] and current["position_ms"] == expected_position
    states, logs, records = c.portal.call(facts)
    state = states[0]
    assert (
        state.play_count == 5
        and state.is_favorite
        and state.audio_track == "1"
        and state.subtitle_track == "off"
    )
    assert not logs and len(records) == 1

    # A replay after the user starts another viewing cannot erase its new position.
    async def replaying():
        async with get_database().session() as s:
            state = (await s.execute(select(PlaybackState))).scalar_one()
            state.position_ms = 90000
            state.last_played_at = datetime(2022, 1, 1)
            state.updated_at = datetime(2022, 1, 2)
            s.add(state)
            await s.commit()

    c.portal.call(replaying)
    assert post(c, 2, [entry])[0]["status"] == "already"
    assert snapshot(c, 2)["items"][0]["position_ms"] == 90000


@pytest.mark.parametrize("target_watch", [False, True])
def test_import_reidentify_cleanup_and_replay_keep_history(client, target_watch):
    c, _, ids = client
    entries = [record(ids[0], str(i), watched_at=f"2020-01-0{i}T12:00:00Z") for i in (1, 2, 3)]
    outcomes = post(c, 2, entries)
    assert all(r["status"] == "applied" for r in outcomes)

    if target_watch:
        assert (
            post(c, 2, [record(ids[1], "target", tmdb_id=101, watched_at="2019-01-01T12:00:00Z")])[
                0
            ]["status"]
            == "applied"
        )

    async def suggest():
        async with get_database().session() as s:
            f = (
                await s.execute(select(LibraryFile).where(LibraryFile.media_item_id == ids[0]))
            ).scalar_one()
            f.review_suggestion = {"media_item_id": ids[1], "title": "Corrected identity"}
            s.add(f)
            await s.commit()
            return f.id

    file_id = c.portal.call(suggest)
    r = c.post(
        "/api/v1/libraries/identification/review-decisions",
        json={"file_ids": [file_id], "decision": "accept_suggestion"},
    )
    assert r.status_code == 200, r.text
    corrected = next(u for u in snapshot(c, 2)["items"] if u["media"]["id"] == ids[1])
    assert len(corrected["watches"]) == 3 + target_watch
    assert all(w["basis"] == "import" for w in corrected["watches"])

    async def cleanup():
        from sqlalchemy import delete

        from movieclaw_api.services.media_scrape import cleanup_orphan_items

        async with get_database().session() as s:
            await s.execute(delete(PlaybackState).where(PlaybackState.media_item_id == ids[0]))
            await s.commit()
        assert await cleanup_orphan_items([ids[0]]) == 1
        async with get_database().session() as s:
            assert await s.get(MediaItem, ids[0]) is None

    c.portal.call(cleanup)
    replay = [{**e, "media_item_id": ids[1], "tmdb_id": 101} for e in entries]
    repeated = post(c, 2, replay)
    assert [r["status"] for r in repeated] == ["already"] * 3
    assert [r["state_version"] for r in repeated] == [r["state_version"] for r in outcomes]
    assert len(c.portal.call(facts)[2]) == 3 + target_watch


@pytest.mark.parametrize("without_state", [False, True])
def test_episode_reassignment_moves_all_members_and_keeps_source_keys(
    client, monkeypatch, without_state
):
    c, _, ids = client
    from movieclaw_api.services import media_scrape
    from movieclaw_api.services.media_library import MediaLibraryService

    async def initial():
        async with get_database().session() as s:
            m = await s.get(MediaItem, ids[0])
            m.kind = "tv"
            f = (
                await s.execute(select(LibraryFile).where(LibraryFile.media_item_id == ids[0]))
            ).scalar_one()
            from movieclaw_db.models import Library

            library = await s.get(Library, f.library_id)
            library.kind = "tv"
            s.add(library)
            f.season_number, f.episode_number = 1, 1
            s.add(
                LibraryFile(
                    library_id=f.library_id,
                    media_item_id=ids[0],
                    season_number=1,
                    episode_number=2,
                    file_path=f.file_path + ".sibling.mkv",
                    size_bytes=1,
                    source=FileSource.SCANNED,
                    state=FileState.IN_PLACE,
                )
            )
            s.add_all([m, f])
            await s.commit()
            return f.id

    file_id = c.portal.call(initial)
    entry = record(ids[0], kind="tv", season=1, episode=1)
    for member in (0, 2):
        assert post(c, member, [entry])[0]["status"] == "applied"
    assert (
        post(c, 2, [record(ids[0], "sibling", kind="tv", season=1, episode=2)])[0]["status"]
        == "applied"
    )
    if without_state:

        async def clear_state():
            from sqlalchemy import delete

            async with get_database().session() as s:
                await s.execute(delete(PlaybackState))
                await s.commit()

        c.portal.call(clear_state)

    async def existing(self, *args, **kwargs):
        return await self._session.get(MediaItem, ids[0])

    async def no_assets(*args, **kwargs):
        pass

    monkeypatch.setattr(MediaLibraryService, "ensure_media_item", existing)
    monkeypatch.setattr(media_scrape, "ensure_assets", no_assets)
    response = c.post(
        f"/api/v1/libraries/identification/files/{file_id}/title-assignment",
        json={"title_ref": "tmdb:tv:100", "season_number": 2, "episode_number": 3},
    )
    assert response.status_code == 200, response.text
    for member in (0, 2):
        current = next(
            u
            for u in snapshot(c, member)["items"]
            if u["media"]["id"] == ids[0] and (u["season"], u["episode"]) == (2, 3)
        )
        assert (current["season"], current["episode"]) == (2, 3)
        assert len(current["watches"]) == 1 and current["watches"][0]["basis"] == "import"
        assert post(c, member, [{**entry, "season": 2, "episode": 3}])[0]["status"] == "already"
    sibling = next(
        u
        for u in snapshot(c, 2)["items"]
        if u["media"]["id"] == ids[0] and (u["season"], u["episode"]) == (1, 2)
    )
    assert len(sibling["watches"]) == 1
    assert (
        post(c, 2, [record(ids[0], "sibling", kind="tv", season=1, episode=2)])[0]["status"]
        == "already"
    )
    assert len(c.portal.call(facts)[2]) == 3


def test_orphan_cleanup_retains_imported_facts_without_state(client):
    c, _, ids = client
    assert post(c, 2, [record(ids[0])])[0]["status"] == "applied"

    async def cleanup():
        from sqlalchemy import delete

        from movieclaw_api.services.media_scrape import cleanup_orphan_items

        async with get_database().session() as s:
            await s.execute(delete(LibraryFile).where(LibraryFile.media_item_id == ids[0]))
            await s.execute(delete(PlaybackState).where(PlaybackState.media_item_id == ids[0]))
            await s.commit()
        assert await cleanup_orphan_items([ids[0]]) == 0
        async with get_database().session() as s:
            assert await s.get(MediaItem, ids[0]) is not None

    c.portal.call(cleanup)
    assert len(c.portal.call(facts)[2]) == 1
    assert post(c, 2, [record(ids[0])])[0]["status"] == "already"


def change(item, expected=None, **fields):
    return {
        "media_item_id": item,
        "kind": "movie",
        "tmdb_id": 100,
        "expected_updated_at": expected,
        **fields,
    }


def put_state(c, member, changes):
    r = c.post(BASE + "/state", json={"member_id": member, "changes": changes})
    assert r.status_code == 200, r.text
    return r.json()["data"]["outcomes"]


def unit_of(c, member, item, season=0, episode=0):
    return next(
        u
        for u in snapshot(c, member)["items"]
        if (u["media"]["id"], u["season"], u["episode"]) == (item, season, episode)
    )


def test_state_writes_resume_unwatch_favorite_without_events(client, monkeypatch):
    c, _, ids = client
    from movieclaw_api import events

    published = []

    async def spy(*args, **kwargs):
        published.append(args)

    monkeypatch.setattr(events, "publish", spy)
    item = ids[0]
    assert unit_of(c, 2, item)["is_favorite"] is False

    # 设续播点：不翻已看，最近播放时间取请求给的。
    out = put_state(
        c, 2, [change(item, position_ms=1_520_000, last_played_at="2024-05-01T08:00:00Z")]
    )[0]
    assert out["status"] == "applied"
    unit = unit_of(c, 2, item)
    assert (unit["played"], unit["position_ms"]) == (False, 1_520_000)
    assert unit["last_played_at"].startswith("2024-05-01T08:00:00")
    v1 = unit["updated_at"]
    assert out["state_version"] == v1

    # 值没变：unchanged，版本不动——同步插件互相回写到这里就停。
    again = put_state(c, 2, [change(item, v1, position_ms=1_520_000)])[0]
    assert again == {"status": "unchanged", "state_version": v1}
    # 过期版本：conflict，不覆盖。
    assert put_state(c, 2, [change(item, None, played=True)])[0]["status"] == "conflict"

    # 已看：位置清零、次数至少 1。
    v2 = put_state(c, 2, [change(item, v1, played=True)])[0]["state_version"]
    states, logs, records = c.portal.call(facts)
    (row,) = states
    assert (row.played, row.position_ms, row.play_count) == (True, 0, 1)
    assert not logs and not records  # 不伪造播放过程，也不写观看事实

    # 取消已看 = 全部清零；同一批里再收藏，共用扫描时的版本。
    outs = put_state(c, 2, [change(item, v2, played=False), change(item, v2, is_favorite=True)])
    assert [o["status"] for o in outs] == ["applied", "applied"]
    (row,), _, _ = c.portal.call(facts)
    assert (row.played, row.position_ms, row.play_count, row.last_played_at) == (
        False,
        0,
        0,
        None,
    )
    assert row.is_favorite and row.favorited_at is not None
    assert unit_of(c, 2, item)["is_favorite"] is True
    # 别的成员不受影响
    assert unit_of(c, 1, item)["is_favorite"] is False
    assert published == []


def test_state_rejects_bad_shapes_identity_and_hidden_units(client):
    c, _, ids = client

    def status(payload):
        return c.post(BASE + "/state", json={"member_id": 2, "changes": [payload]}).status_code

    assert status(change(ids[0])) == 422  # 什么都不改
    assert status(change(ids[0], played=True, position_ms=5)) == 422
    assert status(change(ids[0], season=1, episode=2, played=True)) == 422
    assert status({**change(ids[0], played=True), "watched_at": "2020-01-01T00:00:00Z"}) == 422
    assert status(change(ids[0], played=True, last_played_at="2020-01-01T00:00:00")) == 422
    assert status(change(ids[0], played=True, last_played_at="2999-01-01T00:00:00Z")) == 422
    tv = {"kind": "tv", "tmdb_id": 200}
    assert status(change(ids[0], played=True, season=1, **tv)) == 422  # 整季只能写收藏
    assert status(change(ids[0], is_favorite=True, episode=1, **tv)) == 422
    assert (
        c.post(BASE + "/state", json={"member_id": 9, "changes": [change(ids[0], played=True)]})
    ).status_code == 404

    outs = put_state(
        c,
        2,
        [
            change(ids[0], played=True, tmdb_id=999),  # 编号对不上
            change(ids[0], played=True, kind="tv", tmdb_id=100, season=1, episode=1),
            change(9999, played=True),
        ],
    )
    assert [o["status"] for o in outs] == ["mismatch", "mismatch", "mismatch"]

    async def restrict():
        async with get_database().session() as s:
            member = await s.get(Member, 2)
            member.all_libraries = False
            s.add(member)
            await s.commit()

    c.portal.call(restrict)
    assert put_state(c, 2, [change(ids[0], played=True)])[0]["status"] == "not_found"
    states, _, _ = c.portal.call(facts)
    assert states == []


def test_state_series_and_season_favorites_round_trip(client):
    c, _, _ = client

    async def seed():
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

    show = c.portal.call(seed)
    tv = {"kind": "tv", "tmdb_id": 200}
    media = unit_of(c, 2, show, 1, 1)["media"]
    assert media["favorite"] is None and media["season_favorites"] == []

    outs = put_state(
        c,
        2,
        [
            change(show, is_favorite=True, **tv),  # 整剧
            change(show, is_favorite=True, season=2, **tv),  # 整季
            change(show, is_favorite=True, season=3, **tv),  # 没有这一季的文件
            change(show, played=True, season=1, episode=2, **tv),  # 单集
        ],
    )
    assert [o["status"] for o in outs] == ["applied", "applied", "not_found", "applied"]
    media = unit_of(c, 2, show, 2, 1)["media"]
    assert media["favorite"]["is_favorite"] is True
    assert [(f["season"], f["is_favorite"]) for f in media["season_favorites"]] == [(2, True)]
    assert unit_of(c, 2, show, 1, 2)["played"] is True
    assert unit_of(c, 2, show, 1, 1)["is_favorite"] is False  # 整剧收藏不落到集上

    # 落点与详情页的心同一份数据（marks 服务读的就是哨兵行）
    from movieclaw_api.services.playback import marks

    async def read():
        async with get_database().session() as s:
            series = await marks.get_state(s, marks.MarkTarget(show), member_id=2)
            season = await marks.get_state(s, marks.MarkTarget(show, 2), member_id=2)
            return series.is_favorite, season.is_favorite

    assert c.portal.call(read) == (True, True)

    # 取消整剧收藏需要哨兵行的版本
    version = media["favorite"]["updated_at"]
    assert put_state(c, 2, [change(show, is_favorite=False, **tv)])[0]["status"] == "conflict"
    assert (
        put_state(c, 2, [change(show, version, is_favorite=False, **tv)])[0]["status"] == "applied"
    )
    assert unit_of(c, 2, show, 1, 1)["media"]["favorite"]["is_favorite"] is False


def test_state_operation_is_a_grantable_host_op(client):
    c, app, ids = client
    import tomllib

    from movieclaw_api.plugins import packages as pkg
    from movieclaw_api.services.host_ops import HostOps
    from movieclaw_api.services.plugin_packages import _operations

    # 插件包安装检查用的就是这份目录：声明该操作的包能通过 check_compat。
    text = (
        '[plugin]\nid = "emby-sync"\ntitle = "Emby"\nversion = "0.1.0"\nentry = "emby_sync"\n\n'
        '[permissions]\noperations = ["playback.sync.catalog", "playback.sync.state"]\n'
    )
    pkg.check_compat(
        pkg.Manifest.model_validate(tomllib.loads(text)), reserved=set(), operations=_operations()
    )

    app.dependency_overrides.clear()
    ops = HostOps(app)
    ctx = SimpleNamespace(
        entry_id="emby-sync",
        third_party=True,
        permissions=("playback.sync.catalog", "playback.sync.state"),
        effect=lambda *a, **kw: None,
    )
    ops.configure("emby-sync", grants=["playback.sync.catalog", "playback.sync.import"])

    async def probe():
        reader = await ops.client(ctx)
        payload = {"member_id": 2, "changes": [change(ids[0], is_favorite=True)]}
        with pytest.raises(OpsError, match="PLUGIN_OPERATION_DENIED"):
            await reader.call("playback.sync.state", payload)
        ops.configure("emby-sync", grants=ctx.permissions)
        writer = await ops.client(ctx)
        result = await writer.call("playback.sync.state", payload)
        assert result["outcomes"][0]["status"] == "applied"
        data = await writer.call("playback.sync.catalog", {"member_id": 2})
        assert [u["is_favorite"] for u in data["items"]].count(True) == 1

    c.portal.call(probe)

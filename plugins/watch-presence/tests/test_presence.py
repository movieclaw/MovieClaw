"""Run against MovieClaw v0.36.0: real package install, cookies, DB and routes."""

import io
import os
import sys
import zipfile
from datetime import timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import Library, LibraryFile, MediaItem, MediaMetadata, Member, PlaybackLog
from movieclaw_db.models.base import utcnow
from movieclaw_playback import activity
from movieclaw_playback.events import ClientInfo

BASE = "/api/v1/plugins/watch-presence"
SOURCE = Path(os.environ.get("WATCH_PRESENCE_SOURCE", Path(__file__).parents[1]))


def package():
    if os.environ.get("WATCH_PRESENCE_PACKAGE"):
        return Path(os.environ["WATCH_PRESENCE_PACKAGE"]).read_bytes()
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name in (
            "movieclaw-plugin.toml",
            "watch_presence.py",
            "settings.html",
            "settings.js",
            "settings.css",
        ):
            archive.write(SOURCE / name, name)
    return output.getvalue()


@pytest.fixture
def server(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'presence.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    for reset in (
        get_settings.cache_clear,
        reset_setting_store,
        reset_secret_box,
        reset_auth_state,
        durable_events.reset_state,
        activity.reset,
    ):
        reset()
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as client:
        assert (
            client.post(
                "/api/v1/auth/bootstrap",
                json={"username": "admin", "password": "admin-fixture-pass"},
            ).status_code
            == 200
        )
        admin = client.cookies.get("movieclaw_session")
        credentials = {"admin": admin}
        ids = {}
        for name in ("alice", "bob", "child"):
            created = client.post(
                "/api/v1/members", json={"username": name, "password": name + "-fixture-pass"}
            )
            assert created.status_code == 200, created.text
            ids[name] = created.json()["data"]["id"]
        uploaded = client.post(
            "/api/v1/app/plugins/packages",
            files={"file": ("watch-presence.mcplugin", package(), "application/zip")},
        )
        assert uploaded.status_code == 200, uploaded.text
        approved = client.post(
            "/api/v1/app/plugins/packages/watch-presence/approve",
            json={
                "version": "1.0.0",
                "operations": [],
                "allow_inline": True,
            },
        )
        assert approved.status_code == 200, approved.text
        assert approved.json()["data"]["status"] == "active", approved.text

        async def seed():
            async with get_database().session() as db:
                db.add_all(
                    [
                        Library(id=1, name="电影库", kind="movie"),
                        Library(id=2, name="私人库", kind="movie"),
                        Library(id=3, name="成人", kind="movie"),
                        Library(id=4, name="隐藏库", kind="movie", exclude_from_home=True),
                        Library(id=5, name="剧集库", kind="tv"),
                    ]
                )
                await db.flush()
                for mid, lib, kind in (
                    (11, 1, "movie"),
                    (22, 2, "movie"),
                    (33, 3, "movie"),
                    (44, 4, "movie"),
                    (55, 5, "tv"),
                ):
                    db.add(
                        MediaItem(
                            id=mid,
                            kind=kind,
                            tmdb_id=mid,
                            title=f"影片 {mid}",
                            original_title=f"Title {mid}",
                        )
                    )
                    await db.flush()
                    season, episode = (2, 3) if kind == "tv" else (0, 0)
                    db.add(
                        LibraryFile(
                            id=mid,
                            media_item_id=mid,
                            library_id=lib,
                            file_path=f"/fixture/{mid}.mkv",
                            source="scanned",
                            season_number=season,
                            episode_number=episode,
                            duration_seconds=1200,
                        )
                    )
                    db.add(
                        PlaybackLog(
                            member_id=ids["alice"],
                            media_item_id=mid,
                            title=f"影片 {mid}",
                            season_number=season,
                            episode_number=episode,
                            device_name="Windows",
                            end_position_ms=180000,
                        )
                    )
                await db.commit()

        client.portal.call(seed)
        for name in ids:
            client.cookies.clear()
            login = client.post(
                "/api/v1/auth/login", json={"username": name, "password": name + "-fixture-pass"}
            )
            assert login.status_code == 200, login.text
            credentials[name] = client.cookies.get("movieclaw_session")

        def use(name):
            client.cookies.clear()
            if name:
                client.cookies.set("movieclaw_session", credentials[name])

        use("alice")
        yield client, ids, use
    for reset in (
        get_settings.cache_clear,
        reset_setting_store,
        reset_secret_box,
        reset_auth_state,
        durable_events.reset_state,
        activity.reset,
    ):
        reset()
    for name in list(sys.modules):
        if name.startswith("movieclaw_packages"):
            del sys.modules[name]


def share(client, libraries=(1, 5), enabled=True):
    result = client.put(
        BASE + "/preferences", json={"share_enabled": enabled, "library_ids": list(libraries)}
    )
    assert result.status_code == 200, result.text
    return result


def start(ids, media=11, device="fixture-device", age=0, paused=False):
    unit = (media, 2, 3) if media == 55 else (media, 0, 0)
    activity.report_start(
        device,
        member_id=ids["alice"],
        client=ClientInfo(name="MovieClaw Windows", device_name="Windows"),
        unit=unit,
    )
    activity.report_progress(
        device,
        member_id=ids["alice"],
        client=ClientInfo(name="MovieClaw Windows", device_name="Windows"),
        unit=unit,
        position_ms=120000,
        paused=paused,
    )
    activity._sessions[device].last_report_at -= timedelta(seconds=age)


def test_defaults_and_anonymous_denied(server):
    client, ids, use = server
    assert client.get(BASE + "/preferences").json()["data"]["share_enabled"] is False
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").status_code == 404
    use(None)
    for path in (
        "/preferences",
        "/members",
        "/settings",
        "/settings.js",
        "/settings.css",
        f"/members/{ids['alice']}/history",
    ):
        assert client.get(BASE + path).status_code == 401


def test_offline_members_keep_authorized_history_entry(server):
    client, ids, use = server
    activity.reset()
    own = client.get(BASE + "/members").json()["data"]["members"]
    assert len(own) == 1 and own[0]["member_id"] == ids["alice"]
    assert own[0]["is_self"] is True and own[0]["sessions"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    use("alice")
    share(client, (1,))
    use("bob")
    offline = client.get(BASE + "/members").json()["data"]["members"]
    assert len(offline) == 1 and offline[0]["member_id"] == ids["alice"]
    assert offline[0]["sessions"] == []
    history = client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]
    assert {row["media"]["media_item_id"] for row in history} == {11}
    use("alice")
    share(client, (1,), enabled=False)
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").status_code == 404


def test_same_version_reinstall_preserves_account_privacy(server):
    client, ids, use = server
    share(client, (1,))
    start(ids, 11)
    use("admin")
    duplicate = client.post(
        "/api/v1/app/plugins/packages",
        files={"file": ("watch-presence.mcplugin", package(), "application/zip")},
    )
    assert duplicate.status_code == 400
    removed = client.delete(
        "/api/v1/app/plugins/packages/watch-presence", params={"purge_data": False}
    )
    assert removed.status_code == 200, removed.text
    uploaded = client.post(
        "/api/v1/app/plugins/packages",
        files={"file": ("watch-presence.mcplugin", package(), "application/zip")},
    )
    assert uploaded.status_code == 200, uploaded.text
    approved = client.post(
        "/api/v1/app/plugins/packages/watch-presence/approve",
        json={"version": "1.0.0", "operations": [], "allow_inline": True},
    )
    assert approved.status_code == 200 and approved.json()["data"]["status"] == "active"
    use("alice")
    prefs = client.get(BASE + "/preferences").json()["data"]
    assert prefs["share_enabled"] is True and prefs["library_ids"] == [1]
    use("bob")
    members = client.get(BASE + "/members").json()["data"]["members"]
    assert len(members) == 1 and members[0]["member_id"] == ids["alice"]


def test_private_settings_page_and_assets_use_host_login(server):
    client, ids, use = server
    for path, content_type in (
        ("/settings", "text/html"),
        ("/settings.js", "text/javascript"),
        ("/settings.css", "text/css"),
    ):
        result = client.get(BASE + path)
        assert result.status_code == 200
        assert content_type in result.headers["content-type"]
        assert result.headers["cache-control"] == "no-store"
    assert "我的观看隐私" in client.get(BASE + "/settings").text


def test_owner_hidden_viewer_hidden_adult_rating_and_parental_limit(server):
    client, ids, use = server
    share(client)

    async def hide_owner():
        async with get_database().session() as db:
            member = await db.get(Member, ids["alice"])
            member.ui_prefs = {"home": {"rows": [{"id": "lib:1", "hidden": True}]}}
            db.add(member)
            db.add(MediaMetadata(media_item_id=55, content_rating="NC-17"))
            await db.commit()

    client.portal.call(hide_owner)
    # Revocation must still work after the previously shared library becomes hidden.
    share(client, enabled=False)
    share(client, (5,))
    start(ids)
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"][0]["sessions"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"] == []

    async def restrict_viewer():
        async with get_database().session() as db:
            owner = await db.get(Member, ids["alice"])
            owner.ui_prefs = None
            db.add(owner)
            viewer = await db.get(Member, ids["bob"])
            viewer.ui_prefs = {
                "home": {
                    "rows": [{"library_id": 1, "hidden": True}, {"library_id": 5, "hidden": True}]
                }
            }
            db.add(viewer)
            child = await db.get(Member, ids["child"])
            child.content_age_limit = 12
            child.allow_unrated = False
            db.add(child)
            await db.commit()

    client.portal.call(restrict_viewer)
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    use("child")
    assert client.get(BASE + "/members").json()["data"]["members"][0]["sessions"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"] == []


def test_recent_history_is_bounded_distinct_and_disabled_owner_disappears(server):
    client, ids, use = server
    share(client)

    async def seed_recent():
        async with get_database().session() as db:
            for mid in range(100, 125):
                db.add(
                    MediaItem(
                        id=mid,
                        kind="movie",
                        tmdb_id=mid,
                        title=f"影片 {mid}",
                        original_title=f"Title {mid}",
                    )
                )
                await db.flush()
                db.add(
                    LibraryFile(
                        media_item_id=mid,
                        library_id=1,
                        file_path=f"/fixture/{mid}.mkv",
                        source="scanned",
                    )
                )
                db.add(
                    PlaybackLog(
                        member_id=ids["alice"],
                        media_item_id=mid,
                        title=f"影片 {mid}",
                        last_seen_at=utcnow() - timedelta(minutes=125 - mid),
                    )
                )
            db.add(
                PlaybackLog(
                    member_id=ids["alice"],
                    media_item_id=124,
                    title="same item",
                    last_seen_at=utcnow(),
                )
            )
            await db.commit()

    client.portal.call(seed_recent)
    use("bob")
    rows = client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]
    assert len(rows) == 20 and len({row["media"]["media_item_id"] for row in rows}) == 20
    assert rows[0]["media"]["media_item_id"] == 124

    async def disable():
        async with get_database().session() as db:
            member = await db.get(Member, ids["alice"])
            member.status = "disabled"
            db.add(member)
            await db.commit()

    client.portal.call(disable)
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").status_code == 404


def test_member_live_history_episode_and_revoke(server):
    client, ids, use = server
    share(client)
    start(ids, 55)
    use("bob")
    result = client.get(BASE + "/members")
    assert result.headers["cache-control"] == "no-store"
    members = result.json()["data"]["members"]
    assert len(members) == 1 and members[0]["name"] == "alice"
    live = members[0]["sessions"][0]
    assert live["media"]["season_number"] == 2 and live["media"]["episode_number"] == 3
    assert live["position_ms"] == 120000 and live["device"] == "Windows"
    assert "device_id" not in live and "file_path" not in result.text
    history = client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]
    assert {row["media"]["media_item_id"] for row in history} == {11, 55}
    assert (
        client.get(
            BASE + f"/members/{ids['alice']}/play",
            params={"kind": "live", "entry_id": live["entry_id"]},
        ).status_code
        == 200
    )
    use("alice")
    share(client, enabled=False)
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").status_code == 404
    assert (
        client.get(
            BASE + f"/members/{ids['alice']}/play",
            params={"kind": "live", "entry_id": live["entry_id"]},
        ).status_code
        == 404
    )


def test_library_allowlist_edit_private_live_new_library_and_strict_inputs(server):
    client, ids, use = server
    for body in (
        {"share_enabled": True, "library_ids": []},
        {"share_enabled": True, "library_ids": [3]},
        {"share_enabled": True, "library_ids": [4]},
        {"share_enabled": True, "library_ids": [999]},
        {"share_enabled": "true", "library_ids": [1]},
        {"share_enabled": True, "library_ids": [1], "member_id": ids["bob"]},
    ):
        assert client.put(BASE + "/preferences", json=body).status_code in (400, 422)
    share(client, (1,))
    start(ids, 22)
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"][0]["sessions"] == []
    assert len(client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]) == 1
    use("alice")
    share(client, (5,))
    use("bob")
    assert {
        r["media"]["media_item_id"]
        for r in client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]
    } == {55}


def test_stale_pause_multiple_devices_and_viewer_permissions(server):
    client, ids, use = server
    share(client)
    start(ids, 11, "fresh", paused=True)
    start(ids, 55, "expired", age=46)
    use("bob")
    sessions = client.get(BASE + "/members").json()["data"]["members"][0]["sessions"]
    assert len(sessions) == 1 and sessions[0]["paused"] is True

    async def restrict():
        async with get_database().session() as db:
            member = await db.get(Member, ids["bob"])
            member.all_libraries = False
            db.add(member)
            await db.commit()

    client.portal.call(restrict)
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").status_code == 404


def test_own_devices_are_private_without_public_opt_in(server):
    client, ids, use = server
    start(ids, 11, "own-windows")
    start(ids, 22, "own-mac")
    result = client.get(BASE + "/members")
    own = result.json()["data"]["members"]
    assert len(own) == 1 and own[0]["is_self"] is True
    assert own[0]["member_id"] == ids["alice"]
    assert {r["media"]["media_item_id"] for r in own[0]["sessions"]} == {11, 22}
    assert len({r["entry_id"] for r in own[0]["sessions"]}) == 2
    assert "own-windows" not in result.text and "own-mac" not in result.text
    entry = own[0]["sessions"][0]
    assert (
        client.get(
            BASE + f"/members/{ids['alice']}/play",
            params={"kind": "live", "entry_id": entry["entry_id"]},
        ).status_code
        == 200
    )
    assert client.get(BASE + "/preferences").json()["data"]["share_enabled"] is False
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").status_code == 404
    assert (
        client.get(
            BASE + f"/members/{ids['alice']}/play",
            params={"kind": "live", "entry_id": entry["entry_id"]},
        ).status_code
        == 404
    )


def test_same_account_sessions_split_but_history_merges_by_unit(server):
    client, ids, use = server
    start(ids, 11, "windows-device")
    start(ids, 11, "mac-device")
    sessions = client.get(BASE + "/members").json()["data"]["members"][0]["sessions"]
    assert len(sessions) == 2 and sessions[0]["entry_id"] != sessions[1]["entry_id"]

    async def log_again():
        async with get_database().session() as db:
            db.add(
                PlaybackLog(
                    member_id=ids["alice"],
                    media_item_id=11,
                    title="影片 11",
                    device_name="Mac",
                    end_position_ms=240000,
                )
            )
            await db.commit()

    client.portal.call(log_again)
    history = client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]
    same = [row for row in history if row["media"]["media_item_id"] == 11]
    assert len(same) == 1 and same[0]["position_ms"] == 240000
    share(client, (1,))
    use("bob")
    sessions = client.get(BASE + "/members").json()["data"]["members"][0]["sessions"]
    assert len(sessions) == 2
    history = client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"]
    assert len(history) == 1 and history[0]["position_ms"] == 240000


def test_ambiguous_private_duplicate_and_history_age_fail_closed(server):
    client, ids, use = server
    share(client)

    async def change():
        async with get_database().session() as db:
            db.add(
                LibraryFile(
                    media_item_id=11,
                    library_id=2,
                    file_path="/private/duplicate.mkv",
                    source="scanned",
                )
            )
            log = (
                await db.execute(select(PlaybackLog).where(PlaybackLog.media_item_id == 55))
            ).scalar_one()
            log.last_seen_at = utcnow() - timedelta(days=8)
            db.add(log)
            await db.commit()

    client.portal.call(change)
    start(ids)
    use("bob")
    assert client.get(BASE + "/members").json()["data"]["members"][0]["sessions"] == []
    assert client.get(BASE + f"/members/{ids['alice']}/history").json()["data"]["items"] == []

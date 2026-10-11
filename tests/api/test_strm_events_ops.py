"""网盘预探用到的实时事件与宿主操作（docs/design/plugin-strm-prefetch.md §3）。

走真实应用：插件订阅四个实时事件，扫描入账、开始播放、收藏、打开详情各发一次；
``library.strm.list-pending`` 按库 / 条目 / 季过滤、排除容器、跳过退避期、分页；
``library.strm.probe`` 探一个文件并报结论。
"""

from __future__ import annotations

import time
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events
from movieclaw_api.services.media_probe import MediaSpec
from movieclaw_api.services.playback import strm_probe
from movieclaw_kernel import Entry, plugin
from movieclaw_sdk.library import (
    LIBRARY_FILES_ADDED,
    LIBRARY_ITEM_FAVORITED,
    LIBRARY_ITEM_VIEWED,
    PLAYBACK_STARTED,
)

PENDING = "/api/v1/library-strm/pending"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'strm.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    yield tmp_path
    durable_events.reset_state()
    get_settings.cache_clear()


def make_client():
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    who = Principal(kind="admin", name="tester", is_admin=True)
    app.dependency_overrides[require_login] = lambda: who
    return app, TestClient(app)


def wait_for(predicate, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("等待超时")


async def seed(root, *, episodes: int = 3) -> dict:
    """一个网盘剧集库：一部剧 S01E01..E0n（strm）+ 一部电影（本地 mkv，有规格）。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, FileState, LibraryFile, MediaItem
    from movieclaw_db.repositories.library_repo import LibraryRepository

    root.mkdir(parents=True, exist_ok=True)
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name="网盘", kind="tv", root_paths=[str(root)]
        )
        show = MediaItem(
            kind="tv", tmdb_id=200, title="测试剧集", original_title="Show", year=2024, aliases=[]
        )
        movie = MediaItem(
            kind="movie",
            tmdb_id=300,
            title="测试电影",
            original_title="Movie",
            year=2024,
            aliases=[],
        )
        session.add_all([show, movie])
        await session.commit()
        ids = {"library": library.id, "show": show.id, "movie": movie.id, "files": {}}
        for n in range(1, episodes + 1):
            strm = root / f"测试剧集.S01E0{n}.strm"
            strm.write_text(f"https://pan.example.com/show/e{n}.mkv?sign=x\n", encoding="utf-8")
            row = LibraryFile(
                library_id=library.id,
                media_item_id=show.id,
                season_number=1,
                episode_number=n,
                file_path=str(strm),
                size_bytes=1,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                container="strm",
            )
            session.add(row)
            await session.commit()
            ids["files"][n] = row.id
        ts = root / "测试剧集.S02E01.strm"
        ts.write_text("https://pan.example.com/show/s2e1.ts\n", encoding="utf-8")
        row = LibraryFile(
            library_id=library.id,
            media_item_id=show.id,
            season_number=2,
            episode_number=1,
            file_path=str(ts),
            size_bytes=1,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="strm",
        )
        local = root / "测试电影.mkv"
        local.write_bytes(b"x")
        session.add_all(
            [
                row,
                LibraryFile(
                    library_id=library.id,
                    media_item_id=movie.id,
                    season_number=0,
                    episode_number=0,
                    file_path=str(local),
                    size_bytes=1,
                    source=FileSource.SCANNED,
                    state=FileState.IN_PLACE,
                    container="mkv",
                    video_codec="h264",
                ),
            ]
        )
        await session.commit()
        ids["ts"] = row.id
        return ids


def test_plugins_hear_scan_play_favorite_and_view(env, monkeypatch) -> None:
    import movieclaw_api.services.library.scan as scan_mod

    monkeypatch.setattr(scan_mod, "probe_media", lambda *_a, **_k: None)
    heard: list[tuple[str, object]] = []

    @plugin("test.listener", title="听事件")
    async def listener(ctx) -> None:
        for event in (
            LIBRARY_FILES_ADDED,
            PLAYBACK_STARTED,
            LIBRARY_ITEM_FAVORITED,
            LIBRARY_ITEM_VIEWED,
        ):
            ctx.on(event, lambda p, name=event.name: heard.append((name, p)), id=event.name)

    app, client = make_client()
    with client:
        client.portal.call(app.state.kernel.mount, Entry("test.listener", listener))
        ids = client.portal.call(seed, env / "media")

        def got(name):
            return [p for n, p in heard if n == name]

        # 打开详情（网页）
        reply = client.get(f"/api/v1/libraries/{ids['library']}/items/{ids['show']}")
        assert reply.status_code == 200, reply.text
        wait_for(lambda: got("library.item.viewed"))
        viewed = got("library.item.viewed")[0]
        assert viewed.media_item_id == ids["show"] and viewed.client == "web"

        # 开始播放
        reply = client.post(
            "/api/v1/playback/progress",
            json={
                "media_item_id": ids["show"],
                "season_number": 1,
                "episode_number": 2,
                "event": "start",
                "position_ms": 0,
                "file_id": ids["files"][2],
            },
        )
        assert reply.status_code == 200, reply.text
        wait_for(lambda: got("playback.started"))
        started = got("playback.started")[0]
        assert (started.media_item_id, started.season, started.episode) == (ids["show"], 1, 2)
        assert started.file_id == ids["files"][2]

        # 收藏整部剧
        reply = client.post(
            "/api/v1/playback/marks", json={"media_item_id": ids["show"], "favorite": True}
        )
        assert reply.status_code == 200, reply.text
        wait_for(lambda: got("library.item.favorited"))
        fav = got("library.item.favorited")[0]
        assert fav.media_item_id == ids["show"] and fav.favorite is True
        assert fav.season is None and fav.episode is None

        # 扫描入账新的 strm（按文件名识别失败也算入账：未识别的条目为空）
        new = env / "media" / "新剧.S01E01.strm"
        new.write_text("https://pan.example.com/new/e1.mkv\n", encoding="utf-8")
        client.portal.call(scan_mod.scan_library, ids["library"])
        wait_for(lambda: got("library.files.added"))
        added = got("library.files.added")[0]
        assert added.library_id == ids["library"]
        assert [f.strm for f in added.files] == [True]


def test_pending_list_filters_orders_and_pages(env) -> None:
    app, client = make_client()
    with client:
        ids = client.portal.call(seed, env / "media")

        data = client.get(PENDING).json()["data"]
        # 本地电影有规格、不算；四个 strm 都待探，新入账的在前
        assert data["total"] == 4
        assert [i["file_id"] for i in data["items"]] == [
            ids["ts"],
            ids["files"][3],
            ids["files"][2],
            ids["files"][1],
        ]
        assert data["items"][0]["container"] == "ts" and data["next_cursor"] is None

        data = client.get(PENDING, params={"exclude_containers": ["ts", "iso"]}).json()["data"]
        assert ids["ts"] not in [i["file_id"] for i in data["items"]]

        data = client.get(
            PENDING, params={"media_item_id": ids["show"], "season": 1, "order": "episode"}
        ).json()["data"]
        assert [i["episode"] for i in data["items"]] == [1, 2, 3]

        first = client.get(PENDING, params={"order": "episode", "limit": 2}).json()["data"]
        assert len(first["items"]) == 2 and first["next_cursor"] == "2"
        second = client.get(
            PENDING, params={"order": "episode", "limit": 2, "cursor": first["next_cursor"]}
        ).json()["data"]
        assert [i["file_id"] for i in first["items"] + second["items"]] == [
            ids["files"][1],
            ids["files"][2],
            ids["files"][3],
            ids["ts"],
        ]


def test_probe_reports_and_backoff_hides_from_pending(env, monkeypatch) -> None:
    outcomes = [None, MediaSpec("1080p", "h264", None, 8, 30, 4_000_000)]
    monkeypatch.setattr(strm_probe, "probe_media", lambda *a, **k: outcomes.pop(0))
    app, client = make_client()
    with client:
        ids = client.portal.call(lambda: seed(env / "media", episodes=1))
        file_id = ids["files"][1]
        url = f"/api/v1/library-strm/files/{file_id}/probe"

        failed = client.post(url).json()["data"]
        assert failed["status"] == "failed" and failed["error"]
        assert failed["next_retry_at"]
        # 退避期内：不再列为待探，再探回 backoff
        pending = client.get(PENDING).json()["data"]
        assert file_id not in [i["file_id"] for i in pending["items"]]
        assert client.post(url).json()["data"]["status"] == "backoff"

        # 无视退避（例如用户在界面上点了重试）
        probed = client.post(url, params={"respect_backoff": "false"}).json()["data"]
        assert probed["status"] == "probed"
        assert probed["video_codec"] == "h264" and probed["container"] == "mkv"
        assert client.post(url).json()["data"]["status"] == "ready"
        local = client.get(PENDING).json()["data"]
        assert file_id not in [i["file_id"] for i in local["items"]]
        assert client.post("/api/v1/library-strm/files/99999/probe").status_code == 404


def test_backoff_expiry_returns_files_to_pending(env, monkeypatch) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import StrmProbeState
    from movieclaw_db.models.base import utcnow

    monkeypatch.setattr(strm_probe, "probe_media", lambda *a, **k: None)
    app, client = make_client()
    with client:
        ids = client.portal.call(lambda: seed(env / "media", episodes=1))
        file_id = ids["files"][1]
        client.post(f"/api/v1/library-strm/files/{file_id}/probe")

        async def expire() -> None:
            async with get_database().session() as session:
                state = await session.get(StrmProbeState, file_id)
                state.next_retry_at = utcnow() - timedelta(seconds=1)
                await session.commit()

        client.portal.call(expire)
        pending = client.get(PENDING).json()["data"]
        assert file_id in [i["file_id"] for i in pending["items"]]

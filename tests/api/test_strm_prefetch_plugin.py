"""网盘规格预探插件（docs/design/plugin-strm-prefetch.md §5）。

真实应用 + 随带插件：探测打桩（不碰网络），验证调度——

- 启动 / 改设置后补探全部待探条目，跳过的格式不探，任务中心显示插件给的名字；
- 开始播放让这一季接下来几集插队（优先级高于整库补探）；
- 停用取消它的任务、事件不再触发；卸载后回到首播现探；恢复后接着补探。
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events
from movieclaw_api.services.media_probe import MediaSpec
from movieclaw_api.services.playback import strm_probe

ID = "strm-prefetch"
SPEC = MediaSpec("1080p", "h264", None, 8, 30, 4_000_000)


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'prefetch.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    probed: list[str] = []

    def fake_probe(url, *args, **kwargs):
        probed.append(url)
        return SPEC

    monkeypatch.setattr(strm_probe, "probe_media", fake_probe)
    yield tmp_path, probed
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


def wait_for(predicate, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待超时")


async def seed(root, episodes: int) -> dict:
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
        session.add(show)
        await session.commit()
        files = {}
        for n in range(1, episodes + 1):
            strm = root / f"S01E{n:02d}.strm"
            strm.write_text(f"https://pan.example.com/e{n}.mkv\n", encoding="utf-8")
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
            files[n] = row.id
        ts = root / "S02E01.strm"
        ts.write_text("https://pan.example.com/s2e1.ts\n", encoding="utf-8")
        session.add(
            LibraryFile(
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
        )
        await session.commit()
        return {"library": library.id, "show": show.id, "files": files}


def jobs_of(client: TestClient, job_type: str) -> list[dict]:
    reply = client.get("/api/v1/jobs", params={"job_type": job_type, "limit": 100})
    assert reply.status_code == 200, reply.text
    return reply.json()["data"]["items"]


def configure(client: TestClient, **values) -> None:
    reply = client.put(f"/api/v1/app/plugins/{ID}/settings", json={"values": values})
    assert reply.status_code == 200, reply.text


def test_backfills_pending_files_and_skips_slow_formats(env) -> None:
    tmp, probed = env
    app, client = make_client()
    with client:
        fiber = app.state.kernel.fiber(ID)
        assert fiber.state.value == "active", fiber.error
        plugin = next(
            p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"] if p["id"] == ID
        )
        assert plugin["tier"] == "official" and plugin["removable"] is True

        client.portal.call(lambda: seed(tmp / "media", 3))
        # 改设置会按新设置重启插件：启动时发现有待探的，排一轮补探
        configure(client, interval_seconds=0.5)
        wait_for(lambda: len(probed) == 3)
        wait_for(lambda: [j["status"] for j in jobs_of(client, f"{ID}:backfill")] == ["succeeded"])
        [job] = jobs_of(client, f"{ID}:backfill")
        assert job["job_type_label"] == "网盘规格预探"
        assert job["result"]["probed"] == 3
        assert not any(url.endswith(".ts") for url in probed), "ts 默认不预探"
        pending = client.get("/api/v1/library-strm/pending").json()["data"]
        assert [i["container"] for i in pending["items"]] == ["ts"]


def test_playback_jumps_the_queue_for_the_next_episodes(env) -> None:
    tmp, probed = env
    app, client = make_client()
    with client:
        ids = client.portal.call(lambda: seed(tmp / "media", 6))
        # 间隔拉长，整库补探探完第一个就歇着；播第 3 集 → 第 4、5 集插队
        configure(client, interval_seconds=30)
        wait_for(lambda: len(probed) == 1)
        reply = client.post(
            "/api/v1/playback/progress",
            json={
                "media_item_id": ids["show"],
                "season_number": 1,
                "episode_number": 3,
                "event": "start",
                "position_ms": 0,
            },
        )
        assert reply.status_code == 200, reply.text
        # 整库补探还在歇着，插队任务先把下一集探了（再歇一个间隔探第 5 集）
        wait_for(lambda: len(probed) == 2)
        assert probed[1] == "https://pan.example.com/e4.mkv"
        [job] = jobs_of(client, f"{ID}:item")
        assert job["job_type_label"] == "网盘规格预探（插队）"
        assert job["input_data"]["after_episode"] == 3 and job["input_data"]["limit"] == 2
        [backfill] = jobs_of(client, f"{ID}:backfill")
        assert backfill["status"] == "running"
        # 重复的播放上报不重复排（去重键）
        client.post(
            "/api/v1/playback/progress",
            json={
                "media_item_id": ids["show"],
                "season_number": 1,
                "episode_number": 3,
                "event": "start",
                "position_ms": 0,
            },
        )
        time.sleep(0.3)
        assert len(jobs_of(client, f"{ID}:item")) == 1


def test_disable_uninstall_and_restore(env) -> None:
    tmp, probed = env
    app, client = make_client()
    with client:
        kernel = app.state.kernel
        ids = client.portal.call(lambda: seed(tmp / "media", 4))
        configure(client, interval_seconds=30)
        wait_for(lambda: len(probed) == 1)

        reply = client.put(f"/api/v1/app/plugins/{ID}/enabled", json={"enabled": False})
        assert reply.status_code == 200, reply.text
        wait_for(
            lambda: (
                [j["status"] for j in jobs_of(client, f"{ID}:backfill")]
                in (["cancelled"], ["cancelling"])
            )
        )
        # 停用后打开详情不再插队
        client.get(f"/api/v1/libraries/{ids['library']}/items/{ids['show']}")
        time.sleep(0.3)
        assert jobs_of(client, f"{ID}:item") == []

        reply = client.delete(f"/api/v1/app/plugins/{ID}/bundled")
        assert reply.status_code == 200, reply.text
        assert kernel.fiber(ID) is None
        assert [r["id"] for r in client.get("/api/v1/app/plugins").json()["data"]["removed"]] == [
            ID
        ]

        # 恢复：接着补探剩下的
        configure_after = client.post(f"/api/v1/app/plugins/{ID}/bundled/restore")
        assert configure_after.status_code == 200, configure_after.text
        configure(client, interval_seconds=0.5)
        wait_for(lambda: len(set(probed)) == 4)

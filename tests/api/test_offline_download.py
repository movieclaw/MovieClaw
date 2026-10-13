"""离线下载的服务端（docs/design/offline-download.md）。

测 HTTP 边界上真正会出事的地方：

- 权限：「下载影片到设备」关掉后下载类接口 403，观看记录补传照收；Jellyfin 策略跟着变；
- 清单：给齐展示数据（与详情接口同一份）、播放数据、字幕地址与可选档位；
- 原画：Range 续传、If-Range 对不上整份重下、strm 一律服务端转发（不 302 把令牌带给网盘）；
- 观看记录：按编号幂等、按发生时间判新旧、手机时钟偏差校正、观看时长封顶、对不上条目 rejected；
- 导出：真 ffmpeg 转出可播文件、同档复用、边转边发（转码中的连接跟着文件增长、换代号掐断）。
"""

from __future__ import annotations

import itertools
import shutil
import subprocess
import threading
import time
from datetime import UTC, datetime, timedelta
from functools import partial
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.offline import exports
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    PlaybackLog,
    PlaybackState,
)
from movieclaw_db.repositories.library_repo import LibraryRepository

_API = "/api/v1"
_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}
_MEMBER = {"username": "family", "password": "family-pass-1"}
_DURATION_S = 600

_HAS_FFMPEG = shutil.which("ffmpeg") is not None


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'offline.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("MOVIECLAW_OFFLINE_EXPORTS_DIR", str(tmp_path / "exports"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    # 测试机没有显卡：硬件探测一律为空，转码档走软件（用例里按需打开软件转码）
    monkeypatch.setattr("movieclaw_api.services.playback.plan.hardware_available", lambda: False)
    monkeypatch.setattr(
        "movieclaw_api.services.offline.exports.available_local_backends", lambda: ()
    )
    exports.reset_export_manager(tmp_path / "exports")

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post(f"{_API}/auth/bootstrap", json=_ADMIN)
        yield c
        c.portal.call(exports.get_export_manager().shutdown)  # type: ignore[attr-defined]

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


_counter = itertools.count(1)


def _make_video(path: Path, seconds: int = 4) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"testsrc2=size=1280x720:rate=24:duration={seconds}",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=440:duration={seconds}",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "24",
            "-c:a",
            "aac",
            "-shortest",
            str(path),
        ],
        check=True,
    )


async def _seed(tmp_path: Path, *, real: bool, kind: str = "movie") -> tuple[int, int, int]:
    """建库 + 条目 + 一个在位文件（可带同名外挂 srt），返回 (库, 条目, 文件)。"""
    n = next(_counter)
    root = tmp_path / f"lib{n}"
    root.mkdir(exist_ok=True)
    path = root / f"movie{n}.mp4"
    if real:
        _make_video(path)
    else:
        path.write_bytes(bytes(range(256)) * 4096)
    (root / f"movie{n}.chs.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\n你好\n", "utf-8")
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name=f"库{n}", kind=kind, root_paths=[str(root)]
        )
        item = MediaItem(kind=kind, tmdb_id=n, title=f"示例{n}", original_title=f"Example{n}")
        session.add(item)
        await session.flush()
        file = LibraryFile(
            library_id=library.id,
            media_item_id=item.id,
            file_path=str(path),
            size_bytes=path.stat().st_size,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="mp4",
            video_codec="h264",
            resolution="720p" if real else "1080p",
            duration_seconds=4 if real else _DURATION_S,
            audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
            external_subtitles=[
                {"filename": f"movie{n}.chs.srt", "format": "srt", "language": "chi"}
            ],
        )
        session.add(file)
        await session.commit()
        return library.id, item.id, file.id


def seed(client: TestClient, tmp_path: Path, **kw) -> tuple[int, int, int]:
    return client.portal.call(partial(_seed, tmp_path, **kw))  # type: ignore[attr-defined]


def _file_path(client: TestClient, file_id: int) -> Path:
    async def fetch(session):
        return Path((await session.get(LibraryFile, file_id)).file_path)

    return _run(client, fetch)


def _run(client: TestClient, fn):
    async def go():
        async with get_database().session() as session:
            return await fn(session)

    return client.portal.call(go)  # type: ignore[attr-defined]


def _enable_software_transcode(client: TestClient) -> None:
    resp = client.put(f"{_API}/playback/policy", json={"software_transcode_enabled": True})
    assert resp.status_code == 200, resp.text


def _login_member(client: TestClient, **caps) -> int:
    created = client.post(f"{_API}/members", json=_MEMBER)
    assert created.status_code == 200, created.text
    member_id = created.json()["data"]["id"]
    if caps:
        resp = client.put(f"{_API}/members/{member_id}", json=caps)
        assert resp.status_code == 200, resp.text
    client.cookies.clear()
    resp = client.post(f"{_API}/auth/login", json=_MEMBER)
    assert resp.status_code == 200, resp.text
    return member_id


def _viewing(item_id: int, **kw) -> dict:
    now = datetime.now(UTC)
    record = {
        "viewing_id": kw.pop("viewing_id", "v-0000-0001"),
        "media_item_id": item_id,
        "started_at": (now - timedelta(minutes=10)).isoformat(),
        "updated_at": now.isoformat(),
        "position_ms": 120_000,
        "watched_ms": 120_000,
    }
    record.update(kw)
    return record


def _send_viewings(client: TestClient, records: list[dict], sent_at: datetime | None = None):
    resp = client.post(
        f"{_API}/playback/viewings",
        json={"sent_at": (sent_at or datetime.now(UTC)).isoformat(), "records": records},
    )
    assert resp.status_code == 200, resp.text
    return {r["viewing_id"]: r["status"] for r in resp.json()["data"]["results"]}


# ---------------------------------------------------------------------------
# 权限与实例号
# ---------------------------------------------------------------------------


def test_health_instance_id_matches_jellyfin_server_id(client: TestClient) -> None:
    health = client.get(f"{_API}/health").json()
    assert len(health["instance_id"]) == 32
    info = client.get("/System/Info/Public").json()
    assert info["Id"] == health["instance_id"]
    # 同一台服务器每次都是同一个值
    assert client.get(f"{_API}/health").json()["instance_id"] == health["instance_id"]


def test_video_download_switch_gates_download_but_not_viewings(
    client: TestClient, tmp_path: Path
) -> None:
    _lib, item_id, file_id = seed(client, tmp_path, real=False)
    _login_member(client, allow_video_download=False)
    me = client.get(f"{_API}/auth/me").json()["data"]
    assert me["capabilities"]["allow_video_download"] is False
    for method, path in (
        ("GET", f"/offline/manifest?file_id={file_id}"),
        ("GET", f"/offline/files/{file_id}/content"),
        ("POST", "/offline/exports"),
        ("POST", "/offline/profiles"),
    ):
        body = {"file_id": file_id, "profile": "480p", "file_ids": [file_id]}
        resp = client.request(method, f"{_API}{path}", json=body)
        assert resp.status_code == 403, (path, resp.text)
    # 权限关了，已下的片照样能播：观看记录照收
    assert _send_viewings(client, [_viewing(item_id)]) == {"v-0000-0001": "applied"}


def test_jellyfin_policy_follows_video_download_switch(client: TestClient) -> None:
    created = client.post(f"{_API}/members", json=_MEMBER).json()["data"]
    assert created["allow_video_download"] is True
    client.put(f"{_API}/members/{created['id']}", json={"allow_video_download": False})

    from movieclaw_jellyfin.identity import user_policy

    async def member_policy(session):
        from movieclaw_db.models import Member

        return user_policy(member=await session.get(Member, created["id"]))

    assert _run(client, member_policy)["EnableContentDownloading"] is False


# ---------------------------------------------------------------------------
# 清单与原画
# ---------------------------------------------------------------------------


def _set_size(client: TestClient, file_id: int, size: int) -> None:
    async def update(session):
        row = await session.get(LibraryFile, file_id)
        row.size_bytes = size
        await session.commit()

    _run(client, update)


def test_manifest_carries_detail_tracks_and_profiles(client: TestClient, tmp_path: Path) -> None:
    library_id, item_id, file_id = seed(client, tmp_path, real=False)
    _set_size(client, file_id, 4_000_000_000)  # 台账上是一部 4 GB 的 1080p
    _enable_software_transcode(client)
    data = client.get(f"{_API}/offline/manifest", params={"file_id": file_id}).json()["data"]
    # 展示数据与详情接口同一份：离线时原样喂给同一个页面
    detail = client.get(f"{_API}/libraries/{library_id}/items/{item_id}").json()["data"]
    assert data["item"]["media_item_id"] == detail["media_item_id"] == item_id
    assert data["item"]["title"] == detail["title"]
    assert data["library"]["id"] == library_id
    assert data["duration_ms"] == _DURATION_S * 1000
    # 外挂字幕：带签名的地址，取得到
    [sub] = data["subtitles"]
    assert sub["format"] == "srt" and sub["embedded"] is False
    body = client.get(sub["url"]).text
    assert "你好" in body
    # 1080p 源：原画 + 720p + 480p（不给不高于源的 1080p）
    assert [p["profile"] for p in data["profiles"]] == ["original", "720p", "480p"]
    assert data["profiles"][0]["expected_bytes"] == 4_000_000_000
    assert data["profiles"][1]["expected_bytes"] > data["profiles"][2]["expected_bytes"] > 0


def test_manifest_skips_tiers_not_smaller_than_original(client: TestClient, tmp_path: Path) -> None:
    """源本身码率就低（10 分钟 260 MB）：720p 转出来不比原文件小，不提供；480p 仍小得多，提供。"""
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    _set_size(client, file_id, 260_000_000)
    _enable_software_transcode(client)
    data = client.get(f"{_API}/offline/manifest", params={"file_id": file_id}).json()["data"]
    assert [p["profile"] for p in data["profiles"]] == ["original", "480p"]


def test_manifest_without_transcode_offers_original_only(
    client: TestClient, tmp_path: Path
) -> None:
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    data = client.get(f"{_API}/offline/manifest", params={"file_id": file_id}).json()["data"]
    # 没有硬件、软件转码没开：转码档出不了，只剩原画
    assert [p["profile"] for p in data["profiles"]] == ["original"]


def test_profiles_batch_matches_manifest_rules(client: TestClient, tmp_path: Path) -> None:
    """选档表单批量估大小：档位规则与清单同一套，按请求顺序，重复的只算一次"""
    _lib, _item, big = seed(client, tmp_path, real=False)
    _lib2, _item2, small = seed(client, tmp_path, real=False)
    _set_size(client, big, 4_000_000_000)
    _set_size(client, small, 260_000_000)
    _enable_software_transcode(client)
    resp = client.post(f"{_API}/offline/profiles", json={"file_ids": [small, big, small]})
    assert resp.status_code == 200, resp.text
    files = resp.json()["data"]["files"]
    assert [f["file_id"] for f in files] == [small, big]
    for entry in files:
        manifest = client.get(f"{_API}/offline/manifest", params={"file_id": entry["file_id"]})
        assert entry["profiles"] == manifest.json()["data"]["profiles"]
    assert [p["profile"] for p in files[1]["profiles"]] == ["original", "720p", "480p"]
    assert [p["profile"] for p in files[0]["profiles"]] == ["original", "480p"]


def test_profiles_batch_skips_invisible_files(client: TestClient, tmp_path: Path) -> None:
    _library, _item, hidden = seed(client, tmp_path, real=False)
    other_library, _other_item, shown = seed(client, tmp_path, real=False)
    _login_member(client, all_libraries=False, library_ids=[other_library])
    files = client.post(f"{_API}/offline/profiles", json={"file_ids": [hidden, shown, 999_999]})
    assert [f["file_id"] for f in files.json()["data"]["files"]] == [shown]


def test_profiles_batch_is_one_quick_request_for_a_season(
    client: TestClient, tmp_path: Path
) -> None:
    """一季 40 集：一次请求、不逐集建清单（真机上逐集取 43 份清单要十几秒）"""
    ids = [seed(client, tmp_path, real=False)[2] for _ in range(40)]
    for file_id in ids:
        _set_size(client, file_id, 4_000_000_000)
    _enable_software_transcode(client)
    started = time.perf_counter()
    resp = client.post(f"{_API}/offline/profiles", json={"file_ids": ids})
    elapsed = time.perf_counter() - started
    assert resp.status_code == 200
    assert len(resp.json()["data"]["files"]) == 40
    assert elapsed < 2, f"40 个文件用了 {elapsed:.2f}s"


def test_original_content_supports_range_resume(client: TestClient, tmp_path: Path) -> None:
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    url = f"{_API}/offline/files/{file_id}/content"
    full = client.get(url)
    assert full.status_code == 200
    etag = full.headers["etag"]
    assert full.headers["accept-ranges"] == "bytes"
    expected = _file_path(client, file_id).read_bytes()
    assert full.content == expected
    part = client.get(url, headers={"Range": "bytes=1000-", "If-Range": etag})
    assert part.status_code == 206
    assert part.content == expected[1000:]
    # 文件变了（洗版、重写）：If-Range 对不上，整份重下，不拼坏文件
    stale = client.get(url, headers={"Range": "bytes=1000-", "If-Range": '"other"'})
    assert stale.status_code == 200 and stale.content == expected


def test_manifest_hides_files_outside_member_libraries(client: TestClient, tmp_path: Path) -> None:
    library_id, _item, file_id = seed(client, tmp_path, real=False)
    other_library, _other_item, _other_file = seed(client, tmp_path, real=False)
    _login_member(client, all_libraries=False, library_ids=[other_library])
    assert client.get(f"{_API}/offline/manifest", params={"file_id": file_id}).status_code == 404
    assert client.get(f"{_API}/offline/files/{file_id}/content").status_code == 404


# ---------------------------------------------------------------------------
# 观看记录
# ---------------------------------------------------------------------------


def _state(client: TestClient, item_id: int) -> PlaybackState | None:
    async def fetch(session):
        return (
            await session.execute(
                select(PlaybackState).where(PlaybackState.media_item_id == item_id)
            )
        ).scalar_one_or_none()

    return _run(client, fetch)


def _logs(client: TestClient, item_id: int) -> list[PlaybackLog]:
    async def fetch(session):
        return list(
            (
                await session.execute(
                    select(PlaybackLog).where(PlaybackLog.media_item_id == item_id)
                )
            ).scalars()
        )

    return _run(client, fetch)


def test_viewing_records_are_idempotent_and_keep_real_times(
    client: TestClient, tmp_path: Path
) -> None:
    _lib, item_id, file_id = seed(client, tmp_path, real=False)
    watched_at = datetime.now(UTC) - timedelta(hours=5)
    record = _viewing(
        item_id,
        file_id=file_id,
        started_at=(watched_at - timedelta(minutes=4)).isoformat(),
        updated_at=watched_at.isoformat(),
        position_ms=240_000,
        watched_ms=240_000,
        ended=True,
    )
    assert _send_viewings(client, [record]) == {"v-0000-0001": "applied"}
    assert _send_viewings(client, [record]) == {"v-0000-0001": "applied"}  # 重发：不翻倍
    state = _state(client, item_id)
    assert state.position_ms == 240_000 and state.play_count == 1
    [log] = _logs(client, item_id)
    # 观看日志的时间是真实观看时间，不是补传那一刻
    assert (
        abs(
            (
                log.started_at - (watched_at - timedelta(minutes=4)).replace(tzinfo=None)
            ).total_seconds()
        )
        < 5
    )
    assert log.ended_at is not None and log.watched_ms == 240_000
    assert log.viewing_id == "v-0000-0001"


def test_viewing_older_than_server_state_is_stale_but_logged(
    client: TestClient, tmp_path: Path
) -> None:
    _lib, item_id, _file = seed(client, tmp_path, real=False)
    # 另一台设备刚刚看到 300 秒
    client.post(f"{_API}/playback/progress", json={"media_item_id": item_id, "event": "start"})
    client.post(
        f"{_API}/playback/progress",
        json={"media_item_id": item_id, "event": "stop", "position_ms": 300_000},
    )
    old = datetime.now(UTC) - timedelta(days=1)
    record = _viewing(
        item_id,
        viewing_id="v-old-0000",
        started_at=(old - timedelta(minutes=2)).isoformat(),
        updated_at=old.isoformat(),
        position_ms=100_000,
        watched_ms=100_000,
    )
    assert _send_viewings(client, [record]) == {"v-old-0000": "stale"}
    assert _state(client, item_id).position_ms == 300_000  # 后发生的那次赢
    assert any(log.viewing_id == "v-old-0000" for log in _logs(client, item_id))  # 观看统计照记


def test_viewing_completed_marks_played_and_watch_time_is_capped(
    client: TestClient, tmp_path: Path
) -> None:
    _lib, item_id, _file = seed(client, tmp_path, real=False)
    now = datetime.now(UTC)
    record = _viewing(
        item_id,
        viewing_id="v-done-0000",
        started_at=(now - timedelta(minutes=3)).isoformat(),
        updated_at=now.isoformat(),
        position_ms=_DURATION_S * 1000,
        watched_ms=3_600_000,  # 报得比墙钟还长
        completed=True,
        ended=True,
    )
    assert _send_viewings(client, [record]) == {"v-done-0000": "applied"}
    state = _state(client, item_id)
    assert state.played is True and state.position_ms == 0
    [log] = _logs(client, item_id)
    assert log.completed is True
    assert log.watched_ms <= 3 * 60_000 + 2_000


def test_viewing_clock_skew_is_corrected(client: TestClient, tmp_path: Path) -> None:
    _lib, item_id, _file = seed(client, tmp_path, real=False)
    skew = timedelta(minutes=30)  # 手机快了半小时
    now = datetime.now(UTC)
    record = _viewing(
        item_id,
        viewing_id="v-skew-0000",
        started_at=(now + skew - timedelta(minutes=5)).isoformat(),
        updated_at=(now + skew - timedelta(minutes=1)).isoformat(),
    )
    _send_viewings(client, [record], sent_at=now + skew)
    [log] = _logs(client, item_id)
    expected = (now - timedelta(minutes=5)).replace(tzinfo=None)
    assert abs((log.started_at - expected).total_seconds()) < 5


def test_viewing_for_unknown_item_is_rejected(client: TestClient) -> None:
    assert _send_viewings(client, [_viewing(98765, viewing_id="v-gone-0000")]) == {
        "v-gone-0000": "rejected"
    }


def test_viewing_follows_file_to_its_current_item(client: TestClient, tmp_path: Path) -> None:
    """条目被转移 / 重新识别后，旧条目号对不上，按文件找到现在的条目。"""
    _lib, item_id, file_id = seed(client, tmp_path, real=False)
    record = _viewing(12345, viewing_id="v-moved-0000", file_id=file_id)
    assert _send_viewings(client, [record]) == {"v-moved-0000": "applied"}
    assert _state(client, item_id).position_ms == 120_000


# ---------------------------------------------------------------------------
# 导出
# ---------------------------------------------------------------------------


def _wait_export(client: TestClient, export_id: str, timeout: float = 60) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = client.get(f"{_API}/offline/exports/{export_id}").json()["data"]
        if data["status"] in ("done", "failed"):
            return data
        time.sleep(0.2)
    raise AssertionError("导出超时")


@pytest.mark.skipif(not _HAS_FFMPEG, reason="需要 ffmpeg")
def test_export_produces_playable_file_and_is_reused(client: TestClient, tmp_path: Path) -> None:
    _lib, _item, file_id = seed(client, tmp_path, real=True)
    _enable_software_transcode(client)
    created = client.post(f"{_API}/offline/exports", json={"file_id": file_id, "profile": "480p"})
    assert created.status_code == 200, created.text
    export = created.json()["data"]
    done = _wait_export(client, export["export_id"])
    assert done["status"] == "done", done
    # 同档同片再要一次：同一个导出，不重转
    again = client.post(f"{_API}/offline/exports", json={"file_id": file_id, "profile": "480p"})
    assert again.json()["data"]["export_id"] == export["export_id"]
    assert again.json()["data"]["etag"] == done["etag"]

    resp = client.get(export["content_url"])
    assert resp.status_code == 200 and resp.headers["etag"] == done["etag"]
    assert len(resp.content) == done["final_bytes"]
    out = tmp_path / "check.mp4"
    out.write_bytes(resp.content)
    probe = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=codec_name,height",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1",
            str(out),
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    assert "height=480" in probe and "codec_name=h264" in probe and "codec_name=aac" in probe
    assert abs(float(probe.split("duration=")[1].split()[0]) - 4.0) < 0.5
    # 续传：带导出的 ETag 取后半段
    part = client.get(
        export["content_url"], headers={"Range": "bytes=100-", "If-Range": done["etag"]}
    )
    assert part.status_code == 206 and part.content == resp.content[100:]
    # 下完通知回收
    assert client.delete(f"{_API}/offline/exports/{export['export_id']}").status_code == 200
    assert client.get(f"{_API}/offline/exports/{export['export_id']}").status_code == 404


def test_export_unavailable_without_transcode(client: TestClient, tmp_path: Path) -> None:
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    resp = client.post(f"{_API}/offline/exports", json={"file_id": file_id, "profile": "480p"})
    assert resp.status_code == 400 and "软件转码" in resp.json()["message"]


def test_export_tail_streams_while_transcoding(client: TestClient, tmp_path: Path) -> None:
    """转码中的导出：连接跟着文件增长往后发，转完发完才正常结束。"""
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    manager = exports.get_export_manager()
    state = exports.ExportState(
        export_id="tailtest",
        file_id=file_id,
        profile="480p",
        audio_track=None,
        status=exports.STATUS_RUNNING,
        generation=1,
        expected_bytes=3000,
        created_at=time.time(),
        last_access_at=time.time(),
    )
    manager._loaded = True
    manager._states[state.export_id] = state
    out = manager.output_path(state)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b"a" * 1000)

    def grow():
        time.sleep(0.5)
        with out.open("ab") as fh:
            fh.write(b"b" * 1000)
        time.sleep(0.5)
        with out.open("ab") as fh:
            fh.write(b"c" * 1000)
        state.final_bytes = 3000
        state.status = exports.STATUS_DONE

    threading.Thread(target=grow).start()
    resp = client.get(f"{_API}/offline/exports/tailtest/content")
    assert resp.status_code == 200
    assert resp.headers["etag"] == state.etag
    assert "content-length" not in resp.headers
    assert resp.content == b"a" * 1000 + b"b" * 1000 + b"c" * 1000


def test_export_tail_aborts_when_regenerated(client: TestClient, tmp_path: Path) -> None:
    """中途重转（代号变了）：旧连接掐断，不把两次转码的字节拼在一起。"""
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    manager = exports.get_export_manager()
    state = exports.ExportState(
        export_id="regen",
        file_id=file_id,
        profile="480p",
        audio_track=None,
        status=exports.STATUS_RUNNING,
        generation=1,
        expected_bytes=3000,
        created_at=time.time(),
        last_access_at=time.time(),
    )
    manager._loaded = True
    manager._states[state.export_id] = state
    out = manager.output_path(state)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b"a" * 1000)

    def regenerate():
        time.sleep(0.5)
        state.generation = 2

    threading.Thread(target=regenerate).start()
    with pytest.raises(exports.ExportStreamAborted):  # 连接没有正常结束
        client.get(f"{_API}/offline/exports/regen/content")


def test_queued_export_answers_retry_after(client: TestClient, tmp_path: Path) -> None:
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    manager = exports.get_export_manager()
    state = exports.ExportState(
        export_id="queued",
        file_id=file_id,
        profile="480p",
        audio_track=None,
        status=exports.STATUS_QUEUED,
        generation=0,
        expected_bytes=3000,
        created_at=time.time(),
        last_access_at=time.time(),
    )
    manager._loaded = True
    manager._states[state.export_id] = state
    resp = client.get(f"{_API}/offline/exports/queued/content")
    assert resp.status_code == 503 and int(resp.headers["retry-after"]) >= 60


# ---------------------------------------------------------------------------
# 回归：代码评审发现的问题（先复现、再修）
# ---------------------------------------------------------------------------


def _fake_state(client, file_id, export_id, *, status, generation=1):
    manager = exports.get_export_manager()
    state = exports.ExportState(
        export_id=export_id,
        file_id=file_id,
        profile="480p",
        audio_track=None,
        status=status,
        generation=generation,
        expected_bytes=3000,
        created_at=time.time(),
        last_access_at=time.time(),
    )
    manager._loaded = True
    manager._states[export_id] = state
    return manager, state


def test_head_and_missing_export_do_not_leak_activity_meters(client, tmp_path) -> None:
    """转码中的 HEAD、转完但文件已不在：活动页不能挂着幽灵下载。"""
    from movieclaw_playback import activity

    _lib, _item, file_id = seed(client, tmp_path, real=False)
    manager, running = _fake_state(client, file_id, "headtest", status=exports.STATUS_RUNNING)
    out = manager.output_path(running)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b"x" * 100)
    _fake_state(client, file_id, "gone", status=exports.STATUS_DONE)
    before = len(activity._meters)
    for _ in range(3):
        assert client.head(f"{_API}/offline/exports/headtest/content").status_code == 200
    assert client.get(f"{_API}/offline/exports/gone/content").status_code == 404
    assert len(activity._meters) == before


@pytest.mark.skipif(not _HAS_FFMPEG, reason="需要 ffmpeg")
def test_regenerated_export_gets_a_new_etag(client, tmp_path) -> None:
    """产物被清掉后重转：ETag 不能与上一次相同，否则客户端拿旧 ETag 续传会拼出两次转码的字节。"""
    _lib, _item, file_id = seed(client, tmp_path, real=True)
    _enable_software_transcode(client)
    body = {"file_id": file_id, "profile": "480p"}
    export = client.post(f"{_API}/offline/exports", json=body).json()["data"]
    first = _wait_export(client, export["export_id"])
    assert first["status"] == "done"
    manager = exports.get_export_manager()
    manager.output_path(manager.get(export["export_id"])).unlink()  # 缓存管理清空
    client.post(f"{_API}/offline/exports", json=body)
    second = _wait_export(client, export["export_id"])
    assert second["status"] == "done"
    assert second["etag"] != first["etag"]


def test_untrusted_clock_keeps_order_within_a_batch(client, tmp_path) -> None:
    """手机时钟不可信时整批平移：同一集先看到 20 分钟、后看到 45 分钟，结果应停在 45 分钟。"""
    _lib, item_id, file_id = seed(client, tmp_path, real=False)
    far = datetime.now(UTC) - timedelta(days=30)
    early = _viewing(
        item_id,
        viewing_id="v-clock-early",
        file_id=file_id,
        started_at=(far - timedelta(minutes=30)).isoformat(),
        updated_at=(far - timedelta(minutes=10)).isoformat(),
        position_ms=200_000,
        watched_ms=60_000,
    )
    late = _viewing(
        item_id,
        viewing_id="v-clock-late",
        file_id=file_id,
        started_at=(far - timedelta(minutes=9)).isoformat(),
        updated_at=far.isoformat(),
        position_ms=450_000,
        watched_ms=60_000,
    )
    _send_viewings(client, [early, late], sent_at=far + timedelta(minutes=1))
    assert _state(client, item_id).position_ms == 450_000


def test_resent_viewing_with_untrusted_clock_does_not_override_newer_progress(
    client, tmp_path
) -> None:
    _lib, item_id, file_id = seed(client, tmp_path, real=False)
    far = datetime.now(UTC) - timedelta(days=30)
    record = _viewing(
        item_id,
        viewing_id="v-clock-resend",
        file_id=file_id,
        started_at=(far - timedelta(minutes=5)).isoformat(),
        updated_at=far.isoformat(),
        position_ms=100_000,
        watched_ms=60_000,
    )
    _send_viewings(client, [record], sent_at=far)
    # 之后在电视上看到了 300 秒
    client.post(f"{_API}/playback/progress", json={"media_item_id": item_id, "event": "start"})
    client.post(
        f"{_API}/playback/progress",
        json={"media_item_id": item_id, "event": "stop", "position_ms": 300_000},
    )
    # 确认丢了，手机重发同一份旧记录
    _send_viewings(client, [record], sent_at=far)
    assert _state(client, item_id).position_ms == 300_000


def test_favorite_after_offline_viewing_does_not_make_it_stale(client, tmp_path) -> None:
    """落地后先点了收藏（改了状态行的更新时间），飞机上那段比上次播放更晚的进度不能因此被当成旧的。"""
    _lib, item_id, file_id = seed(client, tmp_path, real=False)
    client.post(f"{_API}/playback/progress", json={"media_item_id": item_id, "event": "start"})
    client.post(
        f"{_API}/playback/progress",
        json={"media_item_id": item_id, "event": "stop", "position_ms": 60_000},
    )
    time.sleep(2)
    record = _viewing(
        item_id,
        viewing_id="v-after-fav",
        file_id=file_id,
        started_at=(datetime.now(UTC) - timedelta(seconds=1)).isoformat(),
        updated_at=(datetime.now(UTC) - timedelta(milliseconds=500)).isoformat(),
        position_ms=400_000,
        watched_ms=500,
    )
    resp = client.post(f"{_API}/playback/marks", json={"media_item_id": item_id, "favorite": True})
    assert resp.status_code == 200
    assert _send_viewings(client, [record]) == {"v-after-fav": "applied"}
    assert _state(client, item_id).position_ms == 400_000


def test_release_keeps_export_another_device_still_needs(client, tmp_path) -> None:
    """家里两台设备下同一集同一档：一台下完调 DELETE，不能删掉另一台还要的导出。"""
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    manager, state = _fake_state(client, file_id, "shared", status=exports.STATUS_DONE)
    out = manager.output_path(state)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b"y" * 10)
    manager.claim("shared", "device-a")
    manager.claim("shared", "device-b")
    manager.release("shared", "device-a")
    assert manager.get("shared") is not None and out.exists()
    manager.release("shared", "device-b")
    assert manager.get("shared") is None


def test_remote_transcoder_alone_offers_export_profiles(client, tmp_path, monkeypatch) -> None:
    """NAS 没有显卡、软件转码没开，但 Mac 转码器在线：转码档照样提供（导出交给转码器做）。"""
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    _set_size(client, file_id, 4_000_000_000)
    monkeypatch.setattr("movieclaw_api.services.playback.plan.hardware_available", lambda: True)
    resp = client.get(f"{_API}/offline/manifest", params={"file_id": file_id}).json()["data"]
    assert [p["profile"] for p in resp["profiles"]] == ["original", "720p", "480p"]


def test_export_waits_when_the_transcoder_drops_before_it_starts(client, tmp_path, monkeypatch):
    """建导出时转码器在线（档位成立）、开转前掉线：排队等它回来，不判失败、不偷偷软转。"""
    _lib, _item, file_id = seed(client, tmp_path, real=False)
    _set_size(client, file_id, 4_000_000_000)
    online = {"value": True}
    monkeypatch.setattr(
        "movieclaw_api.services.playback.plan.hardware_available", lambda: online["value"]
    )
    monkeypatch.setattr(exports, "_CAPACITY_POLL_S", 0.05)
    online["value"] = True
    created = client.post(f"{_API}/offline/exports", json={"file_id": file_id, "profile": "480p"})
    assert created.status_code == 200, created.text
    online["value"] = False  # 转码器掉线，软件转码没开
    time.sleep(0.5)
    state = client.get(f"{_API}/offline/exports/{created.json()['data']['export_id']}").json()
    assert state["data"]["status"] == "queued", state

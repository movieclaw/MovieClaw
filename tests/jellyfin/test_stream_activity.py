"""Issue #624：真实 TCP 验证详情页预缓存与播放活动的区别。"""

from __future__ import annotations

import os
import socket
import sqlite3
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path

import httpx
import pytest

from jellyfin.helpers import ADMIN, AUTH_HEADER, jf_login
from movieclaw_db.models.base import utcnow
from movieclaw_jellyfin.ids import episode_guid, item_guid
from movieclaw_playback import activity


@pytest.fixture
def server(seeded, tmp_path):
    """生产应用在独立进程运行，取流和活动查询都走真实 HTTP。"""

    @contextmanager
    def start():
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        with (tmp_path / "api.log").open("w") as log:
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "uvicorn",
                    "movieclaw_api.app:create_app",
                    "--factory",
                    "--fd",
                    str(sock.fileno()),
                    "--no-access-log",
                ],
                cwd=Path(__file__).resolve().parents[2],
                env={**os.environ, "PYTHONPATH": "src"},
                pass_fds=(sock.fileno(),),
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                with httpx.Client(base_url=f"http://127.0.0.1:{port}", trust_env=False) as c:
                    deadline = time.monotonic() + 30
                    while True:
                        assert process.poll() is None, (tmp_path / "api.log").read_text()
                        assert time.monotonic() < deadline, "服务启动超时"
                        try:
                            c.get("/health", timeout=0.2)
                            break
                        except httpx.TransportError:
                            time.sleep(0.05)
                    yield c
            finally:
                process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                sock.close()

    return start


@pytest.fixture
def client(server):
    with server() as c:
        response = c.post("/api/v1/auth/bootstrap", json=ADMIN)
        assert response.status_code == 200, response.text
        yield c


@pytest.mark.parametrize("client_name", ["Rex", "Infuse", "OtherPlayer"])
def test_detail_prefetch_does_not_report_playing(client, seeded, media_root, client_name):
    """未点播放，三次 Range GET 读取 issue 中的 42,991,616 字节仍不在播；
    之后真正开始播放则显示，停止后继续预缓存也不能把会话复活。"""
    path = media_root / "Inception (2010)" / "Inception.2010.2160p.mkv"
    with path.open("r+b") as file:
        file.truncate(64 * 1024 * 1024)
    login = client.post(
        "/Users/AuthenticateByName",
        json={"Username": ADMIN["username"], "Pw": ADMIN["password"]},
        headers={
            "Authorization": (
                f'MediaBrowser Client="{client_name}", Device="iPad", '
                'DeviceId="prefetch-device", Version="0.5.0"'
            )
        },
    )
    assert login.status_code == 200, login.text
    auth = {"ApiKey": login.json()["AccessToken"]}
    guid = item_guid(seeded["movie"])
    info = client.get(f"/Items/{guid}/PlaybackInfo", params=auth)
    assert info.status_code == 200
    source = next(s for s in info.json()["MediaSources"] if s["Protocol"] == "File")
    stream = {**auth, "static": "true", "mediaSourceId": source["Id"]}
    url = f"/Videos/{guid}/stream"

    total = 0
    for start, end in [(0, 16_777_215), (16_777_216, 33_554_431), (33_554_432, 42_991_615)]:
        with client.stream(
            "GET", url, params=stream, headers={"Range": f"bytes={start}-{end}"}
        ) as r:
            assert r.status_code == 206
            chunks = r.iter_bytes()
            total += len(next(chunks))
            data = client.get("/api/v1/playback/activity").json()["data"]
            assert data["sessions"] == []
            assert data["downloads"] == []
            total += sum(len(chunk) for chunk in chunks)
        assert client.get("/api/v1/playback/activity").json()["data"]["sessions"] == []
    assert total == 42_991_616
    user_data = client.get(f"/Items/{guid}", params=auth).json()["UserData"]
    assert user_data["PlayCount"] == 0
    assert user_data["PlaybackPositionTicks"] == 0

    assert client.post("/Sessions/Playing", params=auth, json={"ItemId": guid}).status_code == 204
    assert client.get(url, params=stream, headers={"Range": "bytes=0-4095"}).status_code == 206
    playing = client.get("/api/v1/playback/activity").json()["data"]["sessions"]
    assert [s["device_id"] for s in playing] == ["prefetch-device"]
    assert playing[0]["bytes_sent"] == 4096

    stopped = client.post(
        "/Sessions/Playing/Stopped",
        params=auth,
        json={"ItemId": guid, "PositionTicks": 90_000 * 10_000},
    )
    assert stopped.status_code == 204
    assert client.get(url, params=stream, headers={"Range": "bytes=4096-8191"}).status_code == 206
    assert client.get("/api/v1/playback/activity").json()["data"]["sessions"] == []


@pytest.mark.parametrize("log_age_seconds", [0, activity.SESSION_TTL_SECONDS + 1])
def test_stream_restores_confirmed_playback_after_process_restart(
    server, seeded, tmp_path, log_age_seconds
):
    """真正重启服务后，HEAD、另一台设备或另一影片的 GET 都不能恢复旧会话；
    同设备同影片的 GET 保留原始开始时间、位置和传输计量。"""
    guid = item_guid(seeded["movie"])
    with server() as client:
        assert client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        auth = {"ApiKey": jf_login(client)}
        info = client.post(f"/Items/{guid}/PlaybackInfo", params=auth).json()
        source = next(s for s in info["MediaSources"] if s["Protocol"] == "File")
        stream = {**auth, "static": "true", "mediaSourceId": source["Id"]}
        assert (
            client.post("/Sessions/Playing", params=auth, json={"ItemId": guid}).status_code == 204
        )
        assert (
            client.post(
                "/Sessions/Playing/Progress",
                params=auth,
                json={"ItemId": guid, "PositionTicks": 90_000 * 10_000, "IsPaused": False},
            ).status_code
            == 204
        )
        before = client.get("/api/v1/playback/activity").json()["data"]["sessions"][0]
        cookies = httpx.Cookies(client.cookies)

    if log_age_seconds:
        # 模拟播放器异常退出、没发 Stopped，旧日志虽未收口也已过保鲜期。
        with sqlite3.connect(tmp_path / "jf.db") as db:
            db.execute(
                "UPDATE playback_log SET last_seen_at = ? WHERE device_id = ?",
                (
                    (utcnow() - timedelta(seconds=log_age_seconds)).isoformat(" "),
                    "test-device-1",
                ),
            )

    with server() as client:
        client.cookies.update(cookies)
        assert client.get("/api/v1/playback/activity").json()["data"]["sessions"] == []
        url = f"/Videos/{guid}/stream"
        assert client.head(url, params=stream).status_code == 200
        assert client.get("/api/v1/playback/activity").json()["data"]["sessions"] == []

        login = client.post(
            "/Users/AuthenticateByName",
            json={"Username": ADMIN["username"], "Pw": ADMIN["password"]},
            headers={"Authorization": AUTH_HEADER.replace("test-device-1", "other-device")},
        )
        assert login.status_code == 200
        other_stream = {**stream, "ApiKey": login.json()["AccessToken"]}
        assert client.get(url, params=other_stream).status_code == 200
        episode = episode_guid(seeded["show"], 1, 1)
        assert (
            client.get(f"/Videos/{episode}/stream", params={**auth, "static": "true"}).status_code
            == 200
        )
        assert client.get("/api/v1/playback/activity").json()["data"]["sessions"] == []

        assert client.get(url, params=stream).status_code == 200
        restored = client.get("/api/v1/playback/activity").json()["data"]["sessions"]
        if log_age_seconds:
            assert restored == []
            return
        assert len(restored) == 1
        assert restored[0]["device_id"] == "test-device-1"
        assert restored[0]["position_ms"] == 90_000
        assert restored[0]["bytes_sent"] == 4096
        delta = datetime.fromisoformat(restored[0]["started_at"]) - datetime.fromisoformat(
            before["started_at"]
        )
        assert abs(delta.total_seconds()) < 1

"""真实 HTTP/WS → 两个 Mac 转码内核 → VideoToolbox → 回传 → 客户端解码。

先在 macos/MovieClawTranscoder 执行 swift build；使用隔离的临时数据库和媒体。
两个内核运行在同一台 Mac，异构硬件/负载的决策对照见 test_worker_scheduling。
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

import httpx
import pytest

from movieclaw_api.services.playback.ffmpeg_args import WorkerVideoCaps, build_hls_command
from movieclaw_db.engine import Database
from movieclaw_db.models import LibraryFile, MediaItem
from movieclaw_db.models.library_file import FileSource, FileState
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_playback.decide import AudioPlan, PlaybackPlan, PlaybackTier, VideoPlan

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "macos/MovieClawTranscoder/.build/debug/movieclaw-transcoder"
pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        sys.platform != "darwin"
        or not NATIVE.is_file()
        or not shutil.which("ffmpeg")
        or not shutil.which("ffprobe"),
        reason="需要 Mac、ffmpeg/ffprobe 及 swift build 编译的转码内核",
    ),
]


def wait_for(check, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("等待端到端状态超时")


@pytest.fixture
def remote_stack(tmp_path):
    yield from _remote_stack(tmp_path)


def _remote_stack(tmp_path, browser_directory=None):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    database_url = f"sqlite+aiosqlite:///{tmp_path / 'server.db'}"
    env = {
        **os.environ,
        "PYTHONPATH": str(ROOT / "src"),
        "DATABASE_URL": database_url,
        "SECRET_KEY_FILE": str(tmp_path / "secret"),
        "SCHEDULER_ENABLED": "false",
        "LOG_DIR": str(tmp_path / "logs"),
        "MOVIECLAW_DATA_DIR": str(tmp_path),
        "MOVIECLAW_TRANSCODE_DIR": str(tmp_path / "transcodes"),
    }
    processes = []
    logs = []

    def start_server():
        output = (tmp_path / f"server-{len(processes)}.log").open("w")
        logs.append(output)
        script = (
            # 宿主也是 Mac：只屏蔽 NAS 本机硬件入口，强制经过真实远程协议。
            "from movieclaw_api.services.playback import hwprobe; "
            "hwprobe.available_local_backends = lambda: (); "
            "from movieclaw_api.app import create_app; import uvicorn; app=create_app(); "
        )
        if browser_directory is not None:
            script += (
                "from starlette.routing import Mount; "
                "from starlette.staticfiles import StaticFiles; "
                "app.router.routes.insert(0, Mount('/__bench', "
                f"app=StaticFiles(directory={str(browser_directory)!r}, html=True))); "
            )
        script += f"uvicorn.run(app, host='127.0.0.1', port={port}, access_log=False)"
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                script,
            ],
            env=env,
            cwd=tmp_path,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        processes.append(process)

        def ready():
            assert process.poll() is None, (
                tmp_path / f"server-{len(processes) - 1}.log"
            ).read_text()
            try:
                return httpx.get(url + "/api/v1/auth/session", timeout=1).status_code != 503
            except httpx.TransportError:
                return False

        wait_for(ready, 30)
        return process

    server = start_server()
    try:
        with httpx.Client(base_url=url, timeout=30) as client:
            admin = {"username": "admin", "password": "E2e-only-password!"}
            assert client.post("/api/v1/auth/bootstrap", json=admin).status_code == 200
            assert client.post("/api/v1/auth/login", json=admin).status_code == 200
            assert (
                client.put("/api/v1/transcode-worker/config", json={"enabled": True}).status_code
                == 200
            )
            workers = []
            for i in range(2):
                grant = client.post(
                    "/api/v1/auth/device/authorize",
                    json={"client_type": "worker", "client_name": f"e2e-mac-{i}"},
                ).json()["data"]
                assert (
                    client.post(
                        f"/api/v1/auth/devices/requests/{grant['user_code']}/approve"
                    ).status_code
                    == 200
                )
                token = client.post(
                    "/api/v1/auth/device/token", json={"device_code": grant["device_code"]}
                ).json()["data"]["token"]
                output = (tmp_path / f"worker-{i}.log").open("w")
                logs.append(output)
                process = subprocess.Popen(
                    [str(NATIVE), "--core"],
                    stdin=subprocess.PIPE,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                processes.append(process)
                process.stdin.write(
                    json.dumps(
                        {
                            "configure": {
                                "_0": {
                                    "nasURL": url,
                                    "token": token,
                                    "workerID": f"e2e-mac-{i}",
                                    "ffmpegPath": shutil.which("ffmpeg"),
                                    "maxJobs": 1,
                                }
                            }
                        }
                    )
                    + "\n"
                )
                process.stdin.flush()
                workers.append(process)
            wait_for(
                lambda: (
                    len(client.get("/api/v1/transcode-worker/status").json()["data"]["workers"])
                    == 2
                )
            )
            yield client, workers, server, start_server, database_url, url
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if process.stdin:
                process.stdin.close()
        for output in logs:
            output.close()


async def seed(database_url, path, *, resolution="720p", duration=300):
    database = Database(database_url)
    try:
        async with database.session() as session:
            library = await LibraryRepository(session).create(
                name=f"远程转码端到端-{path.stem}", kind="movie", root_paths=[str(path.parent)]
            )
            item = MediaItem(
                kind="movie",
                tmdb_id=abs(hash(path.stem)) % 1000000,
                title="转码样本",
                original_title="Sample",
            )
            session.add(item)
            await session.flush()
            file = LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(path),
                size_bytes=path.stat().st_size,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                container="mkv",
                video_codec="hevc",
                bit_depth=8,
                resolution=resolution,
                duration_seconds=duration,
                audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
            )
            session.add(file)
            await session.commit()
            await session.refresh(file)
            return file.id
    finally:
        await database.dispose()


def test_native_workers_config_and_real_playback(remote_stack, tmp_path):
    client, workers, server, start_server, database_url, url = remote_stack
    status_url = "/api/v1/transcode-worker/status"
    status = client.get(status_url).json()["data"]
    first = next(w for w in status["workers"] if w["worker_id"] == "e2e-mac-0")
    endpoint = f"/api/v1/transcode-worker/devices/{first['device_id']}/config"

    def core_limit():
        for line in reversed((tmp_path / "worker-0.log").read_text().splitlines()):
            if line.startswith('{"status":'):
                return json.loads(line)["status"]["_0"]["maxJobs"]
        return None

    assert first["hardware"]["cpu_cores"] > 0
    assert first["hardware"]["memory_bytes"] > 0
    assert client.put(endpoint, json={"max_jobs": 3}).status_code == 200
    wait_for(lambda: core_limit() == 3)
    workers[0].stdin.write('{"setMaxJobs":{"_0":2}}\n')
    workers[0].stdin.flush()
    wait_for(
        lambda: (
            client.get(status_url).json()["data"]["device_limits"][f"ld-{first['device_id']}"] == 2
        )
    )
    wait_for(
        lambda: all(w["load"] is not None for w in client.get(status_url).json()["data"]["workers"])
    )

    source = tmp_path / "sample.mkv"
    generated = subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=blue:size=640x360:rate=24",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000",
            "-t",
            "300",
            "-c:v",
            "libx265",
            "-preset",
            "ultrafast",
            "-x265-params",
            "pools=2:log-level=error",
            "-c:a",
            "aac",
            "-ac",
            "2",
            "-y",
            str(source),
        ],
        capture_output=True,
        timeout=60,
    )
    assert generated.returncode == 0, generated.stderr.decode()[-1000:]
    file_ids = [asyncio.run(seed(database_url, source))]
    for index in (2, 3):
        another_source = tmp_path / f"sample-{index}.mkv"
        shutil.copyfile(source, another_source)
        file_ids.append(asyncio.run(seed(database_url, another_source)))
    sessions = []
    startup = []
    viewers = [
        client,
        httpx.Client(base_url=url, timeout=30),
        httpx.Client(base_url=url, timeout=30),
    ]
    try:
        for viewer in viewers[1:]:
            assert (
                viewer.post(
                    "/api/v1/auth/login",
                    json={"username": "admin", "password": "E2e-only-password!"},
                ).status_code
                == 200
            )
        for viewer, current_file_id in zip(viewers, file_ids, strict=True):
            started = time.monotonic()
            response = viewer.post(
                "/api/v1/playback/sessions",
                json={
                    "file_id": current_file_id,
                    "capability": {
                        "video": [{"codec": "h264"}],
                        "audio": [{"codec": "aac"}],
                        "containers": ["mp4", "hls-fmp4"],
                    },
                },
            )
            assert response.status_code == 200, response.text
            data = response.json()["data"]
            data["viewer"] = viewer
            assert data["decision"]["tier"] == 3
            sessions.append(data)
            startup.append((time.monotonic() - started) * 1000)
        owners = []
        for data in sessions:
            diagnostics_response = client.get(
                f"/api/v1/playback/sessions/{data['session_id']}/diagnostics?"
                + urlsplit(data["stream_url"]).query
            )
            assert diagnostics_response.status_code == 200, diagnostics_response.text
            diagnostics = diagnostics_response.json()["data"]
            owners.append(diagnostics["worker_id"])
        assert len(set(owners)) == 2, owners
        assert owners.count("e2e-mac-0") == 2, owners
        # 三位观众占满 2+1 个槽位；网页调低上限不能停止已接的两路任务。
        assert client.put(endpoint, json={"max_jobs": 1}).status_code == 200
        wait_for(lambda: core_limit() == 1)
        lowered = client.get(status_url).json()["data"]["workers"]
        assert next(w for w in lowered if w["worker_id"] == "e2e-mac-0")["active_jobs"] == 2
        for data in sessions:
            playlist = data["viewer"].get(data["stream_url"])
            assert playlist.status_code == 200 and "#EXTM3U" in playlist.text
            # 每位客户端都真实解码一秒音视频，确认降上限后两台 Worker 都持续供片。
            playback = subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-i",
                    url + data["stream_url"],
                    "-t",
                    "1",
                    "-f",
                    "null",
                    "-",
                ],
                capture_output=True,
                timeout=30,
            )
            assert playback.returncode == 0, playback.stderr.decode()[-2000:]
            assert (
                data["viewer"]
                .post(f"/api/v1/playback/sessions/{data['session_id']}/ping")
                .status_code
                == 200
            )
        assert client.put(endpoint, json={"max_jobs": 2}).status_code == 200
        wait_for(lambda: core_limit() == 2)
        print(f"real native VideoToolbox E2E session creation ms: {startup}")
    finally:
        for data in sessions:
            assert (
                data["viewer"].delete(f"/api/v1/playback/sessions/{data['session_id']}").status_code
                == 200
            )
        for viewer in viewers[1:]:
            viewer.close()
    wait_for(
        lambda: all(w["active_jobs"] == 0 for w in client.get(status_url).json()["data"]["workers"])
    )
    # 服务端重启后，内核自动重连并重新取得持久化设置。
    server.terminate()
    server.wait(timeout=10)
    start_server()
    wait_for(lambda: len(client.get(status_url).json()["data"]["workers"]) == 2)
    status = client.get(status_url).json()["data"]
    assert status["device_limits"][f"ld-{first['device_id']}"] == 2
    assert next(w for w in status["workers"] if w["worker_id"] == "e2e-mac-0")["max_jobs"] == 2


def test_real_videotoolbox_paths_compare(tmp_path):
    """真实 4K HEVC → 1080p H.264，重复三次；不把硬解能力当作性能排名。"""
    source = tmp_path / "uhd.mkv"
    generated = subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=3840x2160:rate=24",
            "-t",
            "8",
            "-c:v",
            "hevc_videotoolbox",
            "-b:v",
            "12M",
            "-pix_fmt",
            "yuv420p",
            "-y",
            str(source),
        ],
        capture_output=True,
        timeout=60,
    )
    assert generated.returncode == 0, generated.stderr.decode()[-1000:]
    p = PlaybackPlan(
        tier=PlaybackTier.HARDWARE_TRANSCODE,
        file_id=1,
        container="hls-fmp4",
        video=VideoPlan(
            action="transcode", codec="h264", source_codec="hevc", source_bit_depth=8, height=1080
        ),
        audio=AudioPlan(action="copy", track_ref=None),
    )
    modes = [
        ("software_decode", WorkerVideoCaps(hw_decoders=frozenset({"h264"}))),
        ("hardware_decode_cpu_filters", WorkerVideoCaps(hw_decoders=frozenset({"hevc"}))),
    ]
    help_output = subprocess.run(
        ["ffmpeg", "-hide_banner", "-h", "filter=scale_vt"],
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout
    if any(line.split() and line.split()[0] == "format" for line in help_output.splitlines()):
        modes.append(
            (
                "gpu_chain",
                WorkerVideoCaps(hw_decoders=frozenset({"hevc"}), filters=frozenset({"scale_vt"})),
            )
        )
    measured = {}
    for name, caps in modes:
        timings = []
        for i in range(3):
            output = tmp_path / f"{name}-{i}"
            output.mkdir()
            command = build_hls_command(
                p,
                source_path=str(source),
                session_dir=output,
                hw_backend="videotoolbox",
                worker_caps=caps,
                start_number=0,
            )
            started = time.perf_counter()
            encoded = subprocess.run(command.argv, capture_output=True, timeout=60)
            timings.append(time.perf_counter() - started)
            assert encoded.returncode == 0, encoded.stderr.decode()[-1500:]
            probe = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "stream=codec_name,height",
                    "-of",
                    "json",
                    str(command.playlist_path),
                ],
                capture_output=True,
                timeout=10,
            )
            assert probe.returncode == 0, probe.stderr.decode()
            assert any(
                s.get("codec_name") == "h264" and s.get("height") == 1080
                for s in json.loads(probe.stdout)["streams"]
            )
        measured[name] = {"seconds": timings, "median_seconds": statistics.median(timings)}
    print("4K real pipeline comparison: " + json.dumps(measured))


@pytest.mark.skipif(
    not shutil.which("npx") or not (ROOT / "apps/web/node_modules/hls.js").exists(),
    reason="需要 Node/npx 和 pnpm install 安装的网页依赖",
)
def test_browser_progressive_full_playback_resume_seek_and_xhr(tmp_path):
    """实际生产引擎 + 浏览器显示帧/音频波形，防止只快首帧却压缩时间轴。"""
    browser_directory = tmp_path / "browser"
    browser_directory.mkdir()
    shutil.copyfile(
        Path(__file__).parent / "assets/remote_playback.html", browser_directory / "index.html"
    )
    subprocess.run(
        [
            "npx", "--yes", "esbuild@0.28.2", "apps/web/lib/player/engine.ts",
            "--bundle", "--format=esm", "--platform=browser", "--define:process.env={}",
            f"--outfile={browser_directory / 'engine.js'}",
        ],
        cwd=ROOT, check=True, capture_output=True, timeout=60,
    )
    source = tmp_path / "uhd.mkv"
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "12",
            "-c:v", "hevc_videotoolbox", "-b:v", "12M", "-g", "48", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ac", "2", "-y", str(source),
        ],
        check=True, capture_output=True, timeout=60,
    )
    # 平坦低码率片段小于 FetchLoader 的 128KB 门槛，仍必须正确 flush 最后一个 moof。
    small = tmp_path / "flat.mkv"
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=1280x720:r=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "8",
            "-c:v", "hevc_videotoolbox", "-b:v", "300k", "-g", "48", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ac", "2", "-y", str(small),
        ],
        check=True, capture_output=True, timeout=30,
    )
    stack = _remote_stack(tmp_path, browser_directory)
    browser_session = f"movieclaw-e2e-{tmp_path.name}"

    def browser(*args):
        result = subprocess.run(
            ["npx", "--yes", "agent-browser@0.38.2", "--session", browser_session, *args],
            capture_output=True, text=True, timeout=50,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout

    try:
        _, _, _, _, database_url, url = next(stack)
        ids = []
        for index in range(4):
            path = tmp_path / f"uhd-{index}.mkv"
            os.link(source, path)
            ids.append(asyncio.run(seed(database_url, path, resolution="2160p", duration=12)))
        small_id = asyncio.run(seed(database_url, small, duration=8))
        cases = [
            ("head", ids[0], "", 288, 12),
            ("cached", ids[0], "", 288, 12),
            ("resume", ids[1], "&start=4", 192, 12),
            ("seek", ids[2], "&seek=8", None, 12),
            ("xhr", ids[3], "&xhr=1", 288, 12),
            ("small", small_id, "", 192, 8),
            ("small-cached", small_id, "", 192, 8),
        ]
        for name, file_id, query, frames, duration in cases:
            browser("open", f"{url}/__bench/?file={file_id}{query}")
            browser("click", "#run")
            measured = json.loads(browser(
                "--json", "eval",
                "(async()=>{while(!window.result)await new Promise(r=>setTimeout(r,100));"
                "return window.result})()",
            ))["data"]["result"]
            (tmp_path / f"browser-{name}.json").write_text(json.dumps(measured))
            assert not measured.get("error") and not measured["errors"], measured
            assert measured["tier"] == 3
            assert measured["ended"] and abs(measured["duration"] - duration) < 0.05, measured
            assert measured["audio_peak"] > 0.01, "必须真实解码出音频波形"
            assert not measured["frame_gaps"], measured["frame_gaps"]
            assert measured["stats"]["droppedFrames"] == 0
            if frames is not None:
                assert measured["stats"]["totalFrames"] == frames, measured["stats"]
                assert measured["waiting"] == 0
            assert measured["stats"]["bitrate"] > 0
            diagnostics = measured["diagnostics"]
            assert diagnostics["cache_hit"] == (name in {"cached", "small-cached"})
            assert measured["progressive_segments"] == (not diagnostics["cache_hit"])
            if name in {"head", "resume", "seek"}:
                assert any(e.get("partial") for e in diagnostics["timeline"] if e["ev"] == "served")
            if name == "head":
                first_landed = next(
                    e["t"] for e in diagnostics["timeline"]
                    if e["ev"] == "landed" and e.get("name") == "seg00000.m4s"
                )
                assert measured["first_frame_ms"] < first_landed, "首帧必须早于整段转完"
            if name == "resume":
                assert abs(measured["first_media_time"] - 4) < 0.05
            if name == "seek":
                assert abs(measured["seek_media_time"] - 8) < 0.1
                assert any(e["ev"] == "restart" for e in diagnostics["timeline"])
            if name in {"cached", "xhr", "small-cached"}:
                assert all(r["partial"] is None for r in measured["media_requests"])
            if name == "small":
                assert max(u["received_bytes"] for u in diagnostics["recent_uploads"]) < 128 * 1024
            print(f"browser {name}: first={measured['first_frame_ms']:.1f}ms "
                  f"seek={measured.get('seek_ms')} frames={measured['stats']['totalFrames']}")
    finally:
        browser("close")
        stack.close()

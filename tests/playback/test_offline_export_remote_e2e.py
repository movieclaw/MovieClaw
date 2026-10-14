"""离线下载的转码导出走真实 Mac 转码内核（offline-download.md §5.3）。

真实 HTTP/WS → 两个转码内核（VideoToolbox）→ 分片回传 → NAS 按序接成一个 MP4 → 客户端下载解码。
覆盖：整片导出（HEVC、时长与帧数准确）、播放来了导出让路再接着转、转码器中途掉线换一台接着转。
拼接处的正确性用「完整解码、帧数一帧不差」验证——接缝处少一帧、多一帧或时间戳倒退都会暴露。

前置同 test_remote_transcode_e2e：Mac、ffmpeg/ffprobe、``swift build`` 编出的转码内核。
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import threading
import time
from pathlib import Path

import httpx
import pytest
from test_remote_transcode_e2e import _remote_stack, pytestmark, wait_for  # noqa: F401

from movieclaw_db.engine import Database
from movieclaw_db.models import LibraryFile, MediaItem
from movieclaw_db.models.library_file import FileSource, FileState
from movieclaw_db.repositories.library_repo import LibraryRepository

_FPS = 24


@pytest.fixture
def remote_stack(tmp_path):
    yield from _remote_stack(tmp_path)


def _make_source(path: Path, seconds: int) -> None:
    generated = subprocess.run(
        [
            "ffmpeg", "-v", "error",
            "-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate={_FPS}",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", str(seconds),
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "48",
            "-c:a", "aac", "-ac", "2",
            "-y", str(path),
        ],
        capture_output=True,
        timeout=300,
    )
    assert generated.returncode == 0, generated.stderr.decode()[-1000:]


async def _seed(
    database_url: str,
    path: Path,
    seconds: int,
    *,
    codec: str = "h264",
    bit_depth: int = 8,
    hdr: str | None = None,
    resolution: str = "720p",
) -> int:
    database = Database(database_url)
    try:
        async with database.session() as session:
            library = await LibraryRepository(session).create(
                name=f"离线导出端到端-{path.stem}", kind="movie", root_paths=[str(path.parent)]
            )
            item = MediaItem(
                kind="movie",
                tmdb_id=abs(hash(path.stem)) % 1000000,
                title=f"导出样本 {path.stem}",
                original_title="Sample",
            )
            session.add(item)
            await session.flush()
            file = LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(path),
                size_bytes=4_000_000_000,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                container="mp4",
                video_codec=codec,
                bit_depth=bit_depth,
                hdr=hdr,
                resolution=resolution,
                duration_seconds=seconds,
                audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
            )
            session.add(file)
            await session.commit()
            await session.refresh(file)
            return int(file.id)
    finally:
        await database.dispose()


def _meta(tmp_path: Path, export_id: str) -> dict:
    path = tmp_path / "data/cache/offline-exports" / export_id / "meta.json"
    return json.loads(path.read_text()) if path.is_file() else {}


def _wait_done(client: httpx.Client, export_id: str, timeout: float = 600) -> dict:
    def done():
        data = client.get(f"/api/v1/offline/exports/{export_id}").json()["data"]
        assert data["status"] != "failed", data
        return data if data["status"] == "done" else None

    return wait_for(done, timeout)


def _check_file(path: Path, seconds: int, height: int) -> dict:
    probe = json.loads(
        subprocess.run(
            [
                "ffprobe", "-v", "error", "-show_entries",
                "stream=codec_type,codec_name,codec_tag_string,height:format=duration",
                "-of", "json", str(path),
            ],
            capture_output=True, check=True, timeout=60,
        ).stdout
    )
    video = next(s for s in probe["streams"] if s["codec_type"] == "video")
    audio = next(s for s in probe["streams"] if s["codec_type"] == "audio")
    assert video["height"] == height and audio["codec_name"] == "aac"
    assert abs(float(probe["format"]["duration"]) - seconds) < 0.2, probe["format"]
    # 完整解码：接缝处坏了会报错；帧数一帧不差说明没有丢段、重段
    decoded = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v",
            "-f", "framemd5", "-",
        ],
        capture_output=True, timeout=300,
    )
    assert decoded.returncode == 0 and not decoded.stderr.strip(), decoded.stderr.decode()[-2000:]
    frames = [line for line in decoded.stdout.decode().splitlines() if not line.startswith("#")]
    assert len(frames) == seconds * _FPS, len(frames)
    pts = [int(line.split(",")[2]) for line in frames]
    assert pts == sorted(pts) and len(set(pts)) == len(pts)
    return video


def _download(client: httpx.Client, export: dict, dest: Path) -> None:
    with client.stream("GET", export["content_url"]) as resp:
        assert resp.status_code == 200, resp.read()
        with dest.open("wb") as out:
            for chunk in resp.iter_bytes():
                out.write(chunk)


def test_export_on_real_transcoder_is_hevc_and_frame_exact(remote_stack, tmp_path):
    client, _workers, _server, _start, database_url, _url = remote_stack
    seconds = 120
    source = tmp_path / "movie.mp4"
    _make_source(source, seconds)
    file_id = asyncio.run(_seed(database_url, source, seconds))

    manifest = client.get("/api/v1/offline/manifest", params={"file_id": file_id})
    assert manifest.status_code == 200, manifest.text
    profiles = {p["profile"]: p for p in manifest.json()["data"]["profiles"]}
    assert "480p" in profiles  # NAS 端屏蔽了本机硬件：档位来自在线的转码器

    started = time.monotonic()
    created = client.post("/api/v1/offline/exports", json={"file_id": file_id, "profile": "480p"})
    assert created.status_code == 200, created.text
    export = created.json()["data"]
    # 边转边下：转码进行中就开始取；同时看活动页那一行是不是转码信息（不是导出号哈希）
    out = tmp_path / "download.mp4"
    downloading = threading.Thread(target=_download, args=(client, export, out))
    downloading.start()
    lines: set[str] = set()
    while downloading.is_alive():
        rows = client.get("/api/v1/playback/activity").json()["data"]["downloads"]
        lines.update(row["file_name"] for row in rows)
        time.sleep(0.3)
    downloading.join()
    done = _wait_done(client, export["export_id"])
    print(f"activity lines: {sorted(lines)}")
    assert any(
        line.startswith("转码 480p HEVC · e2e-mac-") and "已转" in line for line in lines
    ), lines
    assert not any(export["export_id"] in line for line in lines)
    elapsed = time.monotonic() - started
    assert out.stat().st_size == done["final_bytes"]
    video = _check_file(out, seconds, 480)
    assert video["codec_name"] == "hevc" and video["codec_tag_string"] == "hvc1"
    print(f"offline export via native worker: {seconds}s source in {elapsed:.1f}s")


def test_playback_evicts_export_and_lost_worker_resumes_elsewhere(remote_stack, tmp_path):
    """两台转码器各 1 路：导出占一台；两位观众开播，第二位挤掉导出；观众走后导出接着转。
    再杀掉导出所在的转码器，换另一台接着转。最终文件帧数一帧不差。"""
    client, workers, _server, _start, database_url, url = remote_stack
    seconds = 360
    source = tmp_path / "long.mp4"
    _make_source(source, seconds)
    export_file = asyncio.run(_seed(database_url, source, seconds))
    viewer_files = []
    for index in (1, 2):
        copy = tmp_path / f"viewer-{index}.mp4"
        copy.write_bytes(source.read_bytes())
        viewer_files.append(asyncio.run(_seed(database_url, copy, seconds)))

    export = client.post(
        "/api/v1/offline/exports", json={"file_id": export_file, "profile": "480p"}
    ).json()["data"]
    export_id = export["export_id"]
    wait_for(lambda: _meta(tmp_path, export_id).get("done_segments", 0) >= 10, 120)

    viewers = [httpx.Client(base_url=url, timeout=60) for _ in viewer_files]
    sessions = []
    try:
        for viewer, file_id in zip(viewers, viewer_files, strict=True):
            assert viewer.post(
                "/api/v1/auth/login",
                json={"username": "admin", "password": "E2e-only-password!"},
            ).status_code == 200
            response = viewer.post(
                "/api/v1/playback/sessions",
                json={
                    "file_id": file_id,
                    "max_height": 360,
                    "capability": {
                        "video": [{"codec": "h264"}],
                        "audio": [{"codec": "aac"}],
                        "containers": ["mp4", "hls-fmp4"],
                    },
                },
            )
            assert response.status_code == 200, response.text
            data = response.json()["data"]
            assert data["decision"]["tier"] == 3, data["decision"]  # 硬件档，不是被挤去软转
            sessions.append((viewer, data))
        for _viewer, data in sessions:
            played = subprocess.run(
                ["ffmpeg", "-v", "error", "-i", url + data["stream_url"], "-t", "2",
                 "-f", "null", "-"],
                capture_output=True, timeout=60,
            )
            assert played.returncode == 0, played.stderr.decode()[-2000:]
        status = client.get("/api/v1/transcode-worker/status").json()["data"]
        assert sum(w["active_jobs"] for w in status["workers"]) == 2  # 两路都是观众的
        assert client.get(f"/api/v1/offline/exports/{export_id}").json()["data"]["status"] in {
            "running",
        }
    finally:
        for viewer, data in sessions:
            viewer.delete(f"/api/v1/playback/sessions/{data['session_id']}")
        for viewer in viewers:
            viewer.close()

    # 观众走了：导出接着转。再杀掉它所在的那台，换另一台接着转
    progressed = _meta(tmp_path, export_id).get("done_segments", 0)
    wait_for(lambda: _meta(tmp_path, export_id).get("done_segments", 0) >= progressed + 10, 120)

    def export_worker():
        for worker in client.get("/api/v1/transcode-worker/status").json()["data"]["workers"]:
            if worker["active_jobs"]:
                return worker["worker_id"]
        return None

    victim = wait_for(export_worker, 30)
    workers[int(victim.rsplit("-", 1)[1])].kill()
    done = _wait_done(client, export_id)
    out = tmp_path / "resumed.mp4"
    _download(client, export, out)
    assert out.stat().st_size == done["final_bytes"]
    _check_file(out, seconds, 480)


@pytest.mark.skipif(
    not os.environ.get("MC_OFFLINE_EXPORT_SAMPLE"),
    reason="真片测速：MC_OFFLINE_EXPORT_SAMPLE=<4K HDR10 HEVC 片段路径>",
)
def test_real_hdr_sample_speed(remote_stack, tmp_path):
    """真片测速（手动跑）：4K HDR10 → 1080p HEVC（色调映射在 Mac 的 GPU 上），边转边下。"""
    client, _workers, _server, _start, database_url, _url = remote_stack
    sample = Path(os.environ["MC_OFFLINE_EXPORT_SAMPLE"])
    seconds = int(
        float(
            subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                 str(sample)],
                capture_output=True, text=True, check=True,
            ).stdout
        )
    )
    file_id = asyncio.run(
        _seed(database_url, sample, seconds, codec="hevc", bit_depth=10, hdr="HDR10",
              resolution="2160p")
    )
    for profile, height in (("1080p", 1080), ("720p", 720)):
        started = time.monotonic()
        export = client.post(
            "/api/v1/offline/exports", json={"file_id": file_id, "profile": profile}
        ).json()["data"]
        out = tmp_path / f"{profile}.mp4"
        _download(client, export, out)
        done = _wait_done(client, export["export_id"])
        elapsed = time.monotonic() - started
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries",
             "stream=codec_name,height,color_transfer", "-of", "csv=p=0", str(out)],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        mbps = done["final_bytes"] * 8 / seconds / 1e6
        print(
            f"real sample {profile}: {seconds}s in {elapsed:.1f}s "
            f"({seconds / elapsed:.1f}x), {mbps:.2f} Mbps, {probe}"
        )
        assert str(height) in probe and "hevc" in probe

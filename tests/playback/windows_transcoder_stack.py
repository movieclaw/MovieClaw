"""Windows 转码器端到端测试的公共搭台：隔离的 NAS + 配对好的真 Worker + 样片与会话的小工具。

不是测试文件（不以 ``test_`` 开头）：``test_windows_transcoder_e2e.py`` 与
``test_windows_transcoder_matrix.py`` 各自起一套。需要 NVIDIA 显卡与 jellyfin-ffmpeg
（``MOVIECLAW_TEST_FFMPEG`` 指到 ffmpeg 可执行文件，或在 PATH 里）。
"""

from __future__ import annotations

import asyncio
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import httpx
import pytest

ROOT = Path(__file__).resolve().parents[2]
WORKER_DIR = ROOT / "windows" / "MovieClawTranscoder"
sys.path.insert(0, str(WORKER_DIR))

from movieclaw_transcoder.probe import Capabilities, FfmpegProblem, probe  # noqa: E402

ADMIN = {"username": "admin", "password": "E2e-only-password!"}
WORKER_NAME = "e2e-win"

#: 客户端只会 H.264 / AAC：HEVC、VP9 等源会被逼出转码
CAPABILITY = {
    "video": [{"codec": "h264"}],
    "audio": [{"codec": "aac"}],
    "containers": ["mp4", "hls-fmp4"],
}


def require_nvenc_worker() -> tuple[str, Capabilities]:
    """找到 ffmpeg 并确认这台机器能登记为 NVENC 转码器；否则跳过调用它的用例。"""
    ffmpeg = os.environ.get("MOVIECLAW_TEST_FFMPEG") or shutil.which("ffmpeg")
    if ffmpeg is None:
        pytest.skip("需要 jellyfin-ffmpeg（MOVIECLAW_TEST_FFMPEG 或 PATH）")
    try:
        return ffmpeg, probe(ffmpeg)
    except FfmpegProblem as problem:
        pytest.skip(f"这台机器不能登记为 NVENC 转码器：{problem}")


def wait_for(check, timeout: float = 30.0, what: str | Callable[[], str] = "端到端状态"):
    """轮询到 ``check()`` 为真并返回它；超时抛断言错误（``what`` 可以是现取现说的函数）。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(f"等待超时：{what() if callable(what) else what}")


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Capture:
    """把子进程输出逐行收进列表，测试里按内容等。"""

    def __init__(self, process: subprocess.Popen) -> None:
        self.lines: list[str] = []
        threading.Thread(target=self._pump, args=(process,), daemon=True).start()

    def _pump(self, process: subprocess.Popen) -> None:
        assert process.stdout is not None
        for raw in process.stdout:
            self.lines.append(raw.rstrip())

    def text(self) -> str:
        return "\n".join(self.lines)


@contextmanager
def running_stack(
    tmp: Path, ffmpeg: str, *, bench_dir: Path | None = None
) -> Iterator[dict[str, Any]]:
    """起隔离的 NAS（临时数据库、本机硬件入口屏蔽、强制走远程协议），再起一个真的
    ``python -m movieclaw_transcoder`` 并走完设备授权配对。

    ``bench_dir``：顺手把这个目录挂在 NAS 的 ``/__bench``（浏览器里的播放器页要与接口同源）。"""
    port = _free_port()
    url = f"http://127.0.0.1:{port}"
    env = {
        **os.environ,
        "PYTHONPATH": os.pathsep.join([str(ROOT / "src"), str(WORKER_DIR)]),
        "PYTHONUTF8": "1",
        "DATABASE_URL": f"sqlite+aiosqlite:///{tmp / 'server.db'}",
        "SECRET_KEY_FILE": str(tmp / "secret"),
        "SCHEDULER_ENABLED": "false",
        "LOG_DIR": str(tmp / "logs"),
        "MOVIECLAW_DATA_DIR": str(tmp),
        "MOVIECLAW_TRANSCODE_DIR": str(tmp / "transcodes"),
        # 服务端要 ffprobe 读样片的真实规格（与生产镜像里同一个来源）
        "PATH": str(Path(ffmpeg).parent) + os.pathsep + os.environ.get("PATH", ""),
        "TEMP": str(tmp),
        "TMP": str(tmp),
    }
    # 本机也有显卡：只屏蔽 NAS 本机硬件入口，强制经过真实的远程协议
    script = (
        "from movieclaw_api.services.playback import hwprobe; "
        "hwprobe.available_local_backends = lambda: (); "
        "from movieclaw_api.app import create_app; import uvicorn; app = create_app(); "
    )
    if bench_dir is not None:
        script += (
            "from starlette.routing import Mount; "
            "from starlette.staticfiles import StaticFiles; "
            "app.router.routes.insert(0, Mount('/__bench', "
            f"app=StaticFiles(directory={str(bench_dir)!r}, html=True))); "
        )
    script += f"uvicorn.run(app, host='127.0.0.1', port={port}, access_log=False)"
    server_log = (tmp / "server.log").open("w")
    server = subprocess.Popen(
        [sys.executable, "-c", script],
        env=env,
        cwd=tmp,
        stdout=server_log,
        stderr=subprocess.STDOUT,
    )
    workers: list[subprocess.Popen] = []
    try:

        def ready():
            assert server.poll() is None, (tmp / "server.log").read_text(errors="replace")
            try:
                return httpx.get(url + "/api/v1/auth/session", timeout=1).status_code != 503
            except httpx.TransportError:
                return False

        wait_for(ready, 60, "服务端起来")
        client = httpx.Client(base_url=url, timeout=60)
        assert client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        assert client.post("/api/v1/auth/login", json=ADMIN).status_code == 200
        assert (
            client.put("/api/v1/transcode-worker/config", json={"enabled": True}).status_code == 200
        )

        worker_env = {
            **env,
            "MOVIECLAW_TRANSCODER_HOME": str(tmp / "worker-home"),
        }

        def launch(*arguments: str) -> tuple[subprocess.Popen, Capture]:
            """起一个 ``python -m movieclaw_transcoder``；参数之外的配置读本机配置文件。"""
            process = subprocess.Popen(
                [sys.executable, "-m", "movieclaw_transcoder", *arguments],
                env=worker_env,
                cwd=WORKER_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
            )
            workers.append(process)
            return process, Capture(process)

        def approve(output: Capture) -> None:
            """走真实的设备授权：Worker 打印配对码，管理员在「网页」上批准。"""
            code = wait_for(
                lambda: next(
                    (
                        ln.split("：", 1)[1].split("（")[0]
                        for ln in output.lines
                        if "配对码：" in ln
                    ),
                    None,
                ),
                120,
                lambda: f"Worker 打印配对码；输出：{output.text()[-800:]}",
            )
            assert client.post(f"/api/v1/auth/devices/requests/{code}/approve").status_code == 200

        worker, output = launch("--server", url, "--ffmpeg", ffmpeg, "--name", WORKER_NAME)
        approve(output)
        wait_for(
            lambda: client.get("/api/v1/transcode-worker/status").json()["data"]["workers"],
            60,
            "Worker 上线",
        )
        yield {
            "client": client,
            "url": url,
            "tmp": tmp,
            "output": output,
            "worker": worker,
            "launch": launch,
            "approve": approve,
            "ffmpeg": ffmpeg,
            "ffprobe": str(Path(ffmpeg).with_name("ffprobe" + Path(ffmpeg).suffix)),
        }
    finally:
        for process in (*workers, server):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
        server_log.close()


# -- 样片 -------------------------------------------------------------------


def make_source(
    stack: dict[str, Any],
    name: str,
    *,
    codec: str = "hevc_nvenc",
    size: str = "1920x1080",
    rate: int = 24,
    seconds: int = 20,
    pix_fmt: str = "yuv420p",
    vf: str | None = None,
    video_extra: tuple[str, ...] = (),
    audio: tuple[str, ...] = ("-c:a", "aac", "-ac", "2"),
    audio_source: str = "sine=frequency=440:sample_rate=48000",
    extra_inputs: tuple[str, ...] = (),
    extra_output: tuple[str, ...] = (),
) -> Path:
    """用 ffmpeg 现做一段样片（画面是带噪点的 testsrc2：不会因为画面太简单把编码速度测高）。"""
    path = stack["tmp"] / name
    filters = "noise=alls=8:allf=t"
    if vf:
        filters += "," + vf
    command = [
        stack["ffmpeg"], "-v", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc2=size={size}:rate={rate}",
        "-f", "lavfi", "-i", audio_source,
        *extra_inputs,
        "-t", str(seconds),
        "-vf", filters, "-c:v", codec, "-pix_fmt", pix_fmt, *video_extra,
        *audio, *extra_output, str(path),
    ]  # fmt: skip
    done = subprocess.run(command, capture_output=True, timeout=600)
    assert done.returncode == 0, done.stderr.decode(errors="replace")[-1500:]
    return path


async def _seed(database_url: str, path: Path) -> int:
    from movieclaw_api.services.media_probe import probe_media
    from movieclaw_db.engine import Database
    from movieclaw_db.models import LibraryFile, MediaItem
    from movieclaw_db.models.library_file import FileSource, FileState
    from movieclaw_db.repositories.library_repo import LibraryRepository

    spec = probe_media(path)
    assert spec is not None, "ffprobe 读不了样片"
    database = Database(database_url)
    try:
        async with database.session() as session:
            library = await LibraryRepository(session).create(
                name=f"远程转码端到端-{path.stem}",
                kind="movie",
                root_paths=[str(path.parent)],
            )
            item = MediaItem(
                kind="movie",
                tmdb_id=abs(hash(path.stem)) % 1_000_000,
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
                container=path.suffix.lstrip("."),
                video_codec=spec.video_codec,
                bit_depth=spec.bit_depth,
                resolution=spec.resolution,
                hdr=spec.hdr,
                color_space=spec.color_space,
                duration_seconds=spec.duration_seconds,
                bit_rate=spec.bit_rate,
                frame_rate=spec.frame_rate,
                audio_streams=spec.audio_streams,
                subtitle_streams=spec.subtitle_streams,
            )
            session.add(file)
            await session.commit()
            await session.refresh(file)
            return file.id
    finally:
        await database.dispose()


def seed(stack: dict[str, Any], path: Path) -> int:
    return asyncio.run(_seed(f"sqlite+aiosqlite:///{stack['tmp'] / 'server.db'}", path))


# -- 会话 -------------------------------------------------------------------


def start_session(stack: dict[str, Any], file_id: int, **payload: Any) -> dict[str, Any]:
    response = stack["client"].post(
        "/api/v1/playback/sessions",
        json={"file_id": file_id, "capability": CAPABILITY, **payload},
    )
    assert response.status_code == 200, response.text
    return response.json()["data"]


def end_session(stack: dict[str, Any], data: dict[str, Any]) -> None:
    stack["client"].delete(f"/api/v1/playback/sessions/{data['session_id']}")


def decode(
    stack: dict[str, Any], data: dict[str, Any], *, seconds: float = 2, seek: float | None = None
) -> subprocess.CompletedProcess:
    """像播放器一样从播放列表开始真解码若干秒（可先 seek）。"""
    command = [stack["ffmpeg"], "-v", "error"]
    if seek is not None:
        command += ["-ss", str(seek)]
    command += ["-i", stack["url"] + data["stream_url"], "-t", str(seconds), "-f", "null", "-"]
    return subprocess.run(command, capture_output=True, timeout=300)


def diagnostics(stack: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    query = urlsplit(data["stream_url"]).query
    response = stack["client"].get(
        f"/api/v1/playback/sessions/{data['session_id']}/diagnostics?{query}"
    )
    assert response.status_code == 200, response.text
    return response.json()["data"]


def worker_status(stack: dict[str, Any]) -> dict[str, Any]:
    workers = stack["client"].get("/api/v1/transcode-worker/status").json()["data"]["workers"]
    return next(w for w in workers if w["worker_id"] == WORKER_NAME)

"""离线下载的转码导出（docs/design/offline-download.md §5.3）。

App 选了 1080p / 720p / 480p 下载时，服务器把整片转成一个分片化 MP4，手机**边转边下**：
下载请求一到就从文件开头发起，跟着 ffmpeg 的输出往后发，转完发完才正常结束。这样「睡前
点下一整季、锁屏放着」也能下完——先转完再下的话，转完时 App 多半在后台，发不起下载。

形态与片段预切同一路数：进程内单路队列干活，状态落在每个导出自己的目录里
（``<根>/<导出号>/meta.json``），服务重启后没转完的重新排队、换一个代号从头转。

- **导出号** = 文件身份（id、大小、修改时间）+ 档位 + 音轨 + 导出格式版本的指纹：
  全家下同一集同一档只转一次；片源换了（洗版）指纹跟着变。
- **代号**：每转一次加一。ETag 用「导出号 + 代号」，下载中途服务端重转（重启、缓存被清）
  时客户端带旧 ETag 续传，If-Range 对不上，整份重下，不会把两次转码的字节拼在一起。
- **并发**：全局一次一路；只在实时转码还有空位时开始，开始后不占实时名额、降优先级跑。
- **回收**：客户端下完调 DELETE；没人取的，最后一次访问 72 小时后回收。
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import shutil
import time
from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from starlette.responses import Response
from starlette.types import Receive, Scope, Send

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.playback import plan as playback_plan
from movieclaw_api.services.playback.ffmpeg_args import BITRATE_LADDER, build_hls_command
from movieclaw_api.services.playback.hwprobe import available_local_backends, hardware_available
from movieclaw_api.services.playback.limits import auto_transcode_concurrency
from movieclaw_api.services.playback.track_context import track_contexts
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile
from movieclaw_playback.decide import PlaybackPlan, plan_capped_transcode
from movieclaw_playback.profile import media_profile_from_file
from movieclaw_playback.streaming import StrmError, is_strm, parse_strm, strm_source_input

logger = logging.getLogger(__name__)

#: 档位 → 目标高度（码率按实时转码的阶梯，ffmpeg_args.BITRATE_LADDER）
PROFILES: dict[str, int] = {"1080p": 1080, "720p": 720, "480p": 480}
#: 导出参数一变（容器、片段时长、音频档位），已转的产物就不能再当同一份用
EXPORT_FORMAT_VERSION = 1
#: 转码档的音轨：手机上一条立体声 AAC 足够，多声道只是白占空间
AUDIO_BPS = 256_000
RETENTION_S = 72 * 3600
#: 没有空闲实时名额时多久再看一次
_CAPACITY_POLL_S = 5.0
#: 边转边下：读到文件尾、转码还在跑时多久再看一次
_TAIL_POLL_S = 0.25
_CHUNK = 1024 * 1024
_STDERR_KEEP = 40

STATUS_QUEUED = "queued"
STATUS_RUNNING = "running"
STATUS_DONE = "done"
STATUS_FAILED = "failed"


class ExportStreamAborted(RuntimeError):
    """边转边发中途作废（转码失败 / 重转换了代号）：抛出去让服务器掐断连接、不发结束块。"""


class ExportUnavailable(Exception):
    """这个文件出不了这一档（原盘、HDR 没有硬件、软件转码没开……），文案面向用户。"""


@dataclass
class ExportState:
    export_id: str
    file_id: int
    profile: str
    audio_track: str | None
    status: str
    generation: int
    expected_bytes: int
    final_bytes: int | None = None
    error: str | None = None
    created_at: float = 0.0
    last_access_at: float = 0.0

    @property
    def etag(self) -> str:
        return f'"exp-{self.export_id}-{self.generation}"'


def exports_root() -> Path:
    return Path(get_settings().offline_exports_dir)


def video_bps(profile: str) -> int:
    ladder = BITRATE_LADDER[PROFILES[profile]]
    return int(float(ladder[:-1]) * 1_000_000)


def estimate_bytes(profile: str, duration_s: float | None) -> int:
    """预计大小：视频码率上限 + 音轨码率，乘片长；容器开销约 2%。"""
    if not duration_s or duration_s <= 0:
        return 0
    return int((video_bps(profile) + AUDIO_BPS) * duration_s / 8 * 1.02)


def export_fingerprint(file: LibraryFile, profile: str, audio_track: str | None) -> str:
    mtime = None
    with contextlib.suppress(OSError):
        mtime = int(os.stat(file.file_path).st_mtime)
    raw = json.dumps(
        [file.id, file.size_bytes, mtime, profile, audio_track or "", EXPORT_FORMAT_VERSION]
    )
    return hashlib.sha256(raw.encode()).hexdigest()[:24]


async def build_plan(file: LibraryFile, profile: str, audio_track: str | None) -> PlaybackPlan:
    """这一档的转码计划：与 Jellyfin 协议「播放器要求限码率」同一个规划函数。"""
    if profile not in PROFILES:
        raise ExportUnavailable(f"不支持的档位：{profile}")
    if file.is_disc():
        raise ExportUnavailable("原盘暂不支持下载到设备")
    async with get_database().session() as session:
        contexts = await track_contexts(session, [file])
    media = media_profile_from_file(
        file, context=contexts.get(file.id or 0), preferred_audio=audio_track
    )
    policy = await playback_plan.load_policy()
    plan = plan_capped_transcode(
        media,
        policy,
        preferred_audio=audio_track,
        max_height=PROFILES[profile],
        segment_container="mp4",
        audio_codecs=frozenset({"aac"}),
        max_audio_channels=2,
    )
    if not isinstance(plan, PlaybackPlan):
        raise ExportUnavailable(plan.reason)
    return plan


class ExportManager:
    def __init__(self, root: Path | None = None) -> None:
        self._root = root
        self._states: dict[str, ExportState] = {}
        self._loaded = False
        self._queue: deque[str] = deque()
        self._wake = asyncio.Event()
        self._worker: asyncio.Task | None = None
        self._process: asyncio.subprocess.Process | None = None
        self._running_id: str | None = None
        #: 正在被下载的导出（导出号 → 连接数）：回收时跳过
        self._readers: dict[str, int] = {}

    @property
    def root(self) -> Path:
        return self._root or exports_root()

    def _dir(self, export_id: str) -> Path:
        return self.root / export_id

    def output_path(self, state: ExportState) -> Path:
        return self._dir(state.export_id) / f"{state.generation}.mp4"

    # ---- 状态落盘 ----

    def _save(self, state: ExportState) -> None:
        folder = self._dir(state.export_id)
        folder.mkdir(parents=True, exist_ok=True)
        tmp = folder / "meta.json.tmp"
        tmp.write_text(json.dumps(asdict(state)), encoding="utf-8")
        tmp.replace(folder / "meta.json")

    def _load(self) -> None:
        """第一次用到时读回全部导出；没转完的（服务重启打断的）重新排队。"""
        if self._loaded:
            return
        self._loaded = True
        if not self.root.is_dir():
            return
        for folder in self.root.iterdir():
            meta = folder / "meta.json"
            try:
                state = ExportState(**json.loads(meta.read_text(encoding="utf-8")))
            except (OSError, ValueError, TypeError):
                shutil.rmtree(folder, ignore_errors=True)
                continue
            if state.status in (STATUS_QUEUED, STATUS_RUNNING):
                state.status = STATUS_QUEUED
                self._save(state)
                self._queue.append(state.export_id)
            self._states[state.export_id] = state
        if self._queue:
            self._ensure_worker()

    # ---- 对外 ----

    def get(self, export_id: str) -> ExportState | None:
        self._load()
        return self._states.get(export_id)

    async def ensure(
        self, file: LibraryFile, profile: str, audio_track: str | None, *, duration_s: float | None
    ) -> ExportState:
        """建或复用一个导出（幂等）。失败过的再要一次就重转。"""
        self._load()
        await build_plan(file, profile, audio_track)  # 出不了这一档当场告诉客户端
        export_id = export_fingerprint(file, profile, audio_track)
        now = time.time()
        state = self._states.get(export_id)
        if state is not None and state.status == STATUS_DONE and not self.output_path(state).exists():
            state = None  # 产物被清掉了（缓存管理清空）：当作没有
        if state is None or state.status == STATUS_FAILED:
            state = ExportState(
                export_id=export_id,
                file_id=int(file.id or 0),
                profile=profile,
                audio_track=audio_track,
                status=STATUS_QUEUED,
                generation=(state.generation if state else 0),
                expected_bytes=estimate_bytes(profile, duration_s),
                created_at=now,
            )
            self._states[export_id] = state
            self._queue.append(export_id)
        state.last_access_at = now
        self._save(state)
        self._ensure_worker()
        self._wake.set()
        self.collect_garbage()
        return state

    def touch(self, state: ExportState) -> None:
        state.last_access_at = time.time()
        self._save(state)

    def release(self, export_id: str) -> None:
        """客户端下完了：没人在下、也不在转就当场删。"""
        state = self.get(export_id)
        if state is None or state.status in (STATUS_QUEUED, STATUS_RUNNING):
            return
        if self._readers.get(export_id):
            # 别的设备还在下：留给过期回收
            return
        self._drop(export_id)

    def queue_position(self, export_id: str) -> int | None:
        try:
            return list(self._queue).index(export_id)
        except ValueError:
            return None

    def collect_garbage(self) -> None:
        cutoff = time.time() - RETENTION_S
        for export_id, state in list(self._states.items()):
            if state.status in (STATUS_QUEUED, STATUS_RUNNING) or self._readers.get(export_id):
                continue
            if state.last_access_at < cutoff:
                self._drop(export_id)

    def _drop(self, export_id: str) -> None:
        self._states.pop(export_id, None)
        shutil.rmtree(self._dir(export_id), ignore_errors=True)

    def reader_enter(self, export_id: str) -> None:
        self._readers[export_id] = self._readers.get(export_id, 0) + 1

    def reader_leave(self, export_id: str) -> None:
        left = self._readers.get(export_id, 0) - 1
        if left > 0:
            self._readers[export_id] = left
        else:
            self._readers.pop(export_id, None)

    # ---- 转码 ----

    def _ensure_worker(self) -> None:
        if self._worker is None or self._worker.done():
            self._worker = asyncio.create_task(self._run(), name="offline-exports")

    async def _wait_capacity(self) -> None:
        """实时转码满了就等：宁可导出慢，不让播放被拒。"""
        from movieclaw_api.services.playback.session import get_session_manager

        while True:
            limit = auto_transcode_concurrency(hardware=await asyncio.to_thread(hardware_available))
            if get_session_manager().active_transcodes() < limit:
                return
            await asyncio.sleep(_CAPACITY_POLL_S)

    async def _run(self) -> None:
        while True:
            if not self._queue:
                self._wake.clear()
                try:
                    await asyncio.wait_for(self._wake.wait(), timeout=600)
                except TimeoutError:
                    self.collect_garbage()
                    if not self._queue:
                        return
                continue
            export_id = self._queue.popleft()
            state = self._states.get(export_id)
            if state is None or state.status != STATUS_QUEUED:
                continue
            try:
                await self._wait_capacity()
                await self._transcode(state)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 —— 一份导出出错不能拖垮队列
                logger.exception("离线导出失败：%s", export_id)
                state.status = STATUS_FAILED
                state.error = str(exc) or exc.__class__.__name__
                self._save(state)

    async def _transcode(self, state: ExportState) -> None:
        async with get_database().session() as session:
            file = await session.get(LibraryFile, state.file_id)
        if file is None:
            raise ExportUnavailable("文件已不在媒体库里")
        plan = await build_plan(file, state.profile, state.audio_track)
        backends = await asyncio.to_thread(available_local_backends)
        backend, _remote = playback_plan.select_execution_backend(
            plan, available=backends, local_backends=backends, remote_video_available=False
        )
        source_path, input_options = file.file_path, []
        if is_strm(file.file_path):
            try:
                source_path, input_options = strm_source_input(parse_strm(file.file_path))
            except StrmError as exc:
                raise ExportUnavailable(f"strm 用不了：{exc}") from exc
        # 换代号再开转：旧代号的产物删掉，正在读旧产物的连接会发现代号变了而断开
        old = self.output_path(state) if state.generation else None
        state.generation += 1
        state.status = STATUS_RUNNING
        state.error = None
        state.final_bytes = None
        out = self.output_path(state)
        out.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(OSError):
            out.unlink()
        self._save(state)
        if old is not None:
            with contextlib.suppress(OSError):
                old.unlink()
        command = build_hls_command(
            plan,
            source_path=source_path,
            session_dir=out.parent,
            hw_backend=backend,
            input_options=input_options,
            export_path=out,
        )
        argv = list(command.argv)
        if shutil.which("nice"):
            argv = ["nice", "-n", "10", *argv]
        logger.info(
            "离线导出开始：%s（文件 %s，%s，后端 %s）",
            state.export_id, state.file_id, state.profile, backend or "软件",
        )
        started = time.monotonic()
        process = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
        self._process, self._running_id = process, state.export_id
        tail: deque[str] = deque(maxlen=_STDERR_KEEP)
        assert process.stderr is not None
        async for raw in process.stderr:
            line = raw.decode(errors="replace").rstrip()
            if line:
                tail.append(line)
        code = await process.wait()
        self._process, self._running_id = None, None
        if code != 0 or not out.exists():
            state.status = STATUS_FAILED
            state.error = (tail[-1] if tail else f"ffmpeg 退出码 {code}")[:500]
            self._save(state)
            logger.warning("离线导出失败：%s（退出码 %s）：%s", state.export_id, code, "\n".join(tail))
            return
        state.status = STATUS_DONE
        state.final_bytes = out.stat().st_size
        self._save(state)
        logger.info(
            "离线导出完成：%s，%d MB，用时 %d 秒",
            state.export_id, state.final_bytes // (1024 * 1024), time.monotonic() - started,
        )

    async def shutdown(self) -> None:
        if self._process is not None and self._process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                self._process.kill()
        if self._worker is not None:
            self._worker.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._worker


_manager: ExportManager | None = None


def get_export_manager() -> ExportManager:
    global _manager
    if _manager is None:
        _manager = ExportManager()
    return _manager


def reset_export_manager(root: Path | None = None) -> ExportManager:
    """测试用：换一个根目录重建（不碰正在跑的旧实例）。"""
    global _manager
    _manager = ExportManager(root)
    return _manager


class ExportTailResponse(Response):
    """正在转的导出：200 分块传输，从头发、跟着文件增长往后发。

    只有转码成功结束且全部发完才正常收尾；转码失败、换了代号就掐断连接（不发结束块），
    客户端一定报错，不会把半个文件当成完成。客户端断开由后台 ``receive`` 发现
    （见 docs/design 里 is_disconnected 的教训：轮询它在中间件下恒为假）。
    """

    media_type = "video/mp4"

    def __init__(self, manager: ExportManager, state: ExportState) -> None:
        self.manager = manager
        self.export_id = state.export_id
        self.generation = state.generation
        self.path = manager.output_path(state)
        super().__init__(
            status_code=200,
            headers={
                "etag": state.etag,
                "accept-ranges": "bytes",
                "cache-control": "no-store",
                # 预计大小（客户端画进度用；最终大小以实际为准）
                "x-expected-length": str(state.expected_bytes),
            },
        )
        # Response 默认会写 content-length: 0
        self.raw_headers = [(k, v) for k, v in self.raw_headers if k != b"content-length"]

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        disconnected = asyncio.Event()

        async def watch() -> None:
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    disconnected.set()
                    return

        watcher = asyncio.create_task(watch())
        self.manager.reader_enter(self.export_id)
        try:
            await send(
                {"type": "http.response.start", "status": 200, "headers": self.raw_headers}
            )
            if scope.get("method", "GET").upper() == "HEAD":
                await send({"type": "http.response.body", "body": b"", "more_body": False})
                return
            await self._stream(send, disconnected)
        finally:
            watcher.cancel()
            self.manager.reader_leave(self.export_id)

    async def _stream(self, send: Send, disconnected: asyncio.Event) -> None:
        sent = 0
        handle = None
        try:
            while not disconnected.is_set():
                if handle is None:
                    try:
                        handle = await asyncio.to_thread(open, self.path, "rb")
                    except FileNotFoundError:
                        handle = None
                if handle is not None:
                    chunk = await asyncio.to_thread(handle.read, _CHUNK)
                    if chunk:
                        sent += len(chunk)
                        await send({"type": "http.response.body", "body": chunk, "more_body": True})
                        continue
                state = self.manager.get(self.export_id)
                if state is None or state.generation != self.generation:
                    raise ExportStreamAborted(f"离线导出 {self.export_id} 重转了，掐断旧连接")
                if state.status == STATUS_FAILED:
                    raise ExportStreamAborted(f"离线导出 {self.export_id} 转码失败，掐断连接")
                if state.status == STATUS_DONE and handle is not None:
                    if state.final_bytes is not None and sent >= state.final_bytes:
                        await send({"type": "http.response.body", "body": b"", "more_body": False})
                        return
                    continue
                await asyncio.sleep(_TAIL_POLL_S)
        finally:
            if handle is not None:
                handle.close()


def state_view_fields(manager: ExportManager, state: ExportState) -> dict[str, Any]:
    return {
        "export_id": state.export_id,
        "status": state.status,
        "etag": state.etag,
        "expected_bytes": state.expected_bytes,
        "final_bytes": state.final_bytes,
        "error": state.error,
        "queue_position": manager.queue_position(state.export_id),
    }

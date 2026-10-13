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
import secrets
import shutil
import signal
import time
from collections import deque
from collections.abc import Callable
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Any

from starlette.responses import Response
from starlette.types import Receive, Scope, Send

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.playback import plan as playback_plan
from movieclaw_api.services.playback.ffmpeg_args import BITRATE_LADDER, build_hls_command
from movieclaw_api.services.playback.hwprobe import available_local_backends
from movieclaw_api.services.playback.limits import auto_transcode_concurrency
from movieclaw_api.services.playback.track_context import track_contexts
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile
from movieclaw_playback.decide import PlaybackPlan, PlaybackTier, plan_capped_transcode
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
    #: 每转一次换一个随机串：产物被回收后重建、代号从头数时，ETag 也不会与上一次撞上
    #: （否则客户端拿旧 ETag 续传，会把两次转码的字节拼在一起）
    nonce: str = ""
    #: 正在转的 ffmpeg 进程号：服务异常退出后，下次启动据此收拾残留的进程
    pid: int | None = None
    #: 还要这份导出的设备（下完调 DELETE 时只摘掉自己，最后一个摘掉才删）
    claims: list[str] = field(default_factory=list)

    @property
    def etag(self) -> str:
        return f'"exp-{self.export_id}-{self.generation}-{self.nonce}"'


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
    # 导出只在本机执行：「有硬件」要看本机探测通过的后端（合并能力里算上的远程转码器跑不了导出）。
    # 本机没有就按软件转码规划，软件转码没开则这一档不可用——不能悄悄用 libx264 顶上
    local = await asyncio.to_thread(available_local_backends)
    if policy.hardware_available and not local:
        policy = replace(policy, hardware_available=False)
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
    if plan.tier is PlaybackTier.HARDWARE_TRANSCODE:
        backend, _remote = playback_plan.select_execution_backend(
            plan, available=local, local_backends=local, remote_video_available=False
        )
        if backend is None:
            if not policy.software_transcode_enabled:
                raise ExportUnavailable("本机的硬件编码器处理不了这部片，且软件转码未开启")
            plan = plan_capped_transcode(
                media,
                replace(policy, hardware_available=False),
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
                # 上次没正常收尾（崩溃、被杀）：残留的 ffmpeg 还在写旧代号的文件，先收拾掉
                _kill_leftover(state.pid)
                state.status = STATUS_QUEUED
                state.pid = None
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
        self,
        file: LibraryFile,
        profile: str,
        audio_track: str | None,
        *,
        duration_s: float | None,
        claimant: str | None = None,
    ) -> ExportState:
        """建或复用一个导出（幂等）。失败过的再要一次就重转。``claimant`` 是要它的设备。"""
        self._load()
        await build_plan(file, profile, audio_track)  # 出不了这一档当场告诉客户端
        export_id = export_fingerprint(file, profile, audio_track)
        now = time.time()
        state = self._states.get(export_id)
        stale = (
            state is not None
            and state.status == STATUS_DONE
            and not self.output_path(state).exists()
        )  # 产物被清掉了（缓存管理清空）：重转
        if state is None or stale or state.status == STATUS_FAILED:
            state = ExportState(
                export_id=export_id,
                file_id=int(file.id or 0),
                profile=profile,
                audio_track=audio_track,
                status=STATUS_QUEUED,
                generation=(state.generation if state else 0),
                expected_bytes=estimate_bytes(profile, duration_s),
                created_at=now,
                claims=state.claims if state else [],
            )
            self._states[export_id] = state
            self._queue.append(export_id)
        if claimant and claimant not in state.claims:
            state.claims.append(claimant)
        state.last_access_at = now
        self._save(state)
        self._ensure_worker()
        self._wake.set()
        self.collect_garbage()
        return state

    def touch(self, state: ExportState) -> None:
        if self._states.get(state.export_id) is not state:
            return  # 这期间已被回收：不再写回一份孤儿 meta.json
        state.last_access_at = time.time()
        self._save(state)

    def claim(self, export_id: str, claimant: str) -> None:
        state = self.get(export_id)
        if state is not None and claimant not in state.claims:
            state.claims.append(claimant)
            self._save(state)

    def release(self, export_id: str, claimant: str | None = None) -> None:
        """某台设备下完了：摘掉它；没有别的设备还要、没人在下、也不在转，才当场删。"""
        state = self.get(export_id)
        if state is None:
            return
        if claimant in state.claims:
            state.claims.remove(claimant)
            self._save(state)
        if state.status in (STATUS_QUEUED, STATUS_RUNNING) or state.claims:
            return
        if self._readers.get(export_id):
            # 还有连接在读：留给过期回收
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
            local = await asyncio.to_thread(available_local_backends)
            limit = auto_transcode_concurrency(hardware=bool(local))
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
        state.nonce = secrets.token_hex(4)
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
            state.export_id,
            state.file_id,
            state.profile,
            backend or "软件",
        )
        started = time.monotonic()
        process = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
        self._process, self._running_id = process, state.export_id
        state.pid = process.pid
        self._save(state)
        tail: deque[str] = deque(maxlen=_STDERR_KEEP)
        assert process.stderr is not None
        async for raw in process.stderr:
            line = raw.decode(errors="replace").rstrip()
            if line:
                tail.append(line)
        code = await process.wait()
        self._process, self._running_id = None, None
        state.pid = None
        if code != 0 or not out.exists():
            state.status = STATUS_FAILED
            state.error = (tail[-1] if tail else f"ffmpeg 退出码 {code}")[:500]
            self._save(state)
            logger.warning(
                "离线导出失败：%s（退出码 %s）：%s", state.export_id, code, "\n".join(tail)
            )
            return
        state.status = STATUS_DONE
        state.final_bytes = out.stat().st_size
        self._save(state)
        logger.info(
            "离线导出完成：%s，%d MB，用时 %d 秒",
            state.export_id,
            state.final_bytes // (1024 * 1024),
            time.monotonic() - started,
        )

    async def shutdown(self) -> None:
        """后端退出：ffmpeg 起在独立进程组里，要 killpg 整组（TERM，3 秒后 KILL），否则留下孤儿"""
        process = self._process
        if process is not None and process.returncode is None:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            try:
                await asyncio.wait_for(process.wait(), timeout=3)
            except TimeoutError:
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        if self._worker is not None:
            self._worker.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._worker


def _kill_leftover(pid: int | None) -> None:
    """杀掉上次残留的导出 ffmpeg（只认命令行里带离线导出目录的，进程号被复用时不误杀）"""
    if not pid:
        return
    try:
        cmdline = (
            Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        )
    except OSError:
        cmdline = ""
    if "offline-exports" not in cmdline and "ffmpeg" not in cmdline:
        return
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(os.getpgid(pid), signal.SIGKILL)


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

    def __init__(
        self, manager: ExportManager, state: ExportState, on_close: Callable[[], None] | None = None
    ) -> None:
        self.on_close = on_close
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
            await send({"type": "http.response.start", "status": 200, "headers": self.raw_headers})
            if scope.get("method", "GET").upper() == "HEAD":
                await send({"type": "http.response.body", "body": b"", "more_body": False})
                return
            await self._stream(send, disconnected)
        finally:
            watcher.cancel()
            self.manager.reader_leave(self.export_id)
            if self.on_close is not None:
                self.on_close()

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
                    if state.final_bytes is not None and sent < state.final_bytes:
                        # 转完了却读不满（文件被替换、截断）：不能当完成，也不空转
                        raise ExportStreamAborted(f"离线导出 {self.export_id} 产物不完整")
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

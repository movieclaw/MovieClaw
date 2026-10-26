"""控制连接：重连、握手、心跳、派单（docs/design/remote-transcode.md §1、§3、§5.1）。

和 macOS 转码器的 ``WorkerClient`` 说同一套协议：连 ``/api/v1/transcode-worker/ws``，hello 里声明
自己的 ffmpeg 能力；之后 NAS 下发 ``job.start`` / ``job.stop`` / ``job.pause`` / ``job.resume``，
这边回 ``job.accepted`` / ``job.progress`` / ``job.finished`` / ``job.failed``。
"""

from __future__ import annotations

import contextlib
import platform
import threading
import time
import urllib.parse
from collections.abc import Callable
from typing import Any

from . import PROTOCOL_VERSION, __version__
from .job import Job
from .probe import Capabilities
from .telemetry import LoadSampler
from .websocket import HandshakeRejected, ServerClosed, WebSocketClient, rejection_kind

#: 心跳间隔与静默窗口：NAS 超过 45 秒没收到任何消息就判离线；这边用同一个窗口反向判定——
#: 超时没收到 NAS 的任何响应（含心跳 ack）就主动断开重连，避免半开连接下服务端已判离线、
#: Worker 却以为自己在线（Wi-Fi 睡眠唤醒、路由器换 NAT 映射都会这样）
HEARTBEAT_S = 5.0
SERVER_SILENCE_S = 45.0
#: 发起连接后这么久没收到 ``worker.accepted`` 就断开重连：服务端握手一成功就发关闭帧时，
#: 读操作会一直挂着，没有这一层 Worker 会永远停在「正在连接」
HANDSHAKE_TIMEOUT_S = 20.0
#: 主循环空等的时长。任务线程直接发状态消息，不靠这个值出户；它只决定看门狗的精度
POLL_S = 0.5
#: 1008 拒绝后的重试间隔（秒）：凭证失效慢慢试（NAS 从备份恢复后凭证可能重新有效），开关没开与
#: 其他原因每分钟问一次——与 macOS 转码器一致，不走指数退避
REJECT_RETRY_S = {"auth": 300.0, "remote_disabled": 60.0, "other": 60.0}

#: 连接与任务的事件回调，``app`` 外壳靠它驱动托盘与窗口：``connecting(server=…)`` /
#: ``online(max_jobs=…)`` / ``offline(reason=…, retry_seconds=…, rejection=…)`` /
#: ``job_started(job_id=…, name=…)`` / ``job_ended(job_id=…)``。任务事件从任务线程发出，
#: 消费方自己负责线程安全。
Status = Callable[..., None]


def ws_url(server: str) -> str:
    """``http://nas`` → ``ws://nas/api/v1/transcode-worker/ws``（https → wss，保留反代子路径）。"""
    parts = urllib.parse.urlsplit(server)
    scheme = "wss" if parts.scheme == "https" else "ws"
    path = parts.path.rstrip("/") + "/api/v1/transcode-worker/ws"
    return urllib.parse.urlunsplit((scheme, parts.netloc, path, "", ""))


def describe_rejection(error: BaseException) -> tuple[str, str | None]:
    """连接被拒的原因翻成给人看的话，并给出分类（``auth`` / ``remote_disabled`` / ``other``）。"""
    if isinstance(error, ServerClosed) and error.code == 1008:
        return error.reason or "NAS 拒绝了连接", rejection_kind(error.reason)
    if isinstance(error, HandshakeRejected):
        status = error.status
        if status == 403:
            # 旧版服务端在 accept 之前就关连接，uvicorn 只回一个空的 403、理由丢了：
            # 凭证失效和开关没开分不出来，两种都得说
            return (
                "NAS 拒绝了连接（HTTP 403）：请确认网页「应用 → 远程转码」已经打开；"
                "已经打开的话，说明这台电脑的授权已失效，请重新配对（--reset）",
                "other",
            )
        if status == 404:
            return (
                "NAS 上找不到远程转码接口（HTTP 404）：地址可能填错了，或 movieclaw 版本太旧",
                "other",
            )
        if status >= 500:
            # 后端重启（比如 NAS 正在更新）时反向代理回 502 / 503，等一下就好，照常退避
            return f"NAS 暂时不可用（HTTP {status}），稍后自动重连", None
        return f"NAS 拒绝了连接（HTTP {status}）", "other"
    return str(error), None


class TranscoderClient:
    def __init__(
        self,
        *,
        server: str,
        token: str,
        worker_id: str,
        ffmpeg: str,
        capabilities: Capabilities,
        max_jobs: int,
        log: Callable[[str], None] = lambda _message: None,
        on_status: Status = lambda _kind, **_fields: None,
    ) -> None:
        self.server = server.rstrip("/")
        self.token = token
        self.worker_id = worker_id
        self.ffmpeg = ffmpeg
        self.capabilities = capabilities
        self.max_jobs = max_jobs
        self._log = log
        self._status = on_status
        self._jobs: dict[str, Job] = {}
        self._jobs_lock = threading.Lock()
        self._ws: WebSocketClient | None = None
        self._stop = threading.Event()
        self._load = LoadSampler()
        self._unknown_logged: set[str] = set()

    # -- 主循环 ---------------------------------------------------------------

    def run_forever(self) -> None:
        backoff = 2.0
        while not self._stop.is_set():
            started = time.monotonic()
            wait = 0.0
            try:
                self._connect_once()
            except (OSError, ValueError) as exc:
                if self._stop.is_set():
                    break
                reason, kind = describe_rejection(exc)
                fields: dict[str, Any] = {}
                if kind is not None:
                    # 服务端明确拒绝：按理由定间隔，不走退避；分类随状态交出（凭证失效要提示重配）
                    wait = REJECT_RETRY_S[kind]
                    fields["rejection"] = kind
                elif time.monotonic() - started < 30:
                    # 刚连上就断的按退避等，长连过的立即重连
                    wait, backoff = backoff, min(backoff * 2, 30.0)
                else:
                    backoff = 2.0
                self._status("offline", reason=reason, retry_seconds=wait, **fields)
            if wait:
                self._stop.wait(wait)

    def stop(self) -> None:
        self._stop.set()
        ws = self._ws
        if ws is not None:
            with contextlib.suppress(OSError):
                ws.send_json({"type": "worker.goodbye"})
        self._stop_all_jobs()

    def _connect_once(self) -> None:
        self._status("connecting", server=self.server)
        ws = WebSocketClient(
            ws_url(self.server),
            self.token,
            user_agent=f"MovieClawTranscoder/{__version__} (Windows)",
        )
        self._ws = ws
        try:
            ws.send_json(self._hello())
            handshake_deadline = time.monotonic() + HANDSHAKE_TIMEOUT_S
            accepted = False
            last_seen = time.monotonic()
            last_beat = 0.0
            while not self._stop.is_set():
                now = time.monotonic()
                if now - last_beat >= HEARTBEAT_S:
                    last_beat = now
                    ws.send_json({"type": "worker.heartbeat", "load": self._load.sample()})
                message = ws.recv_json(POLL_S)
                if message is not None:
                    last_seen = time.monotonic()
                    if message.get("type") == "worker.accepted":
                        accepted = True
                    self._handle(ws, message)
                elif not accepted and time.monotonic() > handshake_deadline:
                    raise OSError(f"{int(HANDSHAKE_TIMEOUT_S)} 秒内没有完成握手")
                elif time.monotonic() - last_seen > SERVER_SILENCE_S:
                    raise OSError(f"NAS 超过 {int(SERVER_SILENCE_S)} 秒没有任何响应，主动断开重连")
        finally:
            self._ws = None
            # 断线后服务端已把这些任务判失败重派：本地立即收掉 ffmpeg 释放并发位——旧进程占着
            # 任务表，会把重派回来的新任务顶成「Worker 并发已满」，播放直接失败
            self._stop_all_jobs()
            ws.close()

    def _hello(self) -> dict[str, Any]:
        caps = self.capabilities
        return {
            "type": "worker.hello",
            "protocol_version": PROTOCOL_VERSION,
            "worker_version": __version__,
            "worker_id": self.worker_id,
            "draining": False,
            "capabilities": {
                "platform": "Windows",
                "arch": platform.machine().lower() or "unknown",
                "ffmpeg_version": caps.ffmpeg_version,
                "encoders": list(caps.encoders),
                "backends": caps.backends,
                "max_jobs": self.max_jobs,
                "server_config": True,
                "hardware": caps.hardware,
                # 本程序只把分片化 MP4 切成 fMP4 分片回传：TS 分片（Infuse 等）不接
                "segment_types": ["fmp4"],
                # 没有面板消费观众播放位置：申报 true 会让服务端每 3 秒白发一条
                "playback_progress": False,
                # 不读原盘（ffconcat 清单）
                "disc_sources": False,
                "hw_decoders": list(caps.hw_decoders),
                "filters": list(caps.filters),
                "progressive_segments": True,
                "read_options": list(caps.read_options),
            },
        }

    # -- 消息 -----------------------------------------------------------------

    def _handle(self, ws: WebSocketClient, message: dict[str, Any]) -> None:
        kind = str(message.get("type", ""))
        if kind == "worker.accepted":
            self._set_limit(message.get("max_jobs"))
            self._status("online", server=self.server, max_jobs=self.max_jobs)
        elif kind == "worker.config":
            if self._set_limit(message.get("max_jobs")):
                self._log(f"并发上限同步为 {self.max_jobs}")
        elif kind == "worker.config.error":
            self._log(f"并发设置未保存：{message.get('error')}")
        elif kind == "job.start":
            self._start_job(ws, message)
        elif kind in ("job.stop", "job.pause", "job.resume"):
            self._control_job(kind, message)
        elif kind in ("worker.heartbeat.ack", "job.playback"):
            pass  # 任何一条消息都算链路活着（上面的 last_seen），这两条没有别的事要做
        elif kind not in self._unknown_logged:
            self._unknown_logged.add(kind)
            self._log(f"忽略未知控制消息：{kind}")

    def _set_limit(self, value: object) -> bool:
        if isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 4:
            self.max_jobs = value
            return True
        return False

    def _start_job(self, ws: WebSocketClient, message: dict[str, Any]) -> None:
        job_id = str(message.get("job_id") or "")
        if not job_id:
            return
        attempt_id = str(message.get("attempt_id") or job_id)
        with self._jobs_lock:
            existing = self._jobs.get(job_id)
            if existing is not None and existing.attempt_id == attempt_id:
                # 同一轮重复下发（NAS 没等到回执重试）：重新回执，不重复起 ffmpeg
                self._send({"type": "job.accepted", "job_id": job_id, "attempt_id": attempt_id})
                return
            replaced = self._jobs.pop(job_id, None)
        if replaced is not None:
            # 拖进度换一轮：旧一轮被顶掉，也要报结束，否则外壳的「正在转码 N 路」只涨不降
            self._status("job_ended", job_id=job_id)
            replaced.stop(force=True)
        with self._jobs_lock:
            if len(self._jobs) >= self.max_jobs:
                self._send(
                    {
                        "type": "job.failed",
                        "job_id": job_id,
                        "attempt_id": attempt_id,
                        "error": "Worker 并发已满",
                    }
                )
                return
            job = Job(
                message,
                ffmpeg=self.ffmpeg,
                send=self._send,
                log=self._log,
            )
            self._jobs[job_id] = job
        self._log(f"接单 {job_id[-6:]}：{job.display_name or '（未命名）'}")
        # 先报开始再起任务：任务瞬间失败时，事件顺序不会变成「结束」在「开始」之前
        self._status("job_started", job_id=job_id, name=job.display_name or "")
        job.start(self._job_exited)

    def _control_job(self, kind: str, message: dict[str, Any]) -> None:
        job_id = str(message.get("job_id") or "")
        ended = False
        with self._jobs_lock:
            if kind == "job.stop":
                job = self._jobs.pop(job_id, None)
                ended = job is not None
            else:
                job = self._jobs.get(job_id)
        if job is None:
            return
        if kind == "job.stop":
            force = message.get("force") is True
            # force=True 是拖进度条重启（马上有新单接上），不当成故障
            self._log(f"停止转码 {job_id[-6:]}" + ("（拖动进度，重启）" if force else ""))
            if ended:
                # 已经从任务表里摘掉：这里就是它的结束点（_job_exited 认身份会跳过）
                self._status("job_ended", job_id=job_id)
            job.stop(force)
        elif kind == "job.pause":
            job.pause()
        else:
            job.resume()

    def _job_exited(self, job: Job) -> None:
        """任务线程退出即释放并发槽位。**要认身份**：seek 换轮次时旧线程的收尾不能弹掉新一轮。"""
        with self._jobs_lock:
            if self._jobs.get(job.job_id) is job:
                del self._jobs[job.job_id]
                self._status("job_ended", job_id=job.job_id)

    def _stop_all_jobs(self) -> None:
        with self._jobs_lock:
            jobs = list(self._jobs.values())
            self._jobs.clear()
        for job in jobs:
            self._status("job_ended", job_id=job.job_id)
            job.stop(force=True)

    @property
    def active_jobs(self) -> int:
        """当前台账里的任务数。外壳读它显示「正在转码 N 路」，不靠事件加减——
        事件只是通知「变了」，数量以任务表为准（停止、拖进度、断线都不会漏）。"""
        with self._jobs_lock:
            return len(self._jobs)

    def _send(self, payload: dict[str, Any]) -> None:
        """任务线程投递状态消息。连接已经换掉或断了就丢弃：断线时服务端会把这些任务判失败重派。"""
        ws = self._ws
        if ws is None:
            return
        with contextlib.suppress(OSError):
            ws.send_json(payload)

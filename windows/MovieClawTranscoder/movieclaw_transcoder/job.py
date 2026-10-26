"""一个实时转码任务：起 ffmpeg、解析进度、把产物送回 NAS。

NAS 在 ``job.start`` 里下发整条 ffmpeg 命令（``ffmpeg_args``）：源是带签名的 HTTP(S) 地址，ffmpeg
直接读；产物地址同样带签名。**命令由 NAS 的统一装配器拼好，Worker 不自己决定转码参数。**

渐进式任务（消息里有 ``segment_seconds``）的输出是一条分片化 MP4。Windows 上不让 ffmpeg 自己
PUT 回 NAS：ffmpeg 的 HTTP 输出不看响应码、没有重试，丢了分片没人知道（NAS 侧要靠 Worker 主动
上报才能补片）。改成 ffmpeg 把它推到本机回环口，``StreamRelay`` 收下来交给 ``ProgressiveUploader``
切段分块回传——重试、整段兜底、上报都在我们手里，媒体字节不落盘。
其余任务（没有预生成播放列表的会话，HLS muxer 输出）照 NAS 给的地址，由 ffmpeg 直接 PUT。
"""

from __future__ import annotations

import contextlib
import os
import socket
import subprocess
import threading
import time
from collections.abc import Callable
from typing import Any

from . import winproc
from .config import ffmpeg_env
from .probe import NO_WINDOW
from .uploader import ArtifactClient, ProgressiveUploader, split_artifact_url

#: 看门狗（与 macOS 转码器同一组阈值，docs/design/remote-transcode.md §5.1）：起转后这么久还没有
#: 第一条进度、或之后这么久没有新进度，强制结束 ffmpeg 并上报失败，NAS 照常重试或降档
STALL_BEFORE_FIRST_PROGRESS_S = 90.0
STALL_BETWEEN_PROGRESS_S = 60.0
WATCHDOG_TICK_S = 2.0
#: 进度上报的最小间隔：NAS 靠它判断「第一个分片出来了」与测供片速度，不需要更密
PROGRESS_INTERVAL_S = 0.8
STDERR_TAIL_LINES = 40
#: ffmpeg 收尾后给回环口把剩下的字节交完的宽限
DRAIN_TIMEOUT_S = 10.0
UPLOAD_TIMEOUT_S = 30.0

#: 排障开关：把每个任务的 ffmpeg 命令与 stderr 逐行写进日志（命令里有带签名的地址，仅限本机排查）
DEBUG = bool(os.environ.get("MOVIECLAW_TRANSCODER_DEBUG"))

Send = Callable[[dict[str, Any]], None]


class StreamRelay:
    """ffmpeg 往本机回环口推分片化 MP4，这里收下来交给 ``on_bytes``（切段与回传）。

    为什么走回环 TCP 而不是写文件再跟读：文件在任务结束前只增不减（两小时的片子按 6 Mbps 就是
    5 GB 的临时文件，白磨 SSD），回环口自带反压、积压只在内存里，而 NAS 的领先量节流（暂停
    ffmpeg）把它限在两分钟以内。只接 ffmpeg 的这一条连接，端口是每个任务临时挑的。

    ``on_bytes`` 返回非空字符串表示这条流已经坏到没法用了（原因）：之后不再读，
    ``on_failure`` 收到原因。
    """

    POLL_S = 0.2

    def __init__(
        self,
        on_bytes: Callable[[bytes], str | None],
        on_failure: Callable[[str], None],
    ) -> None:
        self._on_bytes = on_bytes
        self._on_failure = on_failure
        self._listener = socket.socket()
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(1)
        #: 交给 ffmpeg 当输出地址
        self.url = f"tcp://127.0.0.1:{self._listener.getsockname()[1]}"
        self._stop = threading.Event()
        self._done = threading.Event()
        self._thread = threading.Thread(target=self._serve, name="stream-relay", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_drained(self, timeout: float) -> bool:
        """ffmpeg 退出后：它那头关了连接，剩下的字节也都交出去了。"""
        return self._done.wait(timeout)

    def stop(self) -> None:
        self._stop.set()
        with contextlib.suppress(OSError):
            self._listener.close()
        if self._thread.is_alive():
            self._thread.join(timeout=3)

    def _accept(self) -> socket.socket | None:
        self._listener.settimeout(self.POLL_S)
        while not self._stop.is_set():
            try:
                return self._listener.accept()[0]
            except TimeoutError:
                continue
            except OSError:
                return None  # 监听口已经关了
        return None

    def _serve(self) -> None:
        try:
            connection = self._accept()
            if connection is None:
                return
            with connection:
                connection.settimeout(self.POLL_S)
                while not self._stop.is_set():
                    try:
                        data = connection.recv(256 * 1024)
                    except TimeoutError:
                        continue
                    except OSError as exc:
                        if not self._stop.is_set():
                            self._on_failure(f"读 ffmpeg 输出失败：{exc}")
                        return
                    if not data:  # ffmpeg 收尾，连接关了
                        return
                    failure = self._on_bytes(data)
                    if failure is not None:
                        self._on_failure(failure)
                        return
        finally:
            self._done.set()


class Job:
    """一个 ``job.start`` 对应的任务。在自己的线程里跑；``send`` 把状态消息交给控制连接去发。"""

    def __init__(
        self,
        message: dict[str, Any],
        *,
        ffmpeg: str,
        send: Send,
        log: Callable[[str], None],
    ) -> None:
        self.job_id = str(message.get("job_id") or "")
        self.attempt_id = str(message.get("attempt_id") or self.job_id)
        self.display_name = str(message.get("display_name") or "")
        self._message = message
        self._ffmpeg = ffmpeg
        self._send = send
        self._log = log
        self._thread: threading.Thread | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self._uploader: ProgressiveUploader | None = None
        self._relay: StreamRelay | None = None
        self.stop_requested = False
        self._paused = False
        self._stderr: list[str] = []
        self._stderr_lock = threading.Lock()
        self._started_at = 0.0
        self._last_progress = 0.0
        self._first_progress = False
        self._stall: str | None = None
        self._broken: str | None = None
        #: 起播分段计时：距收到 job.start 的毫秒数（NAS 并进会话时间线，诊断面板可见）
        self._t0 = time.monotonic()
        self._marks: list[dict[str, Any]] = []
        self._marks_sent = 0
        self._marks_lock = threading.Lock()

    # -- 生命周期 -------------------------------------------------------------

    def start(self, on_exit: Callable[[Job], None]) -> None:
        self._thread = threading.Thread(
            target=self._main, args=(on_exit,), name=f"job-{self.job_id[-6:]}", daemon=True
        )
        self._thread.start()

    def stop(self, force: bool = False) -> None:
        """NAS 叫停（seek 重启换新一轮、会话结束）。本任务不再上报终态。

        ``force`` 是拖进度条重启（马上有新一轮接上）；旧一轮没有交付价值，
        普通 stop 与它一样直接杀。"""
        self.stop_requested = True
        process = self._process
        if self._uploader is not None:
            self._uploader.cancel()
        if process is not None and process.poll() is None:
            with contextlib.suppress(OSError):
                process.kill()  # 对被挂起的进程同样有效，不必先恢复

    def pause(self) -> None:
        process = self._process
        if process is not None and process.poll() is None and not self._paused:
            self._paused = winproc.suspend(process.pid)

    def resume(self) -> None:
        process = self._process
        if process is not None and process.poll() is None and self._paused:
            winproc.resume(process.pid)
            self._paused = False
            self._last_progress = time.monotonic()  # 挂起期间不算卡死

    # -- 线程主体 -------------------------------------------------------------

    def _main(self, on_exit: Callable[[Job], None]) -> None:
        try:
            self._run()
        except Exception as exc:  # noqa: BLE001 - 任务线程不能带着异常消失，NAS 在等终态
            if not self.stop_requested:
                self._fail(str(exc)[:2000])
        finally:
            if self._relay is not None:
                self._relay.stop()
            on_exit(self)

    def _run(self) -> None:
        arguments = [str(arg) for arg in self._message.get("ffmpeg_args") or []]
        if not arguments:
            raise RuntimeError("任务缺少 ffmpeg_args")
        if "segment_seconds" in self._message:
            arguments = self._redirect_stream_output(arguments)
        self._started_at = self._last_progress = time.monotonic()
        self._mark("spawn")
        if DEBUG:
            self._log(f"ffmpeg {self.job_id[-6:]}：{' '.join(arguments)}")
        process = subprocess.Popen(
            [self._ffmpeg, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            creationflags=NO_WINDOW,
            env=ffmpeg_env(),
        )
        self._process = process
        self._mark("ffmpeg")
        winproc.kill_with_parent(process)
        if self.stop_requested:  # 起进程的瞬间 NAS 已经叫停
            process.kill()
        self._send(self._job_message("job.accepted"))
        stderr_thread = threading.Thread(
            target=self._pump_stderr, name="ffmpeg-stderr", daemon=True
        )
        stderr_thread.start()
        watchdog = threading.Thread(target=self._watch, name="job-watchdog", daemon=True)
        watchdog.start()

        exit_code = self._pump_progress(process)
        self._mark("exit", code=exit_code)
        stderr_thread.join(timeout=5)
        relay = self._relay
        if relay is not None:
            if exit_code == 0 and not self.stop_requested:
                relay.wait_drained(DRAIN_TIMEOUT_S)  # ffmpeg 收尾后连接已关，剩下的字节很快交完
            relay.stop()
        uploader = self._uploader
        if uploader is not None:
            if exit_code == 0 and not self.stop_requested and self._broken is None:
                if not uploader.finish(UPLOAD_TIMEOUT_S):
                    uploader.cancel()
                    self._broken = f"产物回传超过 {int(UPLOAD_TIMEOUT_S)} 秒没有传完"
            else:
                uploader.cancel()  # 失败或被叫停：不补收尾块，半截分片留给 NAS 补
        if self.stop_requested:
            return  # NAS 叫停（seek 旧轮次）：不报终态
        self._send_timeline()
        if self._broken is not None:
            self._fail(self._broken)
        elif self._stall is not None:
            self._fail(self._stall)
        elif exit_code == 0:
            self._send(self._job_message("job.finished", exit_code=0))
        else:
            self._fail(f"ffmpeg 退出码 {exit_code}", exit_code=exit_code)

    def _redirect_stream_output(self, arguments: list[str]) -> list[str]:
        """把输出 ``…/artifacts/stream.mp4?token=…`` 换成本机回环口，并搭好回传。"""
        index = next(
            (
                i
                for i, arg in enumerate(arguments)
                if arg.split("?", 1)[0].endswith("/stream.mp4") and split_artifact_url(arg)
            ),
            None,
        )
        if index is None:
            raise RuntimeError("渐进式任务里找不到 stream.mp4 的产物地址")
        target = split_artifact_url(arguments[index])
        assert target is not None
        base, query = target
        start_segment = self._message.get("start_segment")
        client = ArtifactClient(base, query, cancelled=lambda: self.stop_requested, log=self._log)
        self._uploader = ProgressiveUploader(
            client,
            segment_seconds=float(self._message.get("segment_seconds") or 4),
            start_segment=int(start_segment) if start_segment is not None else None,
            on_abandoned=self._artifact_abandoned,
            on_uploaded=self._uploaded,
            log=self._log,
        )
        self._uploader.start()
        self._relay = StreamRelay(self._feed, self._on_stream_broken)
        self._relay.start()  # 先于 ffmpeg 起来：它一启动就要连这个口
        return [*arguments[:index], self._relay.url, *arguments[index + 1 :]]

    def _feed(self, data: bytes) -> str | None:
        if not any(mark["ev"] == "first_bytes" for mark in self._marks):
            self._mark("first_bytes")
        assert self._uploader is not None
        return self._uploader.feed(data)

    def _uploaded(self, name: str) -> None:
        self._mark("init_up" if name == "init.mp4" else "seg_up", name=name)
        if name != "init.mp4" and self._marks_sent == 0:
            self._send_timeline()  # 首片传到 NAS 时发一次，之后任务结束前再发一次

    # -- ffmpeg 输出 ----------------------------------------------------------

    def _pump_progress(self, process: subprocess.Popen[bytes]) -> int:
        """解析 ``-progress pipe:1`` 的键值行，节流后以 ``job.progress`` 上报；返回退出码。"""
        assert process.stdout is not None
        values: dict[str, str] = {}
        pending = b""
        last_sent = 0.0
        while True:
            chunk = process.stdout.read1(4096)
            if not chunk:
                break
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                key, sep, value = line.decode("utf-8", "replace").strip().partition("=")
                if not sep:
                    continue
                values[key] = value
                if key != "progress":
                    continue
                out_time_ms = _out_time_ms(values)
                if out_time_ms is not None and out_time_ms > 0 and not self._first_progress:
                    self._first_progress = True
                    self._mark("first_progress")
                self._last_progress = time.monotonic()
                now = time.monotonic()
                if value == "end" or now - last_sent >= PROGRESS_INTERVAL_S:
                    last_sent = now
                    payload = self._job_message("job.progress", phase=value)
                    if out_time_ms is not None:
                        payload["out_time_ms"] = out_time_ms
                    if values.get("speed"):
                        payload["speed"] = values["speed"]
                    self._send(payload)
        return process.wait()

    def _pump_stderr(self) -> None:
        process = self._process
        if process is None or process.stderr is None:
            return
        for raw in iter(process.stderr.readline, b""):
            line = raw.decode("utf-8", "replace").rstrip()
            if not line:
                continue
            if DEBUG:
                self._log(f"ffmpeg {self.job_id[-6:]} +{time.monotonic() - self._t0:.2f}s：{line}")
            with self._stderr_lock:
                self._stderr.append(line)
                if len(self._stderr) > STDERR_TAIL_LINES:
                    self._stderr.pop(0)

    def _watch(self) -> None:
        """卡死看门狗：ffmpeg 活着却不出进度（源读不动、GPU 挂死）。被 NAS 暂停的任务不计时。"""
        process = self._process
        while process is not None and process.poll() is None and not self.stop_requested:
            time.sleep(WATCHDOG_TICK_S)
            if self._paused:
                continue
            idle = time.monotonic() - (
                self._last_progress if self._first_progress else self._started_at
            )
            limit = (
                STALL_BETWEEN_PROGRESS_S if self._first_progress else STALL_BEFORE_FIRST_PROGRESS_S
            )
            if idle > limit:
                self._stall = f"ffmpeg {int(idle)} 秒没有新的进度" + (
                    "" if self._first_progress else "（起转后一直没有出第一帧）"
                )
                with contextlib.suppress(OSError):
                    process.kill()
                return

    # -- 上报 -----------------------------------------------------------------

    def _mark(self, event: str, **fields: Any) -> None:
        with self._marks_lock:
            self._marks.append(
                {"ev": event, "ms": int((time.monotonic() - self._t0) * 1000), **fields}
            )

    def _send_timeline(self) -> None:
        with self._marks_lock:
            fresh = self._marks[self._marks_sent :]
            self._marks_sent = len(self._marks)
        if fresh:
            self._send(self._job_message("job.timeline", events=fresh))

    def _job_message(self, kind: str, **fields: Any) -> dict[str, Any]:
        return {"type": kind, "job_id": self.job_id, "attempt_id": self.attempt_id, **fields}

    def _fail(self, error: str, *, exit_code: int | None = None) -> None:
        with self._stderr_lock:
            tail = "\n".join(self._stderr)[-2000:]
        extra: dict[str, Any] = {"error": error}
        if exit_code is not None:
            extra["exit_code"] = exit_code
        if tail:
            extra["stderr_tail"] = tail
        self._send(self._job_message("job.failed", **extra))

    def _artifact_abandoned(self, name: str, status: int, reason: str) -> None:
        """产物重试用尽仍没传上去：告诉 NAS，由它按补片台账从这一片重启。"""
        self._log(f"产物 {name} 回传失败（HTTP {status}）：{reason}")
        self._send(self._job_message("job.artifact_failed", name=name, status=status, error=reason))

    def _on_stream_broken(self, reason: str) -> None:
        """输出流坏到没法切段：这一轮没救了，结束 ffmpeg 并以失败收尾。"""
        self._broken = reason
        process = self._process
        if process is not None:
            with contextlib.suppress(OSError):
                process.kill()


def _out_time_ms(values: dict[str, str]) -> int | None:
    """ffmpeg 的 ``out_time_ms`` 名不符实，单位其实是微秒（历史遗留）；优先用 ``out_time_us``。"""
    text = values.get("out_time_us") or values.get("out_time_ms")
    if text is None:
        return None
    try:
        return int(text) // 1000
    except ValueError:
        return None

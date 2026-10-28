"""字幕生成调用的外部进程（ffmpeg 抽音频、seconv 识别图片字幕）：可取消、可超时、不留孤儿。

此前这些进程都跑在 ``asyncio.to_thread(subprocess.run, ...)`` 里，有个硬伤：
取消只能取消「等它的协程」，线程和子进程照跑。用户点了「停止生成」，任务却
一直停在「正在停止」，要等 OCR 自己跑完（最长一小时）；应用更新停机时还会
留下继续占 CPU 的孤儿进程。

这里改用异步子进程并起在独立进程组里（与 ``media_extract`` 抽字幕同一套纪律）：
取消或超时时先给整组发 SIGTERM，留一点时间体面退出，再 SIGKILL。Windows 没有
进程组，退化为结束进程本身。
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import signal
import subprocess
from dataclasses import dataclass

# 先给进程一个正常退出窗口，超时或取消后再强制杀掉整个进程组。
_TERM_GRACE = 2.0
_KILL_GRACE = 5.0


@dataclass(frozen=True)
class Completed:
    """进程自己结束（含非零退出码）时的结果。"""

    returncode: int
    stdout: bytes
    stderr: bytes


class ProcessTimeout(Exception):
    """进程超过时限，已被连同进程组一起结束。"""


def _spawn_options() -> dict[str, object]:
    if os.name == "posix":
        return {"start_new_session": True}
    return {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)}


def _signal(proc: asyncio.subprocess.Process, *, force: bool) -> None:
    """结束整个进程组；进程已退出时按幂等处理。

    pid ≤ 1 一律拒绝：``killpg(1, sig)`` 就是 ``kill(-1, sig)``，会把当前用户
    能碰到的所有进程一起杀掉（``media_extract`` 同一条教训）。
    """
    pid = proc.pid
    if pid is None or pid <= 1:
        return
    with contextlib.suppress(OSError):
        if hasattr(os, "killpg"):
            os.killpg(pid, signal.SIGKILL if force else signal.SIGTERM)
        elif force:
            proc.kill()
        else:
            proc.terminate()


async def _terminate(
    proc: asyncio.subprocess.Process, communicate: asyncio.Future[tuple[bytes, bytes]]
) -> None:
    _signal(proc, force=False)
    try:
        await asyncio.wait_for(asyncio.shield(communicate), _TERM_GRACE)
        return
    except (TimeoutError, OSError):
        pass
    _signal(proc, force=True)
    with contextlib.suppress(TimeoutError, OSError):
        await asyncio.wait_for(asyncio.shield(communicate), _KILL_GRACE)


async def run(argv: list[str], *, timeout: float) -> Completed:
    """运行外部命令并收集输出；超时或被取消时连同进程组一起结束。

    启动失败原样抛 ``OSError``；超时抛 ``ProcessTimeout``；被取消时先回收
    进程再把 ``CancelledError`` 继续向上抛。
    """
    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdin=subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        **_spawn_options(),
    )
    communicate = asyncio.ensure_future(proc.communicate())
    try:
        stdout, stderr = await asyncio.wait_for(asyncio.shield(communicate), timeout)
    except asyncio.CancelledError:
        # 回收也要护住：停机时协程可能被再次取消，进程却不能留下来
        await asyncio.shield(_terminate(proc, communicate))
        raise
    except TimeoutError:
        await _terminate(proc, communicate)
        name = os.path.basename(argv[0])
        # i18n-ignore: internal timeout signal, never shown
        raise ProcessTimeout(f"{name} 超过 {timeout:.0f} 秒没有结束，已停止") from None
    returncode = proc.returncode if proc.returncode is not None else -1
    return Completed(returncode=returncode, stdout=stdout, stderr=stderr)


# ---------------------------------------------------------------------------
# 逐行输出的长进程（本地语音识别，docs/design/subtitle-asr.md §4.2）
# ---------------------------------------------------------------------------

#: 识别子进程每段输出一行 JSON，带全部 token 与时间戳；放宽 asyncio 默认的 64 KiB 行长
_LINE_LIMIT = 1 << 20
#: stderr 只留末尾：失败时给用户看原因够用，不让一个话多的进程占满内存
_STDERR_KEEP = 8192


def _send(proc: asyncio.subprocess.Process, name: str) -> bool:
    """给整个进程组发一个按名字取的信号；平台没有这个信号（Windows 无 SIGSTOP）时返回 False。"""
    sig = getattr(signal, name, None)
    pid = proc.pid
    if sig is None or pid is None or pid <= 1 or proc.returncode is not None:
        return False
    with contextlib.suppress(OSError):
        if hasattr(os, "killpg"):
            os.killpg(pid, sig)
        else:
            proc.send_signal(sig)
        return True
    return False


class Spawned:
    """``spawn`` 起的子进程：逐行读输出，可暂停、继续，退出时由 ``spawn`` 连同进程组回收。"""

    def __init__(self, proc: asyncio.subprocess.Process) -> None:
        self._proc = proc
        self._stderr = bytearray()
        self._stderr_task = asyncio.ensure_future(self._drain_stderr())
        self.paused = False

    async def _drain_stderr(self) -> None:
        stream = self._proc.stderr
        if stream is None:
            return
        while chunk := await stream.read(4096):
            self._stderr += chunk
            del self._stderr[:-_STDERR_KEEP]

    async def readline(self) -> bytes:
        """下一行输出；进程结束且读完后返回空字节。"""
        stream = self._proc.stdout
        return await stream.readline() if stream is not None else b""

    def pause(self) -> None:
        """SIGSTOP 整个进程组（让出 CPU）；平台不支持时什么也不做。"""
        if not self.paused and _send(self._proc, "SIGSTOP"):
            self.paused = True

    def resume(self) -> None:
        if self.paused:
            _send(self._proc, "SIGCONT")
            self.paused = False

    async def wait(self) -> int:
        returncode = await self._proc.wait()
        with contextlib.suppress(Exception):
            await self._stderr_task
        return returncode

    def stderr_tail(self, limit: int = 400) -> str:
        text = self._stderr.decode(errors="replace").strip().replace("\n", " ")
        return text[-limit:]

    async def stop(self) -> None:
        """先让暂停的进程继续（停住的进程收不到 SIGTERM），再按 SIGTERM → SIGKILL 回收。"""
        proc = self._proc
        if proc.returncode is None:
            if self.paused:
                _send(proc, "SIGCONT")
                self.paused = False
            _signal(proc, force=False)
            try:
                await asyncio.wait_for(proc.wait(), _TERM_GRACE)
            except (TimeoutError, OSError):
                _signal(proc, force=True)
                with contextlib.suppress(TimeoutError, OSError):
                    await asyncio.wait_for(proc.wait(), _KILL_GRACE)
        self._stderr_task.cancel()


@contextlib.asynccontextmanager
async def spawn(argv: list[str], *, stdin: bytes = b""):
    """起一个逐行输出的子进程（独立进程组）；离开上下文时若还在跑就连同进程组结束。

    启动失败原样抛 ``OSError``。被取消时回收也要护住：停机时协程可能被再次取消，
    进程却不能留下来。
    """
    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        limit=_LINE_LIMIT,
        **_spawn_options(),
    )
    spawned = Spawned(proc)
    try:
        if proc.stdin is not None:
            with contextlib.suppress(OSError, ConnectionError):
                proc.stdin.write(stdin)
                await proc.stdin.drain()
                proc.stdin.close()
        yield spawned
    finally:
        await asyncio.shield(spawned.stop())

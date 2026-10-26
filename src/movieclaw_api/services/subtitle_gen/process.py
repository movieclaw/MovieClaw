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

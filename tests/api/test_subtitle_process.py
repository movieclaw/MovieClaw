"""字幕生成的外部进程：取消或超时都要连同进程组一起结束，不留孤儿。

ffmpeg 抽音频、seconv 识别图片字幕以前跑在线程里，取消只能取消「等它的协程」，
子进程照跑：用户点停止要等 OCR 自己跑完（最长一小时），停机还会留下孤儿进程。
"""

from __future__ import annotations

import asyncio
import os
import sys
import time
from pathlib import Path

import pytest

from movieclaw_api.services.subtitle_gen import process

pytestmark = pytest.mark.skipif(os.name != "posix", reason="进程组语义只在 POSIX 上验证")


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # 已退出但尚未被回收的僵尸也算死了。不能先 exists() 再读：两步之间进程
    # 可能恰好被 init 回收，读取就会抛 FileNotFoundError（CI 上真实出现过）
    try:
        return Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
    except ProcessLookupError:
        # 打开文件后、读取前进程被回收，Linux 对 /proc/<pid>/stat 的读取返回 ESRCH
        return False
    except FileNotFoundError:
        # Linux 上说明刚被回收；没有 /proc 的平台（macOS）只能以 kill 的结果为准
        return not Path("/proc/self").exists()


def _spawn_grandchild_script(pid_file: Path) -> list[str]:
    """起一个会再派生后台孙进程的命令：只杀子进程的话孙进程会变成孤儿。"""
    return ["sh", "-c", f"sleep 30 & echo $! > {pid_file}; wait"]


async def _wait_for(path: Path) -> int:
    for _ in range(200):
        if path.exists() and path.read_text().strip():
            return int(path.read_text())
        await asyncio.sleep(0.01)
    raise AssertionError("孙进程没有起来")


async def _gone(pid: int) -> bool:
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if not _alive(pid):
            return True
        await asyncio.sleep(0.05)
    return False


async def test_run_collects_output() -> None:
    result = await process.run([sys.executable, "-c", "print('hi')"], timeout=10)
    assert result.returncode == 0 and result.stdout.strip() == b"hi"


async def test_timeout_ends_the_whole_process_group(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(process, "_TERM_GRACE", 0.5)
    pid_file = tmp_path / "grandchild.pid"
    with pytest.raises(process.ProcessTimeout):
        task = asyncio.create_task(process.run(_spawn_grandchild_script(pid_file), timeout=0.5))
        grandchild = await _wait_for(pid_file)
        await task
    assert await _gone(grandchild), "超时后孙进程还活着"


async def test_cancel_ends_the_whole_process_group(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(process, "_TERM_GRACE", 0.5)
    pid_file = tmp_path / "grandchild.pid"
    task = asyncio.create_task(process.run(_spawn_grandchild_script(pid_file), timeout=60))
    grandchild = await _wait_for(pid_file)
    started = time.monotonic()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert time.monotonic() - started < 3, "取消要秒级生效"
    assert await _gone(grandchild), "取消后孙进程还活着"

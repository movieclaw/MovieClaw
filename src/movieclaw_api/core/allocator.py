"""glibc 内存分配器调优：限制线程 arena 数量，按需把空闲页还给系统。

glibc 给每个分配内存的线程配一块独立的 arena（上限 8×CPU 核数），释放的内存
留在各自的 arena 里，被零星存活的小对象钉住，几乎还不回系统。后端线程很多：
aiosqlite 每个连接一条线程、anyio/uvloop 的线程池（图片缩放、文件读写）。最大的
临时分配是 SQLite 页缓存——WAL 模式下任何一次写入都会让其他连接在下次读时清空
整个页缓存，于是每个连接每轮都把页缓存重新分配一遍、再整体释放，几十个 arena
各自停在高水位。

NAS 实测进程常驻 1.36 GB，其中约 1 GB 是 44 个 arena 里的空闲块；本机按 NAS
访问日志构成回放，常驻 1420 MB 里真正在用的不到 200 MB。两项调整之后回放同一
负载，回收后常驻降到 400 MB 上下：

- ``M_ARENA_MAX=2``：所有线程共用 2 个 arena，一个线程释放的块别的线程能接着用；
- 后台线程按需 ``malloc_trim(0)``：把 arena 中间整页空闲的部分 ``madvise`` 还给
  内核（glibc 自己只会裁掉堆顶）。每 10 秒读一次 ``/proc/self/statm``（微秒级），
  常驻比上次回收后涨了 32 MB 以上才回收；空闲时什么都不做。回收在本线程里跑，
  ctypes 调用期间释放 GIL，不占事件循环。

只对 glibc 生效：macOS、musl 下找不到这两个函数，整体跳过。用户显式设置了
``MALLOC_ARENA_MAX`` 环境变量时尊重用户的值。
"""

from __future__ import annotations

import ctypes
import logging
import os
import sys
import threading
import time

logger = logging.getLogger(__name__)

#: glibc malloc.h 的 M_ARENA_MAX
_M_ARENA_MAX = -8
ARENA_MAX = 2
CHECK_INTERVAL_S = 10.0
TRIM_GROWTH_BYTES = 32 << 20


def _glibc() -> ctypes.CDLL | None:
    if not sys.platform.startswith("linux"):
        return None
    try:
        libc = ctypes.CDLL("libc.so.6")
    except OSError:
        return None
    if not hasattr(libc, "mallopt") or not hasattr(libc, "malloc_trim"):
        return None
    return libc


def rss_bytes() -> int:
    with open("/proc/self/statm", "rb") as f:
        return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")


def _trim_loop(libc: ctypes.CDLL, interval: float, growth: int) -> None:
    floor = rss_bytes()
    while True:
        time.sleep(interval)
        rss = rss_bytes()
        if rss - floor < growth:
            # 常驻自然回落（大块直接 munmap 的那部分）时跟着降，下一次按新起点算涨幅
            floor = min(floor, rss)
            continue
        started = time.perf_counter()
        libc.malloc_trim(0)
        floor = rss_bytes()
        logger.debug(
            "malloc_trim：%.1fms，常驻 %dMB → %dMB",
            (time.perf_counter() - started) * 1000,
            rss >> 20,
            floor >> 20,
        )


def tune_allocator(*, interval: float = CHECK_INTERVAL_S, growth: int = TRIM_GROWTH_BYTES) -> bool:
    """限制 arena 数量并启动按需回收线程；非 glibc 平台什么都不做，返回 False。

    要在大量线程开始分配内存之前调用：已经建好的 arena 不会被回收。
    """
    libc = _glibc()
    if libc is None:
        return False
    if "MALLOC_ARENA_MAX" not in os.environ:
        libc.mallopt(_M_ARENA_MAX, ARENA_MAX)
    threading.Thread(
        target=_trim_loop, args=(libc, interval, growth), name="malloc-trim", daemon=True
    ).start()
    return True

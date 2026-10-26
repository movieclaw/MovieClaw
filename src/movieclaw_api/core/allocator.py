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
  内核（glibc 自己只会裁掉堆顶）。每 10 秒用 ``mallinfo2`` 看一次 arena 里的空闲
  字节，比上次回收后多了 32 MB 以上才回收；空闲时什么都不做。回收在本线程里跑，
  ctypes 调用期间释放 GIL，不占事件循环。

  按空闲字节而不是常驻判断：回收若恰好赶在一批内存还在用的时候，按常驻算的起点
  会停在高位，这批内存之后释放了常驻也不会再涨，就一直还不回去。``madvise`` 过的
  块仍算空闲，所以回收后空闲字节不变，起点就是当时的值；之后新释放的才算增量。
  起点在启动回收线程之前取：线程开始跑时，调用方可能已经分配完又释放了一大批。

只对 glibc 生效：macOS、musl 下找不到这几个函数，整体跳过。用户显式设置了
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


class _MallInfo2(ctypes.Structure):
    _fields_ = [
        (name, ctypes.c_size_t)
        for name in (
            "arena",
            "ordblks",
            "smblks",
            "hblks",
            "hblkhd",
            "usmblks",
            "fsmblks",
            "uordblks",
            "fordblks",
            "keepcost",
        )
    ]


def _glibc() -> ctypes.CDLL | None:
    if not sys.platform.startswith("linux"):
        return None
    try:
        libc = ctypes.CDLL("libc.so.6")
    except OSError:
        return None
    if not all(hasattr(libc, f) for f in ("mallopt", "malloc_trim", "mallinfo2")):
        return None
    libc.mallinfo2.restype = _MallInfo2
    return libc


def free_bytes(libc: ctypes.CDLL) -> int:
    """各 arena 里空闲块的总字节数（含 ``madvise`` 还给内核、但还没被重新用上的）。"""
    return libc.mallinfo2().fordblks


def rss_bytes() -> int:
    with open("/proc/self/statm", "rb") as f:
        return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")


def _trim_loop(libc: ctypes.CDLL, interval: float, growth: int, floor: int) -> None:
    while True:
        time.sleep(interval)
        free = free_bytes(libc)
        if free - floor < growth:
            # 空闲块被重新用掉时跟着降，下一次按新起点算增量
            floor = min(floor, free)
            continue
        rss = rss_bytes()
        started = time.perf_counter()
        libc.malloc_trim(0)
        elapsed = time.perf_counter() - started
        floor = free_bytes(libc)
        logger.debug(
            "malloc_trim：%.1fms，常驻 %dMB → %dMB",
            elapsed * 1000,
            rss >> 20,
            rss_bytes() >> 20,
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
        target=_trim_loop,
        args=(libc, interval, growth, free_bytes(libc)),
        name="malloc-trim",
        daemon=True,
    ).start()
    return True

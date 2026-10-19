"""glibc 分配器调优：arena 数量受限、碎片化的空闲内存能按需还给系统。

在子进程里验证真实分配器行为（mallopt 只对之后新建的 arena 生效，不能污染 pytest 进程）。
"""

import json
import subprocess
import sys
from pathlib import Path
from textwrap import dedent
from types import SimpleNamespace

import pytest

from movieclaw_api.core import allocator

glibc_only = pytest.mark.skipif(allocator._glibc() is None, reason="只在 glibc（Linux）上生效")

# 8 条线程各自分配 4KB 块后释放绝大部分、每 64 块留一块钉住页——与后端线程池里
# SQLite 页缓存分配后整体释放、零星对象存活的形态相同
SCRIPT = dedent("""
    import ctypes, json, re, sys, threading, time
    from movieclaw_api.core import allocator

    tuned = sys.argv[1] == "tuned"
    if tuned:
        assert allocator.tune_allocator(interval=0.2, growth=8 << 20)
    libc = ctypes.CDLL("libc.so.6")
    libc.open_memstream.restype = ctypes.c_void_p
    libc.malloc_info.argtypes = [ctypes.c_int, ctypes.c_void_p]
    libc.fclose.argtypes = [ctypes.c_void_p]

    def arenas():
        buf, size = ctypes.c_char_p(), ctypes.c_size_t()
        stream = libc.open_memstream(ctypes.byref(buf), ctypes.byref(size))
        libc.malloc_info(0, stream)
        libc.fclose(stream)
        return len(re.findall(r'<heap nr=', buf.value.decode()))

    pinned = []
    barrier = threading.Barrier(8)
    # 峰值在全部块都还在用时取：回收线程可能在释放过程中就已经回收过一轮
    allocated, measured = threading.Barrier(9), threading.Barrier(9)
    def work():
        barrier.wait()
        blocks = [bytes(4096) for _ in range(12000)]
        allocated.wait()
        measured.wait()
        pinned.extend(blocks[::64])
        del blocks
    threads = [threading.Thread(target=work) for _ in range(8)]
    for t in threads: t.start()
    allocated.wait()
    peak = allocator.rss_bytes()
    measured.wait()
    for t in threads: t.join()
    time.sleep(1.5)
    print(json.dumps({"arenas": arenas(), "peak": peak, "after": allocator.rss_bytes()}))
""")


def _run(mode: str) -> dict:
    result = subprocess.run(
        [sys.executable, "-c", SCRIPT, mode],
        cwd=Path(__file__).resolve().parents[2],
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": "src"},
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


@glibc_only
def test_tuned_allocator_caps_arenas_and_returns_freed_memory():
    tuned = _run("tuned")
    assert tuned["arenas"] <= allocator.ARENA_MAX
    # 分配后只留 1/64：回收线程要把绝大部分还回去
    assert tuned["after"] < tuned["peak"] / 4, tuned


@glibc_only
def test_untuned_allocator_keeps_fragmented_memory():
    # 对照组：证明上面的断言确实依赖调优，而不是分配形态本身就会还内存
    plain = _run("plain")
    assert plain["arenas"] > allocator.ARENA_MAX
    assert plain["after"] > plain["peak"] * 3 / 4, plain


def test_memory_freed_after_a_trim_is_still_returned(monkeypatch):
    # 回收赶在一批内存还在用时：之后这批释放了，空闲字节又涨上来，要再回收一次
    readings = iter(mb << 20 for mb in [40, 40, 40, 35, 80, 80])
    trims = []

    class Libc:
        def mallinfo2(self):
            return SimpleNamespace(fordblks=next(readings))

        def malloc_trim(self, pad):
            trims.append(pad)

    monkeypatch.setattr(allocator.time, "sleep", lambda s: None)
    monkeypatch.setattr(allocator, "rss_bytes", lambda: 0)
    with pytest.raises(StopIteration):
        allocator._trim_loop(Libc(), 0, 32 << 20, 0)
    # 40：涨了 40MB 回收；40、35：没涨（被用掉一点，起点跟着降）；80：比 35 多 45MB，再回收
    assert len(trims) == 2


def test_noop_without_glibc(monkeypatch):
    monkeypatch.setattr(allocator, "_glibc", lambda: None)
    assert allocator.tune_allocator() is False

"""心跳里带的整机负载：NAS 在多台转码器之间挑谁接单时用（docs/design/remote-transcode.md §3.1）。

CPU 占用的平滑值达到 90%、内存告警会降低接单优先级；这份数据 15 秒不更新就不参与选择，
所以采样失败只是少一份参考，不影响接单。Windows 没有「热状态」这个量，恒报 0（正常）。
"""

from __future__ import annotations

import ctypes
import os
import sys


def memory_status() -> tuple[int, int]:
    """(物理内存总量, 可用量) 字节；拿不到返回 (0, 0)。"""
    if sys.platform == "win32":

        class _Status(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        status = _Status()
        status.dwLength = ctypes.sizeof(_Status)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):  # type: ignore[attr-defined]
            return int(status.ullTotalPhys), int(status.ullAvailPhys)
        return 0, 0
    try:
        page = os.sysconf("SC_PAGE_SIZE")
        return page * os.sysconf("SC_PHYS_PAGES"), page * os.sysconf("SC_AVPHYS_PAGES")
    except (ValueError, OSError, AttributeError):
        return 0, 0


def _cpu_times() -> tuple[int, int] | None:
    """(累计空闲, 累计总量)，单位随平台，只用于两次采样做差。"""
    if sys.platform == "win32":
        idle, kernel, user = (ctypes.c_ulonglong(), ctypes.c_ulonglong(), ctypes.c_ulonglong())
        if not ctypes.windll.kernel32.GetSystemTimes(  # type: ignore[attr-defined]
            ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)
        ):
            return None
        # kernel 时间里已经含了 idle
        return idle.value, kernel.value + user.value
    try:
        with open("/proc/stat", encoding="ascii") as handle:
            fields = [int(value) for value in handle.readline().split()[1:]]
    except (OSError, ValueError):
        return None
    return fields[3] + (fields[4] if len(fields) > 4 else 0), sum(fields)


class LoadSampler:
    """每次 ``sample()`` 给出心跳要带的 ``load``；两次采样之间的 CPU 占用取差值。"""

    def __init__(self) -> None:
        self._previous = _cpu_times()

    def sample(self) -> dict[str, float | int]:
        current = _cpu_times()
        cpu = 0.0
        if current is not None and self._previous is not None:
            idle = current[0] - self._previous[0]
            total = current[1] - self._previous[1]
            if total > 0:
                cpu = min(1.0, max(0.0, 1.0 - idle / total))
        self._previous = current
        total_memory, available = memory_status()
        used = max(0, total_memory - available)
        ratio = available / total_memory if total_memory else 1.0
        # 与 macOS 的内存压力同一档位语义：0 正常 / 1 告警 / 2 紧急
        pressure = 2 if ratio < 0.05 else 1 if ratio < 0.15 else 0
        return {
            "cpu": round(cpu, 3),
            "memory_pressure": pressure,
            "thermal_state": 0,
            "memory_used_bytes": used,
        }

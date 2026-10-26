"""进程控制里平台相关的两件事：暂停 / 恢复 ffmpeg，以及转码器自己没了时别留下孤儿 ffmpeg。

``job.pause`` / ``job.resume`` 是 NAS 的「领先量节流」：转码跑到播放进度前面太远就先挂起，
省下 GPU 与带宽。Windows 没有 SIGSTOP，用 ntdll 的 ``NtSuspendProcess`` / ``NtResumeProcess``
（Process Explorer 的「Suspend」就是它）。类 Unix 系统（开发、测试）走信号。
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys

_PROCESS_SUSPEND_RESUME = 0x0800

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _ntdll = ctypes.WinDLL("ntdll")
    _kernel32.OpenProcess.restype = wintypes.HANDLE
    _kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    _kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    _kernel32.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    _kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    _kernel32.SetInformationJobObject.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.LPVOID,
        wintypes.DWORD,
    ]
    _ntdll.NtSuspendProcess.argtypes = [wintypes.HANDLE]
    _ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]

    class _BasicLimit(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_longlong),
            ("PerJobUserTimeLimit", ctypes.c_longlong),
            ("LimitFlags", wintypes.DWORD),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", wintypes.DWORD),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", wintypes.DWORD),
            ("SchedulingClass", wintypes.DWORD),
        ]

    class _IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount",
        )]  # fmt: skip

    class _ExtendedLimit(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", _BasicLimit),
            ("IoInfo", _IoCounters),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
    _JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
    _job_handle: int | None = None

    def _kill_on_close_job() -> int | None:
        """进程级的一个作业对象：句柄随转码器进程关闭时，挂在它下面的 ffmpeg 一并被系统结束。"""
        global _job_handle
        if _job_handle is None:
            handle = _kernel32.CreateJobObjectW(None, None)
            if not handle:
                return None
            info = _ExtendedLimit()
            info.BasicLimitInformation.LimitFlags = _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if not _kernel32.SetInformationJobObject(
                handle,
                _JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                ctypes.byref(info),
                ctypes.sizeof(info),
            ):
                _kernel32.CloseHandle(handle)
                return None
            _job_handle = handle
        return _job_handle

    def _with_handle(pid: int, action) -> bool:  # type: ignore[no-untyped-def]
        handle = _kernel32.OpenProcess(_PROCESS_SUSPEND_RESUME, False, pid)
        if not handle:
            return False
        try:
            return action(handle) == 0
        finally:
            _kernel32.CloseHandle(handle)


def suspend(pid: int) -> bool:
    """挂起进程；成功返回 True。"""
    if sys.platform == "win32":
        return _with_handle(pid, _ntdll.NtSuspendProcess)
    with contextlib.suppress(OSError):
        os.kill(pid, signal.SIGSTOP)
        return True
    return False


def resume(pid: int) -> bool:
    if sys.platform == "win32":
        return _with_handle(pid, _ntdll.NtResumeProcess)
    with contextlib.suppress(OSError):
        os.kill(pid, signal.SIGCONT)
        return True
    return False


def kill_with_parent(process: subprocess.Popen) -> bool:
    """让 ffmpeg 跟着转码器一起走：转码器崩了、被任务管理器杀了，系统也会结束它。

    没有这一层，ffmpeg 会变成孤儿继续读源、占 GPU，直到 NAS 那边会话超时把源地址撤掉。
    作业对象创建失败（极老的系统、已在不允许嵌套的作业里）时返回 False，照常运行。
    """
    if sys.platform != "win32":
        return False
    job = _kill_on_close_job()
    if job is None:
        return False
    handle = _kernel32.OpenProcess(0x0001 | 0x0100 | 0x0800, False, process.pid)
    if not handle:
        return False
    try:
        return bool(_kernel32.AssignProcessToJobObject(job, handle))
    finally:
        _kernel32.CloseHandle(handle)

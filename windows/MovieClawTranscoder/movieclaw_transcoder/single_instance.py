"""Windows 单实例防呆锁：同机第二个转码器进程直接退出。

命名互斥体 ``Global\\MovieClawTranscoder`` 跨登录会话生效，随进程句柄存活——进程被杀也由内核回收，
不存在死锁。同机双开的真实代价是两份 ffmpeg 抢同一块 GPU、两个 WS 连接互相顶掉（同一个 worker_id
重连会让服务端判旧任务失败）。
"""

from __future__ import annotations

import sys

MUTEX_NAME = "Global\\MovieClawTranscoder"

#: 「已经有实例在跑，把它叫到前台」的自定义窗口消息（WM_APP + 2）。托盘窗口收得到，
#: 第二次启动的程序发完就退出——与 macOS 上重复打开 App 的行为一致（带窗口到前台，
#: 不弹错误框）。
WAKE_MESSAGE = 0x8002
TRAY_WINDOW_CLASS = "MovieClawTranscoderTray"

#: CreateMutexW 在互斥体已存在时返回有效句柄 + ERROR_ALREADY_EXISTS
_ERROR_ALREADY_EXISTS = 183

#: 进程生命周期内持有互斥体句柄：谁都不持有，句柄随垃圾回收关掉，锁就没了
_held: object | None = None


def acquire() -> bool:
    """拿全局互斥体；已有实例返回 False。非 Windows 恒成功；创建失败（极少见的权限问题）也放行，
    防呆锁不能升级成可用性风险。"""
    global _held
    if sys.platform != "win32":
        return True
    import ctypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateMutexW.restype = ctypes.c_void_p
    handle = kernel32.CreateMutexW(None, False, MUTEX_NAME)
    if not handle:
        return True
    if ctypes.get_last_error() == _ERROR_ALREADY_EXISTS:
        kernel32.CloseHandle(ctypes.c_void_p(handle))
        return False
    _held = handle
    return True


def wake_existing() -> bool:
    """把已经运行的那个实例叫到前台（窗口是托盘持有的隐藏窗口，它自己负责显示主窗口）。

    返回是否找到了正在运行的实例。非 Windows 恒 False。
    """
    if sys.platform != "win32":
        return False
    import ctypes

    user32 = ctypes.windll.user32
    hwnd = user32.FindWindowW(TRAY_WINDOW_CLASS, None)
    if not hwnd:
        return False
    user32.PostMessageW(hwnd, WAKE_MESSAGE, 0, 0)
    return True

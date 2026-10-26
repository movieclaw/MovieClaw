r"""开机自启：``HKCU\…\Run`` 里写一行「登录后拉起转码器」。

只对当前用户生效（安装也是 per-user），不碰注册表别处；非 Windows 上一律视为
未开启且不可开启（CI 在 Linux 上跑测试）。注册表路径可注入，测试写进自己的临时键。
"""

from __future__ import annotations

import sys

if sys.platform == "win32":
    import winreg

#: 默认键位（当前用户）；测试通过 ``key_path`` 参数写别的键
DEFAULT_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
VALUE_NAME = "MovieClawTranscoder"


def command(python_exe: str, launcher: str) -> str:
    """登录后要执行的命令行：运行时的 pythonw 拉起应用入口脚本。"""
    return f'"{python_exe}" "{launcher}"'


def enabled(key_path: str = DEFAULT_KEY) -> bool:
    if sys.platform != "win32":
        return False
    try:
        with _open(key_path) as key:
            winreg.QueryValueEx(key, VALUE_NAME)
        return True
    except OSError:
        return False


def enable(command_line: str, key_path: str = DEFAULT_KEY) -> bool:
    """写入自启项。返回是否写成功——组策略禁用、权限受限时返回 False，不抛异常。"""
    if sys.platform != "win32":
        return False
    try:
        with _open(key_path, write=True) as key:
            winreg.SetValueEx(key, VALUE_NAME, None, winreg.REG_SZ, command_line)
        return True
    except OSError:
        return False


def disable(key_path: str = DEFAULT_KEY) -> None:
    if sys.platform != "win32":
        return
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, VALUE_NAME)
    except OSError:
        pass


def _open(key_path: str, *, write: bool = False):
    if write:
        # Run 键平常不存在，第一次写要创建（OpenKey 只开已有的）
        return winreg.CreateKey(winreg.HKEY_CURRENT_USER, key_path)
    return winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_QUERY_VALUE)

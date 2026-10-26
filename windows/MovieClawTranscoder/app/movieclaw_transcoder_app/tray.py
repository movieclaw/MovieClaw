"""系统托盘图标：ctypes 直接调 Shell_NotifyIcon，不带第三方依赖。

自己的隐藏窗口收图标回调：左键单击/双击 → ``on_open``；右键 → 弹出菜单（每次弹出时
从 ``menu_items()`` 现取现建，勾选态跟状态走）。Explorer 重启后补回图标。
消息循环跑在自己的线程上；从别的线程改 tooltip 是安全的（Shell_NotifyIcon 线程无关）。
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import threading
from collections.abc import Callable
from dataclasses import dataclass

from movieclaw_transcoder import single_instance

WM_APP = 0x8000
_ICON_CALLBACK = WM_APP + 1
#: 第二次启动的程序发来的「把你叫到前台」。值由 single_instance 定义（发送方与接收方
#: 必须是同一个数），这里只做别名。
_WAKE_MESSAGE = single_instance.WAKE_MESSAGE
_MENU_FIRST_ID = WM_APP + 3

#: 窗口过程：`ctypes.wintypes` 没有 WNDPROC，要自己声明（返回值是 LRESULT）
WNDPROC = ctypes.WINFUNCTYPE(
    ctypes.c_ssize_t, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM
)

NIM_ADD, NIM_MODIFY, NIM_DELETE = 0, 1, 2
NIF_MESSAGE, NIF_ICON, NIF_TIP = 0x1, 0x2, 0x4
IMAGE_ICON = 1
LR_LOADFROMFILE = 0x10
WM_LBUTTONUP, WM_LBUTTONDBLCLK, WM_RBUTTONUP = 0x0202, 0x0203, 0x0205
WM_CLOSE, WM_DESTROY, WM_NULL = 0x0010, 0x0002, 0x0000
MF_STRING, MF_SEPARATOR, MF_CHECKED, MF_GRAYED = 0x0, 0x800, 0x8, 0x2
TPM_RIGHTBUTTON, TPM_NONOTIFY, TPM_RETURNCMD = 0x2, 0x80, 0x100


@dataclass(frozen=True)
class MenuItem:
    """托盘菜单的一项；``checked``/``enabled`` 控制勾选与置灰，``label`` 为空是分隔线。"""

    label: str
    action: str = ""
    checked: bool = False
    enabled: bool = True


def _declare_signatures() -> None:
    """显式声明返回值类型：64 位下 ctypes 默认按 C int 解读，HWND/HICON 会被截断。"""
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    user32.DefWindowProcW.restype = ctypes.c_ssize_t
    user32.DefWindowProcW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
    user32.CreateWindowExW.restype = wt.HWND
    user32.CreateWindowExW.argtypes = [
        wt.DWORD, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD,
        ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        wt.HWND, wt.HMENU, wt.HINSTANCE, ctypes.c_void_p,
    ]
    user32.LoadImageW.restype = wt.HANDLE
    user32.LoadImageW.argtypes = [
        wt.HINSTANCE, wt.LPCWSTR, wt.UINT, ctypes.c_int, ctypes.c_int, wt.UINT
    ]
    user32.CreatePopupMenu.restype = wt.HMENU
    user32.AppendMenuW.restype = wt.BOOL
    user32.AppendMenuW.argtypes = [wt.HMENU, wt.UINT, ctypes.c_size_t, wt.LPCWSTR]
    user32.TrackPopupMenu.restype = wt.BOOL
    user32.TrackPopupMenu.argtypes = [
        wt.HMENU, wt.UINT, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.HWND, ctypes.c_void_p
    ]
    user32.DestroyMenu.argtypes = [wt.HMENU]
    user32.SetForegroundWindow.argtypes = [wt.HWND]
    user32.GetCursorPos.argtypes = [ctypes.POINTER(wt.POINT)]
    user32.GetMessageW.restype = wt.BOOL
    user32.GetMessageW.argtypes = [ctypes.POINTER(wt.MSG), wt.HWND, wt.UINT, wt.UINT]
    user32.DestroyWindow.argtypes = [wt.HWND]
    user32.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
    kernel32.GetModuleHandleW.restype = wt.HMODULE


class TrayIcon:
    """托盘图标 + 菜单。``start()`` 起消息循环线程，``stop()`` 摘掉图标并收线程。"""

    def __init__(
        self,
        icon_path: str,
        tooltip: str,
        *,
        on_open: Callable[[], None],
        on_menu: Callable[[str], None],
        menu_items: Callable[[], list[MenuItem]],
        on_close: Callable[[], None] = lambda: None,
        log: Callable[[str], None] = lambda _message: None,
    ) -> None:
        self._icon_path = icon_path
        self._tooltip = tooltip[:127]
        self._on_open = on_open
        self._on_menu = on_menu
        self._menu_items = menu_items
        self._on_close = on_close
        self._log = log
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._hwnd: int = 0
        self._added = False
        self._taskbar_created = 0

    # -- 生命周期 -------------------------------------------------------------

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="tray", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        hwnd = self._hwnd
        if hwnd:
            ctypes.windll.user32.PostMessageW(wt.HWND(hwnd), WM_CLOSE, 0, 0)

    def set_tooltip(self, text: str) -> None:
        self._tooltip = text[:127]
        if self._added:
            self._notify(NIM_MODIFY)

    # -- Win32 消息循环 ---------------------------------------------------------

    def _run(self) -> None:  # pragma: no cover - Windows 界面线程，CI 上不执行
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32

        class WNDCLASSW(ctypes.Structure):
            _fields_ = [
                ("style", wt.UINT),
                ("lpfnWndProc", WNDPROC),
                ("cbClsExtra", ctypes.c_int),
                ("cbWndExtra", ctypes.c_int),
                ("hInstance", wt.HINSTANCE),
                ("hIcon", wt.HICON),
                ("hCursor", ctypes.c_void_p),
                ("hbrBackground", wt.HBRUSH),
                ("lpszMenuName", wt.LPCWSTR),
                ("lpszClassName", wt.LPCWSTR),
            ]

        class NOTIFYICONDATAW(ctypes.Structure):
            class _TIP(ctypes.Array):
                _type_ = wt.WCHAR
                _length_ = 128

            _fields_ = [
                ("cbSize", wt.DWORD),
                ("hWnd", wt.HWND),
                ("uID", wt.UINT),
                ("uFlags", wt.UINT),
                ("uCallbackMessage", wt.UINT),
                ("hIcon", wt.HICON),
                ("szTip", _TIP),
                ("dwState", wt.DWORD),
                ("dwStateMask", wt.DWORD),
                ("szInfo", ctypes.c_wchar * 256),
                ("uVersion", wt.UINT),
                ("szInfoTitle", ctypes.c_wchar * 64),
                ("dwInfoFlags", wt.DWORD),
            ]

        proc = WNDPROC(self._wnd_proc)
        _declare_signatures()
        icon_handle = user32.LoadImageW(
            None, self._icon_path, IMAGE_ICON, 0, 0, LR_LOADFROMFILE
        )
        self._icon = icon_handle
        self._nid_template = NOTIFYICONDATAW()
        self._nid_template.cbSize = ctypes.sizeof(NOTIFYICONDATAW)
        self._nid_template.uID = 1
        self._nid_template.uFlags = NIF_MESSAGE | NIF_TIP
        self._nid_template.uCallbackMessage = _ICON_CALLBACK
        if icon_handle:
            self._nid_template.uFlags |= NIF_ICON
            self._nid_template.hIcon = icon_handle

        class_name = "MovieClawTranscoderTray"
        wnd_class = WNDCLASSW()
        wnd_class.lpfnWndProc = proc
        wnd_class.lpszClassName = class_name
        instance = kernel32.GetModuleHandleW(None)
        wnd_class.hInstance = instance
        if not user32.RegisterClassW(ctypes.byref(wnd_class)):
            self._log("托盘注册失败，转码继续（界面菜单不可用）")
            return
        self._hwnd = user32.CreateWindowExW(
            0, class_name, "MovieClawTranscoderTray", 0, 0, 0, 0, 0, None, None, instance, None
        )
        self._taskbar_created = user32.RegisterWindowMessageW("TaskbarCreated")
        self._notify(NIM_ADD)
        self._added = True

        msg = wt.MSG()
        while not self._stop_event.is_set():
            result = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
            if result <= 0:
                break
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
        if self._added:
            self._notify(NIM_DELETE)
            self._added = False
        if icon_handle:
            user32.DestroyIcon(icon_handle)

    def _wnd_proc(self, hwnd: int, message: int, wparam: int, lparam: int) -> int:
        if message == self._taskbar_created and self._added:
            # Explorer 重启后托盘里的图标全部消失：补回来
            self._notify(NIM_ADD)
        elif message == WM_CLOSE:
            # 外部请求退出（安装器卸载前会按类名找到这个窗口发 WM_CLOSE）：走完整退出流程
            try:
                self._on_close()
            except Exception as exc:
                self._log(f"退出请求处理失败：{exc}")
            ctypes.windll.user32.DestroyWindow(hwnd)
        elif message == WM_DESTROY:
            ctypes.windll.user32.PostQuitMessage(0)
        elif message == _WAKE_MESSAGE:
            # 用户又点了一次开始菜单/桌面图标：把已有的窗口带到前台，不开第二个进程
            try:
                self._on_open()
            except Exception as exc:
                self._log(f"唤起窗口失败：{exc}")
        elif message == _ICON_CALLBACK:
            if lparam in (WM_LBUTTONUP, WM_LBUTTONDBLCLK):
                try:
                    self._on_open()
                except Exception as exc:  # 界面异常不该拖垮托盘线程
                    self._log(f"打开窗口失败：{exc}")
            elif lparam == WM_RBUTTONUP:
                self._popup_menu()
        return ctypes.windll.user32.DefWindowProcW(hwnd, message, wparam, lparam)

    def _notify(self, action: int) -> None:
        nid = self._nid_template
        nid.hWnd = self._hwnd
        tip = self._tooltip
        nid.szTip = (tip + "\0" * 128)[:128]
        if not ctypes.windll.shell32.Shell_NotifyIconW(action, ctypes.byref(nid)):
            self._log("托盘图标更新失败")

    def _popup_menu(self) -> None:  # pragma: no cover - Windows 界面线程
        user32 = ctypes.windll.user32
        menu = user32.CreatePopupMenu()
        actions: dict[int, str] = {}
        next_id = _MENU_FIRST_ID
        try:
            for item in self._menu_items():
                if not item.label:
                    user32.AppendMenuW(menu, MF_SEPARATOR, 0, None)
                    continue
                flags = MF_STRING | (MF_CHECKED if item.checked else 0)
                if not item.enabled:
                    flags |= MF_GRAYED
                user32.AppendMenuW(menu, flags, next_id, item.label)
                actions[next_id] = item.action
                next_id += 1
            # TrackPopupMenu 会吃掉这次点击：先把前台焦点给自己，菜单外的点击才能正常落回
            user32.SetForegroundWindow(self._hwnd)
            point = wt.POINT()
            user32.GetCursorPos(ctypes.byref(point))
            chosen = user32.TrackPopupMenu(
                menu,
                TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_RETURNCMD,
                point.x,
                point.y,
                0,
                self._hwnd,
                None,
            )
        finally:
            user32.DestroyMenu(menu)
            user32.PostMessageW(self._hwnd, WM_NULL, 0, 0)
        action = actions.get(chosen)
        if action:
            try:
                self._on_menu(action)
            except Exception as exc:  # 界面异常不该拖垮托盘线程
                self._log(f"托盘菜单动作失败：{exc}")

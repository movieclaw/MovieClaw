"""入口：安装版经 ``MovieClawTranscoder.pyw`` 拉起，开发时 ``python -m movieclaw_transcoder_app``。

进程结构：主线程跑 tkinter 主循环，托盘消息循环和转码内核各在一条 daemon 线程上。
任何界面动作都先汇到主线程再改状态。
"""

from __future__ import annotations

import argparse
import contextlib
import logging
import logging.handlers
import os
import signal
import sys
import threading
import traceback
from collections.abc import Sequence
from pathlib import Path

from movieclaw_transcoder import single_instance
from movieclaw_transcoder.config import app_dir, load_config, normalize_server

from . import __version__, autostart
from .model import AppModel, Snapshot
from .tray import MenuItem, TrayIcon
from .window import AppWindow

_TOOLTIP_PREFIX = "MovieClaw 转码器"


def _setup_logging() -> None:
    """与命令行版写同一个 ``transcoder.log``：单实例互斥保证两进程不会同时写。"""
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(message)s", "%H:%M:%S")
    try:
        app_dir().mkdir(parents=True, exist_ok=True)
        handler = logging.handlers.RotatingFileHandler(
            app_dir() / "transcoder.log", maxBytes=1_000_000, backupCount=3, encoding="utf-8"
        )
        handler.setFormatter(fmt)
        root.addHandler(handler)
    except OSError:
        pass
    if sys.stdout is not None:  # pythonw 没有标准输出；开发时能看到控制台
        console = logging.StreamHandler(sys.stdout)
        console.setFormatter(fmt)
        root.addHandler(console)


def _icon_path() -> str:
    return str(Path(__file__).with_name("icon.ico"))


def _autostart_command() -> str:
    """登录后拉起自己的命令行。安装版以脚本方式启动（pythonw + .pyw），开发时退回 -m。"""
    argv0 = sys.argv[0] if sys.argv else ""
    if argv0.endswith((".pyw", ".py")):
        return autostart.command(sys.executable, os.path.abspath(argv0))
    return f'"{sys.executable}" -m movieclaw_transcoder_app'


def _tooltip(snapshot: Snapshot) -> str:
    if snapshot.phase == "onboarding":
        return f"{_TOOLTIP_PREFIX}：还没有配对——双击图标开始"
    if snapshot.phase == "approving":
        return f"{_TOOLTIP_PREFIX}：等网页批准（{snapshot.pairing_code}）"
    if snapshot.connection == "online":
        if snapshot.active_jobs > 0:
            return f"{_TOOLTIP_PREFIX}：正在转码 {snapshot.active_jobs} 路"
        return f"{_TOOLTIP_PREFIX}：已连上 NAS"
    if snapshot.connection == "connecting":
        return f"{_TOOLTIP_PREFIX}：正在连接 NAS…"
    reason = snapshot.connection_reason or "连接断开"
    return f"{_TOOLTIP_PREFIX}：{reason}"[:127]


def _menu_items(snapshot: Snapshot) -> list[MenuItem]:
    pairing = snapshot.phase in ("onboarding", "approving")
    return [
        MenuItem("打开 MovieClaw 转码器", "open"),
        MenuItem("立即重连", "reconnect", enabled=snapshot.phase == "ready"),
        MenuItem("重新配对…", "reset", enabled=not pairing),
        MenuItem("开机自启", "autostart", checked=snapshot.autostart),
        MenuItem("打开日志", "logs"),
        MenuItem("", ""),
        MenuItem("退出", "quit"),
    ]


def _parser() -> argparse.ArgumentParser:
    """命令行参数只为排障与自动化保留：正常使用时双击应用什么都不用给。"""
    parser = argparse.ArgumentParser(
        prog="movieclaw_transcoder_app",
        description="MovieClaw 转码器（Windows 应用）：托盘 + 窗口，打开就能配对。",
    )
    parser.add_argument("--server", help="直接指定 NAS 地址（跳过发现与填写，写进配置）")
    parser.add_argument("--ffmpeg", help="直接指定 ffmpeg.exe（跳过官方下载）")
    parser.add_argument(
        "--headless", action="store_true", help="不开窗口与托盘，配对码只打日志（自动化/排障用）"
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    _setup_logging()
    log = logging.getLogger("movieclaw_transcoder_app")

    if not single_instance.acquire():
        # 已经有一个在跑：把它叫到前台，自己不弹错误框（与 Mac 上重复打开 App 一致）
        if single_instance.wake_existing():
            log.info("已有实例在运行，已请它显示主窗口")
            return 0
        message = "MovieClaw 转码器已经在这台电脑上运行了（同机只允许一个）"
        log.error(message)
        _alert(message)
        return 3

    config = load_config()
    changed = False
    if args.server:
        config.server, changed = normalize_server(args.server), True
    if args.ffmpeg:
        config.ffmpeg, changed = args.ffmpeg, True
    if changed:
        config.save()

    headless = args.headless or os.environ.get("MOVIECLAW_APP_HEADLESS") == "1"
    model = AppModel(
        log=log.info, autostart_command=_autostart_command(), headless=headless
    )
    if headless:
        return _run_headless(model, log)

    window = AppWindow(
        model,
        icon_path=_icon_path(),
        on_tick=lambda snapshot: tray.set_tooltip(_tooltip(snapshot)),
        version=__version__,
    )
    tray = TrayIcon(
        _icon_path(),
        f"{_TOOLTIP_PREFIX} 启动中…",
        on_open=window.show,
        on_menu=_handle_menu(model, window),
        menu_items=lambda: _menu_items(model.snapshot()),
        on_close=window.request_quit,
        log=log.info,
    )

    model.start()
    tray.start()
    try:
        window.run()  # 阻塞到用户从托盘选「退出」
    finally:
        log.info("正在退出…")
        model.shutdown()
        tray.stop()
    return 0


def _run_headless(model: AppModel, log: logging.Logger) -> int:
    """没有窗口与托盘：起 model 后等到 Ctrl+C / 进程被终止。"""
    model.start()
    stop = threading.Event()
    for signal_name in ("SIGINT", "SIGBREAK", "SIGTERM"):
        number = getattr(signal, signal_name, None)
        if number is not None:
            with contextlib.suppress(ValueError, OSError):
                signal.signal(number, lambda *_: stop.set())
    log.info("无界面模式：配对码与服务状态只写日志（%s）", app_dir() / "transcoder.log")
    try:
        while not stop.wait(0.5):
            pass
    except KeyboardInterrupt:
        pass
    finally:
        log.info("正在退出…")
        model.shutdown()
    return 0


def _handle_menu(model: AppModel, window: AppWindow):
    def handle(action: str) -> None:
        if action == "open":
            window.show()
        elif action == "reconnect":
            model.reconnect()
        elif action == "reset":
            model.reset_pairing()
            window.show()
        elif action == "autostart":
            model.toggle_autostart()
        elif action == "logs":
            model.open_logs()
        elif action == "quit":
            window.request_quit()

    return handle


def _alert(message: str) -> None:
    """没有界面可依托时的最后出口：一个系统消息框。"""
    with contextlib.suppress(Exception):
        import ctypes

        ctypes.windll.user32.MessageBoxW(None, message, "MovieClaw 转码器", 0x10)


def _run() -> int:
    try:
        return main()
    except Exception:
        # pythonw 下没有控制台，崩了不能无声无息：写 crash.log 并弹框说一声
        detail = traceback.format_exc()
        with contextlib.suppress(OSError):
            (app_dir() / "crash.log").write_text(detail, encoding="utf-8")
        _alert(f"MovieClaw 转码器启动失败，详情见 {app_dir() / 'crash.log'}\n\n{detail[-600:]}")
        return 1


if __name__ == "__main__":
    sys.exit(_run())
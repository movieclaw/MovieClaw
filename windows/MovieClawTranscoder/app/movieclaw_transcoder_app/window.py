"""主窗口：没配对时是三步引导（连接 → 批准 → 完成），配对后是状态页。

界面只做两件事：每 300 毫秒读一次 :meth:`AppModel.snapshot` 刷新文字；把用户动作
（连接并配对、取消、重试……）转成对 model 的方法调用。关窗不是退出——缩回托盘。
"""

from __future__ import annotations

import contextlib
import threading
import time
import tkinter as tk
from collections.abc import Callable
from tkinter import filedialog, messagebox, ttk

from . import discovery
from .model import AppModel, Snapshot

POLL_MS = 300

_ERROR_FG = "#c0392b"
_OK_FG = "#2e7d32"
_MUTED_FG = "#666666"


class AppWindow:
    """一个窗口三种视图。``on_tick`` 每次刷新后调用（托盘 tooltip 跟着更新）。"""

    def __init__(
        self,
        model: AppModel,
        *,
        icon_path: str | None = None,
        on_tick: Callable[[Snapshot], None] = lambda _snapshot: None,
        version: str = "",
    ) -> None:
        self._model = model
        self._on_tick = on_tick
        self._root = tk.Tk()
        self._root.title("MovieClaw 转码器")
        self._root.resizable(False, False)
        self._root.minsize(452, 0)  # 折行宽度按 420 排版；高度随内容
        self._root.protocol("WM_DELETE_WINDOW", self.hide)
        if icon_path:
            with contextlib.suppress(tk.TclError):
                self._root.iconbitmap(icon_path)
        self._phase_built = ""
        self._server_var = tk.StringVar()
        self._autostart_var = tk.BooleanVar()
        self._discovered: list[discovery.DiscoveredServer] = []
        self._version = version

        container = ttk.Frame(self._root, padding=16)
        container.pack(fill="both", expand=True)
        self._container = container

    # -- 显示与轮询 -------------------------------------------------------------

    def run(self) -> None:
        """进入主循环（阻塞到进程退出）。"""
        self.show()
        self._poll()
        self._root.mainloop()

    def show(self) -> None:
        self._root.deiconify()
        self._root.lift()
        self._root.focus_force()

    def hide(self) -> None:
        self._root.withdraw()

    def request_quit(self) -> None:
        """托盘「退出」在托盘线程上：汇到主线程再结束主循环。"""
        self._root.after(0, self._root.quit)

    def _poll(self) -> None:
        try:
            snapshot = self._model.snapshot()
            self._on_tick(snapshot)
            self._render(snapshot)
        except Exception:  # 界面刷新失败不退出，下一轮再试
            pass
        self._root.after(POLL_MS, self._poll)

    # -- 渲染 -------------------------------------------------------------------

    def _render(self, snapshot: Snapshot) -> None:
        if snapshot.phase != self._phase_built:
            self._phase_built = snapshot.phase
            self._build(snapshot)
            return
        builder = {
            "onboarding": self._update_onboarding,
            "approving": self._update_approving,
            "ready": self._update_ready,
        }.get(snapshot.phase)
        if builder is not None:
            builder(snapshot)

    def _clear(self) -> None:
        for child in self._container.winfo_children():
            child.destroy()

    def _title(self, text: str, subtitle: str = "") -> None:
        ttk.Label(self._container, text=text, font=("", 13, "bold")).pack(anchor="w")
        if subtitle:
            ttk.Label(self._container, text=subtitle, foreground=_MUTED_FG, wraplength=420).pack(
                anchor="w", pady=(2, 10)
            )
        else:
            ttk.Label(self._container, text="").pack(pady=(0, 10))

    # 引导：连接 ------------------------------------------------------------

    def _build(self, snapshot: Snapshot) -> None:
        self._clear()
        if snapshot.phase == "onboarding":
            self._build_onboarding(snapshot)
        elif snapshot.phase == "approving":
            self._build_approving(snapshot)
        else:
            self._build_ready(snapshot)
        if self._version:
            ttk.Label(
                self._container, text=f"MovieClaw 转码器 {self._version}", foreground=_MUTED_FG
            ).pack(anchor="e", pady=(10, 0))

    def _build_onboarding(self, snapshot: Snapshot) -> None:
        self._title(
            "连接你的 NAS",
            "MovieClaw 转码器把这台电脑的 NVIDIA 显卡借给 NAS：4K HDR、字幕烧录这些"
            " NAS 扛不住的转码交给它，媒体文件不会存到这台电脑上。",
        )
        if self._server_var.get() == "":
            self._server_var.set(snapshot.server)
        self._found_frame = ttk.LabelFrame(self._container, text="在局域网里找到了", padding=8)
        self._found_label = ttk.Label(self._found_frame, text="正在搜索…", foreground=_MUTED_FG)
        self._found_label.pack(anchor="w")
        self._found_frame.pack(fill="x", pady=(0, 10))
        ttk.Label(self._container, text="NAS 地址").pack(anchor="w")
        entry = ttk.Entry(self._container, textvariable=self._server_var, width=42)
        entry.pack(anchor="w", pady=(2, 4))
        entry.focus_set()
        self._error_label = ttk.Label(
            self._container, text="", foreground=_ERROR_FG, wraplength=420
        )
        self._error_label.pack(anchor="w", fill="x")
        ttk.Button(self._container, text="连接并配对", command=self._pair_clicked).pack(
            anchor="w", pady=(8, 0)
        )
        self._start_discovery()

    def _start_discovery(self) -> None:
        def run() -> None:
            found = discovery.find()
            self._root.after(0, lambda: self._apply_discovery(found))

        threading.Thread(target=run, name="discover", daemon=True).start()

    def _apply_discovery(self, found: list[discovery.DiscoveredServer]) -> None:
        self._discovered = found
        for child in self._found_frame.winfo_children():
            child.destroy()
        if not found:
            self._found_label = ttk.Label(
                self._found_frame,
                text="没找到。不在同一局域网，或 NAS 关了发现——直接填地址就行。",
                foreground=_MUTED_FG,
                wraplength=400,
            )
            self._found_label.pack(anchor="w")
            return
        for server in found:
            text = f"{server.name}（{server.address}）" if server.name else server.address
            ttk.Radiobutton(
                self._found_frame,
                text=text,
                value=server.address,
                variable=self._server_var,
            ).pack(anchor="w")
        # 与 macOS 转码器同一条默认：只找到一台且地址框空着，就替用户预选
        if len(found) == 1 and self._server_var.get() == "":
            self._server_var.set(found[0].address)

    def _update_onboarding(self, snapshot: Snapshot) -> None:
        self._error_label.config(text=snapshot.pairing_error)

    def _pair_clicked(self) -> None:
        self._error_label.config(text="")
        self._model.pair(self._server_var.get())

    # 引导：批准 ------------------------------------------------------------

    def _build_approving(self, snapshot: Snapshot) -> None:
        ttk.Label(self._container, text="等网页批准", font=("", 13, "bold")).pack(anchor="w")
        ttk.Label(self._container, text="").pack(pady=(0, 10))
        self._code_label = tk.Label(
            self._container,
            text=snapshot.pairing_code,
            font=("Consolas", 26, "bold"),
            fg="#1a1a1a",
        )
        self._code_label.pack(pady=(2, 8))
        ttk.Label(
            self._container,
            text=(
                "浏览器已打开批准页。用管理员账号核对上面的配对码并批准"
                "（转码器只能由管理员批准）。批准页没打开的话，到 NAS 网页"
                "「设置 → 设备」输入这个配对码。"
            ),
            wraplength=420,
        ).pack(anchor="w")
        self._countdown_label = ttk.Label(self._container, text="", foreground=_MUTED_FG)
        self._countdown_label.pack(anchor="w", pady=(8, 0))
        ttk.Button(self._container, text="取消", command=self._model.cancel_pairing).pack(
            anchor="w", pady=(10, 0)
        )

    def _update_approving(self, snapshot: Snapshot) -> None:
        if snapshot.pairing_code:
            self._code_label.config(text=snapshot.pairing_code)
        remaining = int(snapshot.pairing_deadline - time.time())
        if remaining <= 0:
            self._countdown_label.config(text="等批准中…")
            return
        self._countdown_label.config(
            text=f"等待批准 · {remaining // 60} 分 {remaining % 60:02d} 秒后过期"
        )

    # 状态页 ----------------------------------------------------------------

    def _build_ready(self, snapshot: Snapshot) -> None:
        self._connection_label = ttk.Label(self._container, text="", font=("", 11))
        self._connection_label.pack(anchor="w")
        self._connection_detail = ttk.Label(self._container, text="", foreground=_MUTED_FG)
        self._connection_detail.pack(anchor="w")
        self._job_label = ttk.Label(self._container, text="", foreground=_OK_FG)
        self._job_label.pack(anchor="w", pady=(2, 8))
        self._ffmpeg_label = ttk.Label(self._container, text="", wraplength=420)
        self._ffmpeg_label.pack(anchor="w", fill="x")
        self._ffmpeg_progress = ttk.Progressbar(self._container, length=380, maximum=1.0)
        self._ffmpeg_buttons = ttk.Frame(self._container)
        ttk.Button(
            self._ffmpeg_buttons, text="重试", command=self._model.retry_ffmpeg
        ).pack(side="left", padx=(0, 8))
        ttk.Button(self._ffmpeg_buttons, text="手动选择 ffmpeg…", command=self._choose_ffmpeg).pack(
            side="left"
        )
        self._ffmpeg_actions = ttk.Frame(self._container)
        ttk.Button(
            self._ffmpeg_actions, text="更换 ffmpeg…", command=self._choose_ffmpeg
        ).pack(side="left", padx=(0, 8))
        ttk.Button(
            self._ffmpeg_actions,
            text="断开并重新配置…",
            command=self._reset_clicked,
        ).pack(side="left")
        self._ffmpeg_actions.pack(anchor="w", pady=(8, 0))
        self._autostart_var.set(snapshot.autostart)
        ttk.Checkbutton(
            self._container,
            text="开机自启",
            variable=self._autostart_var,
            command=lambda: self._model.set_autostart(self._autostart_var.get()),
        ).pack(anchor="w", pady=(10, 0))
        self._log_button = ttk.Button(
            self._container, text="打开日志", command=self._model.open_logs
        )
        self._log_button.pack(anchor="w", pady=(8, 0))

    def _update_ready(self, snapshot: Snapshot) -> None:
        # 托盘菜单也能开关自启：勾选框跟实际状态走
        if snapshot.autostart != self._autostart_var.get():
            self._autostart_var.set(snapshot.autostart)
        self._render_connection(snapshot)
        self._render_jobs(snapshot)
        self._render_ffmpeg(snapshot)

    def _render_connection(self, snapshot: Snapshot) -> None:
        if snapshot.connection == "online":
            self._connection_label.config(
                text=f"● 已连上 {snapshot.server}", foreground=_OK_FG
            )
            self._connection_detail.config(
                text=f"并发上限 {snapshot.max_jobs} 路（NAS 下发）", foreground=_MUTED_FG
            )
        elif snapshot.connection == "connecting":
            self._connection_label.config(text="○ 正在连接 NAS…", foreground=_MUTED_FG)
            self._connection_detail.config(text="")
        else:
            self._connection_label.config(
                text=f"● 连接断开：{snapshot.connection_reason}", foreground=_ERROR_FG
            )
            self._connection_detail.config(
                text=snapshot.connection_hint, foreground=_MUTED_FG
            )

    def _render_jobs(self, snapshot: Snapshot) -> None:
        if snapshot.connection != "online":
            self._job_label.config(text="")
            return
        if snapshot.active_jobs > 0:
            name = f"（{snapshot.job_name}）" if snapshot.job_name else ""
            self._job_label.config(text=f"正在转码：{snapshot.active_jobs} 路{name}")
        else:
            self._job_label.config(text="空闲——有播放需要硬件转码时会自动接单")

    def _render_ffmpeg(self, snapshot: Snapshot) -> None:
        state = snapshot.ffmpeg_state
        self._ffmpeg_progress.pack_forget()
        self._ffmpeg_buttons.pack_forget()
        if state == "ready":
            gpu = f" · {snapshot.gpu}" if snapshot.gpu else ""
            self._ffmpeg_label.config(
                text=f"ffmpeg {snapshot.ffmpeg_version}{gpu}", foreground=_MUTED_FG
            )
        elif state == "downloading":
            self._ffmpeg_label.config(
                text=f"正在下载 jellyfin-ffmpeg {snapshot.ffmpeg_version}…", foreground=_MUTED_FG
            )
            self._ffmpeg_progress.pack(anchor="w", pady=(4, 0))
            self._ffmpeg_progress.config(value=snapshot.ffmpeg_progress)
        elif state == "error":
            self._ffmpeg_label.config(text=snapshot.ffmpeg_error, foreground=_ERROR_FG)
            self._ffmpeg_buttons.pack(anchor="w", pady=(4, 0))
        elif state == "missing":
            self._ffmpeg_label.config(text="正在准备 ffmpeg…", foreground=_MUTED_FG)
        else:
            self._ffmpeg_label.config(text="正在检查 ffmpeg 与显卡…", foreground=_MUTED_FG)

    def _choose_ffmpeg(self) -> None:
        path = filedialog.askopenfilename(
            title="选择 ffmpeg.exe（推荐 jellyfin-ffmpeg）",
            filetypes=[("ffmpeg", "ffmpeg.exe"), ("所有文件", "*.*")],
        )
        if path:
            self._model.choose_ffmpeg(path)

    def _reset_clicked(self) -> None:
        if messagebox.askyesno(
            "断开并重新配置",
            "会在 NAS 上注销这台电脑的凭证并清掉本机令牌，然后重新走一遍配对。继续吗？",
        ):
            self._model.reset_pairing()

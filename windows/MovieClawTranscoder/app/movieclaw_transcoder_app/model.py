"""应用编排：把「配对 → ffmpeg → 转码内核」三件事串成一台小状态机。

这一层不 import 任何界面库：托盘与窗口只读 :meth:`AppModel.snapshot` 每 300 毫秒
刷新一次，动作（配对、取消、重连……）直接调方法。所有跨线程状态都收在一把锁后面；
线程是各自的 daemon，退出时不必逐个等待。

阶段（``phase``）：``onboarding``（没配对，窗口显示引导）→ ``approving``（等网页批准）
→ ``ready``（已配对，内核连接状态见 ``connection``）。
"""

from __future__ import annotations

import contextlib
import os
import sys
import threading
import time
import webbrowser
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from movieclaw_transcoder.client import TranscoderClient
from movieclaw_transcoder.config import (
    Config,
    app_dir,
    default_worker_id,
    load_config,
    normalize_server,
)
from movieclaw_transcoder.pairing import (
    PairingError,
    check_server,
    request_pairing,
    revoke_credential,
    wait_for_approval,
)
from movieclaw_transcoder.probe import Capabilities, FfmpegProblem, probe

from . import autostart, ffmpeg_install

#: 凭证失效 / 开关没开时的行动提示（与 CLI 的措辞一致）
_REJECTION_HINTS = {
    "auth": "这台电脑的授权已失效，请用托盘菜单「重新配对」",
    "remote_disabled": "请在 NAS 网页「应用 → 远程转码」里打开开关",
}


@dataclass(frozen=True)
class Snapshot:
    """界面消费的全部状态；字段都是不可变的，拿走随便用。"""

    phase: str
    server: str = ""
    pairing_code: str = ""
    pairing_deadline: float = 0.0
    pairing_error: str = ""
    connection: str = "offline"
    connection_reason: str = ""
    connection_hint: str = ""
    max_jobs: int = 0
    active_jobs: int = 0
    job_name: str = ""
    ffmpeg_state: str = "checking"  # checking | missing | downloading | ready | error
    ffmpeg_progress: float = 0.0  # 0..1；总大小未知时停在 0
    ffmpeg_version: str = ""
    ffmpeg_path: str = ""
    ffmpeg_error: str = ""
    gpu: str = ""
    autostart: bool = False


class AppModel:
    """一次运行的全部编排。方法都从界面线程调用；内部起 daemon 线程干活。"""

    def __init__(
        self,
        *,
        log: Callable[[str], None] = lambda _message: None,
        probe_fn: Callable[..., Capabilities] = probe,
        browser_open: Callable[[str], None] = lambda url: webbrowser.open(url),
        autostart_command: str = "",
        headless: bool = False,
    ) -> None:
        self._log = log
        #: 无界面模式（测试与排障用）：不弹浏览器、配对码只走日志
        self.headless = headless
        self._probe_fn = probe_fn
        self._browser_open = browser_open
        self._autostart_command = autostart_command
        self._lock = threading.Lock()
        self._config = Config()
        self._phase = "onboarding"
        self._pairing_code = ""
        self._pairing_deadline = 0.0
        self._pairing_error = ""
        self._connection = "offline"
        self._connection_reason = ""
        self._connection_hint = ""
        self._max_jobs = 0
        self._active_jobs = 0
        self._job_name = ""
        self._ffmpeg_state = "checking"
        self._ffmpeg_progress = 0.0
        self._ffmpeg_version = ""
        self._ffmpeg_path = ""
        self._ffmpeg_error = ""
        self._gpu = ""
        self._capabilities: Capabilities | None = None
        self._cancelled_pairing = False
        self._pairing_cancel = threading.Event()
        self._pairing_thread: threading.Thread | None = None
        self._ffmpeg_busy = False
        self._client: TranscoderClient | None = None
        self._client_thread: threading.Thread | None = None
        self._versions_root = app_dir() / "ffmpeg" / "versions"

    # -- 状态 -----------------------------------------------------------------

    def snapshot(self) -> Snapshot:
        with self._lock:
            return Snapshot(
                phase=self._phase,
                server=self._config.server,
                pairing_code=self._pairing_code,
                pairing_deadline=self._pairing_deadline,
                pairing_error=self._pairing_error,
                connection=self._connection,
                connection_reason=self._connection_reason,
                connection_hint=self._connection_hint,
                max_jobs=self._max_jobs,
                active_jobs=self._active_jobs,
                job_name=self._job_name,
                ffmpeg_state=self._ffmpeg_state,
                ffmpeg_progress=self._ffmpeg_progress,
                ffmpeg_version=self._ffmpeg_version,
                ffmpeg_path=self._ffmpeg_path,
                ffmpeg_error=self._ffmpeg_error,
                gpu=self._gpu,
                autostart=autostart.enabled(),
            )

    # -- 启动与关停 -----------------------------------------------------------

    def start(self) -> None:
        """开机流程：已配对就直接往 ready 走；否则停在引导。

        地址已经知道（上次配到一半、或命令行给了 ``--server``）却没有令牌时，直接发起配对：
        用户双击打开就是等批准，不必再手点一次「连接并配对」。
        """
        self._config = load_config()
        if not self._config.worker_id:
            self._config.worker_id = default_worker_id()
            self._config.save()
        with self._lock:
            self._ffmpeg_state = "checking"
        if self._config.token and self._config.server:
            with self._lock:
                self._phase = "ready"
            self._ensure_ffmpeg()
        else:
            with self._lock:
                self._phase = "onboarding"
                self._ffmpeg_state = "checking"
            if self._config.server:
                self.pair(self._config.server)

    def shutdown(self) -> None:
        self._pairing_cancel.set()
        with self._lock:
            client = self._client
        if client is not None:
            client.stop()

    # -- 动作（界面线程调用） ---------------------------------------------------

    def pair(self, server_text: str) -> None:
        """引导页「连接并配对」。正在配对时忽略重复点击。"""
        if self._pairing_thread is not None and self._pairing_thread.is_alive():
            return
        server = normalize_server(server_text)
        if not server:
            with self._lock:
                self._pairing_error = "请填 NAS 地址（如 http://192.168.1.5:3000）"
            return
        self._pairing_cancel = threading.Event()
        with self._lock:
            self._cancelled_pairing = False
            self._pairing_error = ""
        self._pairing_thread = threading.Thread(
            target=self._pair_run, args=(server,), name="pairing", daemon=True
        )
        self._pairing_thread.start()

    def cancel_pairing(self) -> None:
        """「批准」页的取消：停轮询，回引导页。"""
        self._pairing_cancel.set()

    def reconnect(self) -> None:
        """踢一下内核连接：停掉重开。只在 ffmpeg 就绪时有效。"""
        with self._lock:
            if self._phase != "ready" or self._capabilities is None:
                return
        self._stop_client()
        self._start_client()

    def reset_pairing(self) -> None:
        """「断开并重新配置」：注销 NAS 侧凭证、清本机令牌，回引导页。"""
        if self._pairing_thread is not None and self._pairing_thread.is_alive():
            return
        self._stop_client()
        self._pairing_cancel = threading.Event()
        self._pairing_thread = threading.Thread(
            target=self._reset_run, name="reset", daemon=True
        )
        self._pairing_thread.start()

    def choose_ffmpeg(self, path: str) -> None:
        """用户手动指了一个 ffmpeg（解决下载连不上 GitHub 的情况）。"""
        if not path or not os.path.isfile(path):
            return
        self._config.ffmpeg = path
        self._config.save()
        with self._lock:
            self._ffmpeg_state = "checking"
            self._ffmpeg_busy = False
        self._ensure_ffmpeg()

    def retry_ffmpeg(self) -> None:
        """ffmpeg 出错后的重试：从头再走一遍「找 → 下载 → 自检」。"""
        with self._lock:
            self._ffmpeg_busy = False
            self._ffmpeg_state = "checking"
        self._ensure_ffmpeg()

    def set_autostart(self, value: bool) -> None:
        if value and not autostart.enable(self._autostart_command):
            self._log("开机自启没写进去：这台电脑的组策略或权限不允许（不影响转码）")
        elif not value:
            autostart.disable()

    def toggle_autostart(self) -> bool:
        value = not autostart.enabled()
        self.set_autostart(value)
        return value

    def open_logs(self) -> None:
        """打开数据目录（日志、配置都在里面）。"""
        if sys.platform == "win32":
            with contextlib.suppress(OSError):
                os.startfile(app_dir())  # noqa: S606 - 固定打开本应用自己的目录
        else:
            self._log(f"数据目录：{app_dir()}")

    # -- 配对线程 --------------------------------------------------------------

    def _pair_run(self, server: str) -> None:
        cancel = self._pairing_cancel

        def cancelled() -> bool:
            return cancel.is_set()

        try:
            problem = check_server(server)
            if problem is not None:
                self._back_to_onboarding(problem)
                return
            request = request_pairing(server, self._config.worker_id, self._config.installation_id)
        except (PairingError, OSError) as exc:
            self._back_to_onboarding(str(exc))
            return
        with self._lock:
            self._phase = "approving"
            self._pairing_code = request.user_code
            self._pairing_deadline = time.time() + request.expires_in
            self._config.server = server
        self._log(f"请在浏览器里核对配对码后批准：{request.verification_uri_complete}")
        self._log(f"配对码：{request.user_code}（{int(request.expires_in // 60)} 分钟内有效）")
        if not self.headless:
            with contextlib.suppress(Exception):
                self._browser_open(request.verification_uri_complete)
        try:
            token = wait_for_approval(server, request, cancelled=cancelled)
        except PairingError as exc:
            cancelled_before = self._cancelled_pairing or cancelled()
            self._back_to_onboarding("" if cancelled_before else str(exc))
            return
        self._config.token = token
        self._config.save()
        self._log(f"配对成功，凭证已保存到 {app_dir() / 'config.json'}")
        with self._lock:
            self._phase = "ready"
            self._pairing_code = ""
        self._ensure_ffmpeg()

    def _reset_run(self) -> None:
        token = self._config.token
        if token and self._config.server:
            if revoke_credential(self._config.server, token):
                self._log("已在 NAS 上注销这台电脑的凭证")
            else:
                self._log("NAS 连不上，只清本机令牌；可在网页「设置 → 设备」里手动注销")
        self._config.token = ""
        self._config.save()
        self._back_to_onboarding("")

    def _back_to_onboarding(self, error: str) -> None:
        with self._lock:
            self._phase = "onboarding"
            self._pairing_code = ""
            self._pairing_deadline = 0.0
            self._pairing_error = error
            self._connection = "offline"

    # -- ffmpeg：找 → 下载 → 自检 ----------------------------------------------

    def _ensure_ffmpeg(self) -> None:
        """找到可用的 ffmpeg 就自检起内核；没有就在后台下载一份官方的。"""
        with self._lock:
            if self._phase != "ready" or self._ffmpeg_busy:
                return
            self._ffmpeg_busy = True
        threading.Thread(target=self._ffmpeg_run, name="ffmpeg", daemon=True).start()

    def _ffmpeg_run(self) -> None:
        try:
            path = self._resolved_ffmpeg()
            if path is None and not self._download_ffmpeg():
                return
            self._probe_and_start()
        finally:
            with self._lock:
                self._ffmpeg_busy = False

    def _resolved_ffmpeg(self) -> str | None:
        configured = self._config.ffmpeg
        if configured and configured != "ffmpeg" and os.path.isfile(configured):
            return configured
        previous = ffmpeg_install.installed(self._versions_root)
        if previous is not None:
            self._config.ffmpeg = str(previous)
            self._config.save()
            return str(previous)
        return None

    def _download_ffmpeg(self) -> bool:
        try:
            release = ffmpeg_install.latest_release()
        except (ffmpeg_install.FfmpegInstallError, OSError) as exc:
            self._ffmpeg_failed(f"连不上 Jellyfin 官方发布页：{exc}")
            return False
        with self._lock:
            self._ffmpeg_state = "downloading"
            self._ffmpeg_version = release.version
            self._ffmpeg_progress = 0.0
        try:
            path = ffmpeg_install.install(
                release,
                self._versions_root,
                progress=self._download_progress,
            )
        except (ffmpeg_install.FfmpegInstallError, OSError) as exc:
            self._ffmpeg_failed(str(exc))
            return False
        self._config.ffmpeg = str(path)
        self._config.save()
        return True

    def _download_progress(self, done: int, total: int) -> None:
        with self._lock:
            self._ffmpeg_progress = (done / total) if total else 0.0

    def _probe_and_start(self) -> None:
        with self._lock:
            self._ffmpeg_state = "checking"
        try:
            capabilities = self._probe_fn(
                self._config.ffmpeg,
                cache_file=app_dir() / "capabilities.json",
                log=self._log,
            )
        except FfmpegProblem as problem:
            self._ffmpeg_failed(str(problem))
            return
        with self._lock:
            self._capabilities = capabilities
            self._ffmpeg_state = "ready"
            self._ffmpeg_version = capabilities.ffmpeg_version
            self._ffmpeg_path = self._config.ffmpeg
            self._ffmpeg_error = ""
            self._gpu = str(capabilities.hardware.get("chip") or "")
        gpu = self._gpu or "未知"
        encoders = "、".join(capabilities.encoders)
        self._log(f"ffmpeg {capabilities.ffmpeg_version}｜编码器 {encoders}｜显卡 {gpu}")
        self._start_client()

    def _ffmpeg_failed(self, message: str) -> None:
        with self._lock:
            self._ffmpeg_state = "error"
            self._ffmpeg_progress = 0.0
            self._ffmpeg_error = message
        self._log(f"ffmpeg 不可用：{message}")

    # -- 转码内核线程 -----------------------------------------------------------

    def _start_client(self) -> None:
        with self._lock:
            if self._client_thread is not None and self._client_thread.is_alive():
                return
            capabilities = self._capabilities
            if capabilities is None or not self._config.token:
                return
            client = TranscoderClient(
                server=self._config.server,
                token=self._config.token,
                worker_id=self._config.worker_id,
                ffmpeg=self._config.ffmpeg,
                capabilities=capabilities,
                max_jobs=self._config.max_jobs,
                log=self._log,
                on_status=self._on_status,
            )
            self._client = client
            thread = threading.Thread(target=client.run_forever, name="control", daemon=True)
            # 先启动再放手：断开配对会立刻 join，线程还没 start 时 join 会抛。
            self._client_thread = thread
            thread.start()

    def _stop_client(self) -> None:
        with self._lock:
            client, thread = self._client, self._client_thread
            self._client = None
            self._client_thread = None
            self._active_jobs = 0
            self._connection = "offline"
        if client is not None:
            client.stop()
        if thread is not None:
            thread.join(timeout=10)

    def _live_job_count(self) -> int:
        """正在跑的任务数，以内核的任务表为准；内核已经换掉（重连）时保持现值。"""
        client = self._client
        return client.active_jobs if client is not None else self._active_jobs

    def _on_status(self, kind: str, **fields: Any) -> None:
        with self._lock:
            if kind == "connecting":
                self._connection = "connecting"
                self._connection_reason = ""
                self._connection_hint = ""
                self._active_jobs = 0
                self._job_name = ""
            elif kind == "online":
                self._connection = "online"
                self._connection_reason = ""
                self._connection_hint = ""
                self._max_jobs = int(fields.get("max_jobs") or 0)
            elif kind == "offline":
                self._connection = "offline"
                self._connection_reason = str(fields.get("reason") or "")
                self._connection_hint = _REJECTION_HINTS.get(str(fields.get("rejection") or ""), "")
                self._active_jobs = 0
                self._job_name = ""
            elif kind == "job_started":
                self._active_jobs = self._live_job_count()
                self._job_name = str(fields.get("name") or "")
            elif kind == "job_ended":
                self._active_jobs = self._live_job_count()
                if self._active_jobs == 0:
                    self._job_name = ""

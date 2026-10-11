"""进程外运行器（宿主侧，docs/design/plugin-phase3.md §4）。

进程外插件在内核里就是一个普通条目：``apply`` 拉起子进程（``movieclaw_sdk.runner``）、握手，
再把插件声明的每个监听器**以代理的形式**登记到真实的内核上下文上。于是事件分发、钩子的超时与熔断、
卸载回收全是内核现成的行为，代理背后只是换成了另一个进程：

- 子进程崩溃：在途调用立刻失败（监听器出错 / 钩子走默认实现），按退避重启；
  10 分钟内崩 5 次就不再重启，错误进诊断；
- 卸载：先请插件自己清理，5 秒后 ``SIGTERM``，再 5 秒 ``SIGKILL``，不留进程；
- 子进程只拿到最小环境：代码路径、语言与时区，不继承主密钥、数据库地址、代理凭据。
"""

from __future__ import annotations

import asyncio
import contextlib
import contextvars
import hashlib
import itertools
import json
import logging
import os
import socket
import subprocess
import sys
import tempfile
import time
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote

from fastapi import Request
from fastapi.responses import StreamingResponse

from movieclaw_api.services.plugin_agent import PluginAgent
from movieclaw_kernel import (
    DURABLE_EVENTS,
    Context,
    Delivery,
    Mode,
    Plugin,
    ServiceKey,
    current_delivery,
)
from movieclaw_sdk.http import UnixHttp
from movieclaw_sdk.protocol import dump, known_events, load
from movieclaw_sdk.rpc import CALL_HEADER

logger = logging.getLogger("movieclaw_api.plugin_runtime")

HANDSHAKE_TIMEOUT = 30.0
DESCRIBE_TIMEOUT = 20.0
#: 普通事件的单次投递时限（钩子另有内核的时限，更短）
CALL_TIMEOUT = 30.0
#: 可靠事件的处理时限：处理里常要调宿主操作（删种、删订阅），给足时间；超时按失败重试
DURABLE_TIMEOUT = 300.0
STOP_GRACE = 5.0
CRASH_WINDOW = 600.0
CRASH_LIMIT = 5
BACKOFF_MAX = 60.0
#: 子进程能看到的环境变量（其余一律不给）
_ENV_KEEP = ("PATH", "LANG", "LC_ALL", "TZ", "HOME", "TMPDIR")
_UNSET: Any = object()

NextFn = Callable[[Any], Awaitable[Any]]

#: 正在运行的插件进程（诊断与测试用）
sessions: dict[str, Session] = {}
#: 以独立进程运行的条目（诊断页据此区分「进程内 / 独立进程」）
process_entries: set[str] = set()
#: 进程外插件的配置描述（``describe_config`` 的结果），条目 id → 描述
config_descriptions: dict[str, dict[str, Any] | None] = {}
#: 进程外插件的代码位置（目录、模块），校验设置时另起子进程用
process_specs: dict[str, tuple[Path, str, str | None]] = {}


class PluginProcessGone(RuntimeError):
    pass


class RemoteCallError(RuntimeError):
    """插件处理失败。

    ``job`` 是任务处理器抛出的控制异常（重试 / 阻塞 / 失败 / 取消）的结构化描述。
    """

    def __init__(
        self,
        message: str,
        *,
        job: dict[str, Any] | None = None,
        kind: str | None = None,
        detail: str = "",
    ) -> None:
        super().__init__(message)
        self.job = job
        #: 插件侧的错误类别（通道驱动：auth 凭据失效 / value 参数不对 / cancelled / error）
        self.kind = kind
        #: 插件给出的原始错误信息（不带「插件 x 处理失败」前缀，可以直接给用户看）
        self.detail = detail or message


def _child_env() -> dict[str, str]:
    import movieclaw_sdk

    env = {k: v for k, v in os.environ.items() if k in _ENV_KEEP}
    # 与宿主同一份代码（overlay 部署时是 overlay 里的那份）
    env["PYTHONPATH"] = str(Path(movieclaw_sdk.__file__).resolve().parent.parent)
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


_socket_root: Path | None = None


def _socket_dir() -> Path:
    """路由套接字所在目录：``mkdtemp`` 原子创建、只有宿主用户能进（0700）。

    插件进程不需要知道路径（监听描述符由宿主递过去），所以目录可以对它们完全关闭；
    公共临时目录里的固定文件名则可能被别的插件抢先占住或删掉换成自己的。
    """
    global _socket_root
    if _socket_root is None or not _socket_root.is_dir():
        _socket_root = Path(tempfile.mkdtemp(prefix="mcp-"))
    return _socket_root


def _listen(path: str) -> socket.socket:
    """宿主替插件绑定路由套接字，监听描述符交给插件进程（运行器的 ``--listen-fd``）。

    所有插件进程是同一个非特权用户：若由插件自己绑定（uvicorn 会把权限改成 0666），任何插件
    都能直连别的插件的套接字，绕过宿主在代理路由上注入的鉴权与验签。宿主绑定后文件归宿主、
    权限 0600，目录也只有宿主进得去，只有宿主的反向代理连得上。
    """
    with contextlib.suppress(FileNotFoundError):
        os.unlink(path)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind(path)
        os.chmod(path, 0o600)
        sock.listen(128)
    except BaseException:
        sock.close()
        raise
    return sock


@dataclass
class Launch:
    """拉起插件进程的现场：工作目录、环境变量、要切换到的用户（隔离时）。"""

    cwd: Path
    env: dict[str, str]
    args: list[str]
    """交给运行器的降权参数（``--uid`` / ``--gid``）：由插件进程在导入插件代码前自己切换用户。

    不用 ``Popen(user=...)``：应用跑在 uvloop 上，它的子进程接口不支持这些参数。
    """


def _launch(entry_id: str, path: Path, module: str) -> Launch:
    """宿主是 root 时切换到非特权用户，并改用对它可读的代码副本（plugin_isolation.py）。"""
    from movieclaw_api import __version__
    from movieclaw_api.services import plugin_isolation as iso

    env = _child_env()
    settings = iso.isolation()
    if not settings.enabled:
        return Launch(path, env, [])
    src = iso.stage_source(Path(env["PYTHONPATH"]), __version__)
    code = iso.stage_plugin(entry_id, path, module)
    scratch = iso.scratch_dir(entry_id, settings)
    env.update(PYTHONPATH=str(src), HOME=str(scratch), TMPDIR=str(scratch))
    if settings.uid == os.geteuid():
        return Launch(code, env, [])
    return Launch(code, env, ["--uid", str(settings.uid), "--gid", str(settings.gid)])


class Session:
    """一个插件进程：拉起、握手、调用、监管、停止。"""

    def __init__(
        self,
        entry_id: str,
        *,
        path: Path,
        module: str,
        config: Any,
        data_dir: str = "./data",
        command: str | None = None,
    ) -> None:
        self.entry_id = entry_id
        self._data_dir = str(Path(data_dir).resolve())
        self._path = path
        self._module = module
        self._command = command
        self._config = config
        self._proc: asyncio.subprocess.Process | None = None
        self._handshake: asyncio.Future[dict[str, Any]] | None = None
        self._nexts: dict[str, NextFn] = {}
        self._contexts: dict[str, contextvars.Context] = {}
        self.jobs: dict[str, Any] = {}
        """正在子进程里执行的任务：调用编号 → 宿主这边真实的 ``JobContext``。"""
        self.exports: dict[str, Any] = {}
        """导出给插件的宿主服务：服务名 → 实现（网关按契约分发，plugin_gateway.py）。"""
        self.token: str | None = None
        """这个条目的网关令牌（只在网关上有效）。"""
        self.gateway: str | None = None
        self.contributions: list[dict[str, Any]] = []
        self.channels: dict[str, Any] = {}
        """这个插件贡献的通道：贡献 id → 宿主侧的驱动桩（plugin_channels.py）。"""
        self.routes: list[dict[str, Any]] = []
        self.callbacks: list[dict[str, Any]] = []
        self._fd_host: socket.socket | None = None
        self._http: Any = None
        self._control_http: UnixHttp | None = None
        self.files: Any = None
        """宿主侧这个条目的 ``PluginFiles``（插件注入了 PLUGIN_FILES 时才有）。"""
        # Unix 套接字路径有长度上限（macOS 104 字节）：放在临时目录、用短哈希命名
        digest = hashlib.sha1(f"{entry_id}:{os.getpid()}".encode()).hexdigest()[:12]
        self.socket = str(_socket_dir() / f"{digest}.sock")
        self._ids = itertools.count(1)
        self._readers: list[asyncio.Task[Any]] = []
        self._stopping = False
        self._ready = False
        self._crashes: deque[float] = deque()
        self.declarations: list[dict[str, Any]] = []
        self.title: str | None = None
        self.serving = False
        """插件进程有没有起服务（没有导出——只跑后台任务、只往外调宿主——就不起）。"""

    @property
    def online(self) -> bool:
        """握手完成、进程还在、没在停：只有这时才接受调用（握手期间进来的调用会打乱协议）。"""
        return (
            self._ready
            and self._proc is not None
            and self._proc.returncode is None
            and not self._stopping
        )

    @property
    def pid(self) -> int | None:
        return self._proc.pid if self._proc is not None else None

    def http(self) -> Any:
        """反代插件路由用的客户端：每个进程一个连接池。

        不能每个请求新建：创建客户端要加载证书、建 SSL 上下文，本机实测 3.6 毫秒，
        而且占着宿主主循环，插件路由一忙，整个宿主跟着卡。
        """
        if self._http is None:
            import httpx

            self._http = httpx.AsyncClient(
                transport=httpx.AsyncHTTPTransport(uds=self.socket),
                base_url="http://plugin",
                timeout=httpx.Timeout(30.0, read=None),
            )
        return self._http

    async def _close_http(self) -> None:
        """丢掉连到旧进程的连接（重启、卸载时），下次用时按新进程重建。"""
        client, self._http = self._http, None
        if client is not None:
            await client.aclose()
        control, self._control_http = self._control_http, None
        if control is not None:
            await control.aclose()

    # ------------------------------------------------------------------ 启动
    async def start(self) -> list[dict[str, Any]]:
        """拉起进程、等它就绪，返回插件声明的监听器；插件启动失败抛错（内核据此标 FAILED）。

        引导信息（配置、网关地址与令牌）经 stdin 写一行就关闭：令牌不放环境变量，所有插件是同一个
        用户，能读彼此的 ``/proc/<pid>/environ``。插件跑完 ``apply`` 经网关报就绪
        （``session.ready``），一次带上全部声明。stdout 与 stderr 都只是日志。
        """
        self._ready = False
        await self._close_http()
        launch = await asyncio.to_thread(_launch, self.entry_id, self._path, self._module)
        from movieclaw_api.services import host_ops
        from movieclaw_api.services.plugin_gateway import gateway

        self.gateway = await gateway.ensure(host_ops._app)
        listener = _listen(self.socket)
        # 文件通道：宿主检查授权后打开文件，把描述符经这对套接字递给插件（services/plugin_files.py）
        self._close_fd_channel()
        self._fd_host, child_end = socket.socketpair()
        self._handshake = asyncio.get_running_loop().create_future()
        try:
            self._proc = await asyncio.create_subprocess_exec(
                *_argv(
                    launch,
                    self.entry_id,
                    self._module,
                    self._command,
                    "--fd-socket",
                    str(child_end.fileno()),
                    "--listen-fd",
                    str(listener.fileno()),
                ),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=str(launch.cwd),
                env=launch.env,
                pass_fds=(child_end.fileno(), listener.fileno()),
            )
        finally:
            child_end.close()
            listener.close()
        proc = self._proc
        self._readers = [asyncio.get_running_loop().create_task(self._pump_logs(proc))]
        try:
            assert proc.stdin is not None
            proc.stdin.write(
                json.dumps(
                    {
                        "entry_id": self.entry_id,
                        "config": self._config,
                        "data_dir": self._data_dir,
                        # 插件调宿主走网关（HTTP over Unix 套接字），令牌只在网关上有效
                        "gateway": self.gateway,
                        "token": self.token,
                    },
                    ensure_ascii=False,
                ).encode()
                + b"\n"
            )
            await proc.stdin.drain()
            proc.stdin.close()
            exited = asyncio.ensure_future(proc.wait())
            done, _ = await asyncio.wait(
                {self._handshake, exited},
                timeout=HANDSHAKE_TIMEOUT,
                return_when=asyncio.FIRST_COMPLETED,
            )
            if self._handshake not in done:
                exited.cancel()
                if exited in done:
                    raise PluginProcessGone(f"插件进程启动期间退出（退出码 {proc.returncode}）")
                raise TimeoutError(f"插件 {self.entry_id} {HANDSHAKE_TIMEOUT:.0f} 秒内没有就绪")
            exited.cancel()
            ready = self._handshake.result()
        except BaseException:
            await self._kill()
            raise
        self.title = ready.get("title")
        self.serving = bool(ready.get("serving"))
        self.contributions = list(ready.get("contributions") or [])
        self.routes = list(ready.get("routes") or [])
        self.callbacks = list(ready.get("callbacks") or [])
        declarations = list(ready.get("listeners") or [])
        self._ready = True
        logger.info(
            "插件 %s 已在独立进程中运行（pid %s，%d 个监听器）",
            self.entry_id,
            proc.pid,
            len(declarations),
        )
        return declarations

    def handshake(self, ready: dict[str, Any] | None, error: Exception | None = None) -> None:
        """插件经网关报就绪 / 启动失败（``session`` 服务）。"""
        future = self._handshake
        if future is None or future.done():
            raise RuntimeError("插件已经报过就绪")
        if error is not None:
            future.set_exception(error)
        else:
            future.set_result(ready or {})

    async def _pump_logs(self, proc: asyncio.subprocess.Process) -> None:
        """插件的 stdout / stderr（合在一起）按行收进宿主日志；读到头说明进程退出了。"""
        assert proc.stdout is not None
        try:
            while line := await proc.stdout.readline():
                logger.info("[%s] %s", self.entry_id, line.decode("utf-8", "replace").rstrip())
        finally:
            if proc is self._proc:
                self._ready = False

    def call_context(self, call: str) -> contextvars.Context | None:
        """宿主调插件时的上下文快照（插件经网关带回调用号时，在它里面处理请求）。"""
        return self._contexts.get(call)

    def track(self) -> str:
        """登记一个调用上下文快照，返回调用号（反代路由请求时用；结束后 ``untrack``）。"""
        call_id = str(next(self._ids))
        self._contexts[call_id] = contextvars.copy_context()
        return call_id

    def untrack(self, call_id: str) -> None:
        self._contexts.pop(call_id, None)

    async def run_next(self, call_id: str, payload: Any) -> Any:
        """钩子里插件调 ``next()``：替它跑下游（``hooks`` 服务）。"""
        run = self._nexts.get(call_id)
        if run is None:
            raise LookupError("这次调用已经结束")
        return await run(payload)

    async def send_fd(self, token: str, fd: int) -> None:
        if self._fd_host is None:
            raise PluginProcessGone("文件通道已关闭")
        await asyncio.to_thread(socket.send_fds, self._fd_host, [token.encode()], [fd])

    def _close_fd_channel(self) -> None:
        if self._fd_host is not None:
            self._fd_host.close()
            self._fd_host = None

    def _control(self) -> UnixHttp:
        """宿主调插件控制服务的客户端（每个进程一个连接池）。"""
        if self._control_http is None:
            self._control_http = UnixHttp(self.socket, timeout=None)
        return self._control_http

    # ------------------------------------------------------------------ 调用
    async def call(
        self,
        listener: str,
        payload: Any,
        run_next: NextFn | None = None,
        *,
        timeout: float | None = CALL_TIMEOUT,
        job: Any = None,
        kind: str | None = None,
        cancel: asyncio.Event | None = None,
    ) -> Any:
        """调插件导出的一个目标：``POST /_mc/{kind}/{target}``，请求头带调用号。

        超时、宿主侧取消都是断开连接（插件随之取消处理）；``cancel`` 是体面停止：先请插件
        自己收尾（``/_mc/cancel``），照常等它回复。
        """
        if not self.online:
            raise PluginProcessGone(f"插件 {self.entry_id} 的进程不在运行")
        call_id = str(next(self._ids))
        self._contexts[call_id] = contextvars.copy_context()
        if run_next is not None:
            self._nexts[call_id] = run_next
        body: dict[str, Any] = {"payload": payload}
        if job is not None:
            self.jobs[call_id] = job
            kind = "job"
            body["job_id"] = job.job_id
        delivery = current_delivery.get()
        if delivery is not None:
            body["delivery"] = {
                "event_id": delivery.event_id,
                "name": delivery.name,
                "occurred_at": delivery.occurred_at,
                "origin": {
                    "kind": delivery.origin.kind,
                    "id": delivery.origin.id,
                    "chain": list(delivery.origin.chain),
                },
                "attempt": delivery.attempt,
            }
        headers = {CALL_HEADER: call_id}
        path = f"/_mc/{kind or 'listener'}/{quote(listener, safe='')}"
        watcher: asyncio.Task[None] | None = None
        if cancel is not None:

            async def relay() -> None:
                await cancel.wait()
                with contextlib.suppress(Exception):
                    await self._control().request(
                        "POST", "/_mc/cancel", json={"call": call_id}, timeout=5.0
                    )

            watcher = asyncio.get_running_loop().create_task(relay())
        try:
            response = await self._control().request(
                "POST", path, json=body, headers=headers, timeout=timeout
            )
            try:
                reply = response.json() or {}
            except ValueError:
                reply = {}
            if response.status_code >= 400:
                message = reply.get("message") or f"HTTP {response.status_code}"
                reply = {"ok": False, "error": message}
        except (ConnectionError, OSError) as exc:
            raise PluginProcessGone(f"插件 {self.entry_id} 的进程不在运行") from exc
        finally:
            if watcher is not None:
                watcher.cancel()
            self._nexts.pop(call_id, None)
            self._contexts.pop(call_id, None)
            self.jobs.pop(call_id, None)
        if not reply.get("ok"):
            raise RemoteCallError(
                f"插件 {self.entry_id} 处理失败：{reply.get('error')}",
                job=reply.get("job"),
                kind=reply.get("error_kind"),
                detail=str(reply.get("error") or ""),
            )
        return reply.get("result")

    # ------------------------------------------------------------------ 监管
    async def supervise(self) -> None:
        """进程意外退出就按退避重启；崩溃太频繁则放弃并抛错（错误进诊断）。"""
        backoff = 1.0
        while True:
            proc = self._proc
            assert proc is not None
            code = await proc.wait()
            if self._stopping:
                return
            now = time.monotonic()
            self._crashes.append(now)
            while self._crashes and now - self._crashes[0] > CRASH_WINDOW:
                self._crashes.popleft()
            if len(self._crashes) >= CRASH_LIMIT:
                raise RuntimeError(
                    f"插件进程 {CRASH_WINDOW / 60:.0f} 分钟内崩溃 {len(self._crashes)} 次"
                    f"（最近一次退出码 {code}），已停止重启；修好后重新启用该插件"
                )
            logger.warning(
                "插件 %s 的进程意外退出（退出码 %s），%.0f 秒后重启", self.entry_id, code, backoff
            )
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX)
            previous = _shape(self, self.declarations)
            try:
                declarations = await self.start()
            except Exception:
                logger.exception("插件 %s 重启失败", self.entry_id)
                continue
            if _shape(self, declarations) != previous:
                logger.error("插件 %s 重启后声明的监听器变了，按崩溃处理", self.entry_id)
                await self._kill()
                continue
            backoff = 1.0

    async def stop(self) -> None:
        """释放：``SIGTERM`` 请插件自己清理（``ctx.dispose()``）后退出，宽限期过了 ``SIGKILL``。"""
        self._stopping = True
        proc = self._proc
        if proc is not None and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), STOP_GRACE)
            except TimeoutError:
                proc.kill()
                await proc.wait()
        for task in self._readers:
            task.cancel()
        await asyncio.gather(*self._readers, return_exceptions=True)
        await self._close_http()
        self._close_fd_channel()
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.socket)

    async def _kill(self) -> None:
        proc = self._proc
        if proc is not None and proc.returncode is None:
            proc.kill()
            await proc.wait()


def _remote_error(message: dict[str, Any]) -> Exception:
    """插件进程里的启动异常，按原类型名在宿主重建（诊断里显示 ``ValueError: …`` 而不是套两层）。"""
    name = message.get("error_type")
    text = message.get("error_message")
    if isinstance(name, str) and name.isidentifier() and isinstance(text, str):
        return type(name, (RuntimeError,), {})(text)
    return RuntimeError(message.get("error") or "插件启动失败")


def _shape(session: Session, declarations: list[dict[str, Any]]) -> set[Any]:
    """插件声明的形状：重启后必须一致（代理已经按它登记在内核里了）。"""
    return (
        {("on", d["event"], d["id"]) for d in declarations}
        | {("contribute", c["registry"], c["id"]) for c in session.contributions}
        | {
            ("route", m["zone"], r["operation_id"], r["path"])
            for m in session.routes
            for r in m["routes"]
        }
        | {("callback", c["name"]) for c in session.callbacks}
    )


_CALL_HEADER = CALL_HEADER.lower()

#: 不跨跳转发的头（逐跳头与由传输层重新生成的头）
#: 不转给插件进程的请求头：用户的登录凭据。宿主已经验过身份，插件拿到原始凭据就能越过授权冒充用户
_CREDENTIAL_HEADERS = frozenset({"authorization", "cookie"})

_HOP_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
    }
)


def _route_proxy(session: Session, routes: list[dict[str, Any]]) -> Any:
    """按插件声明的路由清单建一个代理路由器：把请求流式转给插件进程的 Unix 套接字。

    鉴权、验签由宿主在挂载时注入（``PLUGIN_ROUTES.mount``），这里只负责搬运；
    网盘取流这类几 GB 的 Range 请求，请求体与响应体都按块转发，不落内存。
    """
    import httpx
    from fastapi import APIRouter
    from starlette.background import BackgroundTask

    router = APIRouter()

    from movieclaw_api.exceptions import AppException

    def unavailable() -> AppException:
        return AppException(
            status_code=503,
            code="PLUGIN_UNAVAILABLE",
            message=f"插件 {session.entry_id} 暂时不可用（进程不在运行或正在重启），请稍后再试",
        )

    from movieclaw_api.services.plugin_files import SENDFILE_HEADER, sendfile

    async def forward(request: Request) -> Any:
        if not session.online:
            raise unavailable()
        client = session.http()
        # 这次请求的调用号：插件的路由处理函数里再调宿主服务时带回来，宿主按它恢复上下文
        # （外部请求里同名的头一律丢掉，伪造不了）
        call_id = session.track()
        headers = [
            (k, v)
            for k, v in request.headers.items()
            if k.lower() not in _HOP_HEADERS
            and k.lower() not in _CREDENTIAL_HEADERS
            and k.lower() != _CALL_HEADER
        ]
        headers.append((CALL_HEADER, call_id))
        upstream = client.build_request(
            request.method,
            request.url.path,
            params=request.url.query or None,
            headers=headers,
            content=request.stream(),
        )
        try:
            response = await client.send(upstream, stream=True)
        except httpx.TransportError as exc:
            session.untrack(call_id)
            raise unavailable() from exc
        except BaseException:
            session.untrack(call_id)
            raise
        sendfile_path = response.headers.get(SENDFILE_HEADER)
        if sendfile_path is not None:
            from urllib.parse import unquote

            sendfile_path = unquote(sendfile_path)
            # 插件只交出了路径：宿主检查读授权后自己发送（支持 Range），插件碰不到字节
            await response.aclose()
            session.untrack(call_id)
            if session.files is None:
                raise unavailable()
            return await sendfile(session.files, sendfile_path)

        async def close() -> None:
            await response.aclose()
            session.untrack(call_id)

        return StreamingResponse(
            response.aiter_raw(),
            status_code=response.status_code,
            headers={k: v for k, v in response.headers.items() if k.lower() not in _HOP_HEADERS},
            background=BackgroundTask(close),
        )

    for route in routes:
        router.add_api_route(
            route["path"],
            forward,
            methods=route["methods"],
            operation_id=route["operation_id"],
            summary=route.get("summary"),
            name=route.get("name"),
            response_model=None,
            # 插件端点的参数 / 请求体定义：进接口目录，mclaw 才有对应的选项
            openapi_extra=route.get("openapi") or None,
        )
    return router


def _job_error(error: RemoteCallError) -> Exception:
    """子进程里任务处理器抛出的控制异常，在宿主这边还原成同一种异常交给执行器。"""
    from movieclaw_api.services import jobs

    job = error.job or {}
    cls = job.get("cls")
    message = str(job.get("message") or error)
    kwargs = {"code": job["code"]} if job.get("code") else {}
    if cls == "JobCancelled":
        return jobs.JobCancelled()
    if cls == "JobRetry":
        return jobs.JobRetry(
            message,
            delay_seconds=int(job.get("delay_seconds") or 15),
            actions=job.get("actions"),
            **kwargs,
        )
    if cls in ("JobBlocked", "JobFailed"):
        return getattr(jobs, cls)(
            message, actions=job.get("actions"), details=job.get("details"), **kwargs
        )
    return error


def _contribution(session: Session, contribution: dict[str, Any]) -> tuple[Any, Any]:
    """子进程声明的贡献项 → （注册表键，登记到内核里的代理项）。"""
    from movieclaw_api.pipeline import INGEST_STEPS, IngestStep
    from movieclaw_api.plugins.keys import SITE_DATA_PACKS
    from movieclaw_api.services import jobs

    registry, cid, item = contribution["registry"], contribution["id"], contribution["item"]
    if registry == jobs.JOB_HANDLERS.name:

        async def handler(context: Any, data: dict[str, Any]) -> dict[str, Any] | None:
            try:
                return await session.call(cid, data, timeout=None, job=context)
            except PluginProcessGone as exc:
                raise jobs.JobRetry(
                    f"插件 {session.entry_id} 的进程不在运行，稍后重试", delay_seconds=30
                ) from exc
            except RemoteCallError as exc:
                raise _job_error(exc) from exc

        return jobs.JOB_HANDLERS, jobs.RegisteredJobHandler(
            handler, frozenset(int(v) for v in item["versions"])
        )
    if registry == "scheduled-tasks":
        from movieclaw_scheduler import SCHEDULED_TASKS, TaskDefinition, TriggerType

        async def run() -> None:
            # 到点调回插件进程；进程不在、出错都抛给调度器，记为这次执行失败
            await session.call(cid, {}, timeout=None, kind="scheduled-task")

        return SCHEDULED_TASKS, TaskDefinition(
            key=item["key"],
            title=item["title"],
            handler=run,
            default_trigger_type=TriggerType(item["default_trigger_type"]),
            default_interval_seconds=item.get("default_interval_seconds"),
            default_cron=item.get("default_cron"),
            default_enabled=bool(item.get("default_enabled", True)),
            description=item.get("description") or "",
        )
    if registry == "im-channels":
        from movieclaw_api.plugins.keys import IM_CHANNELS
        from movieclaw_api.services.plugin_channels import RemoteChannelDriver

        stub = session.channels.get(cid)
        if stub is None:
            stub = session.channels[cid] = RemoteChannelDriver(session, cid, item)
        return IM_CHANNELS, stub
    if registry == "library.delete-participants":
        from movieclaw_api.services.library import delete_participants as dp

        async def preview(request: dp.DeleteRequest) -> dp.Preview:
            data = await session.call(
                cid,
                request.model_dump(mode="json"),
                timeout=dp.PREVIEW_TIMEOUT,
                kind="delete-preview",
            )
            return dp.Preview.model_validate(data)

        return dp.LIBRARY_DELETE_PARTICIPANTS, dp.DeleteParticipant(
            label=item["label"],
            help=item["help"],
            preview=preview,
            job_type=item["job_type"],
            applies_to=frozenset(item.get("applies_to") or ("item", "file")),
        )
    if registry == "downloader-adapters":
        from movieclaw_api.services.plugin_downloaders import RemoteDownloader
        from movieclaw_downloader.registry import DOWNLOADER_ADAPTERS, DownloaderAdapter

        return DOWNLOADER_ADAPTERS, DownloaderAdapter(
            type=item["type"],
            title=item["title"],
            factory=lambda config: RemoteDownloader(session, cid, config),
            connection=item.get("connection"),
            help=item.get("help") or "",
        )
    if registry == INGEST_STEPS.name:
        return INGEST_STEPS, IngestStep(
            job_type=item["job_type"],
            title=item["title"],
            slot=item["slot"],
            kinds=tuple(item.get("kinds") or ()),
        )
    if registry == SITE_DATA_PACKS.name:
        return SITE_DATA_PACKS, Path(item["path"])
    raise ValueError(f"进程外插件不能往注册表 {registry} 贡献")


def _proxy(session: Session, declaration: dict[str, Any]) -> tuple[Any, Callable[..., Any]]:
    event = known_events().get(declaration["event"])
    if event is None:
        raise ValueError(f"事件 {declaration['event']} 不存在或没有开放给第三方插件")
    listener = declaration["id"]
    timeout = DURABLE_TIMEOUT if event.delivery is Delivery.DURABLE else CALL_TIMEOUT

    if event.mode is Mode.WATERFALL:

        async def waterfall(payload: Any, next_: Callable[..., Any]) -> Any:
            async def run_next(data: Any) -> Any:
                value = await (next_() if data is _UNSET else next_(load(event.payload, data)))
                return dump(event.result, value)

            data = await session.call(listener, dump(event.payload, payload), run_next)
            return load(event.result, data)

        return event, waterfall

    async def call(payload: Any) -> Any:
        data = await session.call(listener, dump(event.payload, payload), timeout=timeout)
        return load(event.result, data) if event.mode is Mode.BAIL else None

    return event, call


def _callback_proxy(ctx: Context, session: Session, declared: dict[str, Any]) -> None:
    """子进程登记的回调端点：宿主这边登记一个转发函数，请求经协议交给插件进程处理。"""
    from movieclaw_api.plugins.keys import PLUGIN_CALLBACKS
    from movieclaw_sdk.callbacks import request_dict, response_from_dict

    name = declared["name"]

    async def forward(request: Any) -> Any:
        # 超时由回调服务统一控制（wait_for 取消这次调用）
        data = await session.call(name, request_dict(request), timeout=None, kind="callback")
        return response_from_dict(data)

    ctx.use(PLUGIN_CALLBACKS).endpoint(
        ctx,
        name,
        forward,
        methods=tuple(declared.get("methods") or ("POST",)),
        max_body=int(declared.get("max_body") or 0) or 1024 * 1024,
        timeout=float(declared.get("timeout") or 10.0),
    )


def _open_services() -> dict[str, ServiceKey[Any]]:
    """进程外插件能用的服务（插件侧有对应的代理，见 ``movieclaw_sdk.runner``）。"""
    from movieclaw_api.plugins.keys import (
        AGENT,
        HOST_OPS,
        PLUGIN_CALLBACKS,
        PLUGIN_DATA,
        PLUGIN_FILES,
        PLUGIN_HEALTH,
        PLUGIN_ROUTES,
    )

    return {
        AGENT.name: AGENT,
        PLUGIN_CALLBACKS.name: PLUGIN_CALLBACKS,
        PLUGIN_FILES.name: PLUGIN_FILES,
        HOST_OPS.name: HOST_OPS,
        PLUGIN_DATA.name: PLUGIN_DATA,
        PLUGIN_HEALTH.name: PLUGIN_HEALTH,
        PLUGIN_ROUTES.name: PLUGIN_ROUTES,
        DURABLE_EVENTS.name: DURABLE_EVENTS,
    }


def _argv(
    launch: Launch, entry_id: str, module: str, command: str | None, *extra: str
) -> list[str]:
    """拉起插件的命令行。

    Python 插件走运行器；非 Python 插件（``exec``，plugin-ipc-http.md §9）先过可信启动器：
    它降权、设资源限制与父进程退出信号后 ``execve`` 插件——不可信的二进制不能指望它自己降权。
    约定与运行器一致：``--describe`` / ``--validate`` / ``--fd-socket`` / ``--listen-fd``。
    """
    if command is not None:
        program = str(launch.cwd / command)
        return [
            sys.executable,
            "-s",
            "-m",
            "movieclaw_sdk.launch",
            *launch.args,
            "--",
            program,
            *extra,
        ]
    return [
        sys.executable,
        "-s",
        "-m",
        "movieclaw_sdk.runner",
        "--path",
        str(launch.cwd),
        "--module",
        module,
        "--entry",
        entry_id,
        *extra,
        *launch.args,
    ]


def describe(path: Path, module: str, entry_id: str, command: str | None = None) -> dict[str, Any]:
    """在子进程里读出插件的声明（标题、要注入的服务、宿主操作），主进程不导入插件代码。

    导入插件代码就会执行它的模块级代码，所以这一步与正式运行同样隔离（同一用户、同一代码副本）。
    """
    launch = _launch(entry_id, path, module)
    proc = subprocess.run(
        _argv(launch, entry_id, module, command, "--describe"),
        capture_output=True,
        cwd=str(launch.cwd),
        env=launch.env,
        timeout=DESCRIBE_TIMEOUT,
        check=False,
    )
    if proc.returncode != 0:
        tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["无输出"]
        raise RuntimeError(f"读取插件声明失败：{tail[0]}")
    return json.loads(proc.stdout.decode("utf-8").splitlines()[-1])


def validate_config(entry_id: str, config: dict[str, Any]) -> list[dict[str, Any]]:
    """在子进程里用插件自己的配置模型校验一份配置，返回 pydantic 的错误列表（空 = 合规）。

    与 ``describe`` 同样隔离：主进程不导入插件代码。保存界面设置前先校验，填错不必重启插件才发现。
    """
    spec = process_specs.get(entry_id)
    if spec is None:
        return []
    path, module, command = spec
    launch = _launch(entry_id, path, module)
    proc = subprocess.run(
        _argv(launch, entry_id, module, command, "--validate"),
        input=json.dumps(config, ensure_ascii=False).encode("utf-8"),
        capture_output=True,
        cwd=str(launch.cwd),
        env=launch.env,
        timeout=DESCRIBE_TIMEOUT,
        check=False,
    )
    if proc.returncode != 0:
        tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["无输出"]
        raise RuntimeError(f"校验插件设置失败：{tail[0]}")
    return json.loads(proc.stdout.decode("utf-8").splitlines()[-1]).get("errors") or []


_MISSING: Any = object()


# ---------------------------------------------------------------------- 导出给插件的服务
# 每个类实现 movieclaw_sdk.services 里的一个契约；网关按契约校验参数后调用（plugin_gateway.py）。
# 都以插件自己的上下文、凭证与数据作用域执行。


class _Data:
    def __init__(self, store: Any) -> None:
        self._store = store

    async def get(self, key: str, scope: str = "global") -> Any:
        from movieclaw_sdk.services import StoredValue

        value = await self._store.get(key, scope=scope, default=_MISSING)
        return StoredValue(found=value is not _MISSING, value=None if value is _MISSING else value)

    async def set(self, key: str, value: Any, scope: str = "global", secret: bool = False) -> None:
        await self._store.set(key, value, scope=scope, secret=secret)

    async def delete(self, key: str, scope: str = "global") -> bool:
        return await self._store.delete(key, scope=scope)

    async def items(self, scope: str = "global") -> dict[str, Any]:
        return await self._store.items(scope=scope)

    async def scopes(self, key: str, entity: str | None = None) -> dict[str, Any]:
        return await self._store.scopes(key, entity=entity)


class _Health:
    def __init__(self, reporter: Any) -> None:
        self._reporter = reporter

    async def degraded(self, key: str, message: str, action_href: str | None = None) -> None:
        await self._reporter.degraded(key, message, action_href=action_href)

    async def ok(self, key: str, message: str = "") -> None:
        await self._reporter.ok(key, message)


class _Callbacks:
    def __init__(self, ctx: Context, callbacks: Any) -> None:
        self._ctx = ctx
        self._callbacks = callbacks

    async def issue(self, name: str, scope: str = "plugin") -> dict[str, Any]:
        from movieclaw_sdk.callbacks import issued_dict

        return issued_dict(await self._callbacks.issue(self._ctx, name, scope=scope))

    async def revoke(self, key_id: int) -> None:
        await self._callbacks.revoke(self._ctx, key_id)

    async def keys(self, name: str | None = None) -> list[dict[str, Any]]:
        from movieclaw_sdk.callbacks import issued_dict

        return [issued_dict(i) for i in await self._callbacks.keys(self._ctx, name)]


class _Routes:
    def __init__(self, ctx: Context, routes: Any) -> None:
        self._ctx = ctx
        self._routes = routes

    async def sign(
        self,
        path: str,
        params: dict[str, str] | None = None,
        expires_in: int | None = None,
        absolute: bool = False,
    ) -> str:
        return await self._routes.sign(
            self._ctx, path, params=params, expires_in=expires_in, absolute=absolute
        )


_OPEN_FLAGS = {
    "rb": os.O_RDONLY,
    "wb": os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
    "ab": os.O_WRONLY | os.O_CREAT | os.O_APPEND,
    "r+b": os.O_RDWR,
    "w+b": os.O_RDWR | os.O_CREAT | os.O_TRUNC,
    "a+b": os.O_RDWR | os.O_CREAT | os.O_APPEND,
}
_fd_tokens = itertools.count(1)


class _Files:
    """检查授权由 ``PluginFiles`` 做。

    ``open`` 打开后把描述符经 socketpair 递过去，返回配对用的令牌。
    """

    def __init__(self, session: Session, files: Any) -> None:
        self._session = session
        self._files = files

    async def open(self, path: str, mode: str = "rb") -> str:
        flags = _OPEN_FLAGS.get(mode.replace("br", "rb"))
        if flags is None:
            raise ValueError(f"不支持的打开模式：{mode}")
        real = await self._files.check(path, write=mode != "rb")
        fd = await asyncio.to_thread(os.open, real, flags | os.O_CLOEXEC, 0o644)
        token = f"f{next(_fd_tokens)}"
        try:
            await self._session.send_fd(token, fd)
        finally:
            os.close(fd)
        return token

    async def stat(self, path: str) -> dict[str, Any] | None:
        return await self._files.stat(path)

    async def listdir(self, path: str) -> list[str]:
        return await self._files.listdir(path)

    async def makedirs(self, path: str) -> None:
        await self._files.makedirs(path)

    async def rename(self, src: str, dst: str) -> None:
        await self._files.rename(src, dst)

    async def remove(self, path: str) -> None:
        await self._files.remove(path)


class _Ops:
    def __init__(self, client: Any) -> None:
        self._client = client

    async def operations(self) -> list[Any]:
        from movieclaw_api.services.host_ops import operation_ref

        index = self._client._index
        return [operation_ref(index[o]) for o in sorted(self._client.operations) if o in index]


class _Net:
    def __init__(self, entry_id: str) -> None:
        self._entry_id = entry_id

    async def proxy(self, service: str) -> str | None:
        # 代理地址可能带账号密码：只回答插件自己的服务名，别的服务直连
        from movieclaw_net import resolve_proxy_url

        return resolve_proxy_url(service) if service in own_services(self._entry_id) else None


class _Job:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _context(self) -> Any:
        from movieclaw_api.services.plugin_gateway import current_call

        context = self._session.jobs.get(current_call.get() or "")
        if context is None:
            raise LookupError("只能在任务处理器里汇报任务进度")
        return context

    async def update_progress(self, progress: dict[str, Any]) -> None:
        await self._context().update_progress(**progress)

    async def current_progress(self) -> dict[str, Any]:
        return await self._context().current_progress()

    async def cancel_requested(self) -> bool:
        return await self._context().cancel_requested()


class _Channels:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _stub(self, channel: str) -> Any:
        stub = self._session.channels.get(channel)
        if stub is None:
            raise LookupError("这个插件没有贡献这个通道")
        return stub

    async def inbound(self, channel: str, account: str, message: dict[str, Any]) -> None:
        await self._stub(channel).callback(
            "channel.inbound", {"account": account, "message": message}
        )

    async def save_state(self, channel: str, account: str, patch: dict[str, Any]) -> None:
        await self._stub(channel).callback(
            "channel.save_state", {"account": account, "patch": patch}
        )


class _Session:
    def __init__(self, session: Session) -> None:
        self._session = session

    async def ready(
        self,
        title: str,
        listeners: list[dict[str, Any]],
        contributions: list[dict[str, Any]],
        routes: list[dict[str, Any]],
        callbacks: list[dict[str, Any]],
        serving: bool,
    ) -> None:
        self._session.handshake(
            {
                "title": title,
                "listeners": listeners,
                "contributions": contributions,
                "routes": routes,
                "callbacks": callbacks,
                "serving": serving,
            }
        )

    async def failed(self, error_type: str, error_message: str) -> None:
        self._session.handshake(
            None, _remote_error({"error_type": error_type, "error_message": error_message})
        )


class _Hooks:
    def __init__(self, session: Session) -> None:
        self._session = session

    async def next(self, payload: Any = None, replace: bool = False) -> Any:
        from movieclaw_api.services.plugin_gateway import current_call

        call = current_call.get()
        if call is None:
            raise LookupError("只能在钩子调用里调 next()")
        return await self._session.run_next(call, payload if replace else _UNSET)


#: 服务名 → 宿主实现（与 movieclaw_sdk.services.SERVICES 一一对应，测试守护签名一致）
EXPORTS: dict[str, type] = {
    "session": _Session,
    "hooks": _Hooks,
    "data": _Data,
    "health": _Health,
    "callbacks": _Callbacks,
    "routes": _Routes,
    "files": _Files,
    "ops": _Ops,
    "net": _Net,
    "job": _Job,
    "channels": _Channels,
    "agent": PluginAgent,
}


async def _exports(ctx: Context, session: Session, names: tuple[str, ...]) -> dict[str, Any]:
    """插件声明了哪些服务就导出哪些；网络、任务上下文、通道回调总是导出（各自再校验）。

    同时为这个条目签好网关令牌：注入了宿主操作的，令牌带操作授权（含 ``act_as``）；
    没有的，令牌只能调运行时接口。
    """
    from movieclaw_api.plugins.keys import (
        AGENT,
        HOST_OPS,
        PLUGIN_CALLBACKS,
        PLUGIN_DATA,
        PLUGIN_FILES,
        PLUGIN_HEALTH,
        PLUGIN_ROUTES,
    )
    from movieclaw_api.services.auth import PluginGrant, issue_plugin_token, revoke_plugin_token

    exports: dict[str, Any] = {
        "session": _Session(session),
        "hooks": _Hooks(session),
        "net": _Net(session.entry_id),
        "job": _Job(session),
        "channels": _Channels(session),
    }
    if HOST_OPS.name in names:
        client = await ctx.use(HOST_OPS).client(ctx)
        session.token = client.token
        exports["ops"] = _Ops(client)
    else:
        session.token = issue_plugin_token(
            PluginGrant(entry_id=ctx.entry_id, operations=frozenset())
        )
        token = session.token
        ctx.effect(lambda: revoke_plugin_token(token), label="revoke-plugin-token")
    if PLUGIN_FILES.name in names:
        session.files = ctx.use(PLUGIN_FILES).scoped(ctx)
        exports["files"] = _Files(session, session.files)
    if PLUGIN_DATA.name in names:
        exports["data"] = _Data(ctx.use(PLUGIN_DATA).scoped(ctx))
    if PLUGIN_HEALTH.name in names:
        exports["health"] = _Health(ctx.use(PLUGIN_HEALTH).reporter(ctx))
    if PLUGIN_CALLBACKS.name in names:
        exports["callbacks"] = _Callbacks(ctx, ctx.use(PLUGIN_CALLBACKS))
    if PLUGIN_ROUTES.name in names:
        exports["routes"] = _Routes(ctx, ctx.use(PLUGIN_ROUTES))
    if AGENT.name in names:
        exports["agent"] = ctx.use(AGENT).for_entry(ctx)
    return exports


def own_services(entry_id: str) -> set[str]:
    """进程外插件能问代理的服务名：条目 id 本身。

    旧格式（带点）的 id 按最后一段（``channel.telegram`` → ``telegram``）；替换随带通道的插件包
    沿用随带通道的出口规则（「设置 → 网络与代理」里的 telegram 等）。
    """
    from movieclaw_api.plugins.bundled import LEGACY_IDS, canonical

    names = {entry_id}
    if "." in entry_id:
        names.add(entry_id.rsplit(".", 1)[-1])
    legacy = {new: old for old, new in LEGACY_IDS.items()}.get(canonical(entry_id))
    if legacy is not None:
        names.add(legacy.rsplit(".", 1)[-1])
    return names


def remote_plugin(
    entry_id: str,
    *,
    title: str,
    path: Path,
    module: str,
    inject: tuple[str, ...] = (),
    permissions: tuple[str, ...] = (),
    config_description: dict[str, Any] | None = None,
    command: str | None = None,
) -> Plugin:
    """进程外运行的插件条目：代码在子进程里，内核里只有代理。

    ``inject`` / ``permissions`` 来自插件自己的声明（``describe``），宿主据此注入服务、
    发宿主操作授权。``command`` 是非 Python 插件的可执行文件（相对插件目录）。
    """
    services = _open_services()
    unknown = [name for name in inject if name not in services]
    if unknown:
        raise ValueError(f"进程外插件暂不能使用服务：{'、'.join(unknown)}")
    process_entries.add(entry_id)
    # 配置模型在子进程里，主进程只拿到它的描述（describe）；界面设置据此渲染
    config_descriptions[entry_id] = config_description
    process_specs[entry_id] = (path, module, command)

    async def apply(ctx: Context) -> None:
        # 卸下后（如插件包被卸载、换回同 id 的随带插件包）诊断不能还显示「独立进程」
        process_entries.add(entry_id)
        ctx.effect(lambda: process_entries.discard(entry_id), label="forget-runtime")
        session = Session(
            entry_id,
            path=path,
            module=module,
            # 内核合并好的配置（清单配置 + 界面设置），每次启动现读：改设置后重启即生效
            config=dict(ctx.config or {}),
            data_dir=getattr(ctx.settings, "data_dir", "./data"),
            command=command,
        )
        session.exports = await _exports(ctx, session, inject)
        # 先登记再拉起：插件在 apply 里就会经网关调宿主服务，网关按条目找会话
        sessions[entry_id] = session
        ctx.effect(lambda: sessions.pop(entry_id, None), label="forget-session")
        declarations = await session.start()
        session.declarations = declarations
        ctx.effect(session.stop, label="stop-process")
        for declaration in declarations:
            event, handler = _proxy(session, declaration)
            ctx.on(
                event, handler, id=declaration["id"], priority=int(declaration.get("priority", 0))
            )
        if session.routes:
            from movieclaw_api.plugins.keys import PLUGIN_ROUTES

            for mounted in session.routes:
                ctx.use(PLUGIN_ROUTES).mount(
                    ctx, _route_proxy(session, mounted["routes"]), zone=mounted["zone"]
                )
        for declared in session.callbacks:
            _callback_proxy(ctx, session, declared)
        for contribution in session.contributions:
            key, item = _contribution(session, contribution)
            ctx.contribute(
                key,
                contribution["id"],
                item,
                priority=int(contribution.get("priority", 0)),
                override=bool(contribution.get("override")),
            )
        # 下划线开头 = 宿主替插件挂的内部任务，不算插件的能力（详情页不列）
        ctx.task(session.supervise(), name="_supervise")

    return Plugin(
        name=entry_id,
        title=title,
        apply=apply,
        inject=tuple(services[name] for name in inject),
        permissions=permissions,
        disableable=True,
        apply_timeout=45.0,
    )

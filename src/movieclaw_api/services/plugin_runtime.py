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

from fastapi import Request
from fastapi.responses import StreamingResponse

from movieclaw_kernel import (
    DURABLE_EVENTS,
    Context,
    Delivery,
    Mode,
    Plugin,
    ServiceKey,
    current_delivery,
)
from movieclaw_sdk.protocol import MAX_LINE, decode, dump, encode, known_events, load

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
RpcFn = Callable[[str, dict[str, Any], str | None], Awaitable[Any]]

#: 正在运行的插件进程（诊断与测试用）
sessions: dict[str, Session] = {}
#: 以独立进程运行的条目（诊断页据此区分「进程内 / 独立进程」）
process_entries: set[str] = set()
#: 进程外插件的配置描述（``describe_config`` 的结果），条目 id → 描述
config_descriptions: dict[str, dict[str, Any] | None] = {}
#: 进程外插件的代码位置（目录、模块），校验设置时另起子进程用
process_specs: dict[str, tuple[Path, str]] = {}


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
        self, entry_id: str, *, path: Path, module: str, config: Any, data_dir: str = "./data"
    ) -> None:
        self.entry_id = entry_id
        self._data_dir = str(Path(data_dir).resolve())
        self._path = path
        self._module = module
        self._config = config
        self._proc: asyncio.subprocess.Process | None = None
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._nexts: dict[str, NextFn] = {}
        self._contexts: dict[str, contextvars.Context] = {}
        self.jobs: dict[str, Any] = {}
        """正在子进程里执行的任务：调用编号 → 宿主这边真实的 ``JobContext``。"""
        self.rpc_handler: RpcFn | None = None
        self.contributions: list[dict[str, Any]] = []
        self.channels: dict[str, Any] = {}
        """这个插件贡献的通道：贡献 id → 宿主侧的驱动桩（plugin_channels.py）。"""
        self.routes: list[dict[str, Any]] = []
        self.callbacks: list[dict[str, Any]] = []
        self._fd_host: socket.socket | None = None
        self.files: Any = None
        """宿主侧这个条目的 ``PluginFiles``（插件注入了 PLUGIN_FILES 时才有）。"""
        # Unix 套接字路径有长度上限（macOS 104 字节）：放在临时目录、用短哈希命名
        digest = hashlib.sha1(f"{entry_id}:{os.getpid()}".encode()).hexdigest()[:12]
        self.socket = str(Path(tempfile.gettempdir()) / f"mcp-{digest}.sock")
        self._ids = itertools.count(1)
        self._readers: list[asyncio.Task[Any]] = []
        self._stopping = False
        self._ready = False
        self._crashes: deque[float] = deque()
        self.declarations: list[dict[str, Any]] = []
        self.title: str | None = None

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

    # ------------------------------------------------------------------ 启动
    async def start(self) -> list[dict[str, Any]]:
        """拉起进程并握手，返回插件声明的监听器；插件启动失败抛错（内核据此标 FAILED）。"""
        self._ready = False
        launch = await asyncio.to_thread(_launch, self.entry_id, self._path, self._module)
        # 路由套接字：上一个进程（可能是别的用户）留下的文件先清掉，插件用户在 /tmp 里删不了它
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.socket)
        # 文件通道：宿主检查授权后打开文件，把描述符经这对套接字递给插件（services/plugin_files.py）
        self._close_fd_channel()
        self._fd_host, child_end = socket.socketpair()
        try:
            self._proc = await asyncio.create_subprocess_exec(
                sys.executable,
                "-s",
                "-m",
                "movieclaw_sdk.runner",
                "--path",
                str(launch.cwd),
                "--module",
                self._module,
                "--entry",
                self.entry_id,
                "--fd-socket",
                str(child_end.fileno()),
                *launch.args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(launch.cwd),
                env=launch.env,
                limit=MAX_LINE,
                pass_fds=(child_end.fileno(),),
            )
        finally:
            child_end.close()
        self._readers = [
            asyncio.get_running_loop().create_task(self._pump_stderr(self._proc)),
        ]
        try:
            declarations = await asyncio.wait_for(self._handshake(self._proc), HANDSHAKE_TIMEOUT)
        except BaseException:
            await self._kill()
            raise
        self._readers.append(asyncio.get_running_loop().create_task(self._pump_stdout(self._proc)))
        self._ready = True
        logger.info(
            "插件 %s 已在独立进程中运行（pid %s，%d 个监听器）",
            self.entry_id,
            self._proc.pid,
            len(declarations),
        )
        return declarations

    async def _handshake(self, proc: asyncio.subprocess.Process) -> list[dict[str, Any]]:
        assert proc.stdout is not None
        hello = await self._read(proc)
        if hello["type"] != "hello":
            raise RuntimeError(f"插件进程握手失败：期望 hello，收到 {hello['type']}")
        await self._send(
            {
                "type": "init",
                "entry_id": self.entry_id,
                "config": self._config,
                "data_dir": self._data_dir,
                "socket": self.socket,
            }
        )
        declarations: list[dict[str, Any]] = []
        self.contributions = []
        self.routes = []
        self.callbacks = []
        while True:
            message = await self._read(proc)
            kind = message["type"]
            if kind == "on":
                declarations.append(message)
            elif kind == "contribute":
                self.contributions.append(message)
            elif kind == "routes":
                self.routes.append(message)
            elif kind == "callback":
                self.callbacks.append(message)
            elif kind == "rpc":
                # 插件在 apply 里就要用宿主服务（拿宿主操作凭证、读插件数据）
                asyncio.get_running_loop().create_task(self._run_rpc(message))
            elif kind == "ready":
                self.title = message.get("title")
                return declarations
            elif kind == "failed":
                raise _remote_error(message)
            else:
                raise RuntimeError(f"插件进程握手期间发来意外的消息：{kind}")

    async def _read(self, proc: asyncio.subprocess.Process) -> dict[str, Any]:
        assert proc.stdout is not None
        line = await proc.stdout.readline()
        if not line:
            code = await proc.wait()
            raise PluginProcessGone(f"插件进程启动期间退出（退出码 {code}）")
        return decode(line)

    async def _send(self, message: dict[str, Any]) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or proc.returncode is not None:
            raise PluginProcessGone("插件进程不在运行")
        proc.stdin.write(encode(message))
        try:
            await proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError) as exc:
            raise PluginProcessGone("插件进程不在运行") from exc

    # ------------------------------------------------------------------ 读取
    async def _pump_stderr(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stderr is not None
        while line := await proc.stderr.readline():
            logger.info("[%s] %s", self.entry_id, line.decode("utf-8", "replace").rstrip())

    async def _pump_stdout(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout is not None
        try:
            while line := await proc.stdout.readline():
                message = decode(line)
                kind = message["type"]
                if kind == "reply":
                    future = self._pending.pop(message["id"], None)
                    if future is not None and not future.done():
                        future.set_result(message)
                elif kind == "next":
                    asyncio.get_running_loop().create_task(self._run_next(message))
                elif kind == "rpc":
                    # 在发起这次调用的事件的上下文里执行：发起方、因果链、可靠事件的投递信息原样沿用
                    context = self._contexts.get(message.get("call") or "")
                    asyncio.get_running_loop().create_task(self._run_rpc(message), context=context)
                elif kind == "disposed":
                    pass
                else:
                    logger.warning("插件 %s 发来意外的消息：%s", self.entry_id, kind)
        except ValueError:
            logger.exception("插件 %s 发来无法解析的消息，断开", self.entry_id)
            await self._kill()
        finally:
            if proc is self._proc:
                self._ready = False
                self._fail_pending(PluginProcessGone("插件进程已退出"))

    async def _run_next(self, message: dict[str, Any]) -> None:
        call_id = message["id"]
        run = self._nexts.pop(call_id, None)
        reply: dict[str, Any] = {"type": "next_result", "id": call_id}
        if run is None:
            reply.update(ok=False, error="这次调用已经结束")
        else:
            try:
                reply.update(ok=True, result=await run(message.get("payload", _UNSET)))
            except Exception as exc:  # noqa: BLE001 -- 下游出错原样告诉插件
                reply.update(ok=False, error=f"{type(exc).__name__}: {exc}")
        with contextlib.suppress(PluginProcessGone):
            await self._send(reply)

    async def _run_rpc(self, message: dict[str, Any]) -> None:
        reply: dict[str, Any] = {"type": "rpc_result", "id": message["id"]}
        try:
            if self.rpc_handler is None:
                raise RuntimeError("宿主没有为这个插件提供服务")
            result = await self.rpc_handler(
                message["method"], message.get("params") or {}, message.get("call")
            )
            reply.update(ok=True, result=result)
        except Exception as exc:  # noqa: BLE001 -- 原样告诉插件，由插件决定怎么处理
            from movieclaw_api.services.host_ops import OpsError

            if isinstance(exc, OpsError):
                error = {
                    "kind": "ops",
                    "status": exc.status,
                    "code": exc.code,
                    "message": exc.message,
                    "details": exc.details,
                }
            elif isinstance(exc, PermissionError):
                error = {"kind": "permission", "message": str(exc)}
            elif isinstance(exc, FileNotFoundError):
                error = {"kind": "not_found", "message": str(exc)}
            elif isinstance(exc, ValueError):
                error = {"kind": "value", "message": str(exc)}
            else:
                error = {"kind": "service", "message": f"{type(exc).__name__}: {exc}"}
            reply.update(ok=False, error=error)
        with contextlib.suppress(PluginProcessGone):
            await self._send(reply)

    async def send_fd(self, token: str, fd: int) -> None:
        if self._fd_host is None:
            raise PluginProcessGone("文件通道已关闭")
        await asyncio.to_thread(socket.send_fds, self._fd_host, [token.encode()], [fd])

    def _close_fd_channel(self) -> None:
        if self._fd_host is not None:
            self._fd_host.close()
            self._fd_host = None

    def _fail_pending(self, exc: Exception) -> None:
        for future in self._pending.values():
            if not future.done():
                future.set_exception(exc)
        self._pending.clear()
        self._nexts.clear()

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
        if not self.online:
            raise PluginProcessGone(f"插件 {self.entry_id} 的进程不在运行")
        call_id = str(next(self._ids))
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[call_id] = future
        self._contexts[call_id] = contextvars.copy_context()
        if run_next is not None:
            self._nexts[call_id] = run_next
        message: dict[str, Any] = {
            "type": "call",
            "id": call_id,
            "listener": listener,
            "payload": payload,
        }
        if job is not None:
            self.jobs[call_id] = job
            message.update(kind="job", job_id=job.job_id)
        elif kind is not None:
            message["kind"] = kind
        delivery = current_delivery.get()
        if delivery is not None:
            message["delivery"] = {
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
        watcher: asyncio.Task[None] | None = None
        if cancel is not None:
            # 调用方要停（如通道账号停止）：告诉插件取消这次调用，插件体面退出后照常回复
            async def relay() -> None:
                await cancel.wait()
                with contextlib.suppress(PluginProcessGone):
                    await self._send({"type": "cancel", "id": call_id})

            watcher = asyncio.get_running_loop().create_task(relay())
        try:
            await self._send(message)
            reply = await asyncio.wait_for(future, timeout)
        finally:
            if watcher is not None:
                watcher.cancel()
            self._pending.pop(call_id, None)
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
        self._stopping = True
        proc = self._proc
        if proc is not None and proc.returncode is None:
            with contextlib.suppress(PluginProcessGone, asyncio.TimeoutError):
                await self._send({"type": "dispose"})
                await asyncio.wait_for(proc.wait(), STOP_GRACE)
            if proc.returncode is None:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), STOP_GRACE)
                except TimeoutError:
                    proc.kill()
                    await proc.wait()
        for task in self._readers:
            task.cancel()
        await asyncio.gather(*self._readers, return_exceptions=True)
        self._fail_pending(PluginProcessGone("插件已卸载"))
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


#: 不跨跳转发的头（逐跳头与由传输层重新生成的头）
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
        client = httpx.AsyncClient(
            transport=httpx.AsyncHTTPTransport(uds=session.socket),
            base_url="http://plugin",
            timeout=httpx.Timeout(30.0, read=None),
        )
        headers = [(k, v) for k, v in request.headers.items() if k.lower() not in _HOP_HEADERS]
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
            await client.aclose()
            raise unavailable() from exc
        except BaseException:
            await client.aclose()
            raise
        sendfile_path = response.headers.get(SENDFILE_HEADER)
        if sendfile_path is not None:
            from urllib.parse import unquote

            sendfile_path = unquote(sendfile_path)
            # 插件只交出了路径：宿主检查读授权后自己发送（支持 Range），插件碰不到字节
            await response.aclose()
            await client.aclose()
            if session.files is None:
                raise unavailable()
            return await sendfile(session.files, sendfile_path)

        async def close() -> None:
            await response.aclose()
            await client.aclose()

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
        HOST_OPS,
        PLUGIN_CALLBACKS,
        PLUGIN_DATA,
        PLUGIN_FILES,
        PLUGIN_HEALTH,
        PLUGIN_ROUTES,
    )

    return {
        PLUGIN_CALLBACKS.name: PLUGIN_CALLBACKS,
        PLUGIN_FILES.name: PLUGIN_FILES,
        HOST_OPS.name: HOST_OPS,
        PLUGIN_DATA.name: PLUGIN_DATA,
        PLUGIN_HEALTH.name: PLUGIN_HEALTH,
        PLUGIN_ROUTES.name: PLUGIN_ROUTES,
        DURABLE_EVENTS.name: DURABLE_EVENTS,
    }


def describe(path: Path, module: str, entry_id: str) -> dict[str, Any]:
    """在子进程里读出插件的声明（标题、要注入的服务、宿主操作），主进程不导入插件代码。

    导入插件代码就会执行它的模块级代码，所以这一步与正式运行同样隔离（同一用户、同一代码副本）。
    """
    launch = _launch(entry_id, path, module)
    proc = subprocess.run(
        [
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
            "--describe",
            *launch.args,
        ],
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
    path, module = spec
    launch = _launch(entry_id, path, module)
    proc = subprocess.run(
        [
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
            "--validate",
            *launch.args,
        ],
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


async def _service_handler(ctx: Context, session: Session, names: tuple[str, ...]) -> RpcFn:
    """插件在子进程里调宿主服务时，宿主这边代它执行（以它自己的上下文、凭证与数据作用域）。"""
    from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA, PLUGIN_FILES, PLUGIN_HEALTH

    client = await ctx.use(HOST_OPS).client(ctx) if HOST_OPS.name in names else None
    files = ctx.use(PLUGIN_FILES).scoped(ctx) if PLUGIN_FILES.name in names else None
    session.files = files
    store = ctx.use(PLUGIN_DATA).scoped(ctx) if PLUGIN_DATA.name in names else None
    health = ctx.use(PLUGIN_HEALTH).reporter(ctx) if PLUGIN_HEALTH.name in names else None

    def need(service: Any, name: str) -> Any:
        if service is None:
            raise LookupError(f"服务 {name} 没有在 inject 里声明")
        return service

    async def handle(method: str, params: dict[str, Any], call: str | None) -> Any:
        if method.startswith("job."):
            context = session.jobs.get(call or "")
            if context is None:
                raise LookupError("只能在任务处理器里汇报任务进度")
            if method == "job.update_progress":
                await context.update_progress(**params)
                return None
            if method == "job.current_progress":
                return await context.current_progress()
            if method == "job.cancel_requested":
                return await context.cancel_requested()
        if method.startswith("files."):
            return await _files_call(session, need(files, PLUGIN_FILES.name), method, params)
        if method.startswith("channel."):
            stub = session.channels.get(params.get("channel") or "")
            if stub is None:
                raise LookupError("这个插件没有贡献这个通道")
            await stub.callback(method, params)
            return None
        if method == "net.proxy":
            # 代理地址可能带账号密码：只回答插件自己的服务名，别的服务直连
            from movieclaw_net import resolve_proxy_url

            service = str(params.get("service") or "")
            if service not in own_services(session.entry_id):
                return None
            return resolve_proxy_url(service)
        if method.startswith("callbacks."):
            from movieclaw_api.plugins.keys import PLUGIN_CALLBACKS
            from movieclaw_sdk.callbacks import issued_dict

            callbacks = need(
                ctx.use(PLUGIN_CALLBACKS) if PLUGIN_CALLBACKS.name in names else None,
                PLUGIN_CALLBACKS.name,
            )
            if method == "callbacks.issue":
                issued = await callbacks.issue(
                    ctx, str(params["name"]), scope=str(params.get("scope") or "plugin")
                )
                return issued_dict(issued)
            if method == "callbacks.revoke":
                await callbacks.revoke(ctx, int(params["key_id"]))
                return None
            if method == "callbacks.keys":
                return [issued_dict(i) for i in await callbacks.keys(ctx, params.get("name"))]
        if method == "routes.sign":
            from movieclaw_api.plugins.keys import PLUGIN_ROUTES

            return await ctx.use(PLUGIN_ROUTES).sign(
                ctx,
                params["path"],
                params=params.get("params"),
                expires_in=params.get("expires_in"),
                absolute=bool(params.get("absolute")),
            )
        if method == "ops.client":
            return {"operations": sorted(need(client, HOST_OPS.name).operations)}
        if method == "ops.call":
            return await need(client, HOST_OPS.name).call(
                params["operation_id"], params.get("arguments"), timeout=params.get("timeout")
            )
        if method.startswith("data."):
            data = need(store, PLUGIN_DATA.name)
            scope = params.get("scope") or "global"
            if method == "data.get":
                value = await data.get(params["key"], scope=scope, default=_MISSING)
                return {
                    "found": value is not _MISSING,
                    "value": None if value is _MISSING else value,
                }
            if method == "data.set":
                await data.set(
                    params["key"],
                    params.get("value"),
                    scope=scope,
                    secret=bool(params.get("secret")),
                )
                return None
            if method == "data.delete":
                return await data.delete(params["key"], scope=scope)
            if method == "data.items":
                return await data.items(scope=scope)
            if method == "data.scopes":
                return await data.scopes(params["key"], entity=params.get("entity"))
        if method == "health.degraded":
            await need(health, PLUGIN_HEALTH.name).degraded(
                params["key"], params["message"], action_href=params.get("action_href")
            )
            return None
        if method == "health.ok":
            await need(health, PLUGIN_HEALTH.name).ok(params["key"], params.get("message") or "")
            return None
        raise LookupError(f"未知的服务调用：{method}")

    return handle


_OPEN_FLAGS = {
    "rb": os.O_RDONLY,
    "wb": os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
    "ab": os.O_WRONLY | os.O_CREAT | os.O_APPEND,
    "r+b": os.O_RDWR,
    "w+b": os.O_RDWR | os.O_CREAT | os.O_TRUNC,
    "a+b": os.O_RDWR | os.O_CREAT | os.O_APPEND,
}


async def _files_call(session: Session, files: Any, method: str, params: dict[str, Any]) -> Any:
    """进程外插件的文件请求：检查授权由 ``PluginFiles`` 做；``open`` 打开后把描述符递过去。"""
    if method == "files.open":
        mode = params.get("mode") or "rb"
        flags = _OPEN_FLAGS.get(mode.replace("br", "rb"))
        if flags is None:
            raise ValueError(f"不支持的打开模式：{mode}")
        real = await files.check(params["path"], write=mode != "rb")
        fd = await asyncio.to_thread(os.open, real, flags | os.O_CLOEXEC, 0o644)
        token = f"f{next(_tokens)}"
        try:
            await session.send_fd(token, fd)
        finally:
            os.close(fd)
        return {"token": token}
    if method == "files.stat":
        return await files.stat(params["path"])
    if method == "files.listdir":
        return await files.listdir(params["path"])
    if method == "files.makedirs":
        await files.makedirs(params["path"])
        return None
    if method == "files.rename":
        await files.rename(params["src"], params["dst"])
        return None
    if method == "files.remove":
        await files.remove(params["path"])
        return None
    raise LookupError(f"未知的文件请求：{method}")


_tokens = itertools.count(1)


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
) -> Plugin:
    """进程外运行的插件条目：代码在子进程里，内核里只有代理。

    ``inject`` / ``permissions`` 来自插件自己的声明（``describe``），宿主据此注入服务、
    发宿主操作授权。
    """
    services = _open_services()
    unknown = [name for name in inject if name not in services]
    if unknown:
        raise ValueError(f"进程外插件暂不能使用服务：{'、'.join(unknown)}")
    process_entries.add(entry_id)
    # 配置模型在子进程里，主进程只拿到它的描述（describe）；界面设置据此渲染
    config_descriptions[entry_id] = config_description
    process_specs[entry_id] = (path, module)

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
        )
        session.rpc_handler = await _service_handler(ctx, session, inject)
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
        ctx.task(session.supervise(), name="supervise")
        sessions[entry_id] = session
        ctx.effect(lambda: sessions.pop(entry_id, None), label="forget-session")

    return Plugin(
        name=entry_id,
        title=title,
        apply=apply,
        inject=tuple(services[name] for name in inject),
        permissions=permissions,
        disableable=True,
        apply_timeout=45.0,
    )

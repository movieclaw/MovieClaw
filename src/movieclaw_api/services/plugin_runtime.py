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
import subprocess
import sys
import tempfile
import time
from collections import deque
from collections.abc import Awaitable, Callable
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


class PluginProcessGone(RuntimeError):
    pass


class RemoteCallError(RuntimeError):
    """插件处理失败。

    ``job`` 是任务处理器抛出的控制异常（重试 / 阻塞 / 失败 / 取消）的结构化描述。
    """

    def __init__(self, message: str, *, job: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.job = job


def _child_env() -> dict[str, str]:
    import movieclaw_sdk

    env = {k: v for k, v in os.environ.items() if k in _ENV_KEEP}
    # 与宿主同一份代码（overlay 部署时是 overlay 里的那份）
    env["PYTHONPATH"] = str(Path(movieclaw_sdk.__file__).resolve().parent.parent)
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


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
        self.routes: list[dict[str, Any]] = []
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
        self._proc = await asyncio.create_subprocess_exec(
            sys.executable,
            "-s",
            "-m",
            "movieclaw_sdk.runner",
            "--path",
            str(self._path),
            "--module",
            self._module,
            "--entry",
            self.entry_id,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(self._path),
            env=_child_env(),
            limit=MAX_LINE,
        )
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
        while True:
            message = await self._read(proc)
            kind = message["type"]
            if kind == "on":
                declarations.append(message)
            elif kind == "contribute":
                self.contributions.append(message)
            elif kind == "routes":
                self.routes.append(message)
            elif kind == "rpc":
                # 插件在 apply 里就要用宿主服务（拿宿主操作凭证、读插件数据）
                asyncio.get_running_loop().create_task(self._run_rpc(message))
            elif kind == "ready":
                self.title = message.get("title")
                return declarations
            elif kind == "failed":
                raise RuntimeError(message.get("error") or "插件启动失败")
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
            elif isinstance(exc, ValueError):
                error = {"kind": "value", "message": str(exc)}
            else:
                error = {"kind": "service", "message": f"{type(exc).__name__}: {exc}"}
            reply.update(ok=False, error=error)
        with contextlib.suppress(PluginProcessGone):
            await self._send(reply)

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
        try:
            await self._send(message)
            reply = await asyncio.wait_for(future, timeout)
        finally:
            self._pending.pop(call_id, None)
            self._nexts.pop(call_id, None)
            self._contexts.pop(call_id, None)
            self.jobs.pop(call_id, None)
        if not reply.get("ok"):
            raise RemoteCallError(
                f"插件 {self.entry_id} 处理失败：{reply.get('error')}", job=reply.get("job")
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
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.socket)

    async def _kill(self) -> None:
        proc = self._proc
        if proc is not None and proc.returncode is None:
            proc.kill()
            await proc.wait()


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

    async def forward(request: Request) -> StreamingResponse:
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


def _open_services() -> dict[str, ServiceKey[Any]]:
    """进程外插件能用的服务（插件侧有对应的代理，见 ``movieclaw_sdk.runner``）。"""
    from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA, PLUGIN_HEALTH, PLUGIN_ROUTES

    return {
        HOST_OPS.name: HOST_OPS,
        PLUGIN_DATA.name: PLUGIN_DATA,
        PLUGIN_HEALTH.name: PLUGIN_HEALTH,
        PLUGIN_ROUTES.name: PLUGIN_ROUTES,
        DURABLE_EVENTS.name: DURABLE_EVENTS,
    }


def describe(path: Path, module: str, entry_id: str) -> dict[str, Any]:
    """在子进程里读出插件的声明（标题、要注入的服务、宿主操作），主进程不导入插件代码。"""
    proc = subprocess.run(
        [
            sys.executable,
            "-s",
            "-m",
            "movieclaw_sdk.runner",
            "--path",
            str(path),
            "--module",
            module,
            "--entry",
            entry_id,
            "--describe",
        ],
        capture_output=True,
        cwd=str(path),
        env=_child_env(),
        timeout=DESCRIBE_TIMEOUT,
        check=False,
    )
    if proc.returncode != 0:
        tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["无输出"]
        raise RuntimeError(f"读取插件声明失败：{tail[0]}")
    return json.loads(proc.stdout.decode("utf-8").splitlines()[-1])


_MISSING: Any = object()


async def _service_handler(ctx: Context, session: Session, names: tuple[str, ...]) -> RpcFn:
    """插件在子进程里调宿主服务时，宿主这边代它执行（以它自己的上下文、凭证与数据作用域）。"""
    from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA, PLUGIN_HEALTH

    client = await ctx.use(HOST_OPS).client(ctx) if HOST_OPS.name in names else None
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


def remote_plugin(
    entry_id: str,
    *,
    title: str,
    path: Path,
    module: str,
    config: Any,
    inject: tuple[str, ...] = (),
    permissions: tuple[str, ...] = (),
) -> Plugin:
    """进程外运行的插件条目：代码在子进程里，内核里只有代理。

    ``inject`` / ``permissions`` 来自插件自己的声明（``describe``），宿主据此注入服务、
    发宿主操作授权。
    """
    services = _open_services()
    unknown = [name for name in inject if name not in services]
    if unknown:
        raise ValueError(f"进程外插件暂不能使用服务：{'、'.join(unknown)}")

    async def apply(ctx: Context) -> None:
        session = Session(
            entry_id,
            path=path,
            module=module,
            config=config,
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

"""进程外运行器（插件侧，docs/design/plugin-phase3.md §4）。

宿主以 ``python -s -m movieclaw_sdk.runner --path <插件目录> --module <模块> --entry <条目 id>``
拉起本进程，经标准输入输出交换协议消息。插件代码照常写 ``@plugin`` 和 ``ctx.on(...)``，拿到的是
``RemoteContext``：声明经协议告诉宿主，宿主在真实的内核上下文里登记代理；事件、钩子调用再经协议
送回这里执行。

插件自己的 ``print`` 会被改到标准错误（宿主按行收进日志），标准输出只留给协议。
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import contextvars
import dataclasses
import importlib
import itertools
import logging
import os
import sys
import time
import traceback
import types
from collections.abc import Callable, Coroutine
from pathlib import Path
from typing import Any

from movieclaw_kernel import (
    DURABLE_EVENTS,
    Delivery,
    DeliveryInfo,
    Event,
    Mode,
    Origin,
    Plugin,
    ServiceKey,
)
from movieclaw_sdk import SDK_VERSION
from movieclaw_sdk.protocol import MAX_LINE, decode, dump, encode, known_events, load

logger = logging.getLogger("movieclaw_sdk.runner")

_UNSET: Any = object()

#: 正在处理的宿主调用（事件 / 钩子）：插件在其中发起的服务调用带上它，宿主据此沿用发起方与因果链
_current_call: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "movieclaw_sdk_call", default=None
)
_current_delivery: contextvars.ContextVar[DeliveryInfo | None] = contextvars.ContextVar(
    "movieclaw_sdk_delivery", default=None
)


class RemoteServiceError(RuntimeError):
    pass


# ---------------------------------------------------------------------- 服务代理
class _RemoteOpsClient:
    def __init__(self, runner: Runner, entry_id: str, operations: list[str]) -> None:
        self._runner = runner
        self.entry_id = entry_id
        self.operations = frozenset(operations)

    def allowed(self, operation_id: str) -> bool:
        return operation_id in self.operations

    async def call(
        self,
        operation_id: str,
        arguments: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> Any:
        return await self._runner.rpc(
            "ops.call", {"operation_id": operation_id, "arguments": arguments, "timeout": timeout}
        )


class _RemoteHostOps:
    def __init__(self, runner: Runner) -> None:
        self._runner = runner

    async def client(self, ctx: Any, *, timeout: float | None = None) -> _RemoteOpsClient:
        reply = await self._runner.rpc("ops.client", {})
        return _RemoteOpsClient(self._runner, ctx.entry_id, reply["operations"])


class _RemoteStore:
    def __init__(self, runner: Runner, entry_id: str) -> None:
        self._runner = runner
        self.entry_id = entry_id

    async def get(self, key: str, *, scope: str = "global", default: Any = None) -> Any:
        found = await self._runner.rpc("data.get", {"key": key, "scope": scope})
        return found["value"] if found["found"] else default

    async def set(
        self, key: str, value: Any, *, scope: str = "global", secret: bool = False
    ) -> None:
        await self._runner.rpc(
            "data.set", {"key": key, "value": value, "scope": scope, "secret": secret}
        )

    async def delete(self, key: str, *, scope: str = "global") -> bool:
        return bool(await self._runner.rpc("data.delete", {"key": key, "scope": scope}))

    async def items(self, *, scope: str = "global") -> dict[str, Any]:
        return dict(await self._runner.rpc("data.items", {"scope": scope}))

    async def scopes(self, key: str, *, entity: str | None = None) -> dict[str, Any]:
        return dict(await self._runner.rpc("data.scopes", {"key": key, "entity": entity}))


class _RemotePluginData:
    def __init__(self, runner: Runner) -> None:
        self._runner = runner

    def scoped(self, ctx: Any) -> _RemoteStore:
        return _RemoteStore(self._runner, ctx.entry_id)


class _RemoteHealth:
    def __init__(self, runner: Runner) -> None:
        self._runner = runner

    async def degraded(self, key: str, message: str, *, action_href: str | None = None) -> None:
        await self._runner.rpc(
            "health.degraded", {"key": key, "message": message, "action_href": action_href}
        )

    async def ok(self, key: str, message: str = "") -> None:
        await self._runner.rpc("health.ok", {"key": key, "message": message})


class _RemotePluginHealth:
    def __init__(self, runner: Runner) -> None:
        self._runner = runner

    def reporter(self, ctx: Any) -> _RemoteHealth:
        return _RemoteHealth(self._runner)


class RemoteJobContext:
    """进程外任务处理器拿到的 ``JobContext``：进度、取消查询经协议交给宿主的真实上下文。"""

    def __init__(self, runner: Runner, job_id: str) -> None:
        self._runner = runner
        self.job_id = job_id
        self._last_progress_write = time.monotonic() - 3600.0

    def progress_due(self, *, min_interval: float = 1.0) -> bool:
        now = time.monotonic()
        if now - self._last_progress_write < min_interval:
            return False
        self._last_progress_write = now
        return True

    async def update_progress(self, **progress: Any) -> None:
        await self._runner.rpc("job.update_progress", progress)

    async def current_progress(self) -> dict[str, Any]:
        return dict(await self._runner.rpc("job.current_progress", {}) or {})

    async def cancel_requested(self) -> bool:
        return bool(await self._runner.rpc("job.cancel_requested", {}))

    async def raise_if_cancelled(self) -> None:
        from movieclaw_api.services.jobs import JobCancelled

        if await self.cancel_requested():
            raise JobCancelled()

    async def acquire_target_resource(self, resource_type: str, resource_id: str | int) -> bool:
        raise NotImplementedError("进程外任务暂不能申请资源锁")


def _contribution(registry: str, item: Any) -> tuple[dict[str, Any], Any]:
    """注册表贡献项 → （发给宿主的数据，留在本进程的东西）。只开放纯数据项与任务处理器。"""
    if registry == "job-handlers":
        return {"versions": sorted(item.definition_versions)}, item.handler
    if registry == "ingest-steps":
        return dataclasses.asdict(item), None
    if registry == "site-data-packs":
        return {"path": str(Path(item).resolve())}, None
    raise NotImplementedError(f"进程外插件暂不能往注册表 {registry} 贡献")


class _RemotePluginRoutes:
    """插件路由：路由器挂进本进程自己的 ASGI 应用（Unix 套接字）。

    宿主按区挂代理路由，鉴权、验签都在宿主；请求与响应流式转发。
    """

    def __init__(self, runner: Runner) -> None:
        self._runner = runner

    def mount(self, ctx: Any, router: Any, *, zone: str = "admin") -> str:
        from fastapi.routing import APIRoute

        prefix = f"/api/v1/plugins/{ctx.entry_id}"
        routes = [
            {
                "path": route.path,
                "methods": sorted(route.methods or ()),
                "operation_id": route.operation_id,
                "summary": route.summary,
                "name": route.name,
            }
            for route in router.routes
            if isinstance(route, APIRoute)
        ]
        self._runner.serve_router(router, prefix)
        self._runner.send({"type": "routes", "zone": zone, "routes": routes})
        return prefix

    async def sign(
        self,
        ctx: Any,
        path: str,
        *,
        params: dict[str, str] | None = None,
        expires_in: int | None = None,
        absolute: bool = False,
    ) -> str:
        return await self._runner.rpc(
            "routes.sign",
            {"path": path, "params": params, "expires_in": expires_in, "absolute": absolute},
        )


class _RemoteFiles:
    """文件接口（插件侧）。

    ``open`` 由宿主检查授权后打开，文件描述符经专用套接字递过来，插件直接读写。
    """

    def __init__(self, runner: Runner, entry_id: str, data_dir: str) -> None:
        self._runner = runner
        self.entry_id = entry_id
        self._private = Path(data_dir) / "plugins" / "data" / entry_id

    async def open(self, path: Any, mode: str = "rb") -> Any:
        if "b" not in mode:
            raise ValueError("只支持二进制模式（rb / wb / ab / r+b）")
        reply = await self._runner.rpc("files.open", {"path": os.fspath(path), "mode": mode})
        fd = await self._runner.receive_fd(reply["token"])
        return os.fdopen(fd, mode)

    async def stat(self, path: Any) -> dict[str, Any] | None:
        return await self._runner.rpc("files.stat", {"path": os.fspath(path)})

    async def exists(self, path: Any) -> bool:
        return await self.stat(path) is not None

    async def listdir(self, path: Any) -> list[str]:
        return list(await self._runner.rpc("files.listdir", {"path": os.fspath(path)}))

    async def makedirs(self, path: Any) -> None:
        await self._runner.rpc("files.makedirs", {"path": os.fspath(path)})

    async def rename(self, src: Any, dst: Any) -> None:
        await self._runner.rpc("files.rename", {"src": os.fspath(src), "dst": os.fspath(dst)})

    async def remove(self, path: Any) -> None:
        await self._runner.rpc("files.remove", {"path": os.fspath(path)})

    def path(self, alias: str, *parts: str) -> str:
        if alias != "plugin":
            raise ValueError("path() 只支持 plugin 别名")
        return str(self._private.joinpath(*parts))

    def response(self, path: Any) -> Any:
        """路由里交出文件：只回一个响应头，宿主代理检查授权后自己发送（插件碰不到字节）。"""
        from urllib.parse import quote

        from starlette.responses import Response

        # 响应头只能是 latin-1：路径（常含中文）按百分号编码，宿主侧解码
        return Response(status_code=200, headers={"X-MovieClaw-Sendfile": quote(os.fspath(path))})


class _RemotePluginFiles:
    def __init__(self, runner: Runner) -> None:
        self._runner = runner

    def scoped(self, ctx: Any) -> _RemoteFiles:
        return _RemoteFiles(self._runner, ctx.entry_id, ctx.settings.data_dir)


_SERVICE_PROXIES: dict[str, Callable[[Runner], Any]] = {
    "host-ops": _RemoteHostOps,
    "plugin-data": _RemotePluginData,
    "plugin-health": _RemotePluginHealth,
    "plugin-routes": _RemotePluginRoutes,
    "plugin-files": _RemotePluginFiles,
}


class RemoteContext:
    """进程外插件拿到的上下文：与内核 ``Context`` 同名同签名。

    支持事件与钩子（含可靠事件与 ``ctx.delivery``）、后台任务、清理；宿主操作、插件数据、
    健康上报三种服务；往任务处理器、入库槽位、站点数据包三个注册表贡献；插件路由与签名链接。
    """

    def __init__(
        self,
        runner: Runner,
        entry_id: str,
        title: str,
        config: Any,
        inject: tuple[str, ...],
        data_dir: str = "./data",
    ) -> None:
        self._runner = runner
        self._inject = inject
        #: 只有数据目录：进程外插件拿不到宿主的完整配置（里面有主密钥、数据库地址）
        self.settings = types.SimpleNamespace(data_dir=data_dir)
        self.entry_id = entry_id
        self.title = title
        self.config = config
        self.third_party = True
        self.logger = logging.getLogger(f"movieclaw_plugin.{entry_id}")
        self._handlers: dict[str, tuple[Event[Any, Any], Callable[..., Any]]] = {}
        self._jobs: dict[str, Callable[..., Any]] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._effects: list[Callable[[], Any]] = []

    def on(
        self,
        event: Event[Any, Any],
        handler: Callable[..., Any],
        *,
        id: str | None = None,
        priority: int = 0,
    ) -> None:
        if known_events().get(event.name) is not event:
            raise ValueError(f"事件 {event.name} 没有开放给第三方插件")
        if event.delivery is Delivery.DURABLE:
            if not id:
                raise ValueError(f"可靠事件 {event.name} 的监听器必须有稳定 id")
            if DURABLE_EVENTS.name not in self._inject:
                raise ValueError(f"订阅可靠事件 {event.name} 须在 inject 里声明 DURABLE_EVENTS")
        key = id or f"{event.name}#{len(self._handlers)}"
        if key in self._handlers:
            raise ValueError(f"监听器 id 重复：{key}")
        self._handlers[key] = (event, handler)
        self._runner.send({"type": "on", "event": event.name, "id": key, "priority": priority})

    def task(self, coro: Coroutine[Any, Any, Any], *, name: str) -> asyncio.Task[Any]:
        task = asyncio.get_running_loop().create_task(coro, name=f"plugin:{self.entry_id}:{name}")
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def effect(self, disposer: Callable[[], Any], *, label: str = "effect") -> None:
        self._effects.append(disposer)

    @property
    def delivery(self) -> DeliveryInfo | None:
        """当前在处理的可靠事件的投递信息（与内核 ``ctx.delivery`` 相同）。"""
        return _current_delivery.get()

    def use(self, key: ServiceKey[Any]) -> Any:
        if key.name not in self._inject:
            raise LookupError(f"服务 {key.name} 没有在 inject 里声明")
        factory = _SERVICE_PROXIES.get(key.name)
        if factory is None:
            raise NotImplementedError(f"进程外插件暂不能使用服务 {key.name}")
        return factory(self._runner)

    def contribute(
        self,
        key: Any,
        id: str,
        item: Any,
        *,
        priority: int = 0,
        override: bool = False,
    ) -> None:
        data, local = _contribution(key.name, item)
        if key.name == "job-handlers":
            self._jobs[id] = local
        self._runner.send(
            {
                "type": "contribute",
                "registry": key.name,
                "id": id,
                "item": data,
                "priority": priority,
                "override": override,
            }
        )

    async def dispose(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        for disposer in reversed(self._effects):
            try:
                result = disposer()
                if asyncio.iscoroutine(result):
                    await result
            except Exception:  # noqa: BLE001 -- 清理出错不影响其余清理
                logger.exception("插件清理函数出错")


class Runner:
    def __init__(self, writer: Any) -> None:
        self._writer = writer
        self._rpcs: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._rpc_ids = itertools.count(1)
        self._nexts: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._calls: set[asyncio.Task[Any]] = set()
        self.ctx: RemoteContext | None = None
        self.socket: str | None = None
        self.fd_socket: Any = None
        self._fds: dict[str, int] = {}
        self._fd_waiters: dict[str, asyncio.Future[int]] = {}
        self._fd_lock = asyncio.Lock()
        self._app: Any = None
        self._server: Any = None
        self._serving: asyncio.Task[Any] | None = None

    async def receive_fd(self, token: str) -> int:
        """收宿主递来的文件描述符（宿主先发描述符、再回 RPC，同一条套接字上按序到达）。"""
        import socket

        if self.fd_socket is None:
            raise RuntimeError("宿主没有为这个插件建立文件通道")
        async with self._fd_lock:
            while token not in self._fds:
                message, fds, _flags, _addr = await asyncio.to_thread(
                    socket.recv_fds, self.fd_socket, 128, 1
                )
                if not message:
                    raise RuntimeError("文件通道已关闭")
                for got in fds:
                    self._fds[message.decode()] = got
            return self._fds.pop(token)

    def serve_router(self, router: Any, prefix: str) -> None:
        """第一次挂路由时在宿主指定的 Unix 套接字上起 ASGI 服务；之后的路由器挂到同一个应用上。"""
        from fastapi import FastAPI

        if self.socket is None:
            raise RuntimeError("宿主没有为这个插件分配路由套接字")
        if self._app is None:
            import uvicorn

            self._app = FastAPI(openapi_url=None, docs_url=None, redoc_url=None)
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.socket)
            config = uvicorn.Config(
                self._app, uds=self.socket, lifespan="off", log_level="warning", access_log=False
            )
            self._server = uvicorn.Server(config)
            self._serving = asyncio.get_running_loop().create_task(self._server.serve())
        self._app.include_router(router, prefix=prefix)

    async def wait_serving(self) -> None:
        if self._server is None:
            return
        deadline = time.monotonic() + 15
        while not self._server.started:
            if self._serving is not None and self._serving.done():
                self._serving.result()
                raise RuntimeError("插件路由服务没有起来")
            if time.monotonic() > deadline:
                raise RuntimeError("插件路由服务 15 秒内没有起来")
            await asyncio.sleep(0.02)

    async def stop_serving(self) -> None:
        if self._server is not None:
            self._server.should_exit = True
        if self._serving is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self._serving, 5)

    def send(self, message: dict[str, Any]) -> None:
        self._writer.write(encode(message))
        self._writer.flush()

    async def rpc(self, method: str, params: dict[str, Any]) -> Any:
        """请宿主执行一次服务调用（宿主操作、插件数据、健康上报）。"""
        rpc_id = f"r{next(self._rpc_ids)}"
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._rpcs[rpc_id] = future
        try:
            self.send(
                {
                    "type": "rpc",
                    "id": rpc_id,
                    "call": _current_call.get(),
                    "method": method,
                    "params": params,
                }
            )
            reply = await future
        finally:
            self._rpcs.pop(rpc_id, None)
        if reply.get("ok"):
            return reply.get("result")
        error = reply.get("error") or {}
        if error.get("kind") == "value":
            raise ValueError(error.get("message") or "参数不对")
        if error.get("kind") == "permission":
            raise PermissionError(error.get("message") or "没有授权")
        if error.get("kind") == "not_found":
            raise FileNotFoundError(error.get("message") or "文件不存在")
        if error.get("kind") == "ops":
            from movieclaw_api.services.host_ops import OpsError

            raise OpsError(
                error["status"], error["code"], error["message"], error.get("details") or None
            )
        raise RemoteServiceError(error.get("message") or "宿主服务调用失败")

    # ------------------------------------------------------------------ 调用
    async def _handle_call(self, message: dict[str, Any]) -> None:
        call_id = message["id"]
        _current_call.set(call_id)
        delivery = message.get("delivery")
        if delivery is not None:
            origin = delivery["origin"]
            _current_delivery.set(
                DeliveryInfo(
                    event_id=delivery["event_id"],
                    name=delivery["name"],
                    occurred_at=delivery["occurred_at"],
                    origin=Origin(
                        kind=origin["kind"], id=origin["id"], chain=tuple(origin["chain"])
                    ),
                    attempt=delivery["attempt"],
                )
            )
        if message.get("kind") == "job":
            await self._handle_job(message)
            return
        try:
            assert self.ctx is not None
            event, handler = self.ctx._handlers[message["listener"]]
            payload = load(event.payload, message["payload"])
            if event.mode is Mode.WATERFALL:
                result = await _maybe_await(handler(payload, self._next_for(call_id, event)))
            else:
                result = await _maybe_await(handler(payload))
            data = dump(event.result, result) if event.mode is not Mode.EMIT else None
            self.send({"type": "reply", "id": call_id, "ok": True, "result": data})
        except Exception as exc:  # noqa: BLE001 -- 监听器出错原样报给宿主，由宿主按内核规则处理
            self.send(
                {
                    "type": "reply",
                    "id": call_id,
                    "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                    "traceback": traceback.format_exc(limit=8),
                }
            )

    async def _handle_job(self, message: dict[str, Any]) -> None:
        from movieclaw_api.services.jobs import JobCancelled, JobControlError, JobRetry

        call_id = message["id"]
        reply: dict[str, Any] = {"type": "reply", "id": call_id}
        try:
            assert self.ctx is not None
            handler = self.ctx._jobs[message["listener"]]
            context = RemoteJobContext(self, message["job_id"])
            result = await _maybe_await(handler(context, message["payload"]))
            reply.update(ok=True, result=result)
        except JobCancelled:
            reply.update(ok=False, error="任务已取消", job={"cls": "JobCancelled"})
        except JobControlError as exc:
            job: dict[str, Any] = {"cls": type(exc).__name__, **exc.as_error()}
            if isinstance(exc, JobRetry):
                job["delay_seconds"] = exc.delay_seconds
            reply.update(ok=False, error=exc.message, job=job)
        except Exception as exc:  # noqa: BLE001 -- 未知错误：宿主按「未知错误」收敛
            traceback.print_exc()
            reply.update(ok=False, error=f"{type(exc).__name__}: {exc}")
        self.send(reply)

    def _next_for(self, call_id: str, event: Event[Any, Any]) -> Callable[..., Any]:
        async def next_(new_value: Any = _UNSET) -> Any:
            future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
            self._nexts[call_id] = future
            message: dict[str, Any] = {"type": "next", "id": call_id}
            if new_value is not _UNSET:
                message["payload"] = dump(event.payload, new_value)
            self.send(message)
            reply = await future
            if not reply.get("ok"):
                raise RuntimeError(reply.get("error") or "下游处理失败")
            return load(event.result, reply.get("result"))

        return next_

    # ------------------------------------------------------------------ 主循环
    async def serve(self, reader: asyncio.StreamReader) -> int:
        while True:
            line = await reader.readline()
            if not line:
                return 0  # 宿主关了管道：宿主没了，跟着退出
            message = decode(line)
            kind = message["type"]
            if kind == "call":
                task = asyncio.get_running_loop().create_task(self._handle_call(message))
                self._calls.add(task)
                task.add_done_callback(self._calls.discard)
            elif kind == "next_result":
                future = self._nexts.pop(message["id"], None)
                if future is not None and not future.done():
                    future.set_result(message)
            elif kind == "rpc_result":
                future = self._rpcs.pop(message["id"], None)
                if future is not None and not future.done():
                    future.set_result(message)
            elif kind == "dispose":
                if self.ctx is not None:
                    await self.ctx.dispose()
                await self.stop_serving()
                self.send({"type": "disposed"})
                return 0


async def _maybe_await(value: Any) -> Any:
    if asyncio.iscoroutine(value):
        return await value
    return value


def _find_plugin(module_name: str, entry_id: str) -> Plugin:
    module = importlib.import_module(module_name)
    for value in vars(module).values():
        if isinstance(value, Plugin) and value.name == entry_id:
            return value
    raise LookupError(f"模块 {module_name} 里没有名为 {entry_id} 的插件")


async def run(args: argparse.Namespace) -> int:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=MAX_LINE)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    runner = Runner(_PROTOCOL_OUT)
    if args.fd_socket is not None:
        import socket

        runner.fd_socket = socket.socket(fileno=args.fd_socket)
    runner.send({"type": "hello", "sdk": SDK_VERSION, "pid": os.getpid()})
    init = decode(await reader.readline())
    runner.socket = init.get("socket")
    # apply 里可能已经要调宿主服务（读插件数据、拿宿主操作凭证）：先开始收消息
    serving = loop.create_task(runner.serve(reader))
    try:
        found = _find_plugin(args.module, args.entry)
        config = init.get("config")
        if found.config is not None:
            config = found.config.model_validate(config or {})
        inject = tuple(key.name for key in found.inject)
        runner.ctx = RemoteContext(
            runner,
            args.entry,
            init.get("title") or found.title,
            config,
            inject,
            init.get("data_dir") or "./data",
        )
        await found.apply(runner.ctx)
        await runner.wait_serving()
    except Exception as exc:  # noqa: BLE001 -- 启动失败报给宿主，由内核标 FAILED
        runner.send(
            {
                "type": "failed",
                "error": f"{type(exc).__name__}: {exc}",
                "error_type": type(exc).__name__,
                "error_message": str(exc),
            }
        )
        traceback.print_exc()
        serving.cancel()
        return 1
    runner.send({"type": "ready", "title": found.title})
    return await serving


def describe(args: argparse.Namespace) -> int:
    """只读出插件的声明（宿主据此构造内核条目），不运行它。"""
    found = _find_plugin(args.module, args.entry)
    _PROTOCOL_OUT.write(
        encode(
            {
                "type": "describe",
                "title": found.title,
                "inject": [key.name for key in found.inject],
                "permissions": list(found.permissions),
            }
        )
    )
    return 0


_PROTOCOL_OUT: Any = None


def _die_with_parent() -> None:
    """宿主进程没了就跟着退出（Linux）：宿主被强杀、容器又没重启时不留孤儿进程。

    标准输入关闭也会让主循环退出，但插件若卡在不让出的计算里就读不到了，所以再加一道内核信号。
    """
    if not sys.platform.startswith("linux"):
        return
    import ctypes
    import signal

    with contextlib.suppress(OSError, AttributeError):
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG
    if os.getppid() == 1:  # 设置之前宿主就已经没了
        os._exit(0)


def main(argv: list[str] | None = None) -> int:
    global _PROTOCOL_OUT
    parser = argparse.ArgumentParser(description="MovieClaw 进程外插件运行器")
    parser.add_argument("--path", required=True, help="插件代码所在目录（加入 sys.path）")
    parser.add_argument("--module", required=True)
    parser.add_argument("--entry", required=True, help="条目 id（@plugin 的名字）")
    parser.add_argument("--describe", action="store_true", help="只输出插件声明后退出")
    parser.add_argument("--fd-socket", type=int, default=None, help="宿主递文件描述符用的套接字")
    args = parser.parse_args(argv)
    _die_with_parent()
    # 标准输出只留给协议：插件的 print 改到标准错误
    _PROTOCOL_OUT = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    sys.stdout = sys.stderr
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(levelname)s %(message)s")
    sys.path.insert(0, args.path)
    # 插件包随包携带的依赖（docs/design/plugin-phase3.md §2：安装时不跑 pip）
    vendor = Path(args.path) / "vendor"
    if vendor.is_dir():
        sys.path.insert(1, str(vendor))
    if args.describe:
        return describe(args)
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())

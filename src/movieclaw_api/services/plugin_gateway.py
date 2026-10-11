"""插件网关：进程外插件调宿主的入口（docs/design/plugin-ipc-http.md §3、§4.6）。

宿主在同一事件循环里多起一个 uvicorn，监听 Unix 套接字。插件用自己的令牌（``mcpl_``）：

- 调宿主服务（插件数据、健康、文件……）：``POST /api/v1/plugin-runtime/{service}/{method}``，
  按 ``movieclaw_sdk.services`` 里的契约自动校验与分发。这条路**不进主应用**：
  不走中间件链和登录依赖，按令牌认出条目就分发（服务本身按条目隔离），开销与原来的管道调用同级；
- 调宿主操作：直接请求标准的 ``/api/v1/…`` 接口，进主应用，鉴权、按操作授权、审计都走现有链路。

三条规则在这里落实：

- **令牌只在网关上有效**：网关给请求打标记，``deps.optional_login`` 只对带标记的请求认插件令牌；
  进程内插件的宿主操作经 ASGI 直调，也套同一层（``gateway_asgi``）。
- **调用上下文只存在宿主**：宿主调插件时登记「调用号 → 上下文快照」，插件把调用号放进请求头带回来，
  这里按调用号在快照里处理请求（发起方、因果链、可靠事件投递信息原样沿用）。插件伪造不了上下文。
- **按插件限制在途调用数**：超出的排队等待；带调用号的（钩子里的嵌套调用、任务进度）不占名额。
"""

from __future__ import annotations

import asyncio
import contextlib
import contextvars
import json
import logging
import os
import socket
import tempfile
from pathlib import Path
from typing import Any

from starlette.responses import JSONResponse, StreamingResponse

from movieclaw_api.services.auth import PLUGIN_GATEWAY_SCOPE, plugin_entry
from movieclaw_kernel import Origin, current_origin
from movieclaw_sdk import rpc
from movieclaw_sdk.services import SERVICES

logger = logging.getLogger("movieclaw_api.plugin_gateway")

GATEWAY_SCOPE = PLUGIN_GATEWAY_SCOPE
#: 运行时接口的前缀
PREFIX = "/api/v1/plugin-runtime/"
#: 每个插件同时在途的调用数（不含带调用号的嵌套调用）
MAX_IN_FLIGHT = 32

#: 正在处理的宿主调用号（网关按请求头恢复）：任务上下文类服务据此找到真实的 ``JobContext``
current_call: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "movieclaw_gateway_call", default=None
)

_gates: dict[str, asyncio.Semaphore] = {}


def _header(scope: dict[str, Any], name: bytes) -> str | None:
    for key, value in scope.get("headers") or ():
        if key.lower() == name:
            return value.decode("latin-1")
    return None


def _call_context(entry_id: str, call: str) -> contextvars.Context | None:
    from movieclaw_api.services import plugin_runtime

    session = plugin_runtime.sessions.get(entry_id)
    return session.call_context(call) if session is not None else None


def gateway_asgi(app: Any) -> Any:
    """网关这一层：打标记、按路径分流、恢复调用上下文、限制在途调用数。"""

    async def wrapped(scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await app(scope, receive, send)
            return
        scope = {**scope, GATEWAY_SCOPE: True}
        authorization = _header(scope, b"authorization") or ""
        entry_id = plugin_entry(authorization.removeprefix("Bearer ").strip())
        target = app
        if scope["path"].startswith(PREFIX):
            if entry_id is None:
                await _reply(scope, receive, send, 401, "UNAUTHORIZED", "插件凭证无效")
                return

            async def target(scope: Any, receive: Any, send: Any) -> None:
                assert entry_id is not None
                await _runtime(entry_id, scope, receive, send)

        call = _header(scope, rpc.CALL_HEADER.lower().encode())
        snapshot = _call_context(entry_id, call) if entry_id and call else None
        if snapshot is not None:
            context = snapshot.copy()
            context.run(current_call.set, call)
            task = asyncio.get_running_loop().create_task(
                target(scope, receive, send), context=context
            )
            try:
                await task
            except asyncio.CancelledError:
                task.cancel()
                raise
            return
        if entry_id is None:
            await target(scope, receive, send)
            return
        gate = _gates.setdefault(entry_id, asyncio.Semaphore(MAX_IN_FLIGHT))
        async with gate:
            await target(scope, receive, send)

    return wrapped


# ---------------------------------------------------------------------- 运行时接口
async def _reply(scope: Any, receive: Any, send: Any, status: int, code: str, message: str) -> None:
    await JSONResponse({"code": code, "message": message}, status_code=status)(scope, receive, send)


async def _body(receive: Any) -> bytes:
    chunks = []
    while True:
        message = await receive()
        if message["type"] == "http.disconnect":
            break
        chunks.append(message.get("body", b""))
        if not message.get("more_body"):
            break
    return b"".join(chunks)


async def _runtime(entry_id: str, scope: Any, receive: Any, send: Any) -> None:
    """``POST /api/v1/plugin-runtime/{service}/{method}``：按契约校验参数、调用本条目导出的服务。"""
    from movieclaw_api.services import plugin_runtime

    parts = scope["path"][len(PREFIX) :].split("/")
    if scope["method"] != "POST" or len(parts) != 2:
        await _reply(scope, receive, send, 404, "NOT_FOUND", "没有这个运行时接口")
        return
    service, method = parts
    session = plugin_runtime.sessions.get(entry_id)
    target = session.exports.get(service) if session is not None else None
    contract = SERVICES.get(service)
    spec = rpc.methods(contract).get(method) if contract is not None else None
    if target is None or spec is None:
        message = f"插件 {entry_id} 没有服务 {service}.{method}"
        await _reply(scope, receive, send, 404, "NOT_FOUND", message)
        return
    # 插件引起的后续动作记在插件名下（因果链沿用调用上下文里的）
    current_origin.set(Origin(kind="plugin", id=entry_id, chain=current_origin.get().chain))
    raw = await _body(receive)
    try:
        data = json.loads(raw) if raw else {}
    except ValueError:
        await _reply(scope, receive, send, 400, "INVALID_ARGUMENT", "请求体不是 JSON")
        return
    if spec.stream:
        response: Any = StreamingResponse(
            rpc.ndjson(spec, target, data),
            media_type=rpc.NDJSON,
            headers={"Cache-Control": "no-cache, no-transform"},
        )
    else:
        try:
            response = JSONResponse(await rpc.invoke(spec, target, data))
        except Exception as exc:  # noqa: BLE001 -- 按统一错误体告诉插件，SDK 还原成同一种异常
            status, body = rpc.error_of(exc)
            if status >= 500:
                logger.exception("插件 %s 调用 %s.%s 出错", entry_id, service, method)
            response = JSONResponse(body, status_code=status)
    await response(scope, receive, send)


# ---------------------------------------------------------------------- 网关服务器
class Gateway:
    def __init__(self) -> None:
        self.path: str | None = None
        self._server: Any = None
        self._task: asyncio.Task[Any] | None = None
        self._lock = asyncio.Lock()

    async def ensure(self, app: Any) -> str:
        """第一个进程外插件启动时拉起；之后复用。"""
        async with self._lock:
            if self._task is not None and not self._task.done():
                assert self.path is not None
                return self.path
            import uvicorn

            directory = Path(tempfile.mkdtemp(prefix="mcg-"))
            # 插件进程（降权后的用户）要能按完整路径连进来，但不能列目录
            os.chmod(directory, 0o711)
            path = str(directory / "gateway.sock")
            sock = _bind(path)
            config = uvicorn.Config(
                gateway_asgi(app),
                lifespan="off",
                log_level="warning",
                access_log=False,
                # 插件的连接池长期复用连接；默认 5 秒保活会让空闲连接反复重建
                timeout_keep_alive=300,
            )
            config.load()
            server = uvicorn.Server(config)
            # 不用 serve()：它会接管 SIGTERM / SIGINT，抢走主服务的停机信号
            self._task = asyncio.get_running_loop().create_task(
                server._serve(sockets=[sock]), name="plugin-gateway"
            )
            while not server.started:
                if self._task.done():
                    self._task.result()
                    raise RuntimeError("插件网关没有起来")
                await asyncio.sleep(0.01)
            self._server, self.path = server, path
            logger.info("插件网关已启动：%s", path)
            return path

    async def stop(self) -> None:
        async with self._lock:
            if self._task is None:
                return
            self._server.should_exit = True
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self._task, 5)
            self._task = None
            if self.path is not None:
                with contextlib.suppress(OSError):
                    os.unlink(self.path)
                    os.rmdir(os.path.dirname(self.path))
            self.path = None
            _gates.clear()


def _bind(path: str) -> socket.socket:
    from movieclaw_api.services.plugin_isolation import isolation

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind(path)
        settings = isolation()
        if settings.enabled and os.geteuid() == 0:
            # 只给插件组：容器里别的用户连不上；身份靠令牌区分
            os.chown(path, 0, settings.gid or settings.uid or 0)
            os.chmod(path, 0o660)
        else:
            os.chmod(path, 0o600)
        sock.listen(128)
    except BaseException:
        sock.close()
        raise
    return sock


gateway = Gateway()

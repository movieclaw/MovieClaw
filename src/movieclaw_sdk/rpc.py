"""插件与宿主之间的通用调用（docs/design/plugin-ipc-http.md §3）。

两端各导出一张调用表，地址是 ``POST <前缀>/{service}/{method}``：

- 请求体是参数（JSON 对象，按参数名）；响应 200 是返回值（JSON）；
- 返回类型是 ``AsyncIterator[T]`` 的方法，响应是 ``application/x-ndjson`` 流，
  一行一个 ``{"v": 元素}``，中途出错则以一行 ``{"error": {...}}`` 结束；
- 失败用统一错误体 ``{"code", "message"}``，两端按 ``code`` 还原成同一种异常。

分发、校验、编解码都由契约的方法签名（``Protocol`` 类）推导，宿主侧分发、SDK 侧代理、
OpenAPI 与一致性测试共用这一份推导，不逐个手写。本模块只依赖 pydantic，可以被进程外插件轻量导入。
"""

from __future__ import annotations

import collections.abc
import contextvars
import inspect
import json
import typing
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from functools import cache
from typing import Any

from pydantic import TypeAdapter

#: 宿主调插件时带上的调用号：插件处理这次调用期间发出的请求原样带回，宿主据此恢复发起方与因果链
CALL_HEADER = "X-MovieClaw-Call"
NDJSON = "application/x-ndjson"

#: 插件侧：正在处理的宿主调用号
current_call: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "movieclaw_rpc_call", default=None
)


class RemoteServiceError(RuntimeError):
    """对端服务出错（未归类的异常）。"""


# ---------------------------------------------------------------------- 方法签名
@dataclass(frozen=True)
class Param:
    name: str
    adapter: TypeAdapter[Any]
    #: ``inspect.Parameter.empty`` 表示必填
    default: Any

    @property
    def required(self) -> bool:
        return self.default is inspect.Parameter.empty


@dataclass(frozen=True)
class MethodSpec:
    name: str
    params: tuple[Param, ...]
    #: 返回值（流式时是元素）的类型；``None`` 表示没有返回值
    returns: TypeAdapter[Any] | None
    stream: bool
    doc: str = ""

    def encode_args(self, arguments: dict[str, Any]) -> dict[str, Any]:
        known = {p.name: p for p in self.params}
        unknown = set(arguments) - set(known)
        if unknown:
            raise TypeError(f"{self.name} 没有参数 {'、'.join(sorted(unknown))}")
        # 发出前先按签名校验：参数不对在本地就报错（ValueError），不必往返一趟
        return {
            name: known[name].adapter.dump_python(
                known[name].adapter.validate_python(value), mode="json"
            )
            for name, value in arguments.items()
        }

    def decode_args(self, data: Any) -> dict[str, Any]:
        if data is None:
            data = {}
        if not isinstance(data, dict):
            raise ValueError("参数须是 JSON 对象")
        known = {p.name for p in self.params}
        unknown = set(data) - known
        if unknown:
            raise ValueError(f"{self.name} 没有参数 {'、'.join(sorted(unknown))}")
        out: dict[str, Any] = {}
        for param in self.params:
            if param.name in data:
                out[param.name] = param.adapter.validate_python(data[param.name])
            elif param.required:
                raise ValueError(f"{self.name} 缺少参数 {param.name}")
        return out

    def encode_result(self, value: Any) -> Any:
        return None if self.returns is None else self.returns.dump_python(value, mode="json")

    def decode_result(self, data: Any) -> Any:
        return None if self.returns is None else self.returns.validate_python(data)


def _is_stream(annotation: Any) -> bool:
    return typing.get_origin(annotation) in (collections.abc.AsyncIterator, AsyncIterator)


@cache
def methods(contract: type) -> dict[str, MethodSpec]:
    """契约类里全部公开的异步方法 → 调用规格（按名字）。"""
    found: dict[str, MethodSpec] = {}
    for name, fn in inspect.getmembers(contract, inspect.isfunction):
        if name.startswith("_"):
            continue
        hints = typing.get_type_hints(fn)
        params = []
        for param in list(inspect.signature(fn).parameters.values())[1:]:
            if param.kind in (param.VAR_POSITIONAL, param.VAR_KEYWORD):
                raise TypeError(f"{contract.__name__}.{name} 不能用 *args / **kwargs")
            params.append(Param(param.name, TypeAdapter(hints.get(param.name, Any)), param.default))
        annotation = hints.get("return", type(None))
        stream = _is_stream(annotation)
        if stream:
            (annotation,) = typing.get_args(annotation)
        returns = None if annotation is type(None) else TypeAdapter(annotation)
        found[name] = MethodSpec(name, tuple(params), returns, stream, inspect.getdoc(fn) or "")
    return found


# ---------------------------------------------------------------------- 错误
#: 异常类型 ↔ 错误码 ↔ HTTP 状态。按顺序匹配（子类在前）
_ERRORS: tuple[tuple[type[BaseException], str, int], ...] = (
    (PermissionError, "PERMISSION_DENIED", 403),
    (FileNotFoundError, "FILE_NOT_FOUND", 404),
    (LookupError, "NOT_FOUND", 404),
    (ValueError, "INVALID_ARGUMENT", 400),
    (TypeError, "INVALID_ARGUMENT", 400),
    (TimeoutError, "TIMEOUT", 504),
)
_RAISE: dict[str, Callable[[str], BaseException]] = {
    "PERMISSION_DENIED": PermissionError,
    "FILE_NOT_FOUND": FileNotFoundError,
    "NOT_FOUND": LookupError,
    "INVALID_ARGUMENT": ValueError,
    "TIMEOUT": TimeoutError,
}


def error_of(exc: BaseException) -> tuple[int, dict[str, Any]]:
    """异常 → (HTTP 状态, 错误体)。"""
    for cls, code, status in _ERRORS:
        if isinstance(exc, cls):
            return status, {"code": code, "message": str(exc) or cls.__name__}
    return 500, {"code": "SERVICE_ERROR", "message": f"{type(exc).__name__}: {exc}"}


def raise_error(body: Any, status: int = 500) -> typing.NoReturn:
    """错误体 → 还原成对应的异常抛出。"""
    if not isinstance(body, dict):
        body = {}
    code = str(body.get("code") or "SERVICE_ERROR")
    message = str(body.get("message") or f"调用失败（HTTP {status}）")
    raise _RAISE.get(code, RemoteServiceError)(message)


# ---------------------------------------------------------------------- 服务端
async def invoke(spec: MethodSpec, target: Any, data: Any) -> Any:
    """服务端：校验参数、调用实现、编码返回值（非流式）。"""
    result = await getattr(target, spec.name)(**spec.decode_args(data))
    return spec.encode_result(result)


async def ndjson(spec: MethodSpec, target: Any, data: Any) -> AsyncIterator[bytes]:
    """服务端：流式方法的响应体。中途出错写一行错误再结束（响应头早已发出，改不了状态码）。"""
    try:
        async for item in getattr(target, spec.name)(**spec.decode_args(data)):
            yield _line({"v": spec.encode_result(item)})
    except Exception as exc:  # noqa: BLE001 -- 原样告诉调用方
        yield _line({"error": error_of(exc)[1]})


def _line(obj: Any) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


# ---------------------------------------------------------------------- 客户端
class RpcClient:
    """调对端某个前缀下的通用调用（HTTP over Unix 套接字，``movieclaw_sdk.http``）。"""

    def __init__(self, http: Any, prefix: str) -> None:
        self.http = http
        self.prefix = prefix.rstrip("/")

    def headers(self) -> dict[str, str]:
        call = current_call.get()
        return {CALL_HEADER: call} if call else {}

    async def call(self, service: str, spec: MethodSpec, arguments: dict[str, Any]) -> Any:
        response = await self.http.request(
            "POST",
            f"{self.prefix}/{service}/{spec.name}",
            json=spec.encode_args(arguments),
            headers=self.headers(),
        )
        body = response.json()
        if response.status_code >= 400:
            raise_error(body, response.status_code)
        return spec.decode_result(body)

    async def stream(
        self, service: str, spec: MethodSpec, arguments: dict[str, Any]
    ) -> AsyncIterator[Any]:
        async with self.http.stream(
            "POST",
            f"{self.prefix}/{service}/{spec.name}",
            json=spec.encode_args(arguments),
            headers=self.headers(),
        ) as response:
            if response.status_code >= 400:
                body = await response.aread()
                raise_error(json.loads(body) if body else None, response.status_code)
            async for line in response.aiter_lines():
                if not line:
                    continue
                item = json.loads(line)
                if "error" in item:
                    raise_error(item["error"])
                yield spec.decode_result(item.get("v"))

    async def aclose(self) -> None:
        await self.http.aclose()


class ServiceProxy:
    """按契约生成的远程服务：``await proxy.method(参数=...)``；流式方法返回异步迭代器。"""

    def __init__(self, client: RpcClient, service: str, contract: type) -> None:
        self._client = client
        self._service = service
        self._specs = methods(contract)

    def __getattr__(self, name: str) -> Any:
        spec = self._specs.get(name)
        if spec is None:
            raise AttributeError(f"服务 {self._service} 没有方法 {name}")
        if spec.stream:
            return lambda **arguments: self._client.stream(self._service, spec, arguments)

        async def call(**arguments: Any) -> Any:
            return await self._client.call(self._service, spec, arguments)

        return call

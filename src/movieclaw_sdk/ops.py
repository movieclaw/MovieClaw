"""宿主操作的请求构造与响应解析（docs/design/plugin-ipc-http.md §3）。

插件调宿主操作就是一次普通的 HTTP 请求：按操作目录里的路径与参数落点拼请求，
结果取响应里的 ``data``。
这里的函数只依赖标准库，宿主的进程内调用（``host_ops``）、MCP 与进程外插件共用同一份实现。

服务键 ``HOST_OPS`` 也定义在这里：只依赖 SDK 的插件（随带插件包）据此注入宿主操作::

    ops = await ctx.use(HOST_OPS).client(ctx)
    data = await ops.call("library.strm.list-pending", {"limit": 1})
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any, Literal

from movieclaw_kernel import ServiceKey, Stability

ArgLocation = Literal["path", "query", "body"]

HOST_OPS: ServiceKey[Any] = ServiceKey(
    "host-ops",
    stability=Stability.EXPERIMENTAL,
    doc="宿主操作：插件以自己的身份调用本进程的 OpenAPI 操作（按操作授权）",
)


class OpsError(Exception):
    """宿主操作失败：HTTP 状态、错误码、可读原因与明细（与接口的错误响应同构）。"""

    def __init__(
        self, status: int, code: str, message: str, details: list[dict[str, Any]] | None = None
    ) -> None:
        super().__init__(f"{code}（{status}）：{message}")
        self.status = status
        self.code = code
        self.message = message
        self.details = details or []


@dataclass(frozen=True)
class OperationRef:
    """插件拿到的一个可调用操作：拼请求所需的最少信息。"""

    operation_id: str
    method: str
    path: str
    #: 参数名 → 落点，顺序即 schema 里的属性顺序（path → query → body）
    arg_locations: dict[str, ArgLocation] = field(default_factory=dict)
    required: tuple[str, ...] = ()
    #: 流式操作（SSE），用 ``ops.stream()`` 调
    stream: bool = False


def build_request(
    path: str,
    arg_locations: dict[str, ArgLocation],
    required: tuple[str, ...] | list[str],
    arguments: dict[str, Any],
    *,
    label: str,
) -> tuple[str, dict[str, Any], Any]:
    """扁平参数 → (路径, query, body)。缺必填路径参数直接报错，不发出去试。"""
    query: dict[str, Any] = {}
    body: dict[str, Any] = {}

    unknown = set(arguments) - set(arg_locations)
    if unknown:
        raise ValueError(
            f"这些参数不属于 {label}：{', '.join(sorted(unknown))}；"
            f"可用参数：{', '.join(arg_locations) or '（无）'}"
        )

    for name, location in arg_locations.items():
        if name not in arguments:
            if name in required and location == "path":
                raise ValueError(f"缺少必填参数 {name}")
            continue
        value = arguments[name]
        if location == "path":
            path = path.replace("{" + name + "}", str(value))
        elif location == "query":
            # 布尔要转成 FastAPI 认的字面量；None 一律不发（等价于「不传」）
            if value is None:
                continue
            query[name] = str(value).lower() if isinstance(value, bool) else value
        else:
            body[name] = value

    if "{" in path:
        missing = [n for n, loc in arg_locations.items() if loc == "path" and n not in arguments]
        raise ValueError(f"缺少必填的路径参数：{', '.join(missing)}")

    # 非对象请求体（目录里记成单个 body 参数）原样发出
    body_slots = list(arg_locations.values()).count("body")
    if body_slots == 1 and "body" in arg_locations:
        return path, query, arguments.get("body")
    return path, query, (body or None)


def parse_response(status: int, text: str) -> Any:
    """接口响应 → ``data``；失败抛 ``OpsError``。"""
    try:
        payload = json.loads(text) if text else None
    except ValueError:
        payload = {"message": text[:500]}
    if status >= 400:
        if not isinstance(payload, dict):
            payload = {}
        raise OpsError(
            status,
            str(payload.get("code") or "HTTP_ERROR"),
            str(payload.get("message") or f"请求失败（HTTP {status}）"),
            payload.get("details") if isinstance(payload.get("details"), list) else None,
        )
    return payload.get("data") if isinstance(payload, dict) and "data" in payload else payload


@dataclass(frozen=True)
class SseEvent:
    """流式操作推来的一个事件。"""

    event: str
    data: str
    id: str | None = None

    def json(self) -> Any:
        return json.loads(self.data) if self.data else None


async def iter_sse(lines: AsyncIterator[str]) -> AsyncIterator[SseEvent]:
    """按行解析 SSE：空行结束一个事件；注释行（心跳）跳过。"""
    event, data, event_id = "message", [], None
    async for line in lines:
        if not line:
            if data:
                yield SseEvent(event=event, data="\n".join(data), id=event_id)
            event, data, event_id = "message", [], None
            continue
        if line.startswith(":"):
            continue
        name, _, value = line.partition(":")
        value = value[1:] if value.startswith(" ") else value
        if name == "event":
            event = value
        elif name == "data":
            data.append(value)
        elif name == "id":
            event_id = value
    if data:
        yield SseEvent(event=event, data="\n".join(data), id=event_id)

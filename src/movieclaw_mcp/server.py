"""MCP 端点的协议应答：把通过鉴权的请求交给官方 SDK（docs/design/mcp-server.md §4.3）。

从 app.py 拆出来单独成模块，是为了让 SDK 按需加载：``import mcp`` 会连带客户端、
服务端、rich、pygments 等整包导入，常驻约 25MB。没开启 MCP 的实例一次也不会走到
这里，也就不占这份内存。
"""

from __future__ import annotations

import asyncio
from typing import Any

from fastapi import FastAPI
from mcp import types
from mcp.server import Server, ServerRequestContext
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import CallToolRequestParams, CallToolResult, ListToolsResult, TextContent
from starlette.types import Receive, Scope, Send

from movieclaw_api import __version__
from movieclaw_api.services import mcp_endpoints
from movieclaw_api.settings.mcp import McpEndpoint
from movieclaw_mcp.dispatch import call_operation
from movieclaw_mcp.tools import Tool, build_tools, resolve_tool

#: 每个端点的并发上限：一个跑飞的客户端不该把连接池和 CPU 吃满。
_MAX_CONCURRENCY = 4
_semaphores: dict[str, asyncio.Semaphore] = {}

#: ``tools/list`` 的缓存提示：工具面只在管理员改配置时才变，五分钟内不必重复拉。
#: 作用域是 private——每个端点的工具面不同，共享缓存会串味。
_TOOLS_TTL_MS = 5 * 60 * 1000


def _semaphore(endpoint_id: str) -> asyncio.Semaphore:
    if endpoint_id not in _semaphores:
        _semaphores[endpoint_id] = asyncio.Semaphore(_MAX_CONCURRENCY)
    return _semaphores[endpoint_id]


def _sdk_tool(tool: Tool) -> types.Tool:
    annotations = tool.annotations
    return types.Tool(
        name=tool.name,
        description=tool.description,
        input_schema=tool.input_schema,
        annotations=(
            types.ToolAnnotations(
                read_only_hint=annotations.read_only_hint,
                destructive_hint=annotations.destructive_hint,
                idempotent_hint=annotations.idempotent_hint,
                open_world_hint=annotations.open_world_hint,
            )
            if annotations is not None
            else None
        ),
    )


def build_server(app: FastAPI, endpoint: McpEndpoint) -> Server:
    """为一个端点构造 SDK 的低阶 Server：工具面与调度都回调进我们自己的代码。"""

    async def on_list_tools(_ctx: ServerRequestContext[Any], _params: Any) -> ListToolsResult:
        return ListToolsResult(
            tools=[
                _sdk_tool(t) for t in build_tools(endpoint.services, expand=endpoint.expand_tools)
            ],
            ttl_ms=_TOOLS_TTL_MS,
            cache_scope="private",
        )

    async def on_call_tool(
        _ctx: ServerRequestContext[Any], params: CallToolRequestParams
    ) -> CallToolResult:
        try:
            operation, arguments = resolve_tool(
                endpoint.services,
                expand=endpoint.expand_tools,
                name=params.name,
                arguments=dict(params.arguments or {}),
            )
        except ValueError as exc:
            # 定位不到工具/命令是模型可以自己纠正的错误，回成结果而不是抛协议错误
            return CallToolResult(content=[TextContent(type="text", text=str(exc))], is_error=True)

        async with _semaphore(endpoint.id):
            try:
                result = await call_operation(
                    app,
                    endpoint.id,
                    operation,
                    arguments,
                    timeout=float(endpoint.timeout_seconds),
                )
            except ValueError as exc:  # 参数拼装失败（缺必填、参数名不认识）
                return CallToolResult(
                    content=[TextContent(type="text", text=str(exc))], is_error=True
                )
            except TimeoutError:
                return CallToolResult(
                    content=[
                        TextContent(
                            type="text",
                            text=f"调用超时（{endpoint.timeout_seconds} 秒）。长任务应改用提交后"
                            "轮询的命令，或让管理员调大这个端点的超时。",
                        )
                    ],
                    is_error=True,
                )
        await mcp_endpoints.touch(endpoint.id)
        return result

    return Server(
        f"movieclaw/{endpoint.slug}",
        version=__version__,
        title=endpoint.name or endpoint.slug,
        instructions=(
            "movieclaw 是一套自部署的影视媒体管理系统：发现影视、订阅追更、搜索并下载 PT "
            "资源、整理入库、管理媒体库与播放。这里的工具直接操作用户自己的实例，"
            "改动会立刻生效——涉及删除的操作先向用户确认。"
        ),
        on_list_tools=on_list_tools,
        on_call_tool=on_call_tool,
    )


async def handle_request(
    app: FastAPI, endpoint: McpEndpoint, scope: Scope, receive: Receive, send: Send
) -> None:
    """为已鉴权的请求现建 Server 与无状态会话管理器并应答（为什么现建见 app.py 模块说明）。"""
    manager = StreamableHTTPSessionManager(
        app=build_server(app, endpoint),
        json_response=True,  # 恒用单个 JSON 体应答，不开 SSE 流（设计文档 §4.8）
        stateless=True,  # 无会话：每个请求自带全部上下文
        # Host/Origin 由调度层判过了（语义更准、也不会误伤局域网访问），
        # 这里关掉 SDK 自带的那道，避免两套白名单各判各的。
        security_settings=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
    async with manager.run():
        await manager.handle_request(scope, receive, send)

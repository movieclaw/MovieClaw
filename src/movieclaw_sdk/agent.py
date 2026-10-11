"""插件驱动 AI 助手（Agent）的契约与门面（docs/design/plugin-agent.md）。

插件写法（进程内、进程外一样）::

    @plugin("acme-a2a", inject=(AGENT,), permissions=("agent:mclaw",))
    async def apply(ctx):
        agent = ctx.use(AGENT).scoped(ctx)
        reply = await agent.ask("沙丘 2 的订阅到哪了？")             # 同步：等这一轮跑完
        turn = await agent.start("继续", session_id=reply.session_id)  # 流式：逐事件
        async for event in turn.events():
            ...

- 授权是权限串 ``agent:none`` / ``agent:mclaw`` / ``agent:full``（工具档位），用户批准才生效；
- 事件与内部 ``AgentEvent`` 解耦：文字、思考（可选）、工具开始 / 结束、上下文压缩、终态；
  工具的参数与输出不给插件（Agent 以管理员身份运行，输出可能含路径等信息）；
- 迭代器关闭不会取消运行（外部断线后可以 ``attach`` 续上）；要取消显式调 ``cancel()``。

本模块只依赖 pydantic，进程外插件导入它很轻。
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any, Literal, Protocol

from pydantic import BaseModel, ConfigDict

from movieclaw_sdk import rpc

#: 工具档位，从低到高
TOOL_TIERS: tuple[str, ...] = ("none", "mclaw", "full")
#: 授权用的权限串前缀：``agent:<档位>``
PERMISSION_PREFIX = "agent:"


class AgentNotGranted(PermissionError):
    """没有授权、档位超出授权、代表成员的插件，或由 Agent 引起的调用（防递归）。"""


class AgentBusy(RuntimeError):
    """这个会话正有一轮在跑，或本插件同时进行的轮次已满。"""


class AgentUnavailable(RuntimeError):
    """还没配置模型供应商，或服务正在关闭。"""


class AgentSessionNotFound(LookupError):
    """会话不存在，或不是本插件建的（两种情况不区分）。"""


rpc.register_error(AgentNotGranted, "AGENT_NOT_GRANTED", 403)
rpc.register_error(AgentBusy, "AGENT_BUSY", 409)
rpc.register_error(AgentUnavailable, "AGENT_UNAVAILABLE", 503)
rpc.register_error(AgentSessionNotFound, "AGENT_SESSION_NOT_FOUND", 404)


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


class AgentTurnRef(_Frozen):
    session_id: str
    message_id: str


class AgentReply(_Frozen):
    """一轮的结果。``status``：done / error / cancelled / timeout。"""

    session_id: str
    message_id: str
    status: Literal["done", "error", "cancelled", "timeout"]
    text: str = ""
    finish_reason: str | None = None
    model: str | None = None
    usage: dict[str, int] | None = None
    error: str | None = None


class ToolStep(_Frozen):
    phase: Literal["start", "end"]
    call_id: str
    name: str
    is_error: bool = False
    elapsed_ms: int | None = None


class TurnEvent(_Frozen):
    """一轮里的一个事件。``seq`` 单调递增，用来续传（``events(after=seq)``）。

    - ``text`` / ``thinking``：``delta`` 是增量文字（思考仅在 ``include_thinking`` 时给）；
    - ``tool``：``tool`` 是工具开始 / 结束；
    - ``compacted``：上下文被压缩；
    - ``done`` / ``error`` / ``cancelled``：终态，``reply`` 是这一轮的结果。
    """

    seq: int
    type: Literal["text", "thinking", "tool", "compacted", "done", "error", "cancelled"]
    delta: str | None = None
    tool: ToolStep | None = None
    reply: AgentReply | None = None


class AgentSessionInfo(_Frozen):
    id: str
    title: str | None = None
    last_prompt: str | None = None
    running: bool = False
    created_at: str
    updated_at: str


class AgentApi(Protocol):
    """宿主导出的 Agent 服务（按调用方插件隔离：只看得到自己建的会话）。"""

    async def start(
        self,
        content: str,
        session_id: str | None = None,
        tools: str | None = None,
        instructions: str | None = None,
        model: str | None = None,
        thinking_level: str | None = None,
    ) -> AgentTurnRef: ...

    async def events(
        self, session_id: str, message_id: str, after: int = 0, include_thinking: bool = False
    ) -> AsyncIterator[TurnEvent]: ...

    async def result(
        self,
        session_id: str,
        message_id: str,
        timeout: float | None = None,
        cancel_on_timeout: bool = True,
    ) -> AgentReply: ...

    async def cancel(self, session_id: str, message_id: str) -> None: ...

    async def attach(self, session_id: str) -> AgentTurnRef | None: ...

    async def sessions(self, limit: int = 50) -> list[AgentSessionInfo]: ...

    async def delete(self, session_id: str) -> bool: ...


# ---------------------------------------------------------------------- 门面
class AgentTurn:
    """一轮对话的句柄。"""

    def __init__(self, api: Any, ref: AgentTurnRef) -> None:
        self._api = api
        self.session_id = ref.session_id
        self.message_id = ref.message_id

    def events(self, *, after: int = 0, include_thinking: bool = False) -> AsyncIterator[TurnEvent]:
        """逐个产出事件，到终态为止；``after`` 是上次收到的 ``seq``（续传）。"""
        return self._api.events(
            session_id=self.session_id,
            message_id=self.message_id,
            after=after,
            include_thinking=include_thinking,
        )

    async def result(
        self, timeout: float | None = None, *, cancel_on_timeout: bool = True
    ) -> AgentReply:
        """等这一轮结束；超时返回 ``status="timeout"``（默认顺带取消这一轮）。"""
        return await self._api.result(
            session_id=self.session_id,
            message_id=self.message_id,
            timeout=timeout,
            cancel_on_timeout=cancel_on_timeout,
        )

    async def cancel(self) -> None:
        await self._api.cancel(session_id=self.session_id, message_id=self.message_id)


class AgentClient:
    """插件拿到的 Agent：``ctx.use(AGENT).scoped(ctx)``。"""

    def __init__(self, api: Any) -> None:
        self._api = api

    async def start(
        self,
        content: str,
        *,
        session_id: str | None = None,
        tools: str | None = None,
        instructions: str | None = None,
        model: str | None = None,
        thinking_level: str | None = None,
    ) -> AgentTurn:
        """新建或续写会话并开始一轮，立即返回句柄。

        ``tools`` 缺省取授权的档位，可以往下调不能往上调；``instructions`` 追加在系统提示词后面
        （例如说明「你正在回答 A2A 对端」），不能替换系统提示词。
        """
        ref = await self._api.start(
            content=content,
            session_id=session_id,
            tools=tools,
            instructions=instructions,
            model=model,
            thinking_level=thinking_level,
        )
        return AgentTurn(self._api, ref)

    async def ask(
        self,
        content: str,
        *,
        timeout: float | None = 300.0,
        cancel_on_timeout: bool = True,
        session_id: str | None = None,
        tools: str | None = None,
        instructions: str | None = None,
        model: str | None = None,
        thinking_level: str | None = None,
    ) -> AgentReply:
        """同步：开始一轮并等它结束。"""
        turn = await self.start(
            content,
            session_id=session_id,
            tools=tools,
            instructions=instructions,
            model=model,
            thinking_level=thinking_level,
        )
        return await turn.result(timeout, cancel_on_timeout=cancel_on_timeout)

    async def attach(self, session_id: str) -> AgentTurn | None:
        """重新拿到会话最近一轮的句柄（外部断线重连）；没有就返回 ``None``。"""
        ref = await self._api.attach(session_id=session_id)
        return AgentTurn(self._api, ref) if ref is not None else None

    async def sessions(self, limit: int = 50) -> list[AgentSessionInfo]:
        return await self._api.sessions(limit=limit)

    async def delete(self, session_id: str) -> bool:
        return await self._api.delete(session_id=session_id)

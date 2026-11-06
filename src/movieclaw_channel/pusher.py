"""StepReplyPusher —— 把 AgentRunner 事件流按「步」收敛成离散 IM 消息。

收敛规则(与用户逐条确认的设计):
- Agent loop 的一步 = 一次模型调用;一步产出的完整正文 = 一条 IM 消息;
- ``text_delta`` 只累积不推送(IM 没有打字机语义);
- 步边界信号:本步出现第一个 ``tool_call``(正文先于工具调用产生),
  或 ``agent_done``(终答);
- ``thinking_delta`` / ``tool_call_delta`` / ``tool_result`` 等中间过程全部丢弃;
- Markdown 原样透传,不做净化(微信端可渲染)。

一步可能连发多个 tool_call:第一个触发 flush 后缓冲已空,后续天然幂等。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable

from movieclaw_agent.events import AgentEvent

#: 发射回调:每条完整消息调用一次(dispatcher 把它接到出站队列)
EmitFn = Callable[[str], Awaitable[None]]


class StepReplyPusher:
    """消费一次 Agent 运行的事件流,产出离散消息文本。"""

    def __init__(self, emit: EmitFn, *, cancelled_text: str = "已取消本次处理。") -> None:
        self._emit = emit
        self._cancelled_text = cancelled_text
        self._buf: list[str] = []
        #: 终答文本(agent_done 携带),供调用方写入会话历史
        self.final_text: str = ""
        #: 是否以错误收尾
        self.errored: bool = False

    async def feed(self, ev: AgentEvent) -> None:
        if ev.type == "text_delta":
            if ev.delta:
                self._buf.append(ev.delta)
        elif ev.type == "tool_call":
            await self._flush()
        elif ev.type == "agent_done":
            await self._flush()
            if ev.result and ev.result.text:
                self.final_text = ev.result.text
        elif ev.type == "agent_error":
            self.errored = True
            await self._flush()
            await self._emit(f"⚠️ 处理失败:{ev.error or '未知错误'}")
        elif ev.type == "agent_cancelled":
            await self._flush()
            await self._emit(self._cancelled_text)
        # thinking_delta / tool_call_start / tool_call_delta / tool_result /
        # context_compacted / agent_start:中间过程,全部丢弃

    async def _flush(self) -> None:
        text = "".join(self._buf).strip()
        self._buf.clear()
        if text:
            await self._emit(text)

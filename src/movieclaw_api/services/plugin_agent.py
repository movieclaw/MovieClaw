"""插件驱动 AI 助手（Agent）的宿主实现（docs/design/plugin-agent.md）。

实现 ``movieclaw_sdk.agent.AgentApi``：进程内插件直接拿它（经 ``AgentClient`` 门面），
进程外插件经网关调它（服务名 ``agent``）。护栏全在这里：

- **授权**：插件声明权限串 ``agent:<档位>``（none / mclaw / full），第三方插件还要用户批准；
  插件包最高 ``mclaw``（能执行命令的 Agent 不交给下载来的包）；代表成员运行（``act_as``）的插件
  不能用——Agent 只能以管理员身份运行；
- **入口区封顶**：从插件的成员区、公开区路由或回调端点进来的调用，一律不带工具
  （否则成员或外部调用方能借插件用上管理员级的 Agent）；
- **防递归**：因果链里带 Agent 标记（``Origin.via_agent``）的调用不能再发起 Agent；
- **成本**：每个插件同时最多 ``MAX_CONCURRENT`` 轮，满了立即报忙（不排队，由插件决定怎么回对端）；
  插件卸下时取消它还在跑的轮次；
- **归属**：插件建的会话归属 ``plugin:<条目 id>``，只看得到、续写、删除自己的。

发起一轮与网页走同一条路（``routes/agent._accept_user_message``），运行进同一个注册表：
网页上看得到、能跟随、能停止。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator
from typing import Any

from movieclaw_kernel import current_origin
from movieclaw_sdk.agent import (
    PERMISSION_PREFIX,
    TOOL_TIERS,
    AgentBusy,
    AgentClient,
    AgentNotGranted,
    AgentReply,
    AgentSessionInfo,
    AgentSessionNotFound,
    AgentTurnRef,
    AgentUnavailable,
    ToolStep,
    TurnEvent,
)

logger = logging.getLogger("movieclaw_api.plugin_agent")

#: 每个插件同时进行的轮次上限
MAX_CONCURRENT = 2
#: 各档位的步数上限（网页会话是 200）
MAX_STEPS = {"none": 40, "mclaw": 40, "full": 200}
#: 等事件的单次长轮询时长（注册表有新事件立即返回）
_WAIT = 15.0
#: 交出终态前最多等收尾多久
_SETTLE = 5.0


def granted_tier(ctx: Any, approved: frozenset[str] | None) -> str | None:
    """插件获准的最高档位：声明 ∩ 批准（内置插件声明即批准），插件包封顶 mclaw。

    没有授权返回 ``None``。
    """
    requested = [p for p in ctx.permissions if p.startswith(PERMISSION_PREFIX)]
    if ctx.third_party:
        requested = [p for p in requested if approved is not None and p in approved]
    tiers = [p[len(PERMISSION_PREFIX) :] for p in requested]
    tiers = [t for t in tiers if t in TOOL_TIERS]
    if not tiers:
        return None
    tier = max(tiers, key=TOOL_TIERS.index)
    if ctx.source == "package" and TOOL_TIERS.index(tier) > TOOL_TIERS.index("mclaw"):
        tier = "mclaw"
    return tier


class PluginAgent:
    """一个插件条目的 Agent（``AgentApi`` 的实现）。"""

    def __init__(self, entry_id: str, *, tier: str | None, act_as: str | None) -> None:
        self.entry_id = entry_id
        self.owner = f"plugin:{entry_id}"
        self._tier = tier
        self._act_as = act_as
        #: 消息编号 → （会话编号, 运行编号）：本插件发起的轮次
        self._turns: dict[str, tuple[str, str]] = {}

    # ------------------------------------------------------------------ 护栏
    def _tier_for(self, requested: str | None) -> str:
        from movieclaw_api.services.plugin_routes import current_zone

        if self._tier is None:
            raise AgentNotGranted(
                f"插件 {self.entry_id} 没有获得调用 AI 助手的授权（权限 agent:<档位>，需用户批准）"
            )
        if self._act_as:
            raise AgentNotGranted(
                "代表成员运行的插件不能调用 AI 助手（Agent 只能以管理员身份运行）"
            )
        if current_origin.get().via_agent:
            raise AgentNotGranted("由 AI 助手引起的调用不能再发起 AI 助手（防止递归）")
        tier = requested or self._tier
        if tier not in TOOL_TIERS:
            raise ValueError(f"未知的工具档位：{tier}（none / mclaw / full）")
        if TOOL_TIERS.index(tier) > TOOL_TIERS.index(self._tier):
            raise AgentNotGranted(f"工具档位 {tier} 超出授权的 {self._tier}")
        zone = current_zone.get()
        if zone is not None and zone != "admin":
            # 成员区、公开区路由或回调端点进来的：不带工具
            tier = "none"
        return tier

    def _active(self) -> int:
        from movieclaw_api.services.agent_runs import get_agent_run_registry

        registry = get_agent_run_registry()
        return sum(1 for _, run_id in self._turns.values() if registry.is_active(run_id))

    async def _own(self, session_id: str) -> Any:
        """会话的索引行；不存在或不归本插件一律当作不存在。"""
        from movieclaw_db.engine import get_database
        from movieclaw_db.repositories.agent_session_repo import AgentSessionRepository

        async with get_database().session() as db:
            row = await AgentSessionRepository(db).get(session_id)
        if row is None or row.owner != self.owner:
            raise AgentSessionNotFound(f"会话 {session_id} 不存在")
        return row

    def _run(self, session_id: str, message_id: str) -> str:
        found = self._turns.get(message_id)
        if found is None or found[0] != session_id:
            raise AgentSessionNotFound(f"会话 {session_id} 没有这一轮（{message_id}）")
        return found[1]

    # ------------------------------------------------------------------ 契约
    async def start(
        self,
        content: str,
        session_id: str | None = None,
        tools: str | None = None,
        instructions: str | None = None,
        model: str | None = None,
        thinking_level: str | None = None,
    ) -> AgentTurnRef:
        from movieclaw_api.api.routes import agent as agent_routes
        from movieclaw_api.exceptions import AppException
        from movieclaw_api.schemas.agent import SessionStartPayload
        from movieclaw_api.services.agent_runs import get_agent_run_registry
        from movieclaw_api.services.auth import Principal
        from movieclaw_db.engine import get_database
        from movieclaw_db.repositories.agent_session_repo import is_running

        tier = self._tier_for(tools)
        if self._active() >= MAX_CONCURRENT:
            raise AgentBusy(f"插件 {self.entry_id} 同时进行的对话已达上限（{MAX_CONCURRENT} 轮）")
        if session_id is not None and is_running(await self._own(session_id)):
            raise AgentBusy("这个会话正有一轮在进行，等它结束或先取消")
        payload = SessionStartPayload(
            content=content,
            session_id=session_id,
            model=model or "",
            thinking_level=thinking_level,
        )
        identity = Principal(kind="admin", name=self.owner)
        try:
            async with get_database().session() as db:
                reply = await agent_routes._accept_user_message(
                    payload,
                    identity,
                    db,
                    owner=self.owner,
                    tool_profile=tier,  # type: ignore[arg-type]
                    instructions=instructions,
                    max_steps=MAX_STEPS[tier],
                )
        except AppException as exc:
            if exc.status_code == 404:
                raise AgentUnavailable(exc.message) from exc
            raise ValueError(exc.message) from exc
        except RuntimeError as exc:  # 注册表正在关闭
            raise AgentUnavailable(str(exc)) from exc
        view = reply.data
        assert view is not None
        run_id = get_agent_run_registry().latest_run(view.session_id)
        assert run_id is not None
        self._turns[view.message_id] = (view.session_id, run_id)
        logger.info(
            "插件 %s 发起 AI 助手对话 session=%s run=%s 档位=%s",
            self.entry_id,
            view.session_id,
            run_id,
            tier,
        )
        return AgentTurnRef(session_id=view.session_id, message_id=view.message_id)

    async def events(
        self, session_id: str, message_id: str, after: int = 0, include_thinking: bool = False
    ) -> AsyncIterator[TurnEvent]:
        from movieclaw_api.exceptions import NotFoundException
        from movieclaw_api.services.agent_runs import get_agent_run_registry

        run_id = self._run(session_id, message_id)
        registry = get_agent_run_registry()
        cursor = after
        while True:
            try:
                batch, terminal = await registry.get_events(run_id, cursor, timeout_seconds=_WAIT)
            except NotFoundException:
                # 运行的事件历史已过期（服务重启、超过保留期）：从转录给出终态
                yield TurnEvent(
                    seq=cursor + 1,
                    type="done",
                    reply=self._from_transcript(session_id, message_id),
                )
                return
            for stored in batch:
                cursor = stored.sequence
                event = _convert(stored.sequence, stored.event, session_id, message_id)
                if event is None or (event.type == "thinking" and not include_thinking):
                    continue
                if event.reply is not None:
                    # 交出终态前等收尾做完：插件拿到结果就能紧接着续写这个会话
                    await registry.wait_settled(run_id, _SETTLE)
                yield event
            if terminal and not batch:
                return

    async def result(
        self,
        session_id: str,
        message_id: str,
        timeout: float | None = None,
        cancel_on_timeout: bool = True,
    ) -> AgentReply:
        try:
            async with asyncio.timeout(timeout):
                async for event in self.events(session_id, message_id):
                    if event.reply is not None:
                        return event.reply
        except TimeoutError:
            if cancel_on_timeout:
                await self.cancel(session_id, message_id)
            return AgentReply(session_id=session_id, message_id=message_id, status="timeout")
        return self._from_transcript(session_id, message_id)

    async def cancel(self, session_id: str, message_id: str) -> None:
        from movieclaw_api.exceptions import NotFoundException
        from movieclaw_api.services.agent_runs import get_agent_run_registry

        run_id = self._run(session_id, message_id)
        # 早已结束、历史已过期的不用再取消
        with contextlib.suppress(NotFoundException):
            await get_agent_run_registry().cancel(run_id)

    async def attach(self, session_id: str) -> AgentTurnRef | None:
        from movieclaw_api.services.agent_runs import get_agent_run_registry

        await self._own(session_id)
        run_id = get_agent_run_registry().latest_run(session_id)
        for message_id, (sid, rid) in self._turns.items():
            if sid == session_id and rid == run_id:
                return AgentTurnRef(session_id=session_id, message_id=message_id)
        return None

    async def sessions(self, limit: int = 50) -> list[AgentSessionInfo]:
        from movieclaw_api.schemas.agent import SessionSummary
        from movieclaw_db.engine import get_database
        from movieclaw_db.repositories.agent_session_repo import AgentSessionRepository

        async with get_database().session() as db:
            rows = await AgentSessionRepository(db).list_recent(
                limit=max(1, min(limit, 200)), owner=self.owner
            )
        found = []
        for row in rows:
            summary = SessionSummary.from_model(row).model_dump(mode="json")
            found.append(
                AgentSessionInfo(
                    id=summary["id"],
                    title=summary["title"],
                    last_prompt=summary["last_prompt"],
                    running=summary["running"],
                    created_at=summary["created_at"],
                    updated_at=summary["updated_at"],
                )
            )
        return found

    async def delete(self, session_id: str) -> bool:
        from movieclaw_api.services.agent_attachments import get_agent_attachment_store
        from movieclaw_api.services.agent_sessions import get_agent_session_store
        from movieclaw_db.engine import get_database
        from movieclaw_db.repositories.agent_session_repo import (
            AgentSessionRepository,
            is_running,
        )

        if is_running(await self._own(session_id)):
            raise AgentBusy("这个会话正有一轮在进行，先取消再删除")
        get_agent_session_store().delete(session_id)
        get_agent_attachment_store().delete_session_attachments(session_id)
        async with get_database().session() as db:
            await AgentSessionRepository(db).delete(session_id)
        self._turns = {m: t for m, t in self._turns.items() if t[0] != session_id}
        return True

    # ------------------------------------------------------------------ 收尾
    async def dispose(self) -> None:
        """插件卸下：取消它还在跑的轮次（没人消费的运行不留着烧钱）。"""
        from movieclaw_api.services.agent_runs import get_agent_run_registry

        try:
            registry = get_agent_run_registry()
        except RuntimeError:
            return
        for _, run_id in list(self._turns.values()):
            if registry.is_active(run_id):
                await registry.cancel(run_id)

    def _from_transcript(self, session_id: str, message_id: str) -> AgentReply:
        """事件历史不在了：取转录里这一轮之后的最后一条助手回复。"""
        from movieclaw_api.services.agent_sessions import (
            SessionMessageEntry,
            get_agent_session_store,
            message_preview,
        )

        try:
            _, entries = get_agent_session_store().read(session_id)
        except FileNotFoundError:
            return AgentReply(
                session_id=session_id, message_id=message_id, status="error", error="会话已删除"
            )
        after = False
        text = ""
        for entry in entries:
            if entry.uuid == message_id:
                after = True
            elif (
                after
                and isinstance(entry, SessionMessageEntry)
                and entry.message.role == "assistant"
            ):
                text = message_preview(entry.message) or text
        return AgentReply(session_id=session_id, message_id=message_id, status="done", text=text)


def _convert(seq: int, event: Any, session_id: str, message_id: str) -> TurnEvent | None:
    """内部 ``AgentEvent`` → 对插件开放的 ``TurnEvent``（工具参数与输出不给）。"""
    kind = event.type
    if kind == "text_delta":
        return TurnEvent(seq=seq, type="text", delta=event.delta or "")
    if kind == "thinking_delta":
        return TurnEvent(seq=seq, type="thinking", delta=event.delta or "")
    if kind == "tool_call" and event.tool_call is not None:
        call = event.tool_call
        return TurnEvent(
            seq=seq, type="tool", tool=ToolStep(phase="start", call_id=call.id, name=call.name)
        )
    if kind == "tool_result" and event.tool_result is not None:
        result = event.tool_result
        step = ToolStep(
            phase="end",
            call_id=result.tool_call_id,
            name=result.name,
            is_error=result.is_error,
            elapsed_ms=result.elapsed_ms,
        )
        return TurnEvent(seq=seq, type="tool", tool=step)
    if kind == "context_compacted":
        return TurnEvent(seq=seq, type="compacted")
    if kind == "agent_done":
        done = event.result
        usage = done.usage.model_dump() if done is not None else None
        reply = AgentReply(
            session_id=session_id,
            message_id=message_id,
            status="done",
            text=(done.text or "") if done is not None else "",
            finish_reason=done.finish_reason if done is not None else None,
            model=done.model if done is not None else None,
            usage={k: int(v) for k, v in (usage or {}).items() if isinstance(v, int)} or None,
        )
        return TurnEvent(seq=seq, type="done", reply=reply)
    if kind == "agent_error":
        reply = AgentReply(
            session_id=session_id, message_id=message_id, status="error", error=event.error
        )
        return TurnEvent(seq=seq, type="error", reply=reply)
    if kind == "agent_cancelled":
        reply = AgentReply(session_id=session_id, message_id=message_id, status="cancelled")
        return TurnEvent(seq=seq, type="cancelled", reply=reply)
    return None


# ---------------------------------------------------------------------- 服务
class AgentService:
    """``AGENT`` 服务：``scoped(ctx)`` 给插件一个 ``AgentClient``（按条目缓存，卸下时收尾）。"""

    def __init__(self, host_ops: Any) -> None:
        self._host_ops = host_ops
        self._agents: dict[str, PluginAgent] = {}

    def for_entry(self, ctx: Any) -> PluginAgent:
        agent = self._agents.get(ctx.entry_id)
        if agent is None:
            approved, act_as = (
                self._host_ops.approval(ctx.entry_id)
                if self._host_ops is not None
                else (None, None)
            )
            agent = PluginAgent(ctx.entry_id, tier=granted_tier(ctx, approved), act_as=act_as)
            self._agents[ctx.entry_id] = agent

            async def forget() -> None:
                if self._agents.get(ctx.entry_id) is agent:
                    del self._agents[ctx.entry_id]
                await agent.dispose()

            ctx.effect(forget, label="dispose-agent")
        return agent

    def scoped(self, ctx: Any) -> AgentClient:
        return AgentClient(self.for_entry(ctx))

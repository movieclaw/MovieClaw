"""IM 通道的 AI 助手对接（所有通道共用一份，docs/design/plugin-channels.md §4）。

能力与网页会话完全一致：同一份系统提示词、同一套工具（services/agent_toolkit），技能调用
同样展开。唯一不带的是卡片绘制工具——IM 里画不出卡片。远程入口的权限收口留给权限机制，
不在这里另拼一份受限的 Agent。

会话持久化：通道里的对话与网页「最近会话」共用同一套 AI 会话（agent_session 索引 + JSONL 转录）。
每个账号持有一个「当前会话」，首条消息时创建、``/reset`` 后换新；历史从转录重建，重启不丢。

体验：收到消息先回执「思考中💭」；通道支持「正在输入」的，处理期间开着，结束关掉。
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
import uuid
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import TYPE_CHECKING

from movieclaw_agent import AgentRunner, AgentStartParams, discover_skills, expand_skill_invocations
from movieclaw_agent.events import AgentEvent
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.i18n import t
from movieclaw_api.services.agent_session_recorder import AgentSessionRecorder
from movieclaw_api.services.agent_sessions import get_agent_session_store
from movieclaw_api.services.agent_toolkit import agent_system_prompt, profile_tools
from movieclaw_api.services.im_attachments import prepare_agent_input
from movieclaw_api.services.llm_config import acquire_llm_router
from movieclaw_channel.dispatcher import (
    SERVICE_INTERRUPTED_TEXT,
    SERVICE_STOP_CANCEL_REASON,
    USER_STOP_CANCEL_REASON,
    current_channel_run_state,
)
from movieclaw_channel.pusher import StepReplyPusher
from movieclaw_db.engine import get_database
from movieclaw_db.repositories.agent_session_repo import AgentSessionRepository
from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository
from movieclaw_sdk.channels import Account, ChannelDriver, InboundMessage

if TYPE_CHECKING:
    from movieclaw_api.services.channel_hub import HostAccount

logger = logging.getLogger("movieclaw_api.channel_agent")

#: 收到消息后的即时回执（先让用户知道已收到，再慢慢生成）
ACK_TEXT_KEY = "agent.channel.thinking"


async def ensure_agent_session(driver: ChannelDriver, account: Account, msg: InboundMessage) -> str:
    """取该账号当前的 AI 会话 id；缺失或已失效（索引行或转录文件不在）则新建并记下。"""
    store = get_agent_session_store()
    async with get_database().session() as session:
        accounts = ChannelAccountRepository(session)
        row = await accounts.get(account.channel_id, account.id)
        existing = (row.agent_session_id or "").strip() if row else ""
        if existing:
            session_row = await AgentSessionRepository(session).get(existing)
            if session_row is not None and store.path(existing).exists():
                return existing
            logger.warning(
                "通道会话已失效，将新建 channel=%s account=%s session=%s",
                account.channel_id,
                account.id,
                existing,
            )
        header = store.create()
        await AgentSessionRepository(session).create(
            header.session_id, title=f"{driver.title or account.channel_id} · {msg.user_id}"
        )
        await accounts.set_agent_session(account.channel_id, account.id, header.session_id)
        return header.session_id


async def run_agent(
    driver: ChannelDriver,
    account: HostAccount,
    msg: InboundMessage,
    emit: Callable[[str], Awaitable[None]],
) -> None:
    from movieclaw_api.i18n import use_locale
    from movieclaw_api.services.locale_preferences import member_locale

    with use_locale(await member_locale(account.member_id)):
        await _run_agent(driver, account, msg, emit)


async def _run_agent(
    driver: ChannelDriver,
    account: HostAccount,
    msg: InboundMessage,
    emit: Callable[[str], Awaitable[None]],
) -> None:
    """dispatcher 的 run_agent 回调：一条入站消息驱动一次 AI 助手运行，分步回复。"""
    await emit(t(ACK_TEXT_KEY))
    run_id = uuid.uuid4().hex[:12]
    pusher = StepReplyPusher(emit, cancelled_text=SERVICE_INTERRUPTED_TEXT)
    run_state = current_channel_run_state()
    recorder: AgentSessionRecorder | None = None
    typing_active = False
    runner_started = False
    last_event: AgentEvent | None = None
    cancel_notice_pushed = False
    fallback_cancel_reason: object | None = None
    cancelled = False
    try:
        try:
            async with get_database().session() as session:
                llm_router = await acquire_llm_router(session)
        except NotFoundException as exc:
            await emit(f"⚠️ {exc.message}")
            return

        store = get_agent_session_store()
        session_id = await ensure_agent_session(driver, account, msg)
        history = store.build_history(session_id)
        recorder = AgentSessionRecorder(
            store, session_id, entry_count=len(history), source="channel"
        )

        # 显式技能调用（/skill:名字）与网页同样展开为技能正文（docs/design/agent-skills.md §9）
        msg = dataclasses.replace(
            msg,
            text=expand_skill_invocations(
                msg.text, discover_skills(Path(get_settings().agent_skills_dir).resolve())
            ),
        )
        # 图片入库 + 提醒回执 + 请求水合
        prepared = await prepare_agent_input(
            llm_router=llm_router, session_id=session_id, msg=msg, history=history, emit=emit
        )
        if prepared is None:
            # 纯图消息且图片全军覆没：失败原因已回执，不留空消息进转录
            return
        await recorder.record_user_message(prepared.user_content)

        tools = await profile_tools("full", session_id, None)
        runner = AgentRunner(
            llm_router,
            tools=tools,
            on_message=recorder.on_message,
            on_compaction=recorder.on_compaction,
        )
        await recorder.begin(run_id)

        if driver.capabilities.typing:
            # 即使取消落在 typing-on 的 await 内，也要在统一 finally 尝试关掉。
            typing_active = True
            await _typing(driver, account, msg, on=True)
        system_prompt = await agent_system_prompt(tools, speaker=account.member_id)
        async for ev in runner.start(
            AgentStartParams(
                input=prepared.input_for_run,
                history=prepared.history_for_run,
                # 通道账号绑定在某个成员名下（0=超管），对面说话的就是他
                system_prompt=system_prompt,
            ),
            run_id=run_id,
        ):
            runner_started = True
            last_event = ev
            await pusher.feed(ev)
            if ev.type == "agent_cancelled":
                cancel_notice_pushed = True
    except asyncio.CancelledError as exc:
        # dispatcher 的共享 run state 是事实源；参数只兼容直接取消该协程的调用方。
        cancelled = True
        if run_state is not None:
            # 必须在任何收尾 await 前同步置位，dispatcher 才不会补第二次 cancel。
            run_state.finalizing = True
        fallback_cancel_reason = exc.args[0] if exc.args else None
        raise
    finally:
        try:
            terminal = (
                AgentEvent(type="agent_cancelled", run_id=run_id)
                if cancelled
                else last_event
                if last_event is not None
                and last_event.type in ("agent_done", "agent_error", "agent_cancelled")
                else AgentEvent(type="agent_cancelled", run_id=run_id)
                if runner_started
                else None
            )
            if terminal is not None:
                if run_state is not None:
                    run_state.finalizing = True
                cancel_reason = (
                    run_state.cancel_reason
                    if run_state is not None and run_state.cancel_reason is not None
                    else fallback_cancel_reason
                )
                # runner 收到 task.cancel() 时可能来不及 yield 终态；服务停机
                # 的提示必须先于 recorder / typing 等慢清理。
                try:
                    if (
                        terminal.type == "agent_cancelled"
                        and not cancel_notice_pushed
                        and cancel_reason != USER_STOP_CANCEL_REASON
                    ):
                        await pusher.feed(terminal)
                finally:
                    if run_state is not None:
                        run_state.outbound_finalized.set()
                if recorder is not None:
                    reason = (
                        USER_STOP_CANCEL_REASON
                        if cancel_reason == USER_STOP_CANCEL_REASON
                        else SERVICE_STOP_CANCEL_REASON
                    )
                    await recorder.on_terminal(terminal, reason=reason)
        finally:
            if typing_active:
                await _typing(driver, account, msg, on=False)


async def _typing(
    driver: ChannelDriver, account: Account, msg: InboundMessage, *, on: bool
) -> None:
    """「正在输入」是锦上添花：驱动出错只记日志，绝不影响消息主链路。"""
    try:
        await driver.typing(account, msg.reply, on)
    except Exception as exc:  # noqa: BLE001
        logger.debug("正在输入状态切换失败（忽略）：%s", exc)

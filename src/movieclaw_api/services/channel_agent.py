"""IM 通道的 AI 助手对接（所有通道共用一份，docs/design/plugin-channels.md §4）。

安全红线：IM 是远程入口，即使有白名单也只给**受限工具集**——只挂 mclaw 产品操作工具，不开
bash / read / write / edit 工作区工具，拿不到宿主机 shell。

会话持久化：通道里的对话与网页「最近会话」共用同一套 AI 会话（agent_session 索引 + JSONL 转录）。
每个账号持有一个「当前会话」，首条消息时创建、``/reset`` 后换新；历史从转录重建，重启不丢。

体验：收到消息先回执「思考中💭」；通道支持「正在输入」的，处理期间开着，结束关掉。
"""

from __future__ import annotations

import logging
import uuid
from collections.abc import Awaitable, Callable
from pathlib import Path

from movieclaw_agent import AgentRunner, AgentStartParams
from movieclaw_agent.events import AgentEvent
from movieclaw_agent.tools import make_mclaw_tool
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.services import auth as auth_service
from movieclaw_api.services.agent_session_recorder import AgentSessionRecorder
from movieclaw_api.services.agent_sessions import get_agent_session_store
from movieclaw_api.services.im_attachments import prepare_agent_input
from movieclaw_api.services.llm_config import acquire_llm_router
from movieclaw_api.services.mclaw_tool import render_service_map
from movieclaw_channel.pusher import StepReplyPusher
from movieclaw_db.engine import get_database
from movieclaw_db.repositories.agent_session_repo import AgentSessionRepository
from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository
from movieclaw_sdk.channels import Account, ChannelDriver, InboundMessage

logger = logging.getLogger("movieclaw_api.channel_agent")

#: 通道侧 AI 助手的步数上限：IM 对话不该跑出超长循环
MAX_STEPS = 40
#: 收到消息后的即时回执（先让用户知道已收到，再慢慢生成）
ACK_TEXT = "思考中💭"


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


async def _restricted_tools(session_id: str, channel_id: str):
    settings = get_settings()
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in channel_id)
    workdir = Path(settings.agent_workspace_dir).resolve() / safe
    workdir.mkdir(parents=True, exist_ok=True)
    token = await auth_service.issue_agent_token(session_id)
    cli_env = {
        "MOVIECLAW_SERVER": f"http://127.0.0.1:{settings.port}",
        "MOVIECLAW_TOKEN": token,
    }
    return [make_mclaw_tool(workdir, cli_env, render_service_map())]


async def run_agent(
    driver: ChannelDriver,
    account: Account,
    msg: InboundMessage,
    emit: Callable[[str], Awaitable[None]],
) -> None:
    """dispatcher 的 run_agent 回调：一条入站消息驱动一次 AI 助手运行，分步回复。"""
    await emit(ACK_TEXT)
    try:
        async with get_database().session() as session:
            llm_router = await acquire_llm_router(session)
    except NotFoundException as exc:
        await emit(f"⚠️ {exc.message}")
        return

    store = get_agent_session_store()
    session_id = await ensure_agent_session(driver, account, msg)
    history = store.build_history(session_id)
    recorder = AgentSessionRecorder(store, session_id, entry_count=len(history))

    # 图片入库 + 提醒回执 + 请求水合
    prepared = await prepare_agent_input(
        llm_router=llm_router, session_id=session_id, msg=msg, history=history, emit=emit
    )
    if prepared is None:
        # 纯图消息且图片全军覆没：失败原因已回执，不留空消息进转录
        return
    await recorder.record_user_message(prepared.user_content)

    runner = AgentRunner(
        llm_router,
        tools=await _restricted_tools(session_id, account.channel_id),
        max_steps=MAX_STEPS,
        on_message=recorder.on_message,
        on_compaction=recorder.on_compaction,
    )
    run_id = uuid.uuid4().hex[:12]
    await recorder.begin(run_id)

    typing = driver.capabilities.typing
    if typing:
        await _typing(driver, account, msg, on=True)
    pusher = StepReplyPusher(emit)
    last_event: AgentEvent | None = None
    try:
        async for ev in runner.start(
            AgentStartParams(input=prepared.input_for_run, history=prepared.history_for_run),
            run_id=run_id,
        ):
            last_event = ev
            await pusher.feed(ev)
    finally:
        if typing:
            await _typing(driver, account, msg, on=False)
        # 任务被取消（服务停机）时事件流没有终态事件，合成 cancelled 供收尾统一处理
        terminal = (
            last_event
            if last_event is not None
            and last_event.type in ("agent_done", "agent_error", "agent_cancelled")
            else AgentEvent(type="agent_cancelled", run_id=run_id)
        )
        # 通道里没有用户主动停止的入口（/stop 走 dispatcher 取消），取消多半来自停机
        await recorder.on_terminal(terminal, reason="service_interrupted")


async def _typing(
    driver: ChannelDriver, account: Account, msg: InboundMessage, *, on: bool
) -> None:
    """「正在输入」是锦上添花：驱动出错只记日志，绝不影响消息主链路。"""
    try:
        await driver.typing(account, msg.reply, on)
    except Exception as exc:  # noqa: BLE001
        logger.debug("正在输入状态切换失败（忽略）：%s", exc)

"""Agent 插件：运行注册表、会话索引校准、附件暂存清理（plugin-kernel.md §7）。"""

from __future__ import annotations

from movieclaw_api.plugins.keys import AGENT_RUNS, DB
from movieclaw_kernel import Context, plugin


@plugin(
    "agent.runs", title="Agent 运行注册表", inject=(DB,), provides=(AGENT_RUNS,), reloadable=True
)
async def agent_runs(ctx: Context) -> None:
    """管理 AI 助手正在进行的对话，支持在后台运行，断线重连后还能接着看进度。"""
    from movieclaw_api.services.agent_runs import (
        close_agent_run_registry,
        init_agent_run_registry,
    )

    # 注册表持有后台 task 和 asyncio.Condition，必须与当前事件循环同生共死。
    # 关闭时先停 Agent，避免它在下游 HTTP 客户端和数据库开始释放后继续工作
    registry = init_agent_run_registry()
    ctx.effect(close_agent_run_registry, label="close-agent-runs")
    ctx.provide(AGENT_RUNS, registry)


@plugin("agent.session-index", title="Agent 会话索引校准", inject=(DB,), reloadable=True)
async def agent_session_index(ctx: Context) -> None:
    """启动时按对话记录文件校准 AI 助手的会话列表，上次异常退出也能对齐。"""
    from movieclaw_api.services.agent_session_recorder import rebuild_agent_session_index

    # JSONL 转录是事实源，把 SQLite 索引校准到与文件一致（上次崩溃在两步写入之间也能恢复）
    await rebuild_agent_session_index()


@plugin("agent.attachments", title="Agent 附件暂存清理", reloadable=True)
async def agent_attachments(ctx: Context) -> None:
    """启动时清理上传后超过 24 小时仍未发送的 AI 助手图片附件。"""
    from movieclaw_api.services.agent_attachments import get_agent_attachment_store

    # 回收上传后从未发送的过期图片附件（staging 区，24h TTL），兜住「长期没人上传」的场景
    get_agent_attachment_store().cleanup_staging()

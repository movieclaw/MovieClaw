"""IM channel Agent cancellation finalization."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

from movieclaw_agent.events import AgentEvent
from movieclaw_api.services import channel_agent
from movieclaw_channel.dispatcher import SERVICE_STOP_CANCEL_REASON, USER_STOP_CANCEL_REASON
from movieclaw_sdk.channels import InboundMessage, ReplyContext


class _SessionContext:
    async def __aenter__(self):
        return object()

    async def __aexit__(self, *args):
        return None


class _Database:
    def session(self):
        return _SessionContext()


class _Store:
    def build_history(self, session_id: str) -> list:
        return []


class _Recorder:
    def __init__(self) -> None:
        self.terminals: list[tuple[str, str]] = []

    async def record_user_message(self, content) -> None:
        return None

    async def begin(self, run_id: str) -> None:
        return None

    async def on_message(self, *args) -> None:
        return None

    async def on_compaction(self, *args) -> None:
        return None

    async def on_terminal(self, event: AgentEvent, reason: str) -> None:
        self.terminals.append((event.type, reason))


def _message() -> InboundMessage:
    return InboundMessage(
        channel_id="weixin",
        account_id="bot1",
        user_id="u1",
        text="你好",
        reply=ReplyContext(channel_id="weixin", account_id="bot1", user_id="u1"),
        provider_message_id="m1",
    )


def _patch_run_dependencies(monkeypatch, runner_type, recorder: _Recorder) -> None:
    async def acquire(_session):
        return object()

    async def ensure_session(*args):
        return "session-1"

    async def prepare(**kwargs):
        return SimpleNamespace(
            user_content="你好",
            input_for_run="你好",
            history_for_run=[],
        )

    async def tools(*args):
        return []

    async def prompt(*args, **kwargs):
        return "system"

    monkeypatch.setattr(channel_agent, "t", lambda _key: "思考中💭")
    monkeypatch.setattr(channel_agent, "get_database", lambda: _Database())
    monkeypatch.setattr(channel_agent, "acquire_llm_router", acquire)
    monkeypatch.setattr(channel_agent, "get_agent_session_store", _Store)
    monkeypatch.setattr(channel_agent, "ensure_agent_session", ensure_session)
    monkeypatch.setattr(channel_agent, "AgentSessionRecorder", lambda *args, **kwargs: recorder)
    monkeypatch.setattr(
        channel_agent, "get_settings", lambda: SimpleNamespace(agent_skills_dir=".")
    )
    monkeypatch.setattr(channel_agent, "discover_skills", lambda _path: [])
    monkeypatch.setattr(channel_agent, "prepare_agent_input", prepare)
    monkeypatch.setattr(channel_agent, "profile_tools", tools)
    monkeypatch.setattr(channel_agent, "agent_system_prompt", prompt)
    monkeypatch.setattr(channel_agent, "AgentRunner", runner_type)


async def test_service_cancel_emits_synthesized_interruption_notice(monkeypatch) -> None:
    """CancelledError 没有流终态时，合成 agent_cancelled 也必须推到原渠道。"""
    started = asyncio.Event()

    class HangingRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            yield AgentEvent(type="agent_start", run_id=run_id)
            started.set()
            await asyncio.Event().wait()
            yield  # pragma: no cover

    recorder = _Recorder()
    _patch_run_dependencies(monkeypatch, HangingRunner, recorder)
    emitted: list[str] = []

    async def emit(text: str) -> None:
        emitted.append(text)

    driver = SimpleNamespace(capabilities=SimpleNamespace(typing=False))
    account = SimpleNamespace(member_id=0)
    task = asyncio.create_task(channel_agent._run_agent(driver, account, _message(), emit))
    await asyncio.wait_for(started.wait(), timeout=2)

    task.cancel(SERVICE_STOP_CANCEL_REASON)
    with pytest.raises(asyncio.CancelledError):
        await task

    assert emitted == ["思考中💭", "已取消本次处理。"]
    assert recorder.terminals == [("agent_cancelled", "service_interrupted")]


async def test_stream_cancelled_terminal_is_not_emitted_twice(monkeypatch) -> None:
    """runner 已发布取消终态时只推一次，finally 不重复刷屏。"""

    class CancelledRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            yield AgentEvent(type="agent_start", run_id=run_id)
            yield AgentEvent(type="agent_cancelled", run_id=run_id)

    recorder = _Recorder()
    _patch_run_dependencies(monkeypatch, CancelledRunner, recorder)
    emitted: list[str] = []

    async def emit(text: str) -> None:
        emitted.append(text)

    driver = SimpleNamespace(capabilities=SimpleNamespace(typing=False))
    account = SimpleNamespace(member_id=0)

    await channel_agent._run_agent(driver, account, _message(), emit)

    assert emitted == ["思考中💭", "已取消本次处理。"]
    assert recorder.terminals == [("agent_cancelled", "service_interrupted")]


async def test_user_stop_keeps_single_dispatcher_ack(monkeypatch) -> None:
    """/stop 已由 dispatcher 回执，channel_agent 不再补第二条取消消息。"""
    started = asyncio.Event()

    class HangingRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            yield AgentEvent(type="agent_start", run_id=run_id)
            started.set()
            await asyncio.Event().wait()
            yield  # pragma: no cover

    recorder = _Recorder()
    _patch_run_dependencies(monkeypatch, HangingRunner, recorder)
    emitted: list[str] = []

    async def emit(text: str) -> None:
        emitted.append(text)

    driver = SimpleNamespace(capabilities=SimpleNamespace(typing=False))
    account = SimpleNamespace(member_id=0)
    task = asyncio.create_task(channel_agent._run_agent(driver, account, _message(), emit))
    await asyncio.wait_for(started.wait(), timeout=2)

    task.cancel(USER_STOP_CANCEL_REASON)
    with pytest.raises(asyncio.CancelledError):
        await task

    assert emitted == ["思考中💭"]
    assert recorder.terminals == [("agent_cancelled", "service_interrupted")]

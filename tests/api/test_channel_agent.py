"""IM channel Agent cancellation finalization."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

from movieclaw_agent.events import AgentDone, AgentEvent
from movieclaw_api.services import channel_agent
from movieclaw_channel import dispatcher as dispatcher_mod
from movieclaw_channel.dispatcher import (
    SERVICE_INTERRUPTED_TEXT,
    SERVICE_STOP_CANCEL_REASON,
    make_dispatcher,
)
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

    assert emitted == ["思考中💭", SERVICE_INTERRUPTED_TEXT]
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

    assert emitted == ["思考中💭", SERVICE_INTERRUPTED_TEXT]
    assert recorder.terminals == [("agent_cancelled", "service_interrupted")]


async def test_prompt_failure_before_runner_does_not_emit_cancel_notice(monkeypatch) -> None:
    """runner 尚未真正开始时的普通异常不能伪装成服务停机。"""

    class UnusedRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):  # pragma: no cover - prompt 先失败
            yield AgentEvent(type="agent_start", run_id=run_id)

    recorder = _Recorder()
    _patch_run_dependencies(monkeypatch, UnusedRunner, recorder)

    async def broken_prompt(*args, **kwargs):
        raise RuntimeError("prompt failed")

    monkeypatch.setattr(channel_agent, "agent_system_prompt", broken_prompt)
    emitted: list[str] = []

    async def emit(text: str) -> None:
        emitted.append(text)

    with pytest.raises(RuntimeError, match="prompt failed"):
        await channel_agent._run_agent(
            SimpleNamespace(capabilities=SimpleNamespace(typing=False)),
            SimpleNamespace(member_id=0),
            _message(),
            emit,
        )

    assert emitted == ["思考中💭"]
    assert recorder.terminals == []


async def test_runner_failure_before_first_event_does_not_emit_cancel_notice(monkeypatch) -> None:
    """runner.start 首次 yield 前的普通异常不能合成 agent_cancelled。"""

    class BrokenRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            if False:  # pragma: no cover - 只用于把函数声明成 async generator
                yield AgentEvent(type="agent_start", run_id=run_id)
            raise RuntimeError("runner startup failed")

    recorder = _Recorder()
    _patch_run_dependencies(monkeypatch, BrokenRunner, recorder)
    emitted: list[str] = []

    async def emit(text: str) -> None:
        emitted.append(text)

    with pytest.raises(RuntimeError, match="runner startup failed"):
        await channel_agent._run_agent(
            SimpleNamespace(capabilities=SimpleNamespace(typing=False)),
            SimpleNamespace(member_id=0),
            _message(),
            emit,
        )

    assert emitted == ["思考中💭"]
    assert recorder.terminals == []


async def test_runner_failure_after_first_event_does_not_emit_cancel_notice(monkeypatch) -> None:
    """runner 已启动但普通异常也不能合成服务停机。"""

    class BrokenRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            yield AgentEvent(type="agent_start", run_id=run_id)
            raise RuntimeError("runner stream failed")

    recorder = _Recorder()
    _patch_run_dependencies(monkeypatch, BrokenRunner, recorder)
    emitted: list[str] = []

    async def emit(text: str) -> None:
        emitted.append(text)

    with pytest.raises(RuntimeError, match="runner stream failed"):
        await channel_agent._run_agent(
            SimpleNamespace(capabilities=SimpleNamespace(typing=False)),
            SimpleNamespace(member_id=0),
            _message(),
            emit,
        )

    assert emitted == ["思考中💭"]
    assert recorder.terminals == []


async def test_shutdown_does_not_cancel_completed_answer_finalizer(monkeypatch) -> None:
    """agent_done 已发最终答案并进入慢 recorder 后，停机不得改判为中断。"""
    recorder_started = asyncio.Event()
    release_recorder = asyncio.Event()

    class DoneRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            yield AgentEvent(type="text_delta", run_id=run_id, delta="最终答案")
            yield AgentEvent(type="agent_done", run_id=run_id, result=AgentDone(text="最终答案"))

    class SlowRecorder(_Recorder):
        async def on_terminal(self, event: AgentEvent, reason: str) -> None:
            recorder_started.set()
            await release_recorder.wait()
            await super().on_terminal(event, reason)

    class OutboundAdapter:
        channel_id = "weixin"
        max_text_len = 1000

        def __init__(self) -> None:
            self.sent: list[str] = []

        async def send_text(self, reply, text: str) -> None:
            self.sent.append(text)

    recorder = SlowRecorder()
    _patch_run_dependencies(monkeypatch, DoneRunner, recorder)
    monkeypatch.setattr(dispatcher_mod, "_CLOSE_RUN_TIMEOUT_S", 0.01)
    driver = SimpleNamespace(capabilities=SimpleNamespace(typing=False))
    account = SimpleNamespace(member_id=0)

    async def run_agent(msg, emit) -> None:
        await channel_agent._run_agent(driver, account, msg, emit)

    adapter = OutboundAdapter()
    dispatcher = make_dispatcher(adapter, is_allowed=lambda _user: True, run_agent=run_agent)
    dispatcher.start()
    await dispatcher.submit_inbound(_message())
    await asyncio.wait_for(recorder_started.wait(), timeout=2)
    session = next(iter(dispatcher._sessions.values()))  # noqa: SLF001
    run = session.current_run
    assert run is not None

    close_task = asyncio.create_task(dispatcher.close())
    await asyncio.sleep(0.05)

    assert run.cancelling() == 0
    assert adapter.sent == ["思考中💭", "最终答案"]
    assert not close_task.done()

    release_recorder.set()
    await asyncio.wait_for(close_task, timeout=2)
    assert adapter.sent == ["思考中💭", "最终答案"]
    assert recorder.terminals == [("agent_done", "service_interrupted")]


async def test_user_stop_keeps_single_dispatcher_ack(monkeypatch) -> None:
    """/stop 的共享 run state 让 channel_agent 记 user_cancelled，且不重复提示。"""
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
    driver = SimpleNamespace(capabilities=SimpleNamespace(typing=False))
    account = SimpleNamespace(member_id=0)

    class OutboundAdapter:
        channel_id = "weixin"
        max_text_len = 1000

        def __init__(self) -> None:
            self.sent: list[str] = []

        async def send_text(self, reply, text: str) -> None:
            self.sent.append(text)

    async def run_agent(msg, emit) -> None:
        await channel_agent._run_agent(driver, account, msg, emit)

    adapter = OutboundAdapter()
    dispatcher = make_dispatcher(adapter, is_allowed=lambda _user: True, run_agent=run_agent)
    dispatcher.start()
    try:
        await dispatcher.submit_inbound(_message())
        await asyncio.wait_for(started.wait(), timeout=2)
        stop = _message()
        stop = InboundMessage(
            channel_id=stop.channel_id,
            account_id=stop.account_id,
            user_id=stop.user_id,
            text="/stop",
            reply=stop.reply,
            provider_message_id="m2",
        )
        await dispatcher.submit_inbound(stop)
        deadline = asyncio.get_running_loop().time() + 2
        while (
            len(adapter.sent) < 2 or not recorder.terminals
        ) and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.01)

        assert adapter.sent == ["思考中💭", "已取消当前处理。"]
        assert recorder.terminals == [("agent_cancelled", "user_cancelled")]
    finally:
        await dispatcher.close()


@pytest.mark.parametrize("stage", ["acquire", "prepare", "typing"])
async def test_cancel_during_acked_setup_still_finalizes_once(monkeypatch, stage: str) -> None:
    """ACK 后任一慢初始化阶段被停机取消，都只发一次中断提示且不被二次取消。"""
    stage_started = asyncio.Event()

    class UnusedRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):  # pragma: no cover - 不会进入 runner
            yield AgentEvent(type="agent_start", run_id=run_id)

    class StageDriver:
        capabilities = SimpleNamespace(typing=stage == "typing")

        async def typing(self, account, reply, on: bool) -> None:
            if on:
                stage_started.set()
                await asyncio.Event().wait()

    class OutboundAdapter:
        channel_id = "weixin"
        max_text_len = 1000

        def __init__(self) -> None:
            self.sent: list[str] = []

        async def send_text(self, reply, text: str) -> None:
            self.sent.append(text)

    recorder = _Recorder()
    _patch_run_dependencies(monkeypatch, UnusedRunner, recorder)
    if stage == "acquire":

        async def slow_acquire(_session):
            stage_started.set()
            await asyncio.Event().wait()

        monkeypatch.setattr(channel_agent, "acquire_llm_router", slow_acquire)
    elif stage == "prepare":

        async def slow_prepare(**kwargs):
            stage_started.set()
            await asyncio.Event().wait()

        monkeypatch.setattr(channel_agent, "prepare_agent_input", slow_prepare)

    monkeypatch.setattr(dispatcher_mod, "_CLOSE_RUN_TIMEOUT_S", 0.01)
    monkeypatch.setattr(dispatcher_mod, "_CLOSE_FORCE_TIMEOUT_S", 0.02)
    driver = StageDriver()
    account = SimpleNamespace(member_id=0)

    async def run_agent(msg, emit) -> None:
        await channel_agent._run_agent(driver, account, msg, emit)

    adapter = OutboundAdapter()
    dispatcher = make_dispatcher(adapter, is_allowed=lambda _user: True, run_agent=run_agent)
    dispatcher.start()
    await dispatcher.submit_inbound(_message())
    await asyncio.wait_for(stage_started.wait(), timeout=2)
    session = next(iter(dispatcher._sessions.values()))  # noqa: SLF001
    run = session.current_run
    assert run is not None

    await dispatcher.close()

    assert adapter.sent == ["思考中💭", SERVICE_INTERRUPTED_TEXT]
    assert run.cancelling() == 1
    expected_terminals = [] if stage == "acquire" else [("agent_cancelled", "service_interrupted")]
    assert recorder.terminals == expected_terminals


async def test_finalizing_is_not_recancelled_during_slow_recorder_and_typing(monkeypatch) -> None:
    """提示先发；慢 recorder/typing 已进入 finalizing 后不能再被停机看门狗补刀。"""
    started = asyncio.Event()
    recorder_started = asyncio.Event()
    release_recorder = asyncio.Event()
    typing_off_started = asyncio.Event()
    release_typing = asyncio.Event()
    typing_off_finished = asyncio.Event()

    class HangingRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            yield AgentEvent(type="agent_start", run_id=run_id)
            started.set()
            await asyncio.Event().wait()
            yield  # pragma: no cover

    class SlowRecorder(_Recorder):
        async def on_terminal(self, event: AgentEvent, reason: str) -> None:
            recorder_started.set()
            await release_recorder.wait()
            await super().on_terminal(event, reason)

    class TypingDriver:
        capabilities = SimpleNamespace(typing=True)

        async def typing(self, account, reply, on: bool) -> None:
            if on:
                return
            typing_off_started.set()
            await release_typing.wait()
            typing_off_finished.set()

    class OutboundAdapter:
        channel_id = "weixin"
        max_text_len = 1000

        def __init__(self) -> None:
            self.sent: list[str] = []

        async def send_text(self, reply, text: str) -> None:
            self.sent.append(text)

    recorder = SlowRecorder()
    _patch_run_dependencies(monkeypatch, HangingRunner, recorder)
    monkeypatch.setattr(dispatcher_mod, "_CLOSE_RUN_TIMEOUT_S", 0.01)
    monkeypatch.setattr(dispatcher_mod, "_CLOSE_FORCE_TIMEOUT_S", 0.02)
    driver = TypingDriver()
    account = SimpleNamespace(member_id=0)

    async def run_agent(msg, emit) -> None:
        await channel_agent._run_agent(driver, account, msg, emit)

    adapter = OutboundAdapter()
    dispatcher = make_dispatcher(adapter, is_allowed=lambda _user: True, run_agent=run_agent)
    dispatcher.start()
    await dispatcher.submit_inbound(_message())
    await asyncio.wait_for(started.wait(), timeout=2)
    session = next(iter(dispatcher._sessions.values()))  # noqa: SLF001
    run = session.current_run
    assert run is not None

    close_task = asyncio.create_task(dispatcher.close())

    await asyncio.wait_for(recorder_started.wait(), timeout=2)
    await asyncio.wait_for(
        _wait_until(lambda: adapter.sent == ["思考中💭", SERVICE_INTERRUPTED_TEXT]), timeout=2
    )
    assert run.cancelling() == 1
    assert not close_task.done()

    release_recorder.set()
    await asyncio.wait_for(typing_off_started.wait(), timeout=2)
    assert not typing_off_finished.is_set()
    release_typing.set()
    await asyncio.wait_for(close_task, timeout=2)
    assert typing_off_finished.is_set()
    assert recorder.terminals == [("agent_cancelled", "service_interrupted")]


async def _wait_until(predicate) -> None:
    while not predicate():
        await asyncio.sleep(0.01)

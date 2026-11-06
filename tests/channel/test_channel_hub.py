"""IM 通道中枢（docs/design/plugin-channels.md §6）。

用假驱动驱动真实的 ChannelHub + ChannelManager + dispatcher 链路：
- 配对码绑定：错满次数作废、命中转正且回执送达、超时停临时账号并恢复原绑定；
- 交互式绑定：前端不轮询也会落库启动，需要输入时转给驱动；
- 表单直绑（推送型通道）与主动推送；
- 通道列表跟着注册表走：驱动没了停账号（账号保留）、回来了自动恢复；
- 凭据失效标记 stale、白名单、私有状态持久化、插件化之前的旧行照常可用；
- 第三方通道 id 带冒号（插件前缀）也能正常启停。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import time
from collections.abc import Callable
from types import SimpleNamespace

import pytest
from sqlmodel import SQLModel

from movieclaw_channel.dispatcher import SERVICE_INTERRUPTED_TEXT
from movieclaw_db.engine import dispose_db, init_db
from movieclaw_sdk.channels import (
    Account,
    AdapterDriver,
    Binding,
    BindResult,
    Capabilities,
    ChannelAuthError,
    ChannelDriver,
    FlowState,
    FormField,
    InboundMessage,
    ReplyContext,
)


@pytest.fixture
async def db(tmp_path):
    """临时 SQLite 库 + 临时密钥的加密器（通道凭据落库前会加密）。"""
    from movieclaw_db.crypto import init_secret_box, reset_secret_box

    reset_secret_box()
    init_secret_box(None, tmp_path / ".secret_key")
    database = init_db(f"sqlite+aiosqlite:///{tmp_path}/test.db")
    async with database.engine.begin() as conn:
        await conn.run_sync(SQLModel.metadata.create_all)
    yield database
    await dispose_db()
    reset_secret_box()


async def _wait_for(predicate: Callable[[], bool], timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        await asyncio.sleep(0.02)
    raise AssertionError("等待条件超时")


class FakeDriver(ChannelDriver):
    """最小驱动：收消息循环只等停，测试经账号句柄注入入站消息；发送记到列表。"""

    title = "假通道"
    capabilities = Capabilities(receive=True, max_text_len=1000)

    def __init__(self, *, pairing: str = "code", account_id: str = "bot1") -> None:
        self.binding = Binding.form((FormField("token", "Token", secret=True),), pairing=pairing)  # type: ignore[arg-type]
        self.account_id = account_id
        self.live: dict[str, Account] = {}
        self.runs: list[dict[str, str]] = []
        self.sent: list[tuple[str, str]] = []
        self.auth_fail = False

    async def validate(self, fields: dict[str, str]) -> BindResult:
        if fields.get("token") == "bad":
            raise ValueError("token 不对")
        return BindResult(
            account_id=self.account_id,
            display_name="testbot",
            credentials={"token": fields["token"]},
        )

    async def run(self, account: Account) -> None:
        self.runs.append(dict(account.credentials))
        self.live[account.id] = account
        if self.auth_fail:
            raise ChannelAuthError("token 过期")
        try:
            await account.stopping.wait()
        finally:
            if self.live.get(account.id) is account:
                del self.live[account.id]

    async def send(self, account: Account, reply: ReplyContext, text: str) -> None:
        # 模拟真实 HTTP 往返：配对终态回执若走出站队列，随后的停账号会把它丢掉
        await asyncio.sleep(0.05)
        self.sent.append((reply.user_id, text))

    def texts(self) -> list[str]:
        return [text for _user, text in self.sent]


class StrictLiveDriver(FakeDriver):
    """模拟 AdapterDriver：收消息循环退出后 client 注销，不能再发送。"""

    async def send(self, account: Account, reply: ReplyContext, text: str) -> None:
        if self.live.get(account.id) is not account:
            raise RuntimeError("账号 client 已停止")
        await super().send(account, reply, text)


class ReplaySource:
    """带持久游标的假服务端；停收泵期间到达的消息留给下次启动。"""

    def __init__(self) -> None:
        self.messages: list[str] = []
        self.available = asyncio.Event()
        self.receiving = asyncio.Event()
        self.quiescing = asyncio.Event()
        self.release_quiesce = asyncio.Event()

    def add(self, text: str) -> None:
        self.messages.append(text)
        self.available.set()

    def reset_runtime_events(self) -> None:
        self.available = asyncio.Event()
        self.receiving = asyncio.Event()
        self.quiescing = asyncio.Event()
        self.release_quiesce = asyncio.Event()


class ReplayClient:
    async def aclose(self) -> None:
        return None


class ReplayAdapter:
    def __init__(self, source: ReplaySource, sent: list[tuple[str, str]]) -> None:
        self.source = source
        self.sent = sent

    async def run(self, ctx) -> None:
        cursor = int(ctx.initial_cursor or 0)
        stop = ctx.stop or asyncio.Event()
        while not stop.is_set():
            if cursor < len(self.source.messages):
                text = self.source.messages[cursor]
                cursor += 1
                await ctx.save_cursor(str(cursor))
                await ctx.on_inbound(
                    InboundMessage(
                        channel_id="replay",
                        account_id=ctx.account_id,
                        user_id="alice",
                        text=text,
                        reply=ReplyContext("replay", ctx.account_id, "alice"),
                        provider_message_id=f"replay-{cursor}",
                    )
                )
                continue
            self.source.receiving.set()
            self.source.available.clear()
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self.source.available.wait(), timeout=0.02)
        self.source.quiescing.set()
        await self.source.release_quiesce.wait()

    async def send_text(self, reply: ReplyContext, text: str) -> None:
        self.sent.append((reply.user_id, text))


class ReplayDriver(AdapterDriver):
    title = "游标回放通道"
    capabilities = Capabilities(receive=True, max_text_len=1000)

    def __init__(self, source: ReplaySource) -> None:
        super().__init__()
        self.source = source
        self.sent: list[tuple[str, str]] = []

    def open(self, account: Account):
        return ReplayClient(), ReplayAdapter(self.source, self.sent)


def _message(account: Account, text: str, seq: int, user: str = "u1") -> InboundMessage:
    reply = ReplyContext(channel_id="whatever", account_id=account.id, user_id=user)
    return InboundMessage(
        channel_id="whatever",
        account_id=account.id,
        user_id=user,
        text=text,
        reply=reply,
        provider_message_id=f"m{seq}",
    )


def make_hub(drivers: dict[str, ChannelDriver]):
    from movieclaw_api.services.channel_hub import ChannelHub

    return ChannelHub(lambda: dict(drivers))


async def _rows():
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    async with get_database().session() as session:
        return await ChannelAccountRepository(session).list_all()


# ---------------------------------------------------------------------- 配对码


async def test_wrong_pair_code_attempt_cap(db) -> None:
    """错满次数后绑定作废、临时账号停止（防 6 位码暴力猜解）。"""
    from movieclaw_api.services.channel_hub import PAIR_MAX_ATTEMPTS

    driver = FakeDriver()
    hub = make_hub({"tg": driver})
    try:
        binding = await hub.begin_binding("tg", {"token": "tok-123456"})
        assert binding.kind == "pairing" and len(binding.pair_code) == 6
        await _wait_for(lambda: "bot1" in driver.live)
        account = driver.live["bot1"]
        for i in range(PAIR_MAX_ATTEMPTS):
            await account.inbound(_message(account, "wrong", i))
        await _wait_for(lambda: binding.status == "failed")
        await _wait_for(lambda: any("作废" in t for t in driver.texts()))
        await _wait_for(lambda: not hub.is_running("tg", "bot1"))
        assert await _rows() == []
    finally:
        await hub.stop()


async def test_correct_pair_code_confirms_and_delivers_receipt(db) -> None:
    """配对成功：回执在临时账号停掉之前送达，发码人成为白名单，账号以正式身份重启。"""
    driver = FakeDriver()
    hub = make_hub({"tg": driver})
    try:
        binding = await hub.begin_binding("tg", {"token": "tok-abc"})
        await _wait_for(lambda: "bot1" in driver.live)
        temp = driver.live["bot1"]
        await temp.inbound(_message(temp, binding.pair_code, 0, user="alice"))
        await _wait_for(lambda: binding.status == "confirmed")
        await _wait_for(lambda: any("绑定成功" in t for t in driver.texts()))
        await _wait_for(lambda: len(driver.runs) >= 2 and "bot1" in driver.live)
        assert driver.live["bot1"] is not temp
        assert driver.live["bot1"].bound_user == "alice"
        [row] = await _rows()
        assert (row.channel_id, row.account_id, row.bound_user_id) == ("tg", "bot1", "alice")
        assert row.display_name == "testbot"
    finally:
        await hub.stop()


async def test_expired_pairing_stops_temp_account_and_restores(db, monkeypatch) -> None:
    """超时：停临时账号，恢复该 bot 原有的正式绑定（用库里的旧凭据，不是这次没配完的新 token）。"""
    from movieclaw_api.services import channel_hub
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    async with get_database().session() as session:
        await ChannelAccountRepository(session).upsert(
            channel_id="tg",
            account_id="bot1",
            credentials={"token": "old-token"},
            display_name="testbot",
            bound_user_id="u1",
        )
    monkeypatch.setattr(channel_hub, "PAIR_TTL_S", 0.2)
    driver = FakeDriver()
    hub = make_hub({"tg": driver})
    try:
        await hub.start()
        await _wait_for(lambda: driver.runs == [{"token": "old-token"}])
        binding = await hub.begin_binding("tg", {"token": "new-token"})
        await _wait_for(lambda: binding.status == "expired")
        await _wait_for(lambda: driver.runs[-1] == {"token": "old-token"} and len(driver.runs) == 3)
        await _wait_for(lambda: hub.is_running("tg", "bot1"))
        assert driver.live["bot1"].bound_user == "u1"
    finally:
        await hub.stop()


async def test_pairing_binding_reports_expiry_when_polled(db, monkeypatch) -> None:
    from movieclaw_api.services import channel_hub

    driver = FakeDriver()
    hub = make_hub({"tg": driver})
    try:
        binding = await hub.begin_binding("tg", {"token": "tok"})
        binding.expires_at = time.monotonic() - 1
        polled = hub.binding(binding.binding_id)
        assert polled is not None and polled.status == "expired"
        with pytest.raises(ValueError, match="token 不对"):
            await hub.begin_binding("tg", {"token": "bad"})
        with pytest.raises(channel_hub.ChannelUnavailable):
            await hub.begin_binding("nope", {})
    finally:
        await hub.stop()


# ---------------------------------------------------------------------- 交互式


class FlowDriver(FakeDriver):
    """交互式绑定：pending → need_input →（输入 42）→ confirmed。"""

    binding = Binding.flow(hint="扫码")

    def __init__(self) -> None:
        super().__init__(pairing="none", account_id="wx1")
        self.binding = Binding.flow(hint="扫码")
        self.status = "pending"
        self.existing: list[str] = []
        self.cancelled: list[str] = []

    async def begin_flow(self, accounts: list[Account]) -> FlowState:
        self.existing = [a.credentials["token"] for a in accounts]
        return await self.flow_state("f1")

    async def flow_state(self, flow_id: str) -> FlowState:
        result = None
        if self.status == "confirmed":
            result = BindResult(
                account_id="wx1",
                display_name="微信",
                credentials={"token": "t", "base_url": "https://gw"},
                bound_user="bob",
                state={"cursor": "c0"},
            )
        return FlowState(
            flow_id=flow_id,
            status=self.status,  # type: ignore[arg-type]
            message=self.status,
            qr="https://qr.example/x",
            input_label="输入数字" if self.status == "need_input" else None,
            result=result,
        )

    async def flow_input(self, flow_id: str, value: str) -> FlowState:
        if value == "42":
            self.status = "confirmed"
        return await self.flow_state(flow_id)

    async def cancel_flow(self, flow_id: str) -> None:
        self.cancelled.append(flow_id)


async def test_flow_binding_commits_without_polling(db, monkeypatch) -> None:
    from movieclaw_api.services import channel_hub

    monkeypatch.setattr(channel_hub, "FLOW_POLL_S", 0.02)
    driver = FlowDriver()
    hub = make_hub({"wx": driver})
    try:
        binding = await hub.begin_binding("wx", {})
        assert binding.kind == "flow" and binding.qr == "https://qr.example/x"
        driver.status = "need_input"
        await _wait_for(lambda: binding.status == "need_input")
        assert binding.input_label == "输入数字"
        await hub.binding_input(binding.binding_id, "41")
        assert binding.status == "need_input"
        await hub.binding_input(binding.binding_id, "42")
        assert binding.status == "confirmed" and binding.account_id == "wx1"
        await _wait_for(lambda: "wx1" in driver.live)
        account = driver.live["wx1"]
        assert account.bound_user == "bob"
        assert account.credentials == {"token": "t", "base_url": "https://gw"}
        assert account.state == {"cursor": "c0"}
        # 再发起一次：驱动拿到已绑定账号的凭据（判断「已绑定过本实例」）
        driver.status = "pending"
        await hub.begin_binding("wx", {})
        assert driver.existing == ["t"]
    finally:
        await hub.stop()
    assert driver.cancelled == ["f1"]


# ---------------------------------------------------------------------- 表单直绑与推送


class PushOnlyDriver(FakeDriver):
    capabilities = Capabilities(receive=False, photo=True)

    def __init__(self) -> None:
        super().__init__(pairing="none", account_id="hook1")
        self.photos: list[tuple[bytes, str]] = []

    async def send_photo(self, account, reply, photo, caption) -> None:
        self.photos.append((photo, caption))

    def push_target(self, account: Account) -> ReplyContext | None:
        return ReplyContext(account.channel_id, account.id, "group")


async def test_form_binding_without_pairing_and_push_fan_out(db) -> None:
    group = PushOnlyDriver()
    chat = FakeDriver()
    hub = make_hub({"hook": group, "tg": chat})
    try:
        binding = await hub.begin_binding("hook", {"token": "x"})
        assert (binding.kind, binding.status, binding.account_id) == ("done", "confirmed", "hook1")
        await _wait_for(lambda: hub.is_running("hook", "hook1"))
        # 能对话的通道没有绑定人（异常数据）：不推送
        from movieclaw_db.engine import get_database
        from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

        async with get_database().session() as session:
            await ChannelAccountRepository(session).upsert(
                channel_id="tg",
                account_id="bot1",
                credentials={"token": "t"},
                display_name="b",
                bound_user_id="u1",
            )
        await hub.sync()
        await _wait_for(lambda: hub.is_running("tg", "bot1"))
        assert await hub.push("新片入库", photo=b"jpg") == 2
        await _wait_for(lambda: group.photos == [(b"jpg", "新片入库")])
        await _wait_for(lambda: chat.sent == [("u1", "新片入库")])
        assert await hub.unbind("hook", "hook1") is True
        assert not hub.is_running("hook", "hook1")
        assert await hub.push("再来一条") == 1
    finally:
        await hub.stop()


# ---------------------------------------------------------------------- 注册表与账号


async def test_accounts_follow_the_registry(db) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    async with get_database().session() as session:
        await ChannelAccountRepository(session).upsert(
            channel_id="acme.ntfy:ntfy",
            account_id="topic-1",
            credentials={"token": "t"},
            display_name="ntfy",
            bound_user_id="u1",
        )
    driver = FakeDriver()
    drivers: dict[str, ChannelDriver] = {}
    hub = make_hub(drivers)
    try:
        await hub.start()
        assert not hub.is_running("acme.ntfy:ntfy", "topic-1")
        # 第三方通道装上（id 带插件前缀与冒号）：自动启动
        drivers["acme.ntfy:ntfy"] = driver
        await hub.sync()
        await _wait_for(lambda: hub.is_running("acme.ntfy:ntfy", "topic-1"))
        # 关掉 / 卸载：账号停下但保留在库里
        drivers.clear()
        await hub.sync()
        await _wait_for(lambda: not hub.is_running("acme.ntfy:ntfy", "topic-1"))
        assert [r.account_id for r in await _rows()] == ["topic-1"]
        with pytest.raises(LookupError):
            hub.driver("acme.ntfy:ntfy")
        drivers["acme.ntfy:ntfy"] = driver
        await hub.sync()
        await _wait_for(lambda: hub.is_running("acme.ntfy:ntfy", "topic-1"))
    finally:
        await hub.stop()
    assert not hub.is_running("acme.ntfy:ntfy", "topic-1")


async def test_inbound_whitelist_state_and_auth_error(db, monkeypatch) -> None:
    from movieclaw_api.services import channel_agent
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    seen: list[tuple[str, str, str]] = []

    async def fake_agent(driver, account, msg, emit) -> None:
        seen.append((msg.channel_id, msg.user_id, msg.text))
        await emit(f"收到：{msg.text}")

    monkeypatch.setattr(channel_agent, "run_agent", fake_agent)
    async with get_database().session() as session:
        await ChannelAccountRepository(session).upsert(
            channel_id="tg",
            account_id="bot1",
            credentials={"token": "t"},
            display_name="b",
            bound_user_id="alice",
        )
    driver = FakeDriver()
    hub = make_hub({"tg": driver})
    try:
        await hub.start()
        await _wait_for(lambda: "bot1" in driver.live)
        account = driver.live["bot1"]
        await account.inbound(_message(account, "陌生人", 1, user="mallory"))
        await account.inbound(_message(account, "你好", 2, user="alice"))
        await _wait_for(lambda: ("alice", "收到：你好") in driver.sent)
        # 通道 id 以注册表为准，陌生人被白名单挡掉
        assert seen == [("tg", "alice", "你好")]
        await account.save_state({"cursor": "42"})
        async with get_database().session() as session:
            row = await ChannelAccountRepository(session).get("tg", "bot1")
        assert row is not None and ChannelAccountRepository.state(row) == {"cursor": "42"}
    finally:
        await hub.stop()

    # 凭据失效：标记 stale，下次启动不再拉起
    failing = FakeDriver()
    failing.auth_fail = True
    hub = make_hub({"tg": failing})
    try:
        await hub.start()
        await _wait_for(lambda: bool(failing.runs))
        async with get_database().session() as session:
            await _wait_for_status(session, "stale")
    finally:
        await hub.stop()


async def test_shutdown_delivers_agent_interruption_before_driver_stops(db, monkeypatch) -> None:
    """真实中枢停机顺序：client 仍 live 时取消 Agent 并送出中断提示。"""
    from movieclaw_api.services import channel_agent
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    started = asyncio.Event()

    async def hanging_agent(driver, account, msg, emit) -> None:
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            await emit("服务更新中断了这次处理，请重新发送。")

    monkeypatch.setattr(channel_agent, "run_agent", hanging_agent)
    async with get_database().session() as session:
        await ChannelAccountRepository(session).upsert(
            channel_id="weixin",
            account_id="bot1",
            credentials={"token": "t"},
            display_name="微信",
            bound_user_id="alice",
        )
    driver = StrictLiveDriver()
    hub = make_hub({"weixin": driver})
    try:
        await hub.start()
        await _wait_for(lambda: "bot1" in driver.live)
        account = driver.live["bot1"]
        await account.inbound(_message(account, "跑个长任务", 1, user="alice"))
        await asyncio.wait_for(started.wait(), timeout=2)

        await hub.stop()

        assert driver.sent == [("alice", "服务更新中断了这次处理，请重新发送。")]
        assert "bot1" not in driver.live
    finally:
        await hub.stop()


async def test_hub_keeps_adapter_client_live_through_slow_finalizer(db, monkeypatch) -> None:
    """完整 Hub 停机链路须等慢 recorder/typing 清理结束后才关闭发送 client。"""
    from movieclaw_agent.events import AgentEvent
    from movieclaw_api.services import channel_agent
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    runner_started = asyncio.Event()
    recorder_started = asyncio.Event()
    release_recorder = asyncio.Event()
    typing_off_started = asyncio.Event()
    release_typing = asyncio.Event()

    class Store:
        def build_history(self, session_id: str) -> list:
            return []

    class SlowRecorder:
        async def record_user_message(self, content) -> None:
            return None

        async def begin(self, run_id: str) -> None:
            return None

        async def on_message(self, *args) -> None:
            return None

        async def on_compaction(self, *args) -> None:
            return None

        async def on_terminal(self, event, reason: str) -> None:
            recorder_started.set()
            await release_recorder.wait()

    class HangingRunner:
        def __init__(self, *args, **kwargs) -> None:
            pass

        async def start(self, params, *, run_id):
            yield AgentEvent(type="agent_start", run_id=run_id)
            runner_started.set()
            await asyncio.Event().wait()
            yield  # pragma: no cover

    class Client:
        def __init__(self) -> None:
            self.closed = False

        async def aclose(self) -> None:
            self.closed = True

    class Adapter:
        def __init__(self, client: Client, sent: list[str]) -> None:
            self.client = client
            self.sent = sent

        async def run(self, ctx) -> None:
            await (ctx.stop or asyncio.Event()).wait()

        async def quiesce(self) -> None:
            return None

        async def send_text(self, reply, text: str) -> None:
            assert not self.client.closed
            self.sent.append(text)

    class Driver(AdapterDriver):
        title = "慢收尾通道"
        capabilities = Capabilities(receive=True, typing=True, max_text_len=1000)

        def __init__(self) -> None:
            super().__init__()
            self.client = Client()
            self.sent: list[str] = []

        def open(self, account: Account):
            return self.client, Adapter(self.client, self.sent)

        async def typing(self, account, reply, on: bool) -> None:
            assert not self.client.closed
            if not on:
                typing_off_started.set()
                await release_typing.wait()
                assert not self.client.closed

    async def acquire(_session):
        return object()

    async def ensure_session(*args):
        return "session-1"

    async def prepare(**kwargs):
        return SimpleNamespace(user_content="你好", input_for_run="你好", history_for_run=[])

    async def tools(*args):
        return []

    async def prompt(*args, **kwargs):
        return "system"

    async def run_agent(driver, account, msg, emit) -> None:
        await channel_agent._run_agent(driver, account, msg, emit)

    monkeypatch.setattr(channel_agent, "run_agent", run_agent)
    monkeypatch.setattr(channel_agent, "t", lambda _key: "思考中💭")
    monkeypatch.setattr(channel_agent, "acquire_llm_router", acquire)
    monkeypatch.setattr(channel_agent, "get_agent_session_store", Store)
    monkeypatch.setattr(channel_agent, "ensure_agent_session", ensure_session)
    monkeypatch.setattr(channel_agent, "AgentSessionRecorder", lambda *a, **kw: SlowRecorder())
    monkeypatch.setattr(
        channel_agent, "get_settings", lambda: SimpleNamespace(agent_skills_dir=".")
    )
    monkeypatch.setattr(channel_agent, "discover_skills", lambda _path: [])
    monkeypatch.setattr(channel_agent, "prepare_agent_input", prepare)
    monkeypatch.setattr(channel_agent, "profile_tools", tools)
    monkeypatch.setattr(channel_agent, "agent_system_prompt", prompt)
    monkeypatch.setattr(channel_agent, "AgentRunner", HangingRunner)

    async with get_database().session() as session:
        await ChannelAccountRepository(session).upsert(
            channel_id="slow",
            account_id="bot1",
            credentials={"token": "t"},
            display_name="slow",
            bound_user_id="alice",
        )

    driver = Driver()
    hub = make_hub({"slow": driver})
    try:
        await hub.start()
        await _wait_for(lambda: hub.running_account("slow", "bot1") is not None)
        account = hub.running_account("slow", "bot1")
        assert account is not None
        await _wait_for(lambda: ("slow", "bot1") in driver._live)  # noqa: SLF001
        await account.inbound(_message(account, "慢任务", 1, user="alice"))
        await asyncio.wait_for(runner_started.wait(), timeout=2)

        stop_task = asyncio.create_task(hub.stop())
        await asyncio.wait_for(recorder_started.wait(), timeout=2)
        await _wait_for(lambda: SERVICE_INTERRUPTED_TEXT in driver.sent)
        assert not driver.client.closed
        assert not stop_task.done()

        release_recorder.set()
        await asyncio.wait_for(typing_off_started.wait(), timeout=2)
        assert not driver.client.closed
        assert not stop_task.done()

        release_typing.set()
        await asyncio.wait_for(stop_task, timeout=2)
        assert driver.client.closed
        assert driver.sent == ["思考中💭", SERVICE_INTERRUPTED_TEXT]
    finally:
        release_recorder.set()
        release_typing.set()
        await hub.stop()


async def test_message_arriving_during_quiesce_replays_from_persisted_cursor(
    db, monkeypatch
) -> None:
    """停机先停收泵且不推进游标；此窗口到达的消息由重启后的账号重放。"""
    from movieclaw_api.services import channel_agent
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    async def echo_agent(driver, account, msg, emit) -> None:
        await emit(f"收到：{msg.text}")

    monkeypatch.setattr(channel_agent, "run_agent", echo_agent)
    async with get_database().session() as session:
        await ChannelAccountRepository(session).upsert(
            channel_id="replay",
            account_id="bot1",
            credentials={"token": "t"},
            display_name="replay",
            bound_user_id="alice",
        )

    source = ReplaySource()
    driver = ReplayDriver(source)
    hub = make_hub({"replay": driver})
    await hub.start()
    await asyncio.wait_for(source.receiving.wait(), timeout=2)
    stop_task = asyncio.create_task(hub.stop())
    await asyncio.wait_for(source.quiescing.wait(), timeout=2)

    source.add("停机窗口消息")
    assert not stop_task.done()
    source.release_quiesce.set()
    await asyncio.wait_for(stop_task, timeout=2)

    async with get_database().session() as session:
        row = await ChannelAccountRepository(session).get("replay", "bot1")
        assert row is not None
        assert ChannelAccountRepository.state(row).get("cursor") is None

    source.reset_runtime_events()
    restarted = make_hub({"replay": driver})
    try:
        await restarted.start()
        await _wait_for(lambda: driver.sent == [("alice", "收到：停机窗口消息")])
        async with get_database().session() as session:
            row = await ChannelAccountRepository(session).get("replay", "bot1")
            assert row is not None
            assert ChannelAccountRepository.state(row)["cursor"] == "1"
    finally:
        source.release_quiesce.set()
        await restarted.stop()


async def _wait_for_status(session, status: str) -> None:
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    for _ in range(100):
        session.expire_all()
        row = await ChannelAccountRepository(session).get("tg", "bot1")
        if row is not None and row.status == status:
            assert "凭据已失效" in (row.last_error or "")
            return
        await asyncio.sleep(0.02)
    raise AssertionError(f"账号没有变成 {status}")


async def test_rows_bound_before_channel_plugins_keep_working(db) -> None:
    """插件化之前绑定的账号：裸凭据 + 网关地址列 + 游标 / 会话令牌列，读出来是新形态。"""
    from movieclaw_db.crypto import get_secret_box
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.channel_account import ChannelAccount
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    box = get_secret_box()
    async with get_database().session() as session:
        session.add(
            ChannelAccount(
                channel_id="weixin",
                account_id="wx-old",
                token=box.encrypt("bot-token"),
                base_url="https://gw.example",
                bound_user_id="me@im.wechat",
                cursor="buf==",
                context_token="ctx",
            )
        )
        session.add(
            ChannelAccount(
                channel_id="feishu",
                account_id="hook",
                token=box.encrypt(json.dumps({"webhook_url": "https://x", "secret": "s"})),
                base_url="",
            )
        )
        await session.commit()
    driver = FakeDriver()
    hub = make_hub({"weixin": driver})
    try:
        await hub.start()
        await _wait_for(lambda: "wx-old" in driver.live)
        account = driver.live["wx-old"]
        assert account.credentials == {"token": "bot-token", "base_url": "https://gw.example"}
        assert account.state == {"cursor": "buf==", "context_token": "ctx"}
        assert account.display_name == "wx-old"
        await account.save_state({"cursor": "next"})
        async with get_database().session() as session:
            row = await ChannelAccountRepository(session).get("weixin", "wx-old")
            hook = await ChannelAccountRepository(session).get("feishu", "hook")
        assert row is not None and hook is not None
        assert ChannelAccountRepository.state(row) == {"cursor": "next", "context_token": "ctx"}
        assert ChannelAccountRepository.credentials(hook) == {
            "webhook_url": "https://x",
            "secret": "s",
        }
    finally:
        await hub.stop()

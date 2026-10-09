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
import json
import time
from collections.abc import Callable

import pytest
from sqlmodel import SQLModel

from movieclaw_db.engine import dispose_db, init_db
from movieclaw_sdk.channels import (
    Account,
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

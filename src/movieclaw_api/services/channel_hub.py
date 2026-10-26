"""IM 通道中枢（docs/design/plugin-channels.md §6）。

所有通道共用的部分都在这里，不认识任何具体平台：

- 通道列表 = 注册表 ``im-channels`` 现取：通道插件装上、关掉、卸载，中枢跟着启停账号，不用重启；
- 账号存储（凭据加密、插件私有状态、白名单、当前 AI 会话）；
- 绑定：表单（可带配对码）与插件驱动的交互式流程两种；
- 收发：复用 ``movieclaw_channel`` 的 manager / dispatcher（白名单、去重、会话串行、拆分、重试），
  驱动经 ``_DriverAdapter`` 接进去；入站消息交给 AI 助手（``channel_agent``）；
- 主动推送：发到某个成员的账号（推什么由通知决定，services/push/im.py）；测试推送发给所有账号。

通道插件不在了（关闭 / 卸载），它的账号仍在库里，设置页显示「通道插件未启用」，接口不报错。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import secrets
import time
import uuid
from collections.abc import Awaitable, Callable, Coroutine
from copy import deepcopy
from dataclasses import dataclass, field, replace
from typing import Any

from movieclaw_api.i18n import current_locale, t, use_locale
from movieclaw_api.i18n.stored import (
    keyed_error,
    reference,
    source_render,
    source_text,
    stored_fields,
)
from movieclaw_api.services.system_notice import resolve_notices, upsert_notice
from movieclaw_channel.adapter import ChannelContext
from movieclaw_channel.dispatcher import make_dispatcher
from movieclaw_channel.manager import ChannelManager
from movieclaw_db.engine import get_database
from movieclaw_db.models import NoticeSeverity
from movieclaw_db.models.channel_account import ChannelAccount, ChannelAccountStatus
from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository
from movieclaw_sdk.channels import (
    Account,
    BindResult,
    ChannelDriver,
    FlowState,
    InboundMessage,
    OutboundEnvelope,
    ReplyContext,
)

logger = logging.getLogger("movieclaw_api.channel_hub")

#: 配对码有效期
PAIR_TTL_S = 10 * 60
#: 配对码最大尝试次数：6 位数字码 + 配对期对所有人放行，不设上限就能被暴力猜码
PAIR_MAX_ATTEMPTS = 5
#: 终态绑定在内存里的留存期（前端轮询还要能读到终态）
BINDING_LINGER_S = 10 * 60
#: 交互式绑定的轮询间隔（驱动自己做长轮询，这里只读它的快照）
FLOW_POLL_S = 1.0

DriverLookup = Callable[[], dict[str, ChannelDriver]]


# ---------------------------------------------------------------------- 账号句柄


class HostAccount(Account):
    """中枢这一侧的账号句柄：驱动读字段、经 ``inbound`` / ``save_state`` 回调中枢。"""

    def __init__(
        self,
        *,
        channel_id: str,
        account_id: str,
        display_name: str,
        bound_user: str | None,
        credentials: dict[str, str],
        state: dict[str, Any],
        persist: bool = True,
        member_id: int = 0,
    ) -> None:
        self.channel_id = channel_id
        #: 归属成员（0=超管）：主动推送按这个人的通知偏好发
        self.member_id = member_id
        self.id = account_id
        self.display_name = display_name
        self.bound_user = bound_user
        self.credentials = credentials
        self.state = dict(state)
        self.stopping = asyncio.Event()
        #: 配对期的临时账号不落库（确认后才有那一行）
        self._persist = persist
        self._on_inbound: Callable[[InboundMessage], Awaitable[None]] | None = None

    async def inbound(self, message: InboundMessage) -> None:
        if self._on_inbound is None:
            return
        # 通道 id 以注册表为准（第三方通道带插件前缀，驱动自己不一定知道）
        if message.channel_id != self.channel_id or message.account_id != self.id:
            message = replace(
                message,
                channel_id=self.channel_id,
                account_id=self.id,
                reply=replace(message.reply, channel_id=self.channel_id, account_id=self.id),
            )
        await self._on_inbound(message)

    async def save_state(self, patch: dict[str, Any]) -> None:
        self.state.update(patch)
        if not self._persist:
            return
        async with get_database().session() as session:
            await ChannelAccountRepository(session).save_state(self.channel_id, self.id, patch)


class _DriverAdapter:
    """把「驱动 + 账号」接成 manager / dispatcher 认识的通道适配器。"""

    def __init__(self, driver: ChannelDriver, account: HostAccount) -> None:
        self.driver = driver
        self.account = account
        self.channel_id = account.channel_id
        self.max_text_len = driver.capabilities.max_text_len
        if driver.capabilities.photo:
            self.send_photo = self._send_photo

    async def run(self, ctx: ChannelContext) -> None:
        self.account.stopping = ctx.stop or asyncio.Event()
        self.account._on_inbound = ctx.on_inbound
        await self.driver.run(self.account)

    async def send_text(self, reply: ReplyContext, text: str) -> None:
        await self.driver.send(self.account, reply, text)

    async def _send_photo(self, reply: ReplyContext, photo: bytes, caption: str) -> None:
        await self.driver.send_photo(self.account, reply, photo, caption)


# ---------------------------------------------------------------------- 绑定


@dataclass(slots=True)
class Binding:
    """一次进行中的绑定（表单配对码或交互式流程），设置页轮询它。"""

    binding_id: str
    channel_id: str
    kind: str  # pairing / flow / done
    status: str = "pending"
    message: str = ""
    pair_code: str = ""
    #: 配对期：bot 的展示名（配对提示与旧版 App 的绑定页用）
    display_name: str = ""
    qr: str | None = None
    input_label: str | None = None
    account_id: str | None = None
    attempts: int = 0
    expires_at: float = field(default_factory=lambda: time.monotonic() + PAIR_TTL_S)
    #: 配对期：驱动校验通过的结果（确认后才落库）
    pending: BindResult | None = None
    #: 交互式：驱动侧的流程 id
    flow_id: str = ""
    #: 靠平台回调收消息的通道：这个账号的回调地址（只在发出的这一刻有完整地址）与说明
    callback_url: str | None = None
    callback_note: str = ""
    message_ref: dict | None = None
    input_label_localized: dict | None = None
    callback_note_ref: dict | None = None
    #: 发起绑定的人的界面语言：配对回执（IM 里的确认消息）用它
    locale: str = field(default_factory=current_locale.get)

    def text(self, key: str) -> str:
        with use_locale(self.locale):
            return t(key)

    def set_reason(self, key: str, **params) -> None:
        self.set_message(stored_fields(key, **params)["message"], reference(key, **params))

    def set_message(self, message: str, message_ref: dict | None = None) -> None:
        self.message = message
        self.message_ref = deepcopy(message_ref)

    @property
    def terminal(self) -> bool:
        return self.status in ("confirmed", "already_bound", "expired", "failed")


class ChannelUnavailable(LookupError):
    """通道插件未启用（关闭、卸载或从未安装）。"""


class ChannelBindingError(ValueError):
    def __init__(self, message_key: str, **params) -> None:
        self.message_key = message_key
        self.params = params
        self.message_ref = reference(message_key, **params)
        super().__init__(stored_fields(message_key, **params)["message"])


class ChannelBindingMissing(LookupError):
    message_ref = reference("channels.binding.missing")


def _message_fields(key: str, **params) -> dict:
    """Binding 的 message（中文原文）与 message_ref（按读者语言渲染）。"""
    return {
        "message": source_render(reference(key, **params)),
        "message_ref": reference(key, **params),
    }


def _driver_label(driver: ChannelDriver) -> dict:
    return {"message_text": driver.title, "message_localized": driver.title_localized}


# ---------------------------------------------------------------------- 中枢


def _notice_key(channel_id: str, account_id: str) -> str:
    return f"channel:{channel_id}:{account_id}"


async def _resolve_notice(channel_id: str, account_id: str) -> None:
    """账号重新绑定、或者解绑了：「账号失效」的待处理事项消退。出错只记日志。"""
    try:
        async with get_database().session() as session:
            await resolve_notices(session, dedupe_key=_notice_key(channel_id, account_id))
    except Exception:  # noqa: BLE001 -- 消退失败不影响绑定 / 解绑
        logger.warning("消退 IM 账号失效提醒失败", exc_info=True)


class ChannelHub:
    def __init__(
        self, drivers: DriverLookup, contributors: Callable[[], dict[str, str]] | None = None
    ) -> None:
        self._drivers = drivers
        #: 通道 id → 提供它的插件条目 id（设置页展示用）
        self._contributors = contributors or dict
        self.manager = ChannelManager()
        #: 在运行的账号：(通道, 账号) → 句柄
        self._accounts: dict[tuple[str, str], HostAccount] = {}
        self._bindings: dict[str, Binding] = {}
        self._bg_tasks: set[asyncio.Task[None]] = set()
        self._sync_lock = asyncio.Lock()
        #: 靠平台回调收消息的通道：通道 id → 撤销回调端点登记的函数
        self._webhooks: dict[str, Callable[[], None]] = {}

    # ------------------------------------------------------------------ 生命周期
    def drivers(self) -> dict[str, ChannelDriver]:
        return self._drivers()

    def contributor(self, channel_id: str) -> str:
        return self._contributors().get(channel_id, "")

    def driver(self, channel_id: str) -> ChannelDriver:
        found = self._drivers().get(channel_id)
        if found is None:
            raise keyed_error(ChannelUnavailable, "channels.binding.disabled", channel=channel_id)
        return found

    async def start(self) -> None:
        await self.sync()

    async def stop(self) -> None:
        for task in list(self._bg_tasks):
            task.cancel()
        for task in list(self._bg_tasks):
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        self._bg_tasks.clear()
        for binding in list(self._bindings.values()):
            if binding.kind == "flow" and binding.flow_id and not binding.terminal:
                with contextlib.suppress(Exception):
                    await self.driver(binding.channel_id).cancel_flow(binding.flow_id)
        self._bindings.clear()
        for dispose in self._webhooks.values():
            dispose()
        self._webhooks.clear()
        await self.manager.close()
        self._accounts.clear()

    async def sync(self) -> None:
        """对齐运行中的账号与注册表：有驱动的启动，驱动没了的停掉。"""
        async with self._sync_lock:
            drivers = self._drivers()
            self._sync_webhooks(drivers)
            for key in list(self._accounts):
                if key[0] not in drivers:
                    await self._stop_account(*key)
            async with get_database().session() as session:
                rows = await ChannelAccountRepository(session).list_all()
            for row in rows:
                key = (row.channel_id, row.account_id)
                if key in self._accounts or row.channel_id not in drivers:
                    continue
                if row.status != ChannelAccountStatus.ACTIVE:
                    continue
                try:
                    await self._start_account(row)
                except Exception:  # noqa: BLE001 -- 一个账号起不来不能拖累别的
                    logger.exception(
                        "通道账号启动失败 channel=%s account=%s", row.channel_id, row.account_id
                    )

    def _sync_webhooks(self, drivers: dict[str, ChannelDriver]) -> None:
        """靠平台回调收消息的通道：替提供它的插件登记 ``webhook`` 回调端点。

        docs/design/plugin-callbacks.md §4.5。
        """
        from movieclaw_api.services.plugin_callbacks import get_service

        for channel_id in list(self._webhooks):
            driver = drivers.get(channel_id)
            if driver is None or not driver.capabilities.webhook:
                self._webhooks.pop(channel_id)()
        service = get_service()
        if service is None:
            return
        for channel_id, driver in drivers.items():
            if not driver.capabilities.webhook or channel_id in self._webhooks:
                continue
            try:
                self._webhooks[channel_id] = service.register(
                    self.contributor(channel_id),
                    WEBHOOK_ENDPOINT,
                    self._webhook_handler(channel_id),
                    methods=("GET", "POST"),
                )
            except ValueError:
                logger.warning("通道 %s 的回调端点没能登记", channel_id, exc_info=True)

    def _webhook_handler(self, channel_id: str) -> Callable[[Any], Awaitable[Any]]:
        async def handle(request: Any) -> Any:
            from movieclaw_sdk.callbacks import CallbackResponse

            parsed = parse_account_scope(request.scope)
            if parsed is None or parsed[0] != channel_id:
                return CallbackResponse(status=404)
            account = self.running_account(*parsed)
            if account is None:
                # i18n-ignore: response to the messaging platform, not a person
                return CallbackResponse.text("这个账号没有在运行", status=503)
            return await self.driver(channel_id).webhook(account, request)

        return handle

    async def _attach_callback(self, binding: Binding) -> None:
        """靠平台回调收消息的通道：给这个账号发回调地址（已有就沿用，平台后台不用重填）。"""
        from movieclaw_api.services.plugin_callbacks import get_service

        driver = self.driver(binding.channel_id)
        if not driver.capabilities.webhook or not binding.account_id:
            return
        service = get_service()
        if service is None:
            raise ChannelBindingError("channels.binding.callbackUnavailable")
        entry_id = self.contributor(binding.channel_id)
        scope = account_scope(binding.channel_id, binding.account_id)
        existing = await service.active(entry_id, scope)
        if existing:
            binding.callback_url = existing[0].url
            binding.callback_note = source_text("channels.binding.callbackReused")
            binding.callback_note_ref = reference("channels.binding.callbackReused")
            return
        issued = await service.issue_for(entry_id, WEBHOOK_ENDPOINT, scope)
        binding.callback_url = issued.url
        note = (
            "channels.binding.callbackAbsolute"
            if issued.absolute
            else "channels.binding.callbackRelative"
        )
        binding.callback_note = source_text(note)
        binding.callback_note_ref = reference(note)

    async def _revoke_callbacks(self, channel_id: str, account_id: str) -> None:
        from movieclaw_api.services.plugin_callbacks import get_service

        service = get_service()
        entry_id = self.contributor(channel_id)
        if service is None or not entry_id:
            return
        await service.revoke_all(entry_id, scope=account_scope(channel_id, account_id))

    def schedule_sync(self) -> None:
        """注册表变化的回调是同步的：排一次对齐。"""
        # i18n-ignore: background task label for logs
        self._spawn(self.sync(), "通道对齐")

    def _spawn(self, coro: Coroutine[Any, Any, None], what: str) -> None:
        task = asyncio.get_running_loop().create_task(coro)
        self._bg_tasks.add(task)

        def done(t: asyncio.Task[None]) -> None:
            self._bg_tasks.discard(t)
            if not t.cancelled() and t.exception() is not None:
                logger.error("%s 后台任务失败", what, exc_info=t.exception())

        task.add_done_callback(done)

    # ------------------------------------------------------------------ 账号
    def is_running(self, channel_id: str, account_id: str) -> bool:
        return self.manager.is_running(channel_id, account_id)

    def running_account(self, channel_id: str, account_id: str) -> HostAccount | None:
        return self._accounts.get((channel_id, account_id))

    async def _start_account(self, row: ChannelAccount) -> None:
        account = HostAccount(
            channel_id=row.channel_id,
            account_id=row.account_id,
            display_name=row.display_name or row.account_id,
            bound_user=(row.bound_user_id or "").strip() or None,
            credentials=ChannelAccountRepository.credentials(row),
            state=ChannelAccountRepository.state(row),
            member_id=row.member_id,
        )
        await self._run_account(account)

    async def _run_account(self, account: HostAccount, *, pairing: Binding | None = None) -> None:
        from movieclaw_api.services.channel_agent import run_agent

        driver = self.driver(account.channel_id)
        adapter = _DriverAdapter(driver, account)
        if pairing is not None:

            async def pair(msg: InboundMessage, emit: Callable[[str], Awaitable[None]]) -> None:
                await self._on_pair_message(pairing, adapter, msg, emit)

            dispatcher = make_dispatcher(adapter, is_allowed=lambda _uid: True, run_agent=pair)
        else:
            bound = account.bound_user

            async def agent(msg: InboundMessage, emit: Callable[[str], Awaitable[None]]) -> None:
                await run_agent(driver, account, msg, emit)

            async def reset(_session_key: str) -> None:
                async with get_database().session() as session:
                    await ChannelAccountRepository(session).set_agent_session(
                        account.channel_id, account.id, None
                    )

            dispatcher = make_dispatcher(
                adapter,
                # 白名单 = 绑定人本人；缺失（推送型通道、异常数据）时拒绝所有人
                is_allowed=lambda uid, _bound=bound: bool(_bound) and uid == _bound,
                run_agent=agent,
                reset_session=reset,
            )
        self._accounts[(account.channel_id, account.id)] = account
        await self.manager.start_account(
            adapter,
            dispatcher,
            account_id=account.id,
            initial_cursor="",
            save_cursor=_noop_save,
            on_auth_error=self._on_auth_error(account.channel_id),
        )

    async def _stop_account(self, channel_id: str, account_id: str) -> None:
        self._accounts.pop((channel_id, account_id), None)
        await self.manager.stop_account(channel_id, account_id)

    def _on_auth_error(self, channel_id: str) -> Callable[[str], Awaitable[None]]:
        async def handle(account_id: str) -> None:
            title = self._title(channel_id)
            async with get_database().session() as session:
                # 存目录原文：读时按读者语言渲染（账号就列在通道下面，不必带通道名）
                await ChannelAccountRepository(session).mark_stale(
                    channel_id, account_id, source_text("channels.accounts.credentialsExpired")
                )
                # 凭据失效 = IM 通知悄悄断了：进待处理事项（管理员手机也会收到），重新绑定后自动消退
                await upsert_notice(
                    session,
                    dedupe_key=_notice_key(channel_id, account_id),
                    severity=NoticeSeverity.WARNING,
                    source="channel",
                    title_key="notify.channelStale.title",
                    message_key="notify.channelStale.body",
                    message_params={"channel": title},
                    payload={"channel_id": channel_id, "account_id": account_id},
                )
            self._accounts.pop((channel_id, account_id), None)

        return handle

    def _title(self, channel_id: str) -> str:
        driver = self._drivers().get(channel_id)
        return driver.title if driver is not None else channel_id

    async def unbind(self, channel_id: str, account_id: str) -> bool:
        """解绑：停收发、删凭据行。历史 AI 会话保留在「最近会话」里。

        与 ``sync`` 互斥：对齐在停账号与删行之间读到这一行的话会把账号又拉起来。
        """
        async with self._sync_lock:
            await self._stop_account(channel_id, account_id)
            await self._revoke_callbacks(channel_id, account_id)
            async with get_database().session() as session:
                removed = await ChannelAccountRepository(session).delete(channel_id, account_id)
        await _resolve_notice(channel_id, account_id)
        return removed

    def account_owners(self) -> set[int]:
        """在运行的账号归属于哪些成员（通知的 IM 渠道据此判断谁有 IM 可收）。"""
        return {account.member_id for account in self._accounts.values()}

    def account_count(self, member_id: int) -> int:
        """这个人在运行的账号数（「账号 → 通知」的测试按钮与实际发送同一口径）。"""
        return sum(1 for account in self._accounts.values() if account.member_id == member_id)

    async def accounts(self) -> list[ChannelAccount]:
        async with get_database().session() as session:
            return await ChannelAccountRepository(session).list_all()

    # ------------------------------------------------------------------ 推送
    async def push(
        self, text: str, photo: bytes | None = None, *, member_id: int | None = None
    ) -> int:
        """把一条文本（可附图）推给在运行、有推送目标的账号；返回送达队列的账号数。

        ``member_id``：只推这个人的账号；None = 所有账号（IM 推送页的测试推送）。
        """
        count = 0
        drivers = self._drivers()
        for (channel_id, account_id), account in list(self._accounts.items()):
            if member_id is not None and account.member_id != member_id:
                continue
            driver = drivers.get(channel_id)
            dispatcher = self.manager.get_dispatcher(channel_id, account_id)
            if driver is None or dispatcher is None:
                continue
            try:
                target = driver.push_target(account)
            except Exception:  # noqa: BLE001 -- 一个通道算不出目标不影响别的
                logger.exception("推送目标计算失败 channel=%s", channel_id)
                continue
            if target is None:
                continue
            await dispatcher.push_outbound(
                OutboundEnvelope(reply=target, text=text, origin="push", photo=photo)
            )
            count += 1
        return count

    # ------------------------------------------------------------------ 绑定
    def binding(self, binding_id: str) -> Binding | None:
        binding = self._bindings.get(binding_id)
        if (
            binding is not None
            and binding.kind == "pairing"
            and binding.status == "pending"
            and time.monotonic() > binding.expires_at
        ):
            binding.status = "expired"
            binding.set_reason("channels.binding.expired")
        return binding

    async def begin_binding(self, channel_id: str, fields: dict[str, str]) -> Binding:
        driver = self.driver(channel_id)
        if driver.binding.kind == "flow":
            return await self._begin_flow(channel_id, driver)
        try:
            result = await driver.validate(fields)
        except ValueError:
            raise
        except Exception as exc:  # noqa: BLE001 -- 校验失败的原因直接给用户看
            raise ChannelBindingError(
                "channels.binding.validationFailed",
                channel=_driver_label(driver),
                error=getattr(exc, "message_ref", None) or str(exc),
            ) from exc
        if driver.binding.pairing == "code":
            return await self._begin_pairing(channel_id, driver, result)
        row = await self._commit(channel_id, result)
        binding = Binding(
            binding_id=uuid.uuid4().hex[:16],
            channel_id=channel_id,
            kind="done",
            status="confirmed",
            **_message_fields("channels.binding.linked", channel=_driver_label(driver)),
            account_id=row.account_id,
        )
        await self._attach_callback(binding)
        self._remember(binding)
        return binding

    async def binding_input(self, binding_id: str, value: str) -> Binding:
        binding = self.binding(binding_id)
        if binding is None:
            raise keyed_error(ChannelBindingMissing, "channels.binding.missing")
        if binding.kind != "flow" or binding.terminal:
            return binding
        state = await self.driver(binding.channel_id).flow_input(binding.flow_id, value)
        await self._apply_flow(binding, state)
        return binding

    def _remember(self, binding: Binding) -> None:
        self._bindings[binding.binding_id] = binding

        async def linger() -> None:
            await asyncio.sleep(max(0.0, binding.expires_at - time.monotonic()) + BINDING_LINGER_S)
            self._bindings.pop(binding.binding_id, None)

        # i18n-ignore: background task label for logs
        self._spawn(linger(), "绑定留存")

    async def _commit(self, channel_id: str, result: BindResult) -> ChannelAccount:
        """绑定确认：凭据落库，账号以正式身份（重新）启动。"""
        async with get_database().session() as session:
            row = await ChannelAccountRepository(session).upsert(
                channel_id=channel_id,
                account_id=result.account_id,
                credentials=result.credentials,
                display_name=result.display_name,
                bound_user_id=result.bound_user,
                state=result.state,
            )
        async with self._sync_lock:  # 与 sync 互斥，免得同一账号被拉起两次
            await self._stop_account(channel_id, result.account_id)
            await self._start_account(row)
        await _resolve_notice(channel_id, result.account_id)
        logger.info("通道账号已绑定 channel=%s account=%s", channel_id, result.account_id)
        return row

    # ---- 交互式（插件驱动的流程，如微信扫码）
    async def _begin_flow(self, channel_id: str, driver: ChannelDriver) -> Binding:
        async with get_database().session() as session:
            rows = await ChannelAccountRepository(session).list_by_channel(channel_id)
        existing = [
            HostAccount(
                channel_id=row.channel_id,
                account_id=row.account_id,
                display_name=row.display_name or row.account_id,
                bound_user=row.bound_user_id,
                credentials=ChannelAccountRepository.credentials(row),
                state={},
                persist=False,
            )
            for row in rows
        ]
        state = await driver.begin_flow(existing)
        binding = Binding(
            binding_id=uuid.uuid4().hex[:16],
            channel_id=channel_id,
            kind="flow",
            flow_id=state.flow_id,
            expires_at=time.monotonic() + PAIR_TTL_S,
        )
        await self._apply_flow(binding, state)
        self._remember(binding)
        # i18n-ignore: background task label for logs
        self._spawn(self._watch_flow(binding), "交互式绑定")
        return binding

    async def _watch_flow(self, binding: Binding) -> None:
        """跟着驱动的流程走：前端不轮询也能完成绑定（扫完码就落库启动）。"""
        while not binding.terminal:
            await asyncio.sleep(FLOW_POLL_S)
            try:
                state = await self.driver(binding.channel_id).flow_state(binding.flow_id)
            except ChannelUnavailable:
                binding.status = "failed"
                binding.set_reason("channels.binding.closed")
                return
            except Exception as exc:  # noqa: BLE001
                logger.warning("读取绑定状态失败：%s", exc)
                continue
            await self._apply_flow(binding, state)

    async def _apply_flow(self, binding: Binding, state: FlowState) -> None:
        if binding.terminal:
            return
        binding.qr = state.qr
        binding.input_label = state.input_label
        binding.input_label_localized = deepcopy(state.input_label_localized)
        if state.status == "confirmed":
            if state.result is None:
                binding.status = "failed"
                binding.set_reason("channels.binding.missingResult")
                return
            try:
                row = await self._commit(binding.channel_id, state.result)
            except Exception as exc:  # noqa: BLE001
                logger.exception("绑定落库失败 channel=%s", binding.channel_id)
                binding.status = "failed"
                binding.set_reason(
                    "channels.binding.failed", error=getattr(exc, "message_ref", None) or str(exc)
                )
                return
            binding.account_id = row.account_id
            await self._attach_callback(binding)
        binding.status = state.status
        binding.set_message(
            state.message,
            {"message_text": state.message, "message_localized": state.message_localized}
            if state.message_localized
            else None,
        )

    # ---- 配对码（表单 + 私聊 bot 发码）
    async def _begin_pairing(
        self, channel_id: str, driver: ChannelDriver, result: BindResult
    ) -> Binding:
        code = f"{secrets.randbelow(1_000_000):06d}"
        binding = Binding(
            binding_id=uuid.uuid4().hex[:16],
            channel_id=channel_id,
            kind="pairing",
            pair_code=code,
            display_name=result.display_name,
            account_id=result.account_id,
            pending=result,
            **_message_fields(
                "channels.binding.pairing",
                channel=_driver_label(driver),
                name=result.display_name,
                code=code,
            ),
        )
        # 配对期临时收发：任何人发来的消息只跟配对码比对，不进 AI 助手；命中即落库转正
        await self._stop_account(channel_id, result.account_id)
        temp = HostAccount(
            channel_id=channel_id,
            account_id=result.account_id,
            display_name=result.display_name,
            bound_user=None,
            credentials=result.credentials,
            state=dict(result.state),
            persist=False,
        )
        await self._run_account(temp, pairing=binding)
        await self._attach_callback(binding)
        if binding.callback_url:
            binding.set_reason(
                "channels.binding.callbackPairing",
                channel=_driver_label(driver),
                name=result.display_name,
                code=code,
            )
        self._remember(binding)
        # i18n-ignore: background task label for logs
        self._spawn(self._pairing_watchdog(binding, temp), "配对超时守护")
        return binding

    async def _on_pair_message(
        self,
        binding: Binding,
        adapter: _DriverAdapter,
        msg: InboundMessage,
        emit: Callable[[str], Awaitable[None]],
    ) -> None:
        if binding.status != "pending":
            return
        if time.monotonic() > binding.expires_at:
            binding.status = "expired"
            binding.set_reason("channels.binding.expired")
            return
        if msg.text.strip() != binding.pair_code:
            binding.attempts += 1
            if binding.attempts >= PAIR_MAX_ATTEMPTS:
                binding.status = "failed"
                binding.set_reason("channels.binding.tooManyAttempts")
                # 终态回执直接发（不走出站队列）：随后停账号会关发送泵，入队的回执会丢
                await _send_receipt(adapter, msg, binding.text("channels.pairing.tooManyAttempts"))
                # i18n-ignore: background task label for logs
                self._spawn(self._teardown_pairing(binding, adapter.account), "配对作废清理")
                return
            await emit(binding.text("channels.pairing.wrongCode"))
            return
        pending = binding.pending
        if pending is None:
            binding.status = "failed"
            binding.set_reason("channels.binding.lost")
            return
        binding.pending = None
        binding.status = "confirmed"
        binding.set_reason("channels.binding.started")
        await _send_receipt(adapter, msg, binding.text("channels.pairing.success"))
        # 当前正在临时账号的会话 worker 里：转正（停临时账号、起正式账号）放后台，避免自锁
        self._spawn(
            self._confirm_pairing(binding, replace(pending, bound_user=msg.user_id)),
            # i18n-ignore: background task label for logs
            "配对转正",
        )

    async def _confirm_pairing(self, binding: Binding, result: BindResult) -> None:
        try:
            await self._commit(binding.channel_id, result)
        except Exception as exc:  # noqa: BLE001
            logger.exception("配对转正失败 channel=%s", binding.channel_id)
            binding.status = "failed"
            binding.set_reason(
                "channels.binding.failed", error=getattr(exc, "message_ref", None) or str(exc)
            )

    async def _pairing_watchdog(self, binding: Binding, temp: HostAccount) -> None:
        await asyncio.sleep(max(0.0, binding.expires_at - time.monotonic()))
        if binding.status == "pending":
            binding.status = "expired"
            binding.set_reason("channels.binding.expired")
        await self._teardown_pairing(binding, temp)

    async def _teardown_pairing(self, binding: Binding, temp: HostAccount) -> None:
        """停掉配对期临时账号；该账号之前有正式绑定的，恢复它。

        幂等：确认流程或新一轮绑定已接管该账号（运行中的句柄不是这个临时句柄）时不做任何事。
        """
        key = (binding.channel_id, temp.id)
        async with self._sync_lock:
            if self._accounts.get(key) is not temp:
                return
            await self._stop_account(*key)
            async with get_database().session() as session:
                row = await ChannelAccountRepository(session).get(*key)
            if row is None:
                await self._revoke_callbacks(*key)
            if row is not None and row.status == ChannelAccountStatus.ACTIVE:
                try:
                    await self._start_account(row)
                    logger.info("配对未完成，已恢复原账号 channel=%s account=%s", *key)
                except Exception:  # noqa: BLE001
                    logger.exception("配对未完成后恢复原账号失败 channel=%s account=%s", *key)


WEBHOOK_ENDPOINT = "webhook"


def account_scope(channel_id: str, account_id: str) -> str:
    """回调密钥的归属：``account:<通道>:<账号>``（两段各自转义，通道 id 里可能有冒号）。"""
    from urllib.parse import quote

    return f"account:{quote(channel_id, safe='')}:{quote(account_id, safe='')}"


def parse_account_scope(scope: str) -> tuple[str, str] | None:
    from urllib.parse import unquote

    parts = scope.split(":")
    if len(parts) != 3 or parts[0] != "account":
        return None
    return unquote(parts[1]), unquote(parts[2])


async def _noop_save(_cursor: str) -> None:
    return None


async def _send_receipt(adapter: _DriverAdapter, msg: InboundMessage, text: str) -> None:
    """配对终态回执：绕过出站队列直接发送；失败只记日志，不影响绑定结果。"""
    try:
        await adapter.send_text(msg.reply, text)
    except Exception:  # noqa: BLE001
        logger.exception("配对回执发送失败（不影响绑定结果）user=%s", msg.user_id)


# ---------------------------------------------------------------------- 单例

_hub: ChannelHub | None = None


def set_hub(hub: ChannelHub | None) -> None:
    global _hub
    _hub = hub


def get_hub() -> ChannelHub | None:
    """通道中枢；中枢插件没运行时为 ``None``（调用方按「通道不可用」处理，不抛错）。"""
    return _hub

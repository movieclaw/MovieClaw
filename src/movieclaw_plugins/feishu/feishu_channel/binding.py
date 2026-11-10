"""飞书自建应用的扫码创建流程。

设置页走中枢已有的交互式绑定:本模块后台轮询设备码,``flow_state`` 只读内存快照。
成功后先用 App ID / App Secret 换 tenant_access_token(连通性校验),再请用户确认
推送目标。留空推给扫码人的 open_id;填 ``oc_`` 开头的 chat_id 推到群,``ou_`` 开头的
open_id 推给指定用户。欢迎消息发出去才算绑定完成。发不出去就停在输入步,凭据留在
本进程里,方便换一个目标或回到表单重试。

``client_secret`` 只留在内存里,不写日志,也不放进给页面的 prefill。生命周期:

- 每个扫码会话(flow)各自独立,多个标签页 / 多个管理员同时扫码互不取消。
- 拿到凭据后另发一个 ≥128 bit 的随机续传令牌(``resume_token``,不进日志,和会进日志的
  flow_id 无关)。暂存的 Secret 只能凭令牌取一次:取走即从表里删掉,失败才放回原处,
  所以并发的两次续传 / 两次提交只有一个能用上。
- 绑定成功、表单续传成功、暂存过期(30 分钟,定时器主动清,不靠下一次访问)后,
  flow 与暂存一起删掉;成功结果交给中枢后只再留一个很短的宽限期给中枢读取,随后清空
  ``result.credentials`` 并删除 flow。取消 / 过期 / 失败且没有凭据的 flow 同样在宽限期后删除。
"""

from __future__ import annotations

import asyncio
import contextlib
import copy
import logging
import re
import secrets
import time
import uuid
from dataclasses import dataclass, field

from movieclaw_sdk.channels import BindResult, ChannelInputError, FlowState

from .client import FeishuApiError, FeishuClient, credentials_token
from .registration import RegistrationError, RegistrationSession

logger = logging.getLogger("movieclaw_plugins.feishu.binding")

APP_WELCOME = "🎉 MovieClaw 已接入，订阅投递、入库完成等事件将推送到这里。"
APP_DISPLAY_NAME = "飞书应用机器人"

_TERMINAL = frozenset({"confirmed", "already_bound", "expired", "failed"})
_HOLD_TTL_S = 30 * 60
#: 终态 flow 留给中枢读取结果的宽限期。中枢每秒轮询一次,够用且尽量短。
_DONE_GRACE_S = 30.0
_ID_MAX = 128
_TARGET_RE = re.compile(r"^(oc_|ou_)[A-Za-z0-9]+$")

# 中文原文与英文成对出现,供设置页和 i18n 台账使用。
# {code} 用 replace,避免用户码里的花括号被 format 吃掉。
_BINDING_MESSAGES = {
    "scan": ("请用飞书扫码创建应用", "Scan with Feishu to create an app"),
    "scan_code": (
        "请用飞书扫码创建应用，用户码 {code}",
        "Scan with Feishu to create an app. User code {code}",
    ),
    "expired": ("扫码已过期，请重新发起", "The scan expired. Start again"),
    "denied": ("已拒绝创建应用", "App creation was denied"),
    "error": ("创建应用失败，请重试", "Could not create the app. Try again"),
    "unsupported": (
        "当前环境不支持用 client_secret 创建应用",
        "This environment does not support creating an app with client_secret",
    ),
    "target": (
        "应用已创建。填写群 chat_id（oc_ 开头）推到群；留空则推给扫码人",
        "App created. Enter a group chat_id (starts with oc_) to push to a group, "
        "or leave this empty to push to the person who scanned",
    ),
    "target_update": (
        "该应用已绑定，继续将更新推送目标与凭据。"
        "填写群 chat_id（oc_ 开头）推到群；留空则推给扫码人",
        "This app is already linked. Continuing updates the push target and credentials. "
        "Enter a group chat_id (starts with oc_) to push to a group, or leave this empty "
        "to push to the person who scanned",
    ),
    "target_missing": (
        "还没有扫码人的 open_id，请填写群 chat_id（oc_ 开头）或用户 open_id（ou_ 开头）",
        "No scanner open_id is available. Enter a group chat_id (starts with oc_) "
        "or a user open_id (starts with ou_)",
    ),
    "target_bad": (
        "推送目标需要是群 chat_id（oc_ 开头）或用户 open_id（ou_ 开头），"
        "最长 128 个字符；留空则推给扫码人",
        "Enter a group chat_id (starts with oc_) or a user open_id (starts with ou_), "
        "at most 128 characters. Leave this empty to push to the person who scanned",
    ),
    "welcome_failed": (
        "欢迎消息没发出去。请确认机器人已在群里且具备发消息权限，或换一个推送目标再试",
        "The welcome message was not sent. Confirm the bot is in the group and can send "
        "messages, or try another target",
    ),
    "welcome_permission": (
        "欢迎消息没发出去：应用还不能发消息。请在飞书开放平台为该应用开通「以应用身份发消息」"
        "（im:message）权限并发布版本，然后直接重试。凭据已保留。",
        "The welcome message was not sent because the app cannot send messages yet. "
        "In the Feishu open platform, enable the im:message permission (send messages as the app) "
        "for this app and publish a version, then retry. The credentials are kept.",
    ),
    "confirmed": ("飞书应用已接入", "The Feishu app is linked"),
    "token_failed": (
        "拿到了应用凭据，但获取 tenant_access_token 失败。凭据已保留，可返回表单重试",
        "App credentials were issued, but requesting a tenant access token failed. "
        "The credentials are kept. Go back to the form and retry",
    ),
    "kept": (
        "已取消。应用凭据保留 30 分钟，可返回表单继续填写推送目标",
        "Cancelled. The app credentials are kept for 30 minutes. "
        "Go back to the form to choose a push target",
    ),
    "updated": (
        "该应用已绑定，将更新推送目标与凭据",
        "This app is already linked. The push target and credentials will be updated",
    ),
    "resume_expired": (
        "扫码得到的应用凭据已失效，请重新填写 App Secret 或重新扫码",
        "The credentials from the scan have expired. Enter the App Secret again, or scan again",
    ),
    "gone": ("绑定流程已结束或不存在", "This linking request has ended or does not exist"),
    "input": (
        "群 chat_id（oc_ 开头），留空则推给扫码人",
        "Group chat_id (starts with oc_). Leave empty to push to the person who scanned",
    ),
}


def classify_target(value: str) -> str:
    """``empty`` / ``chat`` / ``open`` / ``bad``。空串是「推给扫码人」,不是占位符。"""
    target = value.strip()
    if not target:
        return "empty"
    if len(target) > _ID_MAX or _TARGET_RE.fullmatch(target) is None:
        return "bad"
    return "chat" if target.startswith("oc_") else "open"


def input_error(key: str) -> ChannelInputError:
    zh, en = _BINDING_MESSAGES[key]
    return ChannelInputError(zh, message_localized={"en": en})


def rebind_notice() -> tuple[str, dict[str, str]]:
    zh, en = _BINDING_MESSAGES["updated"]
    return zh, {"en": en}


@dataclass
class _Held:
    """扫码拿到的凭据。``app_secret`` / ``token`` 不进入 repr,避免打进日志。"""

    token: str = field(repr=False)
    flow_id: str
    app_id: str
    app_secret: str = field(repr=False)
    open_id: str
    domain: str
    stored_at: float
    timer: asyncio.TimerHandle | None = field(default=None, repr=False)

    def wipe(self) -> None:
        if self.timer is not None:
            self.timer.cancel()
            self.timer = None
        self.app_secret = ""


@dataclass
class _Flow:
    flow_id: str
    session: RegistrationSession
    status: str = "pending"
    message: str = ""
    message_localized: dict = field(default_factory=dict)
    qr: str | None = None
    input_label: str | None = None
    input_label_localized: dict = field(default_factory=dict)
    app_id: str = ""
    #: 当前暂存凭据的续传令牌;为空表示本 flow 没有可续用的凭据
    token: str = field(default="", repr=False)
    open_id: str = ""
    domain: str = "feishu"
    known_ids: frozenset[str] = frozenset()
    result: BindResult | None = None
    task: asyncio.Task[None] | None = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    reaper: asyncio.TimerHandle | None = field(default=None, repr=False)

    def set_message(self, key: str, **repl: str) -> None:
        zh, en = _BINDING_MESSAGES[key]
        for name, value in repl.items():
            token = "{" + name + "}"
            zh = zh.replace(token, value)
            en = en.replace(token, value)
        self.message = zh
        self.message_localized = {"en": en}

    def snapshot(self, held: bool) -> FlowState:
        return FlowState(
            flow_id=self.flow_id,
            status=self.status,  # type: ignore[arg-type]
            message=self.message,
            qr=self.qr,
            input_label=self.input_label,
            # 给中枢的是副本:本地这份在 flow 删除时清空,不影响中枢已经拿走的结果
            result=copy.deepcopy(self.result),
            message_localized=dict(self.message_localized),
            input_label_localized=dict(self.input_label_localized),
            input_optional=self.status == "need_input",
            prefill={"app_id": self.app_id} if held else {},
            resume_token=self.token if held else "",
        )


class FeishuBindingRegistry:
    """进程内的扫码绑定表。插件停止时 ``close`` 取消未完成的轮询并清空暂存。"""

    def __init__(self) -> None:
        self._flows: dict[str, _Flow] = {}
        #: 续传令牌 → 暂存凭据。键是随机令牌,不是 flow_id。
        self._held: dict[str, _Held] = {}

    async def begin(self, known_ids: set[str] | frozenset[str] = frozenset()) -> FlowState:
        """发起一次新的扫码。不影响其他进行中的扫码会话。

        ``known_ids`` 是发起时本通道已有的账号 id:同一 App ID 再次出现时提示将更新。
        """
        session = RegistrationSession()
        try:
            started = await session.start()
        except Exception:
            await session.aclose()
            raise
        flow = _Flow(
            flow_id=uuid.uuid4().hex,
            session=session,
            qr=started.qr,
            known_ids=frozenset(known_ids),
        )
        if started.user_code:
            flow.set_message("scan_code", code=started.user_code)
        else:
            flow.set_message("scan")
        flow.task = asyncio.create_task(self._drive(flow), name=f"feishu-binding-{flow.flow_id}")
        self._flows[flow.flow_id] = flow
        logger.info("飞书扫码绑定已发起 flow=%s", flow.flow_id)
        return self._snapshot(flow)

    def snapshot(self, flow_id: str) -> FlowState:
        flow = self._flows.get(flow_id)
        if flow is None:
            return _missing(flow_id)
        self._expire_hold(flow)
        return self._snapshot(flow)

    def claim(self, token: str, app_id: str) -> _Held | None:
        """凭续传令牌取走暂存凭据(一次性)。

        取走即从表里删掉,并发的第二个请求拿不到;App ID 不符也会作废这份暂存。
        过期、不存在、不符统一返回 None,不区分原因。调用方用完后必须 ``settle`` 或 ``restore``。
        """
        held = self._held.pop(token, None) if token else None
        if held is None:
            return None
        if held.timer is not None:
            held.timer.cancel()
            held.timer = None
        if held.app_id != app_id or not held.app_secret or self._stale(held):
            self._drop_held(held)
            return None
        return held

    def restore(self, held: _Held) -> None:
        """取走后没用成(校验失败):放回原令牌下,不延长原有的 30 分钟。"""
        if not held.app_secret or self._stale(held):
            self._drop_held(held)
            return
        flow = self._flows.get(held.flow_id)
        if flow is not None and flow.token not in ("", held.token):
            # flow 已换了新凭据,这份旧的不再需要
            self._drop_held(held)
            return
        self._held[held.token] = held
        self._arm_hold(held)

    def settle(self, held: _Held) -> None:
        """凭据已经落库:清掉暂存,并删掉对应的 flow。"""
        self._drop_held(held)
        flow = self._flows.get(held.flow_id)
        if flow is not None:
            flow.token = ""
            self._forget(flow.flow_id)

    async def submit(self, flow_id: str, value: str) -> FlowState:
        """确认推送目标。非法输入留在 need_input,不抛 ValueError(宿主会把 ValueError 变成 500)。

        按 flow 加锁:同一个 flow 的并发提交串行执行,第二个看到的已是终态,不会重复发欢迎消息。
        """
        flow = self._flows.get(flow_id)
        if flow is None:
            return _missing(flow_id)
        async with flow.lock:
            self._expire_hold(flow)
            if flow.status != "need_input":
                return self._snapshot(flow)
            held = self.claim(flow.token, flow.app_id)
            if held is None:
                flow.token = ""
                flow.set_message("resume_expired")
                return self._snapshot(flow)
            try:
                return await self._submit_with(flow, held, value)
            finally:
                if held.app_secret:
                    # 没有绑定成功:放回去,用户可以换目标或回到表单重试
                    self.restore(held)

    async def _submit_with(self, flow: _Flow, held: _Held, value: str) -> FlowState:
        kind = classify_target(value)
        target = value.strip()
        if kind == "empty":
            if not flow.open_id:
                flow.set_message("target_missing")
                return self._snapshot(flow, held=True)
            receive_id, receive_id_type = flow.open_id, "open_id"
        elif kind == "chat":
            receive_id, receive_id_type = target, "chat_id"
        elif kind == "open":
            receive_id, receive_id_type = target, "open_id"
        else:
            flow.set_message("target_bad")
            return self._snapshot(flow, held=True)
        credentials = {
            "app_id": held.app_id,
            "app_secret": held.app_secret,
            "receive_id": receive_id,
            "receive_id_type": receive_id_type,
            "domain": held.domain or "feishu",
        }
        client = FeishuClient(credentials_token(credentials))
        try:
            await client.send_text(APP_WELCOME)
        except FeishuApiError as exc:
            logger.warning(
                "飞书欢迎消息发送失败 flow=%s type=%s code=%s",
                flow.flow_id,
                type(exc).__name__,
                exc.code,
            )
            flow.set_message(
                "welcome_permission" if exc.missing_send_permission else "welcome_failed"
            )
            return self._snapshot(flow, held=True)
        except Exception as exc:  # noqa: BLE001 -- 留在输入步,用户可以换目标
            logger.warning("飞书欢迎消息发送失败 flow=%s type=%s", flow.flow_id, type(exc).__name__)
            flow.set_message("welcome_failed")
            return self._snapshot(flow, held=True)
        finally:
            await client.aclose()
        notice, localized = rebind_notice()
        flow.result = BindResult(
            account_id=held.app_id,
            display_name=APP_DISPLAY_NAME,
            credentials=credentials,
            bound_user=receive_id if receive_id_type == "open_id" else None,
            rebind_message=notice,
            rebind_message_localized=localized,
        )
        flow.status = "confirmed"
        flow.input_label = None
        flow.input_label_localized = {}
        flow.qr = None
        flow.set_message("confirmed")
        flow.token = ""
        self._drop_held(held)
        state = self._snapshot(flow)
        # 结果已经交给调用方;只留短宽限期给中枢的后台轮询,随后清空凭据并删除
        self._schedule_forget(flow)
        return state

    async def cancel(self, flow_id: str) -> None:
        flow = self._flows.get(flow_id)
        if flow is None:
            return
        await self._cancel_task(flow)
        if flow.status in _TERMINAL:
            self._finish(flow)
            return
        if self._held_for(flow) is not None:
            flow.qr = None
            flow.input_label = None
            flow.input_label_localized = {}
            flow.status = "failed"
            flow.set_message("kept")
            return
        flow.session.device_code = ""
        flow.status = "expired"
        flow.set_message("expired")
        self._finish(flow)

    async def close(self) -> None:
        for flow in list(self._flows.values()):
            await self._cancel_task(flow)
            flow.session.device_code = ""
            self._forget(flow.flow_id)
        for held in list(self._held.values()):
            held.wipe()
        self._held.clear()

    # ---- 内部

    def _snapshot(self, flow: _Flow, held: bool | None = None) -> FlowState:
        if held is None:
            held = self._held_for(flow) is not None
        return flow.snapshot(held)

    def _held_for(self, flow: _Flow) -> _Held | None:
        if not flow.token:
            return None
        return self._held.get(flow.token)

    @staticmethod
    def _stale(held: _Held) -> bool:
        return time.monotonic() - held.stored_at > _HOLD_TTL_S

    def _remember(self, flow: _Flow, app_secret: str) -> None:
        if not flow.app_id or not app_secret:
            return
        old = self._held_for(flow)
        if old is not None:
            self._drop_held(old)
        held = _Held(
            token=secrets.token_urlsafe(32),
            flow_id=flow.flow_id,
            app_id=flow.app_id,
            app_secret=app_secret,
            open_id=flow.open_id,
            domain=flow.domain or "feishu",
            stored_at=time.monotonic(),
        )
        self._held[held.token] = held
        flow.token = held.token
        self._arm_hold(held)

    def _arm_hold(self, held: _Held) -> None:
        if held.timer is not None:
            held.timer.cancel()
        remaining = max(0.0, _HOLD_TTL_S - (time.monotonic() - held.stored_at))
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:  # pragma: no cover -- 只在事件循环里调用
            return
        held.timer = loop.call_later(remaining, self._expire_token, held.token)

    def _expire_token(self, token: str) -> None:
        """30 分钟到点主动清:暂存删掉,flow 若还停在输入步就改成失败并安排删除。"""
        held = self._held.get(token)
        if held is None:
            return
        held.timer = None
        self._drop_held(held)
        flow = self._flows.get(held.flow_id)
        if flow is None or flow.token != token:
            return
        flow.token = ""
        if flow.status not in _TERMINAL:
            flow.status = "failed"
            flow.input_label = None
            flow.input_label_localized = {}
        flow.set_message("resume_expired")
        self._finish(flow)

    def _drop_held(self, held: _Held) -> None:
        if self._held.get(held.token) is held:
            del self._held[held.token]
        held.wipe()

    def _expire_hold(self, flow: _Flow) -> None:
        """访问时顺手检查一次(定时器之外的兜底,例如系统时钟被挂起)。"""
        held = self._held_for(flow)
        if held is not None and self._stale(held):
            self._expire_token(held.token)

    def _finish(self, flow: _Flow) -> None:
        """终态且没有可续用的凭据:宽限期后删除。还有凭据时由暂存的定时器负责。"""
        if flow.status in _TERMINAL and self._held_for(flow) is None:
            self._schedule_forget(flow)

    def _schedule_forget(self, flow: _Flow) -> None:
        if flow.reaper is not None:
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:  # pragma: no cover
            self._forget(flow.flow_id)
            return
        flow.reaper = loop.call_later(_DONE_GRACE_S, self._forget, flow.flow_id)

    def _forget(self, flow_id: str) -> None:
        flow = self._flows.pop(flow_id, None)
        if flow is None:
            return
        if flow.reaper is not None:
            flow.reaper.cancel()
            flow.reaper = None
        held = self._held_for(flow)
        if held is not None:
            self._drop_held(held)
        flow.token = ""
        if flow.result is not None:
            flow.result.credentials.clear()
            flow.result = None
        flow.session.device_code = ""

    async def _cancel_task(self, flow: _Flow) -> None:
        task = flow.task
        if task is None or task.done():
            return
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

    async def _drive(self, flow: _Flow) -> None:
        try:
            while True:
                outcome = await flow.session.poll_once()
                if outcome.status == "pending":
                    remaining = flow.session.deadline - time.monotonic()
                    if remaining <= 0:
                        flow.status = "expired"
                        flow.set_message("expired")
                        return
                    await asyncio.sleep(min(outcome.interval, remaining))
                    continue
                if outcome.status == "success":
                    await self._accept(flow, outcome)
                    return
                if outcome.status == "denied":
                    flow.status = "failed"
                    flow.set_message("denied")
                    return
                if outcome.status == "expired":
                    flow.status = "expired"
                    flow.set_message("expired")
                    return
                logger.info("飞书应用注册失败 flow=%s status=%s", flow.flow_id, outcome.status)
                flow.status = "failed"
                flow.set_message("error")
                return
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.warning("飞书扫码绑定中断 flow=%s", flow.flow_id)
            if flow.status not in _TERMINAL and flow.status != "need_input":
                flow.status = "failed"
                flow.set_message("error")
        finally:
            flow.session.device_code = ""
            await flow.session.aclose()
            if flow.flow_id in self._flows:
                self._finish(flow)

    async def _accept(self, flow: _Flow, outcome) -> None:
        flow.app_id = outcome.client_id
        flow.open_id = outcome.open_id
        flow.domain = outcome.domain or "feishu"
        app_secret = outcome.client_secret
        outcome.client_secret = ""
        self._remember(flow, app_secret)
        client = FeishuClient(
            credentials_token(
                {
                    "app_id": flow.app_id,
                    "app_secret": app_secret,
                    "receive_id": flow.open_id or "ou_pending",
                    "receive_id_type": "open_id",
                    "domain": flow.domain,
                }
            )
        )
        try:
            await client.tenant_access_token()
        except Exception as exc:  # noqa: BLE001 -- 令牌拿不到就结束,不把密钥写进日志
            logger.warning("飞书应用令牌校验失败 flow=%s type=%s", flow.flow_id, type(exc).__name__)
            flow.qr = None
            flow.status = "failed"
            flow.set_message("token_failed")
            return
        finally:
            await client.aclose()
        flow.qr = None
        flow.set_message("target_update" if flow.app_id in flow.known_ids else "target")
        label, english = _BINDING_MESSAGES["input"]
        flow.input_label = label
        flow.input_label_localized = {"en": english}
        flow.status = "need_input"


def _missing(flow_id: str) -> FlowState:
    zh, en = _BINDING_MESSAGES["gone"]
    return FlowState(flow_id, "failed", message=zh, message_localized={"en": en})


def raise_registration(exc: RegistrationError) -> None:
    """begin 失败时把错误码翻成给用户看的双语文案。由驱动抛出。"""
    key = exc.code if exc.code in _BINDING_MESSAGES else "error"
    zh, en = _BINDING_MESSAGES[key]
    raise ChannelInputError(zh, message_localized={"en": en}) from exc

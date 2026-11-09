"""飞书自建应用的扫码创建流程。

设置页走中枢已有的交互式绑定:本模块后台轮询设备码,``flow_state`` 只读内存快照。
成功后先用 App ID / App Secret 换 tenant_access_token(连通性校验),再请用户确认
推送目标。留空推给扫码人的 open_id;填 ``oc_`` 开头的 chat_id 推到群,``ou_`` 开头的
open_id 推给指定用户。欢迎消息发出去才算绑定完成。发不出去就停在输入步,凭据留在
本进程里,方便换一个目标或回到表单重试。

``client_secret`` 只留在内存里的本次流程上,不写日志,也不放进给页面的 prefill。
新的 begin 会取消上一次未完成的流程,并丢掉那次暂存的凭据。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
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
        "已取消。应用凭据已保留，可返回表单继续填写推送目标；重新扫码会放弃这份凭据",
        "Cancelled. The app credentials are kept. Go back to the form to choose a push target. "
        "Scanning again discards them",
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
    "replaced": (
        "已发起新的绑定，本流程终止",
        "A new linking request has started. This request has ended",
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
    """扫码拿到的凭据。``app_secret`` 不进入 repr,避免打进日志。"""

    app_id: str
    app_secret: str = field(repr=False)
    open_id: str
    domain: str
    stored_at: float


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
    app_secret: str = field(default="", repr=False)
    open_id: str = ""
    domain: str = "feishu"
    result: BindResult | None = None
    task: asyncio.Task[None] | None = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def set_message(self, key: str, **repl: str) -> None:
        zh, en = _BINDING_MESSAGES[key]
        for name, value in repl.items():
            token = "{" + name + "}"
            zh = zh.replace(token, value)
            en = en.replace(token, value)
        self.message = zh
        self.message_localized = {"en": en}

    def snapshot(self) -> FlowState:
        held = bool(self.app_id and self.app_secret)
        return FlowState(
            flow_id=self.flow_id,
            status=self.status,  # type: ignore[arg-type]
            message=self.message,
            qr=self.qr,
            input_label=self.input_label,
            result=self.result,
            message_localized=dict(self.message_localized),
            input_label_localized=dict(self.input_label_localized),
            input_optional=self.status == "need_input",
            prefill={"app_id": self.app_id} if held else {},
            resume_token=self.flow_id if held else "",
        )

    def drop_secrets(self) -> None:
        self.app_secret = ""
        self.session.device_code = ""


class FeishuBindingRegistry:
    """进程内的扫码绑定表。插件停止时 ``close`` 取消未完成的轮询。"""

    def __init__(self) -> None:
        self._flows: dict[str, _Flow] = {}
        self._held: dict[str, _Held] = {}
        #: 开始扫码时本通道已有的账号 id。同一 App ID 再次出现时提示将更新,不拒绝。
        self.known_ids: set[str] = set()

    async def begin(self) -> FlowState:
        await self._supersede()
        session = RegistrationSession()
        try:
            started = await session.start()
        except Exception:
            await session.aclose()
            raise
        flow = _Flow(flow_id=uuid.uuid4().hex[:16], session=session, qr=started.qr)
        if started.user_code:
            flow.set_message("scan_code", code=started.user_code)
        else:
            flow.set_message("scan")
        flow.task = asyncio.create_task(self._drive(flow), name=f"feishu-binding-{flow.flow_id}")
        self._flows[flow.flow_id] = flow
        logger.info("飞书扫码绑定已发起 flow=%s", flow.flow_id)
        return flow.snapshot()

    def snapshot(self, flow_id: str) -> FlowState:
        flow = self._flows.get(flow_id)
        if flow is None:
            return _missing(flow_id)
        self._expire_hold(flow)
        return flow.snapshot()

    def secret_for(self, flow_id: str, app_id: str) -> str:
        """表单重试时取回暂存的 App Secret。过期或 App ID 不符都返回空串,不区分原因。"""
        flow = self._flows.get(flow_id)
        if flow is not None:
            self._expire_hold(flow)
        else:
            self._expire_id(flow_id)
        held = self._held.get(flow_id)
        if held is None or held.app_id != app_id or not held.app_secret:
            return ""
        return held.app_secret

    def release(self, flow_id: str) -> None:
        """绑定已经落库:丢掉暂存。密钥此时在绑定结果里,不再留在流程上。"""
        self._held.pop(flow_id, None)
        flow = self._flows.get(flow_id)
        if flow is not None:
            flow.app_secret = ""

    async def submit(self, flow_id: str, value: str) -> FlowState:
        """确认推送目标。非法输入留在 need_input,不抛 ValueError(宿主会把 ValueError 变成 500)。"""
        flow = self._flows.get(flow_id)
        if flow is None:
            return _missing(flow_id)
        async with flow.lock:
            self._expire_hold(flow)
            if flow.status != "need_input":
                return flow.snapshot()
            if not flow.app_secret:
                flow.set_message("resume_expired")
                return flow.snapshot()
            kind = classify_target(value)
            target = value.strip()
            if kind == "empty":
                if not flow.open_id:
                    flow.set_message("target_missing")
                    return flow.snapshot()
                receive_id, receive_id_type = flow.open_id, "open_id"
            elif kind == "chat":
                receive_id, receive_id_type = target, "chat_id"
            elif kind == "open":
                receive_id, receive_id_type = target, "open_id"
            else:
                flow.set_message("target_bad")
                return flow.snapshot()
            credentials = {
                "app_id": flow.app_id,
                "app_secret": flow.app_secret,
                "receive_id": receive_id,
                "receive_id_type": receive_id_type,
                "domain": flow.domain or "feishu",
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
                return flow.snapshot()
            except Exception as exc:  # noqa: BLE001 -- 留在输入步,用户可以换目标
                logger.warning(
                    "飞书欢迎消息发送失败 flow=%s type=%s", flow.flow_id, type(exc).__name__
                )
                flow.set_message("welcome_failed")
                return flow.snapshot()
            finally:
                await client.aclose()
            notice, localized = rebind_notice()
            flow.result = BindResult(
                account_id=flow.app_id,
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
            flow.drop_secrets()
            self._held.pop(flow.flow_id, None)
            return flow.snapshot()

    async def cancel(self, flow_id: str) -> None:
        flow = self._flows.get(flow_id)
        if flow is None:
            return
        await self._cancel_task(flow)
        if flow.status in _TERMINAL:
            return
        if flow.app_id and flow.app_secret:
            flow.qr = None
            flow.input_label = None
            flow.input_label_localized = {}
            flow.status = "failed"
            flow.set_message("kept")
            return
        flow.drop_secrets()
        flow.status = "expired"
        flow.set_message("expired")

    async def close(self) -> None:
        for flow in list(self._flows.values()):
            await self._cancel_task(flow)
            flow.drop_secrets()
        self._held.clear()

    async def _supersede(self) -> None:
        for flow in list(self._flows.values()):
            self._held.pop(flow.flow_id, None)
            flow.app_secret = ""
            if flow.status in _TERMINAL:
                continue
            await self._cancel_task(flow)
            flow.session.device_code = ""
            flow.status = "expired"
            flow.set_message("replaced")

    def _remember(self, flow: _Flow) -> None:
        if not flow.app_id or not flow.app_secret:
            return
        self._held[flow.flow_id] = _Held(
            app_id=flow.app_id,
            app_secret=flow.app_secret,
            open_id=flow.open_id,
            domain=flow.domain or "feishu",
            stored_at=time.monotonic(),
        )

    def _expire_hold(self, flow: _Flow) -> None:
        held = self._held.get(flow.flow_id)
        if held is None or time.monotonic() - held.stored_at <= _HOLD_TTL_S:
            return
        self._held.pop(flow.flow_id, None)
        flow.app_secret = ""

    def _expire_id(self, flow_id: str) -> None:
        flow = self._flows.get(flow_id)
        if flow is not None:
            self._expire_hold(flow)
            return
        held = self._held.get(flow_id)
        if held is not None and time.monotonic() - held.stored_at > _HOLD_TTL_S:
            self._held.pop(flow_id, None)

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

    async def _accept(self, flow: _Flow, outcome) -> None:
        flow.app_id = outcome.client_id
        flow.app_secret = outcome.client_secret
        flow.open_id = outcome.open_id
        flow.domain = outcome.domain or "feishu"
        self._remember(flow)
        client = FeishuClient(
            credentials_token(
                {
                    "app_id": flow.app_id,
                    "app_secret": flow.app_secret,
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
        flow.set_message("target_update" if flow.app_id in self.known_ids else "target")
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

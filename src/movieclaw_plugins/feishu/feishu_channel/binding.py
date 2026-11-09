"""飞书自建应用的扫码创建流程。

设置页走中枢已有的交互式绑定:本模块后台轮询设备码,``flow_state`` 只读内存快照。
成功后先用 App ID / App Secret 换 tenant_access_token(连通性校验),再请用户确认
推送目标。填 ``-`` 推给扫码人的 open_id;填 ``oc_`` 开头的 chat_id 推到群。
欢迎消息发出去才算绑定完成,发不出去就停在输入步,方便换一个目标重试。

``client_secret`` 只留在内存里的本次流程上,不写日志。新的 begin 会取消上一次未完成的流程。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
import uuid
from dataclasses import dataclass, field

from movieclaw_sdk.channels import BindResult, ChannelInputError, FlowState

from .client import FeishuClient, credentials_token
from .registration import RegistrationError, RegistrationSession

logger = logging.getLogger("movieclaw_plugins.feishu.binding")

APP_WELCOME = "🎉 MovieClaw 已接入，订阅投递、入库完成等事件将推送到这里。"
APP_DISPLAY_NAME = "飞书应用机器人"

_TERMINAL = frozenset({"confirmed", "already_bound", "expired", "failed"})

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
        "应用已创建。填写群 chat_id（oc_ 开头）推到群；填写 - 则推给扫码人",
        "App created. Enter a group chat_id (starts with oc_) to push to a group, "
        "or - to push to the person who scanned",
    ),
    "target_missing": (
        "还没有扫码人的 open_id，请填写群 chat_id（oc_ 开头）或用户 open_id（ou_ 开头）",
        "No scanner open_id is available. Enter a group chat_id (starts with oc_) "
        "or a user open_id (starts with ou_)",
    ),
    "target_bad": (
        "推送目标需要是群 chat_id（oc_ 开头）、用户 open_id（ou_ 开头），或 -",
        "Enter a group chat_id (starts with oc_), a user open_id (starts with ou_), or -",
    ),
    "welcome_failed": (
        "欢迎消息没发出去。请确认机器人已在群里且具备发消息权限，或换一个推送目标再试",
        "The welcome message was not sent. Confirm the bot is in the group and can send "
        "messages, or try another target",
    ),
    "confirmed": ("飞书应用已接入", "The Feishu app is linked"),
    "token_failed": (
        "拿到了应用凭据，但获取 tenant_access_token 失败，请重试",
        "App credentials were issued, but requesting a tenant access token failed. Try again",
    ),
    "gone": ("绑定流程已结束或不存在", "This linking request has ended or does not exist"),
    "input": ("群 chat_id，或 -", "Group chat_id, or -"),
    "replaced": (
        "已发起新的绑定，本流程终止",
        "A new linking request has started. This request has ended",
    ),
}


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
    app_secret: str = ""
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
        return FlowState(
            flow_id=self.flow_id,
            status=self.status,  # type: ignore[arg-type]
            message=self.message,
            qr=self.qr,
            input_label=self.input_label,
            result=self.result,
            message_localized=dict(self.message_localized),
            input_label_localized=dict(self.input_label_localized),
        )

    def drop_secrets(self) -> None:
        self.app_secret = ""
        self.session.device_code = ""


class FeishuBindingRegistry:
    """进程内的扫码绑定表。插件停止时 ``close`` 取消未完成的轮询。"""

    def __init__(self) -> None:
        self._flows: dict[str, _Flow] = {}

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
        return flow.snapshot()

    async def submit(self, flow_id: str, value: str) -> FlowState:
        """确认推送目标。非法输入留在 need_input,不抛 ValueError(宿主会把 ValueError 变成 500)。"""
        flow = self._flows.get(flow_id)
        if flow is None:
            return _missing(flow_id)
        async with flow.lock:
            if flow.status != "need_input":
                return flow.snapshot()
            target = value.strip()
            if target == "-":
                if not flow.open_id:
                    flow.set_message("target_missing")
                    return flow.snapshot()
                receive_id, receive_id_type = flow.open_id, "open_id"
            elif target.startswith("oc_"):
                receive_id, receive_id_type = target, "chat_id"
            elif target.startswith("ou_"):
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
            except Exception as exc:  # noqa: BLE001 -- 留在输入步,用户可以换目标
                logger.warning(
                    "飞书欢迎消息发送失败 flow=%s type=%s", flow.flow_id, type(exc).__name__
                )
                flow.set_message("welcome_failed")
                return flow.snapshot()
            finally:
                await client.aclose()
            flow.result = BindResult(
                account_id=flow.app_id,
                display_name=APP_DISPLAY_NAME,
                credentials=credentials,
                bound_user=receive_id if receive_id_type == "open_id" else None,
            )
            flow.status = "confirmed"
            flow.input_label = None
            flow.input_label_localized = {}
            flow.qr = None
            flow.set_message("confirmed")
            flow.drop_secrets()
            return flow.snapshot()

    async def cancel(self, flow_id: str) -> None:
        flow = self._flows.get(flow_id)
        if flow is None:
            return
        await self._cancel_task(flow)
        flow.drop_secrets()
        if flow.status not in _TERMINAL:
            flow.status = "expired"
            flow.set_message("expired")

    async def close(self) -> None:
        for flow in list(self._flows.values()):
            await self._cancel_task(flow)
            flow.drop_secrets()

    async def _supersede(self) -> None:
        for flow in list(self._flows.values()):
            if flow.status in _TERMINAL:
                continue
            await self._cancel_task(flow)
            flow.drop_secrets()
            flow.status = "expired"
            flow.set_message("replaced")

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
            flow.status = "failed"
            flow.set_message("token_failed")
            flow.drop_secrets()
            return
        finally:
            await client.aclose()
        flow.status = "need_input"
        flow.qr = None
        flow.set_message("target")
        label, english = _BINDING_MESSAGES["input"]
        flow.input_label = label
        flow.input_label_localized = {"en": english}


def _missing(flow_id: str) -> FlowState:
    zh, en = _BINDING_MESSAGES["gone"]
    return FlowState(flow_id, "failed", message=zh, message_localized={"en": en})


def raise_registration(exc: RegistrationError) -> None:
    """begin 失败时把错误码翻成给用户看的双语文案。由驱动抛出。"""
    key = exc.code if exc.code in _BINDING_MESSAGES else "error"
    zh, en = _BINDING_MESSAGES[key]
    raise ChannelInputError(zh, message_localized={"en": en}) from exc

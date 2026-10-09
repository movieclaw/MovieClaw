"""IM 通道契约（docs/design/plugin-channels.md §5）。

通道插件只实现一个平台「怎么收、怎么发、怎么绑定」：往注册表 ``im-channels`` 贡献一个
``ChannelDriver``。白名单、会话串行、AI 助手、长消息拆分、主动推送、账号存储、设置页都由主程序的
通道中枢负责，插件不用管::

    from movieclaw_sdk import plugin
    from movieclaw_sdk.channels import IM_CHANNELS, Binding, ChannelDriver, FormField

    class Ntfy(ChannelDriver):
        title = "ntfy"
        binding = Binding.form((FormField("topic", "订阅主题"),))
        ...

    @plugin("acme.ntfy", title="ntfy 通道")
    async def apply(ctx):
        ctx.contribute(IM_CHANNELS, "ntfy", Ntfy())

同一份驱动代码既能在主进程里运行，也能在独立进程里运行（宿主经桩调用它，账号句柄的回调经协议回到宿主）。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Any, Literal

import httpx

from movieclaw_kernel import RegistryKey, Stability

logger = logging.getLogger("movieclaw_sdk.channels")

# ---------------------------------------------------------------------- 消息


class ChannelAuthError(Exception):
    """通道凭据失效（如微信 errcode -14 token 过期）。

    ``run`` 里抛出本异常：中枢停掉该账号、标记「需重新绑定」，而不是无脑重试。
    """


@dataclass(frozen=True, slots=True)
class ReplyContext:
    """定位「往哪里回消息」所需的全部信息。

    ``token`` 是**通道私有的不透明字典**（微信放 context_token，Discord 放私聊频道 id），
    中枢永远不解读它，只原样带回给同一个驱动。
    """

    channel_id: str
    account_id: str
    #: 平台内用户标识，如微信的 xxx@im.wechat
    user_id: str
    token: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class InboundImage:
    """随入站消息附带的一张图片（驱动已下载 / 解密成明文字节）。

    只带字节与展示名：真实图片类型由中枢落盘时按魔数嗅探，平台声明的类型一律不信。
    """

    data: bytes
    #: 展示名（前端附件条与给模型的附件清单用），如「微信图片」
    name: str = "图片"


@dataclass(frozen=True, slots=True)
class InboundMessage:
    """归一化后的入站消息（驱动产出，交给 ``Account.inbound``）。"""

    channel_id: str
    account_id: str
    user_id: str
    #: 文本正文（语音消息取平台转写文字）
    text: str
    reply: ReplyContext
    #: 平台侧消息标识，用于幂等去重（长轮询游标通常是至少一次投递）
    provider_message_id: str
    timestamp_ms: int = 0
    #: 随消息附带的图片（纯图消息 text 为空）
    images: tuple[InboundImage, ...] = ()

    @property
    def has_content(self) -> bool:
        """是否有可交给 AI 助手的内容（文字或图片）。"""
        return bool(self.text.strip() or self.images)

    @property
    def session_key(self) -> str:
        """会话键：同一账号同一用户 = 一条串行处理的会话。"""
        return f"{self.channel_id}:{self.account_id}:{self.user_id}"


@dataclass(frozen=True, slots=True)
class OutboundEnvelope:
    """出站信封：中枢发送泵唯一认识的载荷（AI 回复、命令回执、主动推送都走这一个口）。"""

    reply: ReplyContext
    text: str
    #: 来源标记，仅用于日志排障
    origin: Literal["agent", "system", "push"] = "agent"
    #: 随消息附带的图片字节；通道不支持发图时自动退回纯文本
    photo: bytes | None = None


# ---------------------------------------------------------------------- 能力与绑定


@dataclass(frozen=True, slots=True)
class Capabilities:
    #: 能收消息（能与 AI 助手对话）；只能推送的通道（如飞书群机器人）为 False
    receive: bool = True
    #: 实现了 ``send_photo``（推送带配图）
    photo: bool = False
    #: 实现了 ``typing``（处理期间显示「正在输入」）
    typing: bool = False
    #: 单条文本的长度上限，超长由中枢按段落拆分
    max_text_len: int = 2000


@dataclass(frozen=True, slots=True)
class FormField:
    key: str
    label: str
    #: 凭据类字段：输入框打码，接口不回显
    secret: bool = False
    placeholder: str = ""
    help: str = ""
    required: bool = True


@dataclass(frozen=True, slots=True)
class Binding:
    """绑定方式（§5.2）。

    - ``form``：按字段渲染表单，提交给 ``validate``；``pairing="code"`` 时中枢再生成 6 位配对码，
      用户私聊 bot 发码，发码人成为白名单（Telegram / Discord 这类 bot）；
    - ``flow``：插件维护的交互式流程（微信扫码），中枢渲染 ``FlowState`` 并轮询。
    """

    kind: Literal["form", "flow"]
    fields: tuple[FormField, ...] = ()
    pairing: Literal["code", "none"] = "none"
    #: 绑定对话框顶部的一句说明
    hint: str = ""

    @classmethod
    def form(
        cls,
        fields: tuple[FormField, ...],
        *,
        pairing: Literal["code", "none"] = "none",
        hint: str = "",
    ) -> Binding:
        return cls(kind="form", fields=fields, pairing=pairing, hint=hint)

    @classmethod
    def flow(cls, *, hint: str = "") -> Binding:
        return cls(kind="flow", hint=hint)


@dataclass(frozen=True, slots=True)
class BindResult:
    """绑定成功：中枢据此落库并启动账号。"""

    account_id: str
    display_name: str
    #: 凭据（中枢加密存储，启动账号时原样交还给驱动）
    credentials: dict[str, str]
    #: 白名单用户；配对码流程由中枢补上发码人，推送型通道可为空
    bound_user: str | None = None
    #: 插件私有状态的初值
    state: dict[str, Any] = field(default_factory=dict)


FlowStatus = Literal[
    "pending", "scanned", "need_input", "confirmed", "already_bound", "expired", "failed"
]
TERMINAL_FLOW_STATUSES = frozenset({"confirmed", "already_bound", "expired", "failed"})


@dataclass(frozen=True, slots=True)
class FlowState:
    """交互式绑定的一个快照（中枢原样渲染给设置页）。"""

    flow_id: str
    status: FlowStatus
    message: str = ""
    #: 要用户扫的二维码内容（中枢渲染成图）
    qr: str | None = None
    #: ``need_input`` 时输入框的说明，如「输入手机上显示的配对数字」
    input_label: str | None = None
    #: ``confirmed`` 时的绑定结果
    result: BindResult | None = None

    @property
    def terminal(self) -> bool:
        return self.status in TERMINAL_FLOW_STATUSES


# ---------------------------------------------------------------------- 账号与驱动


class Account:
    """账号句柄：中枢构造，交给驱动的 ``run`` / ``send`` 等方法。

    驱动只读 ``credentials`` / ``state`` 等字段，经 ``inbound`` 把消息交给中枢、经 ``save_state``
    持久化自己的私有状态（游标、会话令牌），中枢不解读它们。``stopping`` 置位表示中枢要停这个账号：
    长轮询应尽快中断并退出 ``run``（宽限期过后中枢会直接取消）。
    """

    channel_id: str
    id: str
    display_name: str
    bound_user: str | None
    credentials: dict[str, str]
    state: dict[str, Any]
    stopping: asyncio.Event

    async def inbound(self, message: InboundMessage) -> None:
        raise NotImplementedError

    async def save_state(self, patch: dict[str, Any]) -> None:
        raise NotImplementedError


class ChannelDriver:
    """一个 IM 平台的驱动（注册表 ``im-channels`` 的贡献项）。

    子类设置 ``title`` / ``capabilities`` / ``binding``，按绑定方式实现 ``validate`` 或
    ``begin_flow`` 一族，能收消息的实现 ``run``，都要实现 ``send``。
    """

    title: str = ""
    description: str = ""
    capabilities: Capabilities = Capabilities()
    binding: Binding = Binding.form(())

    # ---- 绑定：表单
    async def validate(self, fields: dict[str, str]) -> BindResult:
        """校验表单并返回账号；失败抛 ``ValueError``（信息直接展示给用户）。"""
        raise NotImplementedError

    # ---- 绑定：交互式
    async def begin_flow(self, accounts: list[Account]) -> FlowState:
        """开始一次交互式绑定。``accounts`` 是本通道已绑定的账号（判断「已绑定过」用）。"""
        raise NotImplementedError

    async def flow_state(self, flow_id: str) -> FlowState:
        raise NotImplementedError

    async def flow_input(self, flow_id: str, value: str) -> FlowState:
        raise NotImplementedError

    async def cancel_flow(self, flow_id: str) -> None:
        return None

    # ---- 运行
    async def run(self, account: Account) -> None:
        """收消息循环，直到 ``account.stopping`` 置位。只能推送的通道等着停即可（默认实现）。"""
        await account.stopping.wait()

    async def send(self, account: Account, reply: ReplyContext, text: str) -> None:
        """发一条文本（中枢已按 ``max_text_len`` 拆好）。失败抛异常，中枢会重试一次。"""
        raise NotImplementedError

    async def send_photo(
        self, account: Account, reply: ReplyContext, photo: bytes, caption: str
    ) -> None:
        raise NotImplementedError

    async def typing(self, account: Account, reply: ReplyContext, on: bool) -> None:
        """开 / 关「正在输入」（``capabilities.typing``）。失败只该记日志，不能抛给中枢。"""
        return None

    def push_target(self, account: Account) -> ReplyContext | None:
        """主动推送发给谁：默认是绑定人；没有绑定人的通道（群机器人）覆盖它。"""
        if not account.bound_user:
            return None
        return ReplyContext(account.channel_id, account.id, account.bound_user)


#: 通道插件往这个注册表贡献驱动（贡献 id 即通道 id；第三方插件自动带插件 id 前缀）
IM_CHANNELS: RegistryKey[ChannelDriver] = RegistryKey(
    "im-channels",
    stability=Stability.EXPERIMENTAL,
    schema=ChannelDriver,
    doc="IM 通道：插件贡献一个通道驱动（收发与绑定），中枢负责账号、对话与推送",
)


# ---------------------------------------------------------------------- 工具

#: 单张入站图片的下载上限：防「一条消息拖垮收消息循环」的粗闸（中枢入库前还会再压缩）。
#: 取 Telegram getFile 的 20MB 上限，各通道统一口径。
MAX_INBOUND_IMAGE_BYTES = 20 * 1024 * 1024


class MediaDownloadError(Exception):
    """入站媒体下载失败（HTTP 错误或超出体积上限）。"""


async def download_capped(
    client: httpx.AsyncClient,
    url: str,
    *,
    max_bytes: int = MAX_INBOUND_IMAGE_BYTES,
    timeout_s: float = 30.0,
    label: str = "媒体",
) -> bytes:
    """流式下载一份媒体字节，超过 ``max_bytes`` 立即中断（``resp.content`` 会先整个读进内存）。"""
    async with client.stream("GET", url, timeout=httpx.Timeout(timeout_s)) as resp:
        if resp.status_code != 200:
            raise MediaDownloadError(f"{label}下载失败 HTTP {resp.status_code}")
        chunks: list[bytes] = []
        total = 0
        async for chunk in resp.aiter_bytes():
            total += len(chunk)
            if total > max_bytes:
                raise MediaDownloadError(f"{label}超过 {max_bytes // (1024 * 1024)}MB 上限")
            chunks.append(chunk)
    return b"".join(chunks)


# ---------------------------------------------------------------------- 线上格式
# 进程外运行时，宿主与插件进程之间用 JSON 传这些结构（图片字节走 base64）。


def driver_spec(driver: ChannelDriver) -> dict[str, Any]:
    caps = driver.capabilities
    spec = driver.binding
    return {
        "title": driver.title,
        "description": driver.description,
        "capabilities": {
            "receive": caps.receive,
            "photo": caps.photo,
            "typing": caps.typing,
            "max_text_len": caps.max_text_len,
        },
        "binding": {
            "kind": spec.kind,
            "pairing": spec.pairing,
            "hint": spec.hint,
            "fields": [
                {
                    "key": f.key,
                    "label": f.label,
                    "secret": f.secret,
                    "placeholder": f.placeholder,
                    "help": f.help,
                    "required": f.required,
                }
                for f in spec.fields
            ],
        },
    }


def spec_parts(data: dict[str, Any]) -> tuple[Capabilities, Binding]:
    b = data["binding"]
    return Capabilities(**data["capabilities"]), Binding(
        kind=b["kind"],
        pairing=b["pairing"],
        hint=b["hint"],
        fields=tuple(FormField(**f) for f in b["fields"]),
    )


def account_dict(account: Account) -> dict[str, Any]:
    return {
        "channel_id": account.channel_id,
        "id": account.id,
        "display_name": account.display_name,
        "bound_user": account.bound_user,
        "credentials": dict(account.credentials),
        "state": dict(account.state),
    }


def reply_dict(reply: ReplyContext) -> dict[str, Any]:
    return {
        "channel_id": reply.channel_id,
        "account_id": reply.account_id,
        "user_id": reply.user_id,
        "token": dict(reply.token),
    }


def reply_from(data: dict[str, Any]) -> ReplyContext:
    return ReplyContext(data["channel_id"], data["account_id"], data["user_id"], data["token"])


def message_dict(message: InboundMessage) -> dict[str, Any]:
    import base64

    return {
        "channel_id": message.channel_id,
        "account_id": message.account_id,
        "user_id": message.user_id,
        "text": message.text,
        "reply": reply_dict(message.reply),
        "provider_message_id": message.provider_message_id,
        "timestamp_ms": message.timestamp_ms,
        "images": [
            {"data": base64.b64encode(i.data).decode(), "name": i.name} for i in message.images
        ],
    }


def message_from(data: dict[str, Any]) -> InboundMessage:
    import base64

    return InboundMessage(
        channel_id=data["channel_id"],
        account_id=data["account_id"],
        user_id=data["user_id"],
        text=data["text"],
        reply=reply_from(data["reply"]),
        provider_message_id=data["provider_message_id"],
        timestamp_ms=int(data.get("timestamp_ms") or 0),
        images=tuple(
            InboundImage(base64.b64decode(i["data"]), i.get("name") or "图片")
            for i in data.get("images") or ()
        ),
    )


def bind_result_dict(result: BindResult) -> dict[str, Any]:
    return {
        "account_id": result.account_id,
        "display_name": result.display_name,
        "credentials": dict(result.credentials),
        "bound_user": result.bound_user,
        "state": dict(result.state),
    }


def bind_result_from(data: dict[str, Any]) -> BindResult:
    return BindResult(
        account_id=data["account_id"],
        display_name=data["display_name"],
        credentials=dict(data["credentials"]),
        bound_user=data.get("bound_user"),
        state=dict(data.get("state") or {}),
    )


def flow_dict(state: FlowState) -> dict[str, Any]:
    return {
        "flow_id": state.flow_id,
        "status": state.status,
        "message": state.message,
        "qr": state.qr,
        "input_label": state.input_label,
        "result": bind_result_dict(state.result) if state.result is not None else None,
    }


def flow_from(data: dict[str, Any]) -> FlowState:
    result = data.get("result")
    return FlowState(
        flow_id=data["flow_id"],
        status=data["status"],
        message=data.get("message") or "",
        qr=data.get("qr"),
        input_label=data.get("input_label"),
        result=bind_result_from(result) if result else None,
    )

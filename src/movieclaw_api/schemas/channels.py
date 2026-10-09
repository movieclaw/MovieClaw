"""IM 通道接口的请求 / 响应模型（docs/design/plugin-channels.md §6）。"""

from __future__ import annotations

from datetime import datetime

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel


class ChannelFieldView(BaseModel):
    key: str
    label: str
    secret: bool = Field(description="凭据类字段：输入框打码")
    placeholder: str
    help: str
    required: bool


class ChannelBindingSpecView(BaseModel):
    kind: str = Field(description="form：填表单；flow：插件驱动的交互式流程（如扫码）")
    fields: list[ChannelFieldView]
    pairing: str = Field(description="code：提交后私聊 bot 发 6 位配对码；none：提交即完成")
    hint: str


class ChannelView(BaseModel):
    """一个可用的通道（注册表里有它的驱动）。"""

    id: str
    title: str
    description: str
    entry_id: str = Field(description="提供这个通道的插件")
    receive: bool = Field(description="能收消息（能对话 AI 助手）；false 表示只能推送")
    photo: bool = Field(description="推送能带配图")
    binding: ChannelBindingSpecView


class ChannelAccountView(BaseModel):
    channel_id: str
    account_id: str
    display_name: str
    #: 白名单用户（同时是推送目标）；群机器人为空
    bound_user_id: str | None
    status: str = Field(description="active / stale（凭据失效，须重新绑定）")
    running: bool
    #: 提供这个通道的插件没有启用（关闭 / 卸载）：账号保留，重新启用后自动恢复
    channel_available: bool
    last_error: str | None
    bound_at: datetime


class ChannelsView(BaseModel):
    channels: list[ChannelView]
    accounts: list[ChannelAccountView]


class ChannelBindPayload(BaseModel):
    """发起绑定：通道与表单字段（交互式绑定字段留空）。"""

    channel_id: str = Field(min_length=1, max_length=200, description="通道 id（见 GET /channels）")
    fields: dict[str, str] = Field(default_factory=dict)


class ChannelBindingInputPayload(BaseModel):
    """交互式绑定里提交输入（如微信配对数字）。"""

    value: str = Field(min_length=1, max_length=64)


class ChannelBindingView(BaseModel):
    """绑定状态（发起返回 + 前端轮询同一结构）。

    status：pending / scanned / need_input / confirmed / already_bound / expired / failed。
    """

    binding_id: str
    channel_id: str
    kind: str = Field(description="pairing：等用户发配对码；flow：交互式；done：已完成")
    status: str
    message: str
    #: 配对码（kind=pairing）
    pair_code: str
    #: 要扫的二维码（SVG data URL）；二维码会中途刷新，每次轮询都以此为准
    qr_image: str
    #: need_input 时输入框的说明
    input_label: str | None
    account: ChannelAccountView | None = None


class PushTestPayload(BaseModel):
    """测试推送文本（缺省用默认文案）。"""

    text: str = Field(default="", max_length=500)


class ChannelPushConfigView(BaseModel):
    """推送内容开关（GET 返回与 PUT 载荷同构）。"""

    push_dispatch: bool = Field(description="订阅开始下载时推送")
    push_imported: bool = Field(description="入库完成时推送")


# ---------------------------------------------------------------------------
# 旧接口的模型（已发布的 App 在用，见 api/routes/channels_legacy.py）
# ---------------------------------------------------------------------------


class WeixinAccountView(BaseModel):
    """已绑定的微信账号（旧接口）。"""

    account_id: str
    bound_user_id: str | None
    status: str
    running: bool
    last_error: str | None
    bound_at: datetime


class WeixinBindingStartView(BaseModel):
    """发起微信绑定的返回（旧接口）。"""

    challenge_id: str
    qrcode_url: str
    qrcode_image: str
    message: str


class WeixinBindingStatusView(BaseModel):
    """微信绑定状态（旧接口）：pending / scanned / need_verify_code / confirmed / already_bound /
    expired / failed。"""

    challenge_id: str
    status: str
    message: str
    qrcode_url: str
    qrcode_image: str
    account: WeixinAccountView | None = None


class WeixinVerifyCodePayload(BaseModel):
    code: str = Field(min_length=1, max_length=16, description="配对码")


class ImAccountView(BaseModel):
    """已绑定的 Telegram / Discord / 飞书账号（旧接口）。"""

    channel_id: str
    account_id: str
    bound_user_id: str | None
    status: str
    running: bool
    last_error: str | None
    bound_at: datetime


class ImBindTokenPayload(BaseModel):
    token: str = Field(min_length=8, max_length=256, description="bot token")


class FeishuBindPayload(BaseModel):
    webhook_url: str = Field(
        min_length=16, max_length=512, description="飞书自定义机器人 Webhook 地址"
    )
    secret: str = Field(default="", max_length=256, description="签名校验密钥；未开启留空")


class ImBindingView(BaseModel):
    """配对绑定状态（旧接口）：pending / confirmed / expired / failed。"""

    challenge_id: str
    status: str
    pair_code: str
    bot_name: str
    message: str
    account: ImAccountView | None = None

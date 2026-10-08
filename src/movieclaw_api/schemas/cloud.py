"""「MovieClaw Cloud」与「App 推送」接口的请求 / 响应模型（docs/design/cloud-push.md §7）。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel

# ----------------------------------------------------------------------
# MovieClaw Cloud
# ----------------------------------------------------------------------


class CloudPairingView(BaseModel):
    user_code: str
    verification_uri: str
    verification_uri_complete: str
    qrcode_image: str = Field(description="verification_uri_complete 的二维码（SVG data URL）")
    expires_at: datetime
    status: str = Field(description="pending / denied / expired / error")
    message: str | None = None
    instance_name: str


class CloudConnectionView(BaseModel):
    instance_id: str
    instance_name: str
    account_display: str = Field(description="打了掩码的账号标识，如 y•••@gmail.com")
    connected_at: datetime | None
    last_renew_at: datetime | None
    token_expires_at: datetime | None
    scopes: list[str]
    capabilities: list[str]
    limits: dict[str, int]


class CloudDisconnectView(BaseModel):
    reason: str = Field(description="revoked：在官网解绑或账号已删除")
    message: str
    at: datetime | None


class CloudNoticeView(BaseModel):
    id: str
    level: str = Field(description="info / warning")
    message: str


class CloudStatusView(BaseModel):
    state: str = Field(description="disconnected / pairing / connected")
    health: str | None = Field(description="已连接时：ok / unreachable / expired / unsupported")
    health_message: str | None
    cloud_url: str
    custom_cloud_url: bool = Field(description="设置了 MOVIECLAW_CLOUD_URL")
    server_name: str = Field(description="连接时默认的服务器名称")
    pairing: CloudPairingView | None
    connection: CloudConnectionView | None
    last_disconnect: CloudDisconnectView | None
    report_stats: bool
    last_report: dict[str, Any] | None
    last_report_at: datetime | None
    notices: list[CloudNoticeView]


class CloudPairingRequest(BaseModel):
    instance_name: str | None = Field(default=None, max_length=64, description="服务器名称")


class CloudDisconnectRequest(BaseModel):
    force: bool = Field(default=False, description="云端连不上时只删除本地凭证")


class CloudSettingsRequest(BaseModel):
    report_stats: bool


# ----------------------------------------------------------------------
# App 推送：通道（管理员）
# ----------------------------------------------------------------------


class PushQuotaView(BaseModel):
    limit: int | None
    used: int | None
    remaining: int | None
    reset_at: datetime | None


class PushChannelView(BaseModel):
    id: str
    kind: str = Field(description="official / custom")
    name: str
    enabled: bool
    state: str = Field(description="inactive / ok / warning / error")
    status_text: str
    url: str | None
    auth_mode: str | None = Field(description="issuer / static / none；没拉到过 /v1/info 为空")
    token_hint: str | None
    software: str | None
    topics: list[str]
    quota: PushQuotaView | None
    last_success_at: datetime | None
    last_error: str | None
    device_count: int


class UncoveredAppView(BaseModel):
    """登记了推送、但没有任何可用通道能推的 App 版本（按 Bundle ID 汇总）。"""

    topic: str
    device_count: int


class PushChannelsView(BaseModel):
    cloud_state: str = Field(description="disconnected / pairing / connected")
    channels: list[PushChannelView]
    uncovered: list[UncoveredAppView] = Field(
        description="没有可用通道的 App 版本；空 = 每台登记过的设备都有通道"
    )


class OfficialChannelRequest(BaseModel):
    enabled: bool


class RelayProbeRequest(BaseModel):
    url: str = Field(max_length=500)


class RelayProbeView(BaseModel):
    url: str
    reachable: bool
    error: str | None
    software: str | None
    protocol: int | None
    auth_mode: str | None
    topics: list[str]
    types: list[str]
    matched_devices: int
    warnings: list[str]


class RelayCreateRequest(BaseModel):
    name: str = Field(default="", max_length=64)
    url: str = Field(max_length=500)
    token: str | None = Field(default=None, max_length=500)


class RelayUpdateRequest(BaseModel):
    name: str | None = Field(default=None, max_length=64)
    url: str | None = Field(default=None, max_length=500)
    token: str | None = Field(default=None, max_length=500, description="空串表示不改")
    enabled: bool | None = None


# ----------------------------------------------------------------------
# App 推送：我的通知（所有人）
# ----------------------------------------------------------------------


class PushEventView(BaseModel):
    key: str
    title: str
    description: str
    group: str
    enabled: bool
    default: bool


class PushAttentionView(BaseModel):
    """我的一台收不到通知的设备。"""

    device_id: str
    device_name: str
    status: str = Field(description="permission_denied / no_channel / bad_token")
    status_text: str


class PushLibraryView(BaseModel):
    """「媒体库有新片」可选的库：我能看到的库。"""

    id: int
    name: str
    kind: str


class PushMutedItemView(BaseModel):
    """「这部剧不再提醒」静音了的一部片。"""

    id: int
    title: str
    year: int | None
    kind: str


class MyPushView(BaseModel):
    instance_ready: bool = Field(description="服务器有没有任何可用通道")
    is_admin: bool
    events: list[PushEventView]
    ready_devices: int = Field(description="我能收到通知的设备数")
    libraries: list[PushLibraryView] = Field(
        description="我能看到的媒体库（「媒体库有新片」的选项）"
    )
    library_ids: list[int] | None = Field(
        description="「媒体库有新片」关心的库；null = 能看到的全部（含以后新建的）"
    )
    attention: list[PushAttentionView] = Field(description="我收不到通知的设备；空 = 没问题")
    # 可空：App 连旧服务器时没有这个字段，生成的模型得能解码
    muted_items: list[PushMutedItemView] | None = Field(
        default=None,
        description="静音了的片（长按通知「这部剧不再提醒」），最近静音的在前",
    )


class PushPreferencesRequest(BaseModel):
    events: dict[str, bool] = Field(default_factory=dict)
    library_ids: list[int] | None = Field(
        default=None,
        description="「媒体库有新片」关心的库；null = 全部；不传这个字段 = 不改",
    )


class PushTestResultView(BaseModel):
    device_id: str
    device_name: str
    result: str
    message: str


class PushTestView(BaseModel):
    sent: int
    results: list[PushTestResultView]


class PushRegistrationRequest(BaseModel):
    token: str | None = Field(default=None, max_length=400)
    topic: str | None = Field(default=None, max_length=155)
    environment: str | None = Field(default=None, max_length=16)
    types: list[str] | None = Field(default=None, max_length=8)
    key_id: str | None = Field(default=None, max_length=16)
    key: str | None = Field(default=None, max_length=64)
    permission: str = Field(max_length=16)
    client_version: str | None = Field(
        default=None, max_length=64, description="App 当前版本（登录时记下的会过时，借登记刷新）"
    )


class PushRegistrationView(BaseModel):
    registered: bool
    status: str
    status_text: str
    channel_name: str | None

"""MovieClaw Cloud 与 App 推送通道的配置域（docs/design/cloud-push.md）。

两个域：

- ``cloud``：和云端的连接——实例凭证、令牌、账号标识、权限、服务通知、上报、发现文档缓存。
  ``instance_secret`` 和 ``access_token`` 加密落库：令牌也落库，是为了重启时云端恰好
  连不上，推送还能用到令牌过期为止。
- ``push.channels``：推送通道——官方通道的启用开关和 ``/v1/info`` 快照、管理员加的
  自建中继（令牌嵌在列表里，和 Webhook 一样用序列化钩子自带加解密）、collapse_key。

运行期状态（最近一次推送成功的时间、额度、错误）只在内存里，见 services/push/channels.py。
"""

from __future__ import annotations

import contextlib
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_serializer, field_validator

from movieclaw_api.settings.base import SettingSchema, register_setting
from movieclaw_db.crypto import SecretBox, get_secret_box

CLOUD_NAMESPACE = "cloud"
PUSH_CHANNELS_NAMESPACE = "push.channels"


class CloudDiscovery(BaseModel):
    """发现文档（``/.well-known/movieclaw-cloud``）的缓存。"""

    model_config = ConfigDict(extra="ignore")

    api: str = ""
    push_endpoints: list[str] = Field(default_factory=list, description="按 priority 排好序")
    min_instance_version: str = ""
    fetched_at: datetime | None = None


class OfficialRelayCheck(BaseModel):
    """这台服务器看到的官方推送中继连通情况（云端协议 §6.1 的 ``relay``）。

    每次续签前带上令牌调一次官方中继的 ``GET /v1/info``（推送中继协议 §4.1）得出，存库，
    重启后不丢。中继收不到请求时只有这里知道「连不上」，官网据此提示检查网络；连得通时
    官网以中继自己记下的请求为准。
    """

    #: 最近一次调官方中继有没有收到答复（401、503 也算收到）
    reachable: bool = True
    checked_at: datetime | None = None
    #: 最近一次成功推送（取推送时记下的和上次存的里更晚的）
    last_success_at: datetime | None = None
    #: 连不上时的原因（给人看）和从什么时候开始一直连不上
    error: str = ""
    failing_since: datetime | None = None


class CloudNotice(BaseModel):
    """云端发来的服务通知（续签响应的 ``notices``）。"""

    model_config = ConfigDict(extra="ignore")

    id: str
    level: str = "info"
    message: str = ""


@register_setting(
    namespace=CLOUD_NAMESPACE,
    title="MovieClaw Cloud",
    secret_fields=["instance_secret", "access_token"],
)
class CloudSetting(SettingSchema):
    """和 MovieClaw Cloud 的连接。``instance_secret`` 为空即未连接。"""

    # -- 连接 ------------------------------------------------------------------
    instance_id: str = ""
    instance_secret: str = Field(default="", description="长期凭证，只发给云端 api")
    instance_name: str = ""
    api_url: str = Field(default="", description="连接时用的云端 api（来自发现文档）")
    connected_at: datetime | None = None
    account_display: str = Field(default="", description="打了掩码的账号标识，如 y•••@gmail.com")

    # -- 续签拿到的 ----------------------------------------------------------------
    access_token: str = Field(default="", description="24 小时的实例令牌，只发给推送中继")
    token_expires_at: datetime | None = None
    scopes: list[str] = Field(default_factory=list)
    capabilities: list[str] = Field(default_factory=list)
    limits: dict[str, int] = Field(default_factory=dict)
    renew_interval: int = Field(default=3600, description="云端建议的续签间隔（秒）")
    last_renew_at: datetime | None = None
    unsupported_message: str = Field(
        default="", description="云端说版本不再受支持时的说明；空 = 受支持"
    )
    notices: list[CloudNotice] = Field(default_factory=list)
    dismissed_notice_ids: list[str] = Field(default_factory=list)

    # -- 被动断开（在官网解绑、账号删除）：未连接页面上告诉管理员发生了什么 ----------
    last_disconnect_reason: str = ""
    last_disconnect_message: str = ""
    last_disconnect_at: datetime | None = None

    # -- 上报 ----------------------------------------------------------------------
    report_stats: bool = Field(default=True, description="上报设备数和中继连通情况")
    last_report: dict | None = None
    last_report_at: datetime | None = None
    relay_check: OfficialRelayCheck | None = Field(
        default=None, description="续签前对官方中继的例行检查；没检查过、官方通道停用时为空"
    )

    # -- 发现文档缓存 --------------------------------------------------------------
    discovery: CloudDiscovery | None = None

    @property
    def connected(self) -> bool:
        return bool(self.instance_secret and self.instance_id)


class RelayInfo(BaseModel):
    """中继 ``GET /v1/info`` 的快照：路由要用 ``topics``，重启时不用等它就能路由。"""

    model_config = ConfigDict(extra="ignore")

    protocol: int = 0
    software: str = ""
    aud: str = ""
    topics: list[str] = Field(default_factory=list)
    environments: list[str] = Field(default_factory=list)
    types: list[str] = Field(default_factory=list)
    auth_mode: str = ""
    max_batch: int = 100
    limits: dict[str, int] = Field(default_factory=dict)
    fetched_at: datetime | None = None


class PushRelay(BaseModel):
    """管理员加的一个自建中继。"""

    model_config = ConfigDict(extra="ignore")

    id: str
    name: str = ""
    url: str = ""
    token: str = Field(default="", description="中继发的令牌（static 模式）；加密落库")
    enabled: bool = True
    info: RelayInfo | None = None
    created_at: datetime | None = None


@register_setting(
    namespace=PUSH_CHANNELS_NAMESPACE,
    title="App 推送通道",
    secret_fields=["collapse_key"],
)
class PushChannelsSetting(SettingSchema):
    """推送通道。官方通道的地址和凭证来自 MovieClaw Cloud，这里只有它的开关和快照。"""

    official_enabled: bool = Field(default=True, description="连接云之后默认启用")
    official_info: RelayInfo | None = None
    relays: list[PushRelay] = Field(default_factory=list)
    collapse_key: str = Field(default="", description="collapse_id 用的本地密钥，不发给任何人")

    @field_validator("relays", mode="after")
    @classmethod
    def _decrypt_relay_tokens(cls, relays: list[PushRelay]) -> list[PushRelay]:
        """从库读回时解密各中继的令牌；加密器未初始化时保持密文（宁可暂不可用）。"""
        for relay in relays:
            if relay.token and SecretBox.is_encrypted(relay.token):
                with contextlib.suppress(RuntimeError):
                    relay.token = get_secret_box().decrypt(relay.token)
        return relays

    @field_serializer("relays")
    def _encrypt_relay_tokens(self, relays: list[PushRelay]) -> list[dict]:
        """序列化（落库 / 导出）时加密令牌。加密器未初始化时抛错——静默放行等于明文落库。"""
        result = []
        for relay in relays:
            data = relay.model_dump(mode="json")
            if data["token"] and not SecretBox.is_encrypted(data["token"]):
                data["token"] = get_secret_box().encrypt(data["token"])
            result.append(data)
        return result


@register_setting(namespace="push.arrivals", title="媒体库新片推送进度")
class ArrivalsProgress(SettingSchema):
    """「媒体库有新片」检查到哪了：每个库一个水位，水位之前的台账行都处理过了。"""

    started_at: datetime | None = Field(default=None, description="第一次运行的时间（不回溯）")
    marks: dict[str, datetime] = Field(default_factory=dict, description="库 id → 水位")
    held: dict[str, datetime] = Field(
        default_factory=dict,
        description="认不出、等认出来再推的台账行 id → 第一次看到的时间（最多等 24 小时）",
    )


@register_setting(namespace="push.signed_out", title="自己退出登录的设备")
class SignedOutDevices(SettingSchema):
    """在设备上自己退出登录的 App、命令行：同一台再登录回来不算「新设备登录」。

    只记设备自己退出的（``DELETE /auth/devices/current``）；在「账号 → 设备」里被注销的
    不记——那可能正是要赶走的陌生设备，它再登录必须提醒。键是
    「成员 + 客户端类型 + 安装标识」的哈希，30 天后作废。
    """

    entries: dict[str, datetime] = Field(default_factory=dict, description="哈希 → 退出时间")

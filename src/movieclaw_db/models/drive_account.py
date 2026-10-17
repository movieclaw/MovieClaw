from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, Column, Index, Text
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin

#: 账号状态（docs/design/cloud-storage.md §3.1）。存值本身（普通字符串列，不用枚举类型：
#: SQLModel 的 StrEnum 列存的是成员名，改动时容易静默对不上）
DRIVE_STATUS_OK = "ok"
DRIVE_STATUS_AUTH_EXPIRED = "auth_expired"
DRIVE_STATUS_RATE_LIMITED = "rate_limited"
DRIVE_STATUS_API_BROKEN = "api_broken"
DRIVE_STATUS_DISABLED = "disabled"


class DriveAccount(TimestampMixin, table=True):
    """网盘账号：一行 = 一个已登录的网盘用户（docs/design/cloud-storage.md §3.1）。

    ``backend`` 是存储后端的类型值（插件声明的 ``type``，如 ``115``），换一个实现同一网盘的
    插件时沿用，账号接得上。同一后端同一网盘用户只有一行（浏览器扩展重复推送、重新扫码都
    更新这一行）。

    ``credentials`` 是凭据 JSON 的 SecretBox 密文，加解密收口在 Repository 层；明文只在调用
    插件时交出去，插件刷新后的新凭据先落库再交给调用方（§11.3）。

    每日预算的已用次数只记在内存里（计量不碰盘），重启后从零算起。
    """

    __tablename__ = "drive_account"
    __table_args__ = (
        Index("uq_drive_account_backend_user", "backend", "remote_user_id", unique=True),
    )

    id: int | None = Field(default=None, primary_key=True)
    backend: str = Field(description="存储后端类型（插件声明的 type）")
    remote_user_id: str = Field(description="网盘侧的用户 id")
    name: str = Field(description="账号名（默认取网盘昵称，用户可改）")
    credentials: str = Field(sa_column=Column(Text, nullable=False), description="凭据 JSON 密文")
    login_method: str = Field(default="scan", description="登录方式：scan / cookie")
    login_detail: str | None = Field(default=None, description="登录细节（如扫码选的登录端）")
    status: str = Field(
        default=DRIVE_STATUS_OK,
        description="ok / auth_expired / rate_limited / api_broken / disabled",
    )
    status_message: str | None = Field(default=None, description="状态说明（中文，给用户看）")
    status_until: datetime | None = Field(default=None, description="限流的恢复时间（UTC）")
    qps: float | None = Field(default=None, description="请求速率上限；NULL = 用插件默认值")
    daily_budget: int | None = Field(default=None, description="每日调用预算；NULL = 用插件默认值")
    read_slots: int | None = Field(default=None, description="同时播放数；NULL = 用插件默认值")
    vip: str | None = Field(default=None, description="会员等级的说法")
    quota_total: int | None = Field(
        default=None, sa_column=Column(BigInteger), description="容量（字节）"
    )
    quota_used: int | None = Field(
        default=None, sa_column=Column(BigInteger), description="已用（字节）"
    )
    profile_at: datetime | None = Field(default=None, description="昵称与容量的刷新时间")
    change_cursor: str | None = Field(default=None, description="操作动态的游标（§4.3）")

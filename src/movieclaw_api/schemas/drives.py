"""网盘接口的请求 / 响应模型（docs/design/cloud-storage.md §11）。"""

from __future__ import annotations

from datetime import datetime

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel


class DriveCapabilitiesView(BaseModel):
    writable: bool = Field(description="能写（上传、移动、删除）")
    rapid_upload_hashes: list[str] = Field(description="秒传用的指纹；空 = 不支持秒传")
    range_challenge: bool
    list_hashes: bool = Field(description="列目录时带文件哈希")
    change_feed: bool = Field(description="有操作动态（增量感知网盘上的变化）")
    original_link: bool = Field(description="直链是原画")
    link_needs_ua: bool
    recycle_bin: bool = Field(description="删除进网盘回收站")
    default_qps: float
    default_daily_budget: int
    default_read_slots: int


class DriveLoginChoiceView(BaseModel):
    value: str
    label: str
    help: str


class DriveLoginOptionView(BaseModel):
    key: str
    label: str
    default: str
    help: str
    choices: list[DriveLoginChoiceView]


class DriveLoginSpecView(BaseModel):
    scan: bool = Field(description="支持扫码登录")
    cookie: bool = Field(description="支持用浏览器扩展导入或粘贴 Cookie 登录")
    cookie_domains: list[str]
    options: list[DriveLoginOptionView] = Field(description="扫码前要选的项（如登录端）")
    hint: str


class DriveBackendView(BaseModel):
    """一种可用的网盘（有插件提供后端）。"""

    type: str
    title: str
    description: str
    accent_color: str = Field(description="图标主题色；空 = 用默认色")
    capabilities: DriveCapabilitiesView
    login: DriveLoginSpecView


class DriveAccountView(BaseModel):
    id: int
    backend: str = Field(description="网盘类型")
    backend_title: str = Field(description="网盘名；插件不在时就是类型值")
    backend_available: bool = Field(description="提供这种网盘的插件在运行")
    accent_color: str
    name: str
    login_method: str = Field(description="scan / cookie")
    login_detail: str | None = Field(description="登录细节（如扫码选的登录端）")
    status: str = Field(description="ok / auth_expired / rate_limited / api_broken / disabled")
    status_message: str | None
    status_until: datetime | None = Field(description="限流的恢复时间")
    qps: float = Field(description="生效的请求速率（次 / 秒）")
    daily_budget: int = Field(description="生效的每日调用预算")
    read_slots: int = Field(description="生效的同时播放数")
    qps_custom: bool = Field(description="请求速率是用户改过的")
    daily_budget_custom: bool
    read_slots_custom: bool
    used_today: int = Field(description="今天已用的调用次数")
    vip: str | None
    quota_total: int | None
    quota_used: int | None
    profile_at: datetime | None
    created_at: datetime


class DriveAccountUpdatePayload(BaseModel):
    name: str | None = None
    qps: float | None = None
    daily_budget: int | None = None
    read_slots: int | None = None
    reset: list[str] = Field(
        default_factory=list, description="回到插件默认值的字段：qps / daily_budget / read_slots"
    )


class DriveLoginPayload(BaseModel):
    backend: str
    options: dict[str, str] = Field(default_factory=dict, description="扫码前选的项")


class DriveCookiePayload(BaseModel):
    backend: str
    cookie: str = Field(description="整页 Cookie（name=value; name2=value2）")


class DriveLoginView(BaseModel):
    login_id: str
    backend: str
    status: str = Field(description="pending / scanned / confirmed / expired / failed")
    message: str
    qr_image: str = Field(description="二维码图片（data URL）；没有为空")
    account: DriveAccountView | None = Field(description="confirmed 时的账号")
    created: bool = Field(description="confirmed 时：是新账号（否则是重新登录了已有账号）")

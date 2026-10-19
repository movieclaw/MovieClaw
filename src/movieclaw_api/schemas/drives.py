"""网盘接口的请求 / 响应模型（docs/design/cloud-storage.md §11）。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

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
    form: dict[str, Any] | None = Field(
        default=None,
        description="填表登录的字段（JSON Schema 子集，同插件设置）；null = 不支持填表登录",
    )
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
    login_method: str = Field(description="scan / cookie / form")
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
    relogin: int | None = Field(
        default=None, description="从这个账号的卡片上重新登录：登进来的必须是同一个网盘用户"
    )


class DriveCookiePayload(BaseModel):
    backend: str
    cookie: str = Field(description="整页 Cookie（name=value; name2=value2）")
    relogin: int | None = Field(
        default=None, description="从这个账号的卡片上重新登录：登进来的必须是同一个网盘用户"
    )


class DriveFormLoginPayload(BaseModel):
    backend: str
    values: dict[str, Any] = Field(description="按后端声明的 login.form 填的值")
    relogin: int | None = Field(
        default=None, description="从这个账号的卡片上重新登录：登进来的必须是同一个网盘用户"
    )


class DriveLoginView(BaseModel):
    login_id: str
    backend: str
    status: str = Field(description="pending / scanned / confirmed / expired / failed")
    message: str
    qr_image: str = Field(description="二维码图片（data URL）；没有为空")
    account: DriveAccountView | None = Field(description="confirmed 时的账号")
    created: bool = Field(description="confirmed 时：是新账号（否则是重新登录了已有账号）")


class DriveDirView(BaseModel):
    """目录选择器里的一个子目录。"""

    id: str = Field(description="网盘目录 id")
    name: str
    path: str = Field(description="网盘上的完整路径（展示用，如「影视/电影」）")
    has_children: bool | None = Field(description="底下还有没有子目录；不知道为 null")
    video_count: int | None = Field(description="视频文件数（网盘目录信息直接给的）；不知道为 null")
    library_id: int | None = Field(
        default=None, description="这个目录（或它的上层、下层）已经挂在哪个媒体库上"
    )
    library_name: str | None = None


class DriveStatusView(BaseModel):
    """网盘功能醒没醒着（cloud-storage.md §11.8）：各端据此决定网盘入口出不出现，一次请求问完。"""

    active: bool = Field(description="有插件提供网盘后端；没有时网盘功能整体休眠")
    accounts: int = Field(
        description="网盘账号数（插件卸载后账号还在，设置页要能看到并提示装插件）"
    )


class DriveSettingsView(BaseModel):
    """网盘的全局选项。"""

    remove_download_tasks: bool = Field(
        description="本地腾空后删除对应的下载任务（H&R、非 MovieClaw 投递的种子保留）"
    )


class DriveSettingsPayload(BaseModel):
    remove_download_tasks: bool | None = Field(default=None, description="不传表示不改动")

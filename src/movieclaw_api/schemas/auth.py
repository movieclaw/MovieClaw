"""登录鉴权相关的请求 / 响应模型。"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel


class DemoAccountView(BaseModel):
    """公开演示站在登录页公布的一个账号（docs/design/demo-site.md）。"""

    username: str
    password: str
    label: str = Field(description="角色名，如「超级管理员」「家庭成员」")
    description: str = Field(default="", description="一句话说明这个角色能看到什么")


class DemoSiteView(BaseModel):
    """公开演示站的说明：登录页据此展示只读提示与可一键填入的账号。"""

    notice: str = Field(default="", description="演示站说明（内容来源、只读、定时还原等）")
    accounts: list[DemoAccountView] = Field(default_factory=list)


class BootstrapStatus(BaseModel):
    """首次初始化状态：前端据此决定进引导页（/setup）还是登录页（/login）。"""

    initialized: bool
    demo: DemoSiteView | None = Field(
        default=None, description="公开演示站模式下的说明与演示账号；正常部署恒为空"
    )


class BootstrapRequest(BaseModel):
    """首次初始化：创建超级管理员账号。"""

    username: str = Field(min_length=3, max_length=32, description="管理员用户名")
    password: str = Field(min_length=8, max_length=128, description="管理员密码，至少 8 位")


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=32)
    password: str = Field(min_length=1, max_length=128)
    remember: bool = Field(default=False, description="记住我：会话有效期 7 天 → 30 天")


class ChangePasswordRequest(BaseModel):
    old_password: str = Field(min_length=1, max_length=128, description="当前密码（校验身份）")
    new_password: str = Field(min_length=8, max_length=128, description="新密码，至少 8 位")
    sign_out_paired: bool = Field(
        default=False,
        description=(
            "同时注销命令行、转码器与手工令牌。默认保留：它们常年无人值守，"
            "改个密码就停转码很难排查；怀疑密码泄露时应勾上"
        ),
    )


class UpdateProfileRequest(BaseModel):
    """修改个人信息（当前只有昵称；登录用户名不可改）。"""

    nickname: str = Field(min_length=1, max_length=32, description="展示昵称")


class ApiTokenCreateRequest(BaseModel):
    """网页手工创建令牌（给没有人能按批准的无人值守环境）。"""

    name: str = Field(
        min_length=1, max_length=64, description="令牌名字，如 'nas-cron'，便于识别与注销"
    )
    scope: Literal["full", "transcode"] = Field(
        default="full",
        description="full=与你相同的完全权限；transcode=只能转码（给命令行模式的转码器用）",
    )


class ApiTokenCreatedView(BaseModel):
    """创建成功的返回体：token 明文仅此一次，请立即保存。"""

    id: str = Field(description="设备 id（在「设备」列表里注销时使用）")
    name: str
    scope: str
    created_at: datetime
    token: str = Field(description="令牌明文；服务端只存哈希，之后无法再次查看")


class SessionCapabilities(BaseModel):
    """当前主体的能力开关快照（前端据此裁剪入口；安全边界仍在后端 403）。"""

    allow_subscribe: bool = True
    allow_search: bool = True
    allow_direct_download: bool = True


class DeviceBrief(BaseModel):
    """当前请求所用的登录设备（「当前设备」标记、``mclaw status`` 回显用）。"""

    id: str
    kind: str = Field(description="web / ios / tvos / macos / android / cli / worker / manual")
    name: str


class SessionView(BaseModel):
    """当前登录状态（GET /auth/me 与登录成功后的返回体）。"""

    username: str
    nickname: str
    avatar_url: str | None = Field(
        default=None, description="头像相对 URL（含版本号）；未上传过头像时为空"
    )
    role: str = Field(default="admin", description="admin=超级管理员；member=成员")
    capabilities: SessionCapabilities = Field(
        default_factory=SessionCapabilities,
        description="能力开关快照；管理员恒为全开",
    )
    device: DeviceBrief | None = Field(
        default=None,
        description="本次请求所用的登录设备；升级前签发的旧网页会话为空",
    )
    # 声明成可空只为生成的 iOS 模型是可选字段（apps/apple/scripts/gen_api.py 按可空性
    # 定可选）：App 连没有这个字段的老服务器时解码不能失败。服务端恒输出 true / false
    demo: bool | None = Field(
        default=False,
        description="是否是公开演示站的只读会话（审核账号与正式部署恒为 false）："
        "网页据此显示只读说明，不再摆出服务端会拒绝的操作",
    )


# ---------------------------------------------------------------------------
# 多账号切换（docs/design/account-switching.md §3）
# ---------------------------------------------------------------------------


class LogoutRequest(BaseModel):
    """退出登录。默认只退当前账号并切到袋子里的下一个；all=True 清空全部。"""

    all: bool = Field(default=False, description="true=退出本浏览器里的全部账号")


class SwitchAccountRequest(BaseModel):
    """切换到浏览器已保存的某个账号（按用户名，用户名在超管与成员间全局唯一）。"""

    username: str = Field(min_length=1, max_length=32)


class AccountView(BaseModel):
    """浏览器当前持有的一个账号（GET /auth/accounts 列表项）。"""

    username: str
    nickname: str
    avatar_url: str | None = Field(default=None, description="头像相对 URL；未上传过为空")
    role: str = Field(default="admin", description="admin=超级管理员；member=成员")
    active: bool = Field(description="是否为当前激活账号（列表里恰有一个为 true）")


# ---------------------------------------------------------------------------
# 设备授权（docs/design/device-auth.md §2）
# ---------------------------------------------------------------------------


class DeviceAuthorizeRequest(BaseModel):
    """客户端发起接入请求。

    刻意**没有权限字段**：客户端只声明自己是什么形态、叫什么名字，
    能做什么由批准者决定。
    """

    client_type: str = Field(
        description=(
            "客户端形态：worker（转码 Worker）、cli（命令行 / Agent）、tvos（Apple TV App）、"
            "macos（Mac App）、androidtv（Android TV App）"
        )
    )
    client_name: str = Field(
        min_length=1,
        max_length=64,
        description="设备名，批准页上给人看的，如 'Yi的Mac-mini'",
    )
    installation_id: str | None = Field(
        default=None,
        max_length=128,
        description="客户端安装标识：同一台机器重新配对时替换旧凭证，而不是越积越多",
    )
    platform: str | None = Field(
        default=None, max_length=128, description="系统与架构，如 'macOS 26.0 · arm64'"
    )
    client_version: str | None = Field(default=None, max_length=64, description="客户端版本")


class DeviceAuthorizeView(BaseModel):
    """接入请求的回执。``user_code`` 给人看，``device_code`` 用于兑换。"""

    user_code: str = Field(description="配对码，客户端显示给用户，在网页上核对")
    device_code: str = Field(description="兑换凭据，仅客户端持有，不得展示给用户")
    verification_uri: str = Field(description="批准页地址（不带配对码，用户需手动输入）")
    verification_uri_complete: str = Field(
        description="带配对码的批准页地址：打开即显示这一条请求，客户端应优先打开它"
    )
    interval: int = Field(description="建议的轮询间隔（秒），不要比这更快")
    expires_in: int = Field(description="配对码有效期（秒），超时需重新发起")


class DeviceTokenRequest(BaseModel):
    """客户端轮询兑换令牌。"""

    device_code: str = Field(min_length=1, max_length=128)


class DeviceTokenView(BaseModel):
    """兑换成功的返回体：令牌明文仅此一次。"""

    token: str = Field(description="令牌明文；服务端只存哈希，之后无法再次查看")
    client_name: str
    client_type: str
    granted_by: str = Field(description="批准者的用户名：这枚令牌就是他的身份")


class DeviceRequestView(BaseModel):
    """一条待批准的接入请求（按配对码取，批准页的数据源）。"""

    user_code: str
    client_type: str
    client_name: str
    source_ip: str = Field(
        description=(
            "请求来源 IP，帮助用户判断这是不是自己那台机器；"
            "容器桥接网络会把源地址 NAT 掉，那种情况下为空串，界面应如实说无法确定"
        )
    )
    expires_in: int = Field(description="剩余有效秒数")
    platform: str | None = Field(default=None, description="客户端自报的系统与架构")
    client_version: str | None = Field(default=None, description="客户端自报的版本")
    requires_admin: bool = Field(
        default=False, description="只有管理员能批准（转码器）；成员看到时应说明原因"
    )


# ---------------------------------------------------------------------------
# 登录设备（docs/design/login-devices.md）
# ---------------------------------------------------------------------------


class DeviceClientInfo(BaseModel):
    """原生 App 登录时自报的设备信息。"""

    kind: Literal["ios", "tvos", "macos", "android", "androidtv"] = Field(description="App 平台")
    installation_id: str = Field(
        min_length=8,
        max_length=128,
        description="App 安装标识（存在系统钥匙串）：同一台设备同一个人重新登录时替换旧凭证",
    )
    name: str | None = Field(
        default=None, max_length=64, description="设备名，如 'iPhone Air'；用户之后可改名"
    )
    platform: str | None = Field(
        default=None, max_length=128, description="系统与机型，如 'iOS 26.0 · iPhone18,4'"
    )
    client_version: str | None = Field(default=None, max_length=64, description="App 版本")


class DeviceLoginRequest(BaseModel):
    """原生 App 用账号密码登录，换一枚设备令牌。"""

    username: str = Field(min_length=1, max_length=32)
    password: str = Field(min_length=1, max_length=128)
    client: DeviceClientInfo


class DevicePushView(BaseModel):
    """App 设备能不能收到推送（docs/design/cloud-push.md §4）。界面只在不是 ok 时提示。"""

    status: str = Field(
        description="ok / permission_denied / no_channel / bad_token / not_registered"
    )
    status_text: str


class LoginDeviceView(BaseModel):
    """「我的设备」列表里的一台设备（登录设备或 Jellyfin 播放器）。"""

    id: str = Field(description="设备 id：登录设备为 ld-<n>，Jellyfin 播放器为 jf-<n>")
    kind: str = Field(
        description="web / ios / tvos / macos / android / cli / worker / manual / jellyfin"
    )
    kind_label: str = Field(description="给人看的类型名：浏览器、iOS App、命令行、Infuse……")
    family: str = Field(
        description="login=用密码登录的（改密即下线）；paired=配对或手工创建的（改密默认保留）"
    )
    name: str
    scope: str = Field(description="full=与主人相同的权限；transcode=只能转码")
    platform: str | None = None
    client_version: str | None = None
    created_at: datetime
    last_seen_at: datetime | None = None
    last_seen_ip: str | None = None
    expires_at: datetime | None = Field(default=None, description="网页会话的过期时间")
    current: bool = Field(description="是不是发起本次请求的这台设备")
    connected: bool = Field(
        default=False,
        description=(
            "此刻是否有一条活着的转码控制连接（只有转码器有长连接；其余设备恒为 false，"
            "在不在用看 last_seen_at）"
        ),
    )
    renamable: bool = Field(description="能否改名（Jellyfin 播放器的名字由客户端上报，不能改）")
    owner_id: int = Field(description="主人：成员 id；0 = 超管")
    owner_username: str
    owner_nickname: str
    push: DevicePushView | None = Field(
        default=None, description="推送状态；只有 App 类设备、且在设备列表里才有"
    )


class DeviceLoginView(BaseModel):
    """App 登录成功：设备令牌（明文仅此一次）+ 这台设备 + 当前身份。"""

    token: str = Field(description="设备令牌明文；存进系统钥匙串，服务端只存哈希")
    device: LoginDeviceView
    session: SessionView


class RenameDeviceRequest(BaseModel):
    name: str = Field(min_length=1, max_length=64, description="新的设备名")


class DeviceCleanupRequest(BaseModel):
    inactive_days: int = Field(ge=1, le=3650, description="注销多少天没用过的设备")
    all: bool = Field(default=False, description="超管：清理全部成员的设备（否则只清自己的）")
    dry_run: bool = Field(default=False, description="只列出会被注销的设备，不真的注销")


class DeviceCleanupItem(BaseModel):
    id: str = Field(description="设备 ID（与设备列表同一套）")
    name: str = Field(description="设备名")
    owner_nickname: str = Field(description="主人的昵称")


class DeviceCleanupView(BaseModel):
    devices: list[DeviceCleanupItem] = Field(description="会被（或已被）注销的设备")

"""网盘存储后端契约（docs/design/cloud-storage.md §11）。

一个网盘插件只实现「怎么跟这家网盘说话」：继承 ``DriveBackend``，往注册表
``drive-backends`` 贡献一个实例。账号与凭据加密、限速与每日预算、超时、错误归类、
登录流程的轮询、界面都由主程序负责，插件不用管::

    from movieclaw_sdk import plugin
    from movieclaw_sdk.drives import (
        DRIVE_BACKENDS, AccountInfo, Capabilities, DriveAccount, DriveBackend, Login, LoginFlow,
    )

    class Pan115(DriveBackend):
        type = "115"
        title = "115 网盘"
        capabilities = Capabilities(writable=True, rapid_upload_hashes=("sha1",))
        login = Login(scan=True, cookie_domains=("115.com",))

        async def begin_login(self, options: dict[str, str]) -> LoginFlow: ...
        async def login_state(self, flow_id: str) -> LoginFlow: ...
        async def account_info(self, account: DriveAccount) -> AccountInfo: ...

    @plugin("cloud-115", title="115 网盘")
    async def apply(ctx):
        ctx.contribute(DRIVE_BACKENDS, "115", Pan115())

**凭据**：带账号的方法拿到 ``DriveAccount``，凭据在 ``account.credentials``。
令牌刷新、Cookie 换新之后直接给 ``account.credentials`` 赋新值；主程序在这次调用返回后
先把新凭据落库，再把结果交给调用方（滚动刷新的令牌用一次就作废，先用后存会在崩溃时
丢失登录态）。

**错误**：只抛本模块的异常（``RateLimited``、``AuthExpired`` ……），主程序按类型决定
推迟、重试还是让用户重新登录。**只有确认登录已失效才抛 ``AuthExpired``**：限流、风控、
网络错误都不是。其余异常一律按 ``Transient`` 处理。插件里不要自己睡眠重试、不要自己
限速；每个 HTTP 请求都要设超时。

同一份后端既能在主进程里运行，也能在独立进程里运行（宿主经代理调用它的方法）。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, ClassVar, Literal

from movieclaw_kernel import RegistryKey, Stability

# ---------------------------------------------------------------------- 声明


@dataclass(frozen=True, slots=True)
class Capabilities:
    """后端能做什么、默认怎么用（cloud-storage.md §11.1）。主程序据此决定界面与调度。"""

    #: 能不能写（上传、移动、删除）；不能写的盘一期不支持
    writable: bool = False
    #: 秒传用哪些指纹（``sha1`` / ``md5``）；空 = 不支持秒传
    rapid_upload_hashes: tuple[str, ...] = ()
    #: 秒传会不会要求回答任意区间的哈希（要求时上传方必须有本地字节）
    range_challenge: bool = False
    #: 列目录时给不给文件哈希（纳管的文件能不能直接带指纹）
    list_hashes: bool = False
    #: 有没有操作动态（增量感知网盘上的变化）
    change_feed: bool = False
    #: 直链是不是原画（不是转码流）
    original_link: bool = True
    #: 直链是否按取链时的 User-Agent 签发（播放器跟随跳转时 UA 必须一致）
    link_needs_ua: bool = False
    #: 删除是否进网盘回收站
    recycle_bin: bool = False
    #: 主程序限速的默认值（次 / 秒），用户可改
    default_qps: float = 1.0
    #: 每日接口调用预算的默认值，用户可改
    default_daily_budget: int = 5000
    #: 同时播放数（服务器读网盘的并发连接名额）的默认值，用户可改
    default_read_slots: int = 2
    #: 同一账号同时上传几个文件
    upload_concurrency: int = 1
    #: 单文件大小上限（字节）；未知为 None
    max_file_bytes: int | None = None


@dataclass(frozen=True, slots=True)
class Choice:
    value: str
    label: str
    help: str = ""


@dataclass(frozen=True, slots=True)
class LoginOption:
    """扫码前要用户选的一项（如 115 的登录端），设置页渲染成下拉框。"""

    key: str
    label: str
    choices: tuple[Choice, ...]
    default: str
    help: str = ""


@dataclass(frozen=True, slots=True)
class Login:
    """登录方式（cloud-storage.md §11.1 / §11.5）。"""

    #: 支持扫码（实现 ``begin_login`` / ``login_state``）
    scan: bool = False
    #: 接收浏览器扩展推送的 Cookie 的域名（实现 ``login_with_cookie``）；空 = 不支持
    cookie_domains: tuple[str, ...] = ()
    #: 扫码前的选项
    options: tuple[LoginOption, ...] = ()
    #: 添加账号对话框顶部的一句说明
    hint: str = ""


# ---------------------------------------------------------------------- 结果


@dataclass(frozen=True, slots=True)
class LoginResult:
    """登录成功：主程序据此建账号或更新同一用户的账号。"""

    #: 网盘侧的用户 id（同一用户只会有一个账号）
    user_id: str
    display_name: str
    #: 凭据（主程序加密存储，以后调用时原样交还）
    credentials: dict[str, str]


LoginStatus = Literal["pending", "scanned", "confirmed", "expired", "failed"]
TERMINAL_LOGIN_STATUSES = frozenset({"confirmed", "expired", "failed"})


@dataclass(frozen=True, slots=True)
class LoginFlow:
    """扫码登录的一个快照（主程序原样渲染给设置页）。"""

    flow_id: str
    status: LoginStatus
    message: str = ""
    #: 要用户扫的二维码内容（主程序渲染成图）
    qr: str | None = None
    #: ``confirmed`` 时的登录结果
    result: LoginResult | None = None

    @property
    def terminal(self) -> bool:
        return self.status in TERMINAL_LOGIN_STATUSES


@dataclass(frozen=True, slots=True)
class AccountInfo:
    display_name: str
    #: 会员等级的说法（如「VIP」「年费会员」）；没有就是 None
    vip: str | None = None
    quota_total: int | None = None
    quota_used: int | None = None


@dataclass(slots=True)
class DriveAccount:
    """账号句柄：主程序构造，交给带账号的方法。凭据变了直接给 ``credentials`` 赋新值。"""

    user_id: str
    credentials: dict[str, str] = field(default_factory=dict)


# ---------------------------------------------------------------------- 错误


class DriveError(Exception):
    """网盘后端报的错。``message`` 直接给用户看，写清楚原因。"""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class RateLimited(DriveError):
    """被网盘限流。``retry_after`` 是建议等待的秒数（不知道就 None）。"""

    def __init__(self, message: str, retry_after: float | None = None) -> None:
        super().__init__(message)
        self.retry_after = retry_after


class RiskControl(DriveError):
    """触发网盘风控（比限流更重，要停得更久）。"""


class AuthExpired(DriveError):
    """登录已失效，必须重新登录。只在确认失效时抛。"""


class ApiChanged(DriveError):
    """网盘接口变了、插件不认识（要更新插件）。"""


class NotFound(DriveError):
    """文件或目录不存在。"""


class QuotaExceeded(DriveError):
    """网盘空间不足。"""


class Conflict(DriveError):
    """同名已存在。"""


class Transient(DriveError):
    """临时性错误（网络、5xx），稍后重试即可。"""


_ERRORS: dict[str, type[DriveError]] = {
    cls.__name__: cls
    for cls in (
        RateLimited,
        RiskControl,
        AuthExpired,
        ApiChanged,
        NotFound,
        QuotaExceeded,
        Conflict,
        Transient,
    )
}


def error_dict(exc: DriveError) -> dict[str, Any]:
    return {
        "kind": type(exc).__name__,
        "message": exc.message,
        "retry_after": getattr(exc, "retry_after", None),
    }


def error_from(data: dict[str, Any]) -> DriveError:
    cls = _ERRORS.get(data.get("kind") or "", Transient)
    message = str(data.get("message") or "网盘插件出错")
    if cls is RateLimited:
        return RateLimited(message, data.get("retry_after"))
    return cls(message)


# ---------------------------------------------------------------------- 后端


class DriveBackend:
    """一家网盘的后端（注册表 ``drive-backends`` 的贡献项）。

    子类设置 ``type`` / ``title`` / ``capabilities`` / ``login``，按登录方式实现
    ``begin_login`` 一族或 ``login_with_cookie``，都要实现 ``account_info``。
    文件相关的方法随存储层的后续阶段加入。
    """

    #: 存进账号的类型值，全局唯一（如 ``115``）；换一个实现同一网盘的插件时沿用同一个值，
    #: 账号就接得上
    type: ClassVar[str] = ""
    title: ClassVar[str] = ""
    description: ClassVar[str] = ""
    #: 界面图标的主题色（``#2a77ff``）；主程序用名称生成字母方块，不支持插件带图片
    accent_color: ClassVar[str] = ""
    capabilities: ClassVar[Capabilities] = Capabilities()
    login: ClassVar[Login] = Login()

    # ---- 登录：扫码
    async def begin_login(self, options: dict[str, str]) -> LoginFlow:
        """开始一次扫码登录。``options`` 是用户在 ``login.options`` 里选的值。"""
        raise NotImplementedError

    async def login_state(self, flow_id: str) -> LoginFlow:
        raise NotImplementedError

    async def cancel_login(self, flow_id: str) -> None:
        return None

    # ---- 登录：Cookie（浏览器扩展推送或用户粘贴）
    async def login_with_cookie(self, cookie_header: str) -> LoginResult:
        """从整页 Cookie 里挑出需要的几项并校验。

        没登录抛 ``AuthExpired``，Cookie 不全抛 ``ValueError``。
        """
        raise NotImplementedError

    # ---- 账号
    async def account_info(self, account: DriveAccount) -> AccountInfo:
        raise NotImplementedError


#: 网盘插件往这个注册表贡献后端（贡献 id 随意，按 ``type`` 识别）
DRIVE_BACKENDS: RegistryKey[DriveBackend] = RegistryKey(
    "drive-backends",
    version="1.0",
    stability=Stability.EXPERIMENTAL,
    schema=DriveBackend,
    doc="网盘存储后端：插件贡献一家网盘的协议实现（登录、文件操作），主程序负责账号、调度与界面",
)


# ---------------------------------------------------------------------- 序列化（进程外运行）


def backend_spec(backend: DriveBackend) -> dict[str, Any]:
    caps = backend.capabilities
    login = backend.login
    return {
        "type": backend.type,
        "title": backend.title,
        "description": backend.description,
        "accent_color": backend.accent_color,
        "capabilities": {
            "writable": caps.writable,
            "rapid_upload_hashes": list(caps.rapid_upload_hashes),
            "range_challenge": caps.range_challenge,
            "list_hashes": caps.list_hashes,
            "change_feed": caps.change_feed,
            "original_link": caps.original_link,
            "link_needs_ua": caps.link_needs_ua,
            "recycle_bin": caps.recycle_bin,
            "default_qps": caps.default_qps,
            "default_daily_budget": caps.default_daily_budget,
            "default_read_slots": caps.default_read_slots,
            "upload_concurrency": caps.upload_concurrency,
            "max_file_bytes": caps.max_file_bytes,
        },
        "login": {
            "scan": login.scan,
            "cookie_domains": list(login.cookie_domains),
            "hint": login.hint,
            "options": [
                {
                    "key": o.key,
                    "label": o.label,
                    "default": o.default,
                    "help": o.help,
                    "choices": [
                        {"value": c.value, "label": c.label, "help": c.help} for c in o.choices
                    ],
                }
                for o in login.options
            ],
        },
    }


def spec_parts(data: dict[str, Any]) -> tuple[Capabilities, Login]:
    caps = dict(data["capabilities"])
    caps["rapid_upload_hashes"] = tuple(caps.get("rapid_upload_hashes") or ())
    login = data["login"]
    return Capabilities(**caps), Login(
        scan=bool(login["scan"]),
        cookie_domains=tuple(login.get("cookie_domains") or ()),
        hint=login.get("hint") or "",
        options=tuple(
            LoginOption(
                key=o["key"],
                label=o["label"],
                default=o["default"],
                help=o.get("help") or "",
                choices=tuple(Choice(**c) for c in o["choices"]),
            )
            for o in login.get("options") or ()
        ),
    )


def result_dict(result: LoginResult) -> dict[str, Any]:
    return {
        "user_id": result.user_id,
        "display_name": result.display_name,
        "credentials": dict(result.credentials),
    }


def result_from(data: dict[str, Any]) -> LoginResult:
    return LoginResult(
        user_id=str(data["user_id"]),
        display_name=str(data["display_name"]),
        credentials={str(k): str(v) for k, v in data["credentials"].items()},
    )


def flow_dict(flow: LoginFlow) -> dict[str, Any]:
    return {
        "flow_id": flow.flow_id,
        "status": flow.status,
        "message": flow.message,
        "qr": flow.qr,
        "result": result_dict(flow.result) if flow.result is not None else None,
    }


def flow_from(data: dict[str, Any]) -> LoginFlow:
    result = data.get("result")
    return LoginFlow(
        flow_id=data["flow_id"],
        status=data["status"],
        message=data.get("message") or "",
        qr=data.get("qr"),
        result=result_from(result) if result else None,
    )


def info_dict(info: AccountInfo) -> dict[str, Any]:
    return {
        "display_name": info.display_name,
        "vip": info.vip,
        "quota_total": info.quota_total,
        "quota_used": info.quota_used,
    }


def info_from(data: dict[str, Any]) -> AccountInfo:
    return AccountInfo(
        display_name=str(data["display_name"]),
        vip=data.get("vip"),
        quota_total=data.get("quota_total"),
        quota_used=data.get("quota_used"),
    )


def account_dict(account: DriveAccount) -> dict[str, Any]:
    return {"user_id": account.user_id, "credentials": dict(account.credentials)}


def account_from(data: dict[str, Any]) -> DriveAccount:
    return DriveAccount(
        user_id=str(data["user_id"]),
        credentials={str(k): str(v) for k, v in (data.get("credentials") or {}).items()},
    )


__all__ = [
    "DRIVE_BACKENDS",
    "AccountInfo",
    "ApiChanged",
    "AuthExpired",
    "Capabilities",
    "Choice",
    "Conflict",
    "DriveAccount",
    "DriveBackend",
    "DriveError",
    "Login",
    "LoginFlow",
    "LoginOption",
    "LoginResult",
    "NotFound",
    "QuotaExceeded",
    "RateLimited",
    "RiskControl",
    "Transient",
]

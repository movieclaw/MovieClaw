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

**登录方式**：扫码（``begin_login`` 一族）、Cookie（``login_with_cookie``）、填表
（``login_with_form``）。填表适合开放平台的 Client ID / 密钥、WebDAV 的地址与密码这类
「用户填几项、插件验一次」的网盘：``Login(form=Credentials)`` 声明一个 pydantic 模型，
主程序按它画表单（``SecretStr`` 字段按密码框画、不回显）::

    class Credentials(BaseModel):
        client_id: str = Field(title="Client ID")
        client_secret: SecretStr = Field(title="Client Secret")

    class Pan123(DriveBackend):
        login = Login(form=Credentials)

        async def login_with_form(self, values: dict[str, Any]) -> LoginResult:
            creds = Credentials.model_validate(values)   # 不合格抛 ValueError
            token = await self._token(creds)              # 真去换一次令牌，密钥不对抛 AuthExpired
            me = await self._me(token)                    # 拿真实的网盘用户 id
            return LoginResult(user_id=me.uid, display_name=me.nickname, credentials={...})

令牌由长期密钥换来（client credentials）的，把密钥与令牌、过期时间一起放进 ``credentials``，
令牌快过期时在调用里重新换、赋给 ``account.credentials`` 即可。

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

    #: 能不能写（上传、移动、删除）；只读网盘目前不支持，须为 True 并实现上传与删除
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
    #: 填表登录的字段（pydantic 模型，实现 ``login_with_form``）；None = 不支持。
    #: 进程外运行时宿主这边拿到的是已经转好的 JSON Schema（dict）
    form: Any = None
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


@dataclass(frozen=True, slots=True)
class DirectLink:
    """一个文件的直链。不带请求头：要带头才能访问的直链，302 出去的播放器也不会带。"""

    url: str
    #: 这条链接能复用多久（秒）；主程序按它缓存，最长一小时
    expires_in: float = 300.0


@dataclass(frozen=True, slots=True)
class RemoteFile:
    """网盘上的一个文件（核验、对账、纳管用）。"""

    remote_id: str
    name: str
    size: int
    #: 网盘给的 SHA1（大写十六进制）；不给就是 None
    sha1: str | None = None
    #: 所在目录的 id
    parent_id: str | None = None
    #: ``list_tree`` 里：相对被列目录的路径（含文件名，``/`` 分隔），其余方法不填
    rel_path: str | None = None


@dataclass(frozen=True, slots=True)
class RemoteDir:
    """目录选择器里的一个子目录（``list_dir``）。"""

    remote_id: str
    name: str
    #: 底下还有没有子目录（决定能不能展开）；不知道就是 None
    has_children: bool | None = None
    #: 目录里（含子目录）的视频文件数：网盘的目录信息直接给的才填，不要为它遍历
    video_count: int | None = None


@dataclass(frozen=True, slots=True)
class RemoteTree:
    """一个目录下整棵树的文件（``list_tree``，纳管与每周复查用）。"""

    #: 全部文件（不只视频，主程序自己挑），``rel_path`` 必填
    files: tuple[RemoteFile, ...] = ()
    #: 全部子目录的 id（不含被列目录自己）：主程序据此判断操作动态落没落在库里
    dir_ids: tuple[str, ...] = ()


#: 操作动态的种类：新文件 / 文件或目录被删 / 移动 / 改名 / 新建目录
ChangeKind = Literal["added", "removed", "moved", "renamed", "dir_created"]


@dataclass(frozen=True, slots=True)
class Change:
    """操作动态里的一条（``changes``）。"""

    kind: ChangeKind
    remote_id: str
    is_dir: bool = False
    name: str = ""
    #: 现在所在的目录；删除时是原来所在的目录（网盘不给就是 None）
    parent_id: str | None = None


@dataclass(frozen=True, slots=True)
class ChangePage:
    #: 下次从这里接着拉
    cursor: str
    changes: tuple[Change, ...] = ()
    #: 还有没拉完的（主程序接着拉）
    has_more: bool = False


#: 指纹里「文件头」的长度（115 秒传的 preid）
HEAD_BYTES = 128 * 1024


@dataclass(frozen=True, slots=True)
class Fingerprint:
    """宿主一次顺序读算好的本地文件指纹（哈希都是大写十六进制）。"""

    size: int
    sha1: str
    md5: str
    #: 前 ``HEAD_BYTES`` 字节的 SHA1
    head_sha1: str


@dataclass(frozen=True, slots=True)
class UploadStep:
    """``begin_upload`` 的结论，三选一：

    - ``file``：文件已经在网盘上了（秒传命中，或续传时发现早就传完）；
    - ``need_range``：网盘要校验一段字节（115 的二次校验）。宿主读出 ``(offset, length)`` 这段，带着
      ``state`` 与 ``range_data`` 再调一次 ``begin_upload``；
    - 都没有：要真传。宿主按 ``part_size`` 切片，从第 ``next_part`` 片起逐片调 ``upload_part``，
      最后 ``finish_upload``。最后一片可以小于 ``part_size``；``part_size`` 不小于文件大小就是
      整个文件一片。
    """

    file: RemoteFile | None = None
    need_range: tuple[int, int] | None = None
    part_size: int = 0
    next_part: int = 0
    #: 插件的续传状态（能转成 JSON）。宿主原样保存、原样交回，重启后据此续传
    state: dict[str, Any] = field(default_factory=dict)


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
    ``begin_login`` 一族、``login_with_cookie`` 或 ``login_with_form``，都要实现 ``account_info``；
    取流实现 ``stat`` / ``direct_link``，纳管实现 ``list_dir`` / ``list_tree``（有操作动态再实现
    ``changes``），上传实现 ``ensure_dir`` / ``begin_upload`` / ``upload_part`` /
    ``finish_upload``，删除实现 ``delete``。
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

    # ---- 登录：填表（开放平台的 Client ID / 密钥、WebDAV 地址与密码……）
    async def login_with_form(self, values: dict[str, Any]) -> LoginResult:
        """用户按 ``login.form`` 填的值：真去网盘验一次，交回凭据与**真实的**网盘用户 id。

        ``values`` 只含表单里声明的字段（必填项主程序已查过非空）。凭据不对抛 ``AuthExpired``，
        填得不合格抛 ``ValueError``；限流、网络错误照常抛对应的异常，不要都归成凭据不对。
        """
        raise NotImplementedError

    # ---- 账号
    async def account_info(self, account: DriveAccount) -> AccountInfo:
        raise NotImplementedError

    # ---- 目录（纳管）
    async def list_dir(self, account: DriveAccount, dir_id: str) -> list[RemoteDir]:
        """列一个目录的**子目录**（目录选择器按需展开）。``dir_id`` 为空串表示网盘根目录。"""
        raise NotImplementedError

    async def list_tree(self, account: DriveAccount, dir_id: str) -> RemoteTree:
        """一次拉回目录下整棵树的文件（相对路径、大小、哈希、文件 id）。

        用网盘的整树列举接口，不要逐个目录往下列；目录不存在抛 ``NotFound``。
        """
        raise NotImplementedError

    async def changes(self, account: DriveAccount, cursor: str | None) -> ChangePage:
        """操作动态增量（``capabilities.change_feed`` 为真才会被调）。

        ``cursor`` 为 None 表示从现在开始：只返回当前游标，不返回历史动态。动态不全（漏记复制、
        改名）没关系，主程序每周还会复查一次。
        """
        raise NotImplementedError

    # ---- 上传
    async def ensure_dir(self, account: DriveAccount, parent_id: str, path: str) -> str:
        """在 ``parent_id`` 下逐级找或建 ``path``（``/`` 分隔），返回最里层的目录 id。

        ``path`` 为空串时返回 ``parent_id`` 本身。同名目录已存在就直接用。
        """
        raise NotImplementedError

    async def begin_upload(
        self,
        account: DriveAccount,
        dir_id: str,
        name: str,
        fingerprint: Fingerprint,
        state: dict[str, Any] | None,
        range_data: bytes | None,
    ) -> UploadStep:
        """开始（或续上）一次上传：先试秒传，不中就交回真传的切片方式与续传状态。

        ``state`` 不为空表示续传（宿主重启后交回上次的状态）：核对网盘那边的进度，交回从第几片
        接着传。``range_data`` 是上一步 ``need_range`` 要的那段字节。同名文件已存在时按内容判断：
        同大小同哈希就当传完了（返回 ``file``），否则抛 ``Conflict``。
        """
        raise NotImplementedError

    async def upload_part(
        self, account: DriveAccount, state: dict[str, Any], index: int, data: bytes
    ) -> dict[str, Any]:
        """传第 ``index`` 片（从 0 起），返回新的续传状态。

        网络错误不要自己重试，抛 ``Transient``。
        """
        raise NotImplementedError

    async def finish_upload(self, account: DriveAccount, state: dict[str, Any]) -> RemoteFile:
        """全部分片传完：合并并返回网盘上的文件（之后宿主还会 ``stat`` 核验大小与哈希）。"""
        raise NotImplementedError

    # ---- 删除
    async def delete(self, account: DriveAccount, remote_ids: list[str]) -> None:
        """删掉这些文件。网盘有回收站就进回收站（``capabilities.recycle_bin``），不要清回收站。

        主程序只传台账里的文件 id，只在用户确认的删除与回收站清理时调用，一次最多 100 个。
        已经不在的文件当删成功（不抛 ``NotFound``）。
        """
        raise NotImplementedError

    # ---- 文件
    async def stat(self, account: DriveAccount, remote_id: str) -> RemoteFile:
        """一个文件的大小与哈希；不存在抛 ``NotFound``。"""
        raise NotImplementedError

    async def direct_link(
        self, account: DriveAccount, remote_id: str, user_agent: str
    ) -> DirectLink:
        """取直链。直链按 ``user_agent`` 签发的网盘，必须用它取（播放器跟随跳转时 UA 一致）。

        主程序自己读（转发、转码、抽字幕）时传主程序的 UA，给播放器 302 时传播放器的 UA。
        对已删除的文件取链容易触发风控：主程序只对已核验、没进回收站的副本取链。
        """
        raise NotImplementedError


#: 网盘插件往这个注册表贡献后端（贡献 id 随意，按 ``type`` 识别）
DRIVE_BACKENDS: RegistryKey[DriveBackend] = RegistryKey(
    "drive-backends",
    # 1.1：stat / direct_link（取流）；1.2：list_dir / list_tree / changes（纳管）；
    # 1.3：ensure_dir / begin_upload / upload_part / finish_upload（上传）；1.4：delete；
    # 1.5：Login.form / login_with_form（填表登录）
    version="1.5",
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
            "form": form_schema(login),
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
        form=login.get("form"),
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


def form_schema(login: Login) -> dict[str, Any] | None:
    """填表登录的 JSON Schema（``config_schema`` 子集）；没有表单为 None。

    进程外的后端交来的已经是 dict；模型超出子集抛 ``SchemaNotSupported``（插件写错了，加载时暴露）。
    """
    if login.form is None:
        return None
    if isinstance(login.form, dict):
        return login.form
    from movieclaw_sdk.config_schema import config_schema

    return config_schema(login.form)


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


def link_dict(link: DirectLink) -> dict[str, Any]:
    return {"url": link.url, "expires_in": link.expires_in}


def link_from(data: dict[str, Any]) -> DirectLink:
    return DirectLink(url=str(data["url"]), expires_in=float(data.get("expires_in") or 300.0))


def remote_file_dict(item: RemoteFile) -> dict[str, Any]:
    return {
        "remote_id": item.remote_id,
        "name": item.name,
        "size": item.size,
        "sha1": item.sha1,
        "parent_id": item.parent_id,
        "rel_path": item.rel_path,
    }


def remote_file_from(data: dict[str, Any]) -> RemoteFile:
    return RemoteFile(
        remote_id=str(data["remote_id"]),
        name=str(data["name"]),
        size=int(data["size"]),
        sha1=data.get("sha1"),
        parent_id=data.get("parent_id"),
        rel_path=data.get("rel_path"),
    )


def remote_dir_dict(item: RemoteDir) -> dict[str, Any]:
    return {
        "remote_id": item.remote_id,
        "name": item.name,
        "has_children": item.has_children,
        "video_count": item.video_count,
    }


def remote_dir_from(data: dict[str, Any]) -> RemoteDir:
    return RemoteDir(
        remote_id=str(data["remote_id"]),
        name=str(data["name"]),
        has_children=data.get("has_children"),
        video_count=data.get("video_count"),
    )


def tree_dict(tree: RemoteTree) -> dict[str, Any]:
    return {
        "files": [remote_file_dict(f) for f in tree.files],
        "dir_ids": list(tree.dir_ids),
    }


def tree_from(data: dict[str, Any]) -> RemoteTree:
    return RemoteTree(
        files=tuple(remote_file_from(f) for f in data.get("files") or ()),
        dir_ids=tuple(str(d) for d in data.get("dir_ids") or ()),
    )


def fingerprint_dict(fp: Fingerprint) -> dict[str, Any]:
    return {"size": fp.size, "sha1": fp.sha1, "md5": fp.md5, "head_sha1": fp.head_sha1}


def fingerprint_from(data: dict[str, Any]) -> Fingerprint:
    return Fingerprint(
        size=int(data["size"]),
        sha1=str(data["sha1"]),
        md5=str(data["md5"]),
        head_sha1=str(data["head_sha1"]),
    )


def upload_step_dict(step: UploadStep) -> dict[str, Any]:
    return {
        "file": remote_file_dict(step.file) if step.file is not None else None,
        "need_range": list(step.need_range) if step.need_range is not None else None,
        "part_size": step.part_size,
        "next_part": step.next_part,
        "state": step.state,
    }


def upload_step_from(data: dict[str, Any]) -> UploadStep:
    need = data.get("need_range")
    return UploadStep(
        file=remote_file_from(data["file"]) if data.get("file") else None,
        need_range=(int(need[0]), int(need[1])) if need else None,
        part_size=int(data.get("part_size") or 0),
        next_part=int(data.get("next_part") or 0),
        state=dict(data.get("state") or {}),
    )


def change_page_dict(page: ChangePage) -> dict[str, Any]:
    return {
        "cursor": page.cursor,
        "has_more": page.has_more,
        "changes": [
            {
                "kind": c.kind,
                "remote_id": c.remote_id,
                "is_dir": c.is_dir,
                "name": c.name,
                "parent_id": c.parent_id,
            }
            for c in page.changes
        ],
    }


def change_page_from(data: dict[str, Any]) -> ChangePage:
    return ChangePage(
        cursor=str(data["cursor"]),
        has_more=bool(data.get("has_more")),
        changes=tuple(
            Change(
                kind=c["kind"],
                remote_id=str(c["remote_id"]),
                is_dir=bool(c.get("is_dir")),
                name=c.get("name") or "",
                parent_id=c.get("parent_id"),
            )
            for c in data.get("changes") or ()
        ),
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
    "Change",
    "ChangePage",
    "Choice",
    "Conflict",
    "DirectLink",
    "DriveAccount",
    "DriveBackend",
    "DriveError",
    "Fingerprint",
    "Login",
    "LoginFlow",
    "LoginOption",
    "LoginResult",
    "NotFound",
    "QuotaExceeded",
    "RateLimited",
    "RemoteDir",
    "RemoteFile",
    "RemoteTree",
    "RiskControl",
    "Transient",
    "UploadStep",
]

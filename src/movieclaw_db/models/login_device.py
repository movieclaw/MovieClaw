from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, Column
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin
from movieclaw_db.models.member_scoped import MemberScopedMixin, register_member_scoped


@register_member_scoped
class LoginDevice(MemberScopedMixin, TimestampMixin, table=True):
    """登录设备：一个人授权给一台客户端的一枚长期凭证（docs/design/login-devices.md）。

    一行 = 「谁」×「哪台客户端」。网页浏览器的登录会话、原生 App、命令行、
    转码器、网页手工创建的令牌都落在这里——签发方式各不相同（输密码 / 配对码
    批准 / 手工创建），但存储、验证、列表、注销走同一套：

    - **凭证只存哈希**：``token_hash`` 是令牌明文的 sha256。明文只在签发那一刻
      交给客户端一次，服务端不可再回显；验签按哈希直接查唯一索引。
    - **权限不落库**：行里只记「属于谁」（``member_id``，0=超管哨兵）和「是什么
      客户端」（``kind``）；能做什么在每次验签时按主人当前的身份装配，管理员事后
      改成员的能力开关，令牌立刻跟着变。唯一例外是 ``scope``——转码器的凭证被
      收窄到「只能转码」，这是客户端形态的上限，不是人的权限。
    - **成员级数据**：删除成员时由 ``register_member_scoped`` 登记的统一清理把
      这个人的设备全部删掉（SQLite 会复用成员 id，漏删等于把凭证过继给下一个人）。
    """

    __tablename__ = "login_device"

    id: int | None = Field(default=None, primary_key=True)

    # 客户端类型：web（浏览器）/ ios / tvos / macos / android（原生 App）/
    # cli（命令行）/ worker（转码器）/ manual（网页手工创建的令牌）。
    # 决定两件事：能不能签发新凭证（人直接操作的客户端才能），以及改密时
    # 属于哪一类（密码换来的随改密下线；配对换来的默认保留）。
    kind: str = Field(index=True, description="客户端类型")
    name: str = Field(description="给人看的设备名，可改名")
    token_hash: str = Field(unique=True, index=True, description="令牌明文的 sha256")
    scope: str = Field(default="full", description="full=等同本人；transcode=只能转码")
    # 客户端自报的安装标识：同一台设备、同一个人重新登录时据此替换旧行，
    # 而不是越积越多。网页会话没有它（退出登录会删行，过期会清理）。
    installation_id: str | None = Field(default=None, index=True, description="客户端安装标识")
    client_version: str | None = Field(default=None, description="客户端版本")
    platform: str | None = Field(default=None, description="系统与机型，如 iOS 26.0 · iPhone18,4")
    user_agent: str | None = Field(default=None, description="最近一次请求的 User-Agent")
    last_seen_at: datetime | None = Field(default=None, description="最近活跃时间（分钟粒度）")
    last_seen_ip: str | None = Field(default=None, description="最近活跃的来源地址")
    # 只有网页会话有过期时间（沿用 7 天 / 记住我 30 天）；App、命令行、转码器
    # 长期有效，失效只靠注销——自动过期等于让用户某天莫名其妙掉线。
    expires_at: datetime | None = Field(default=None, description="过期时间；空=长期有效")

    # -- App 推送登记（docs/design/cloud-push.md §4）------------------------------
    # 只有 App 类设备（ios / tvos / android）会登记：App 用这台设备自己的凭证把 APNs
    # 令牌和解密密钥交给实例。跟着这一行走——退出登录、注销设备、删除成员时随行删除，
    # 不会留下一个还能往别人手机上推的登记。密钥是这台设备解密推送内容用的，加密存储。
    push_token: str | None = Field(default=None, description="APNs 设备令牌（十六进制）")
    push_topic: str | None = Field(default=None, description="App 的 Bundle ID")
    push_environment: str | None = Field(
        default=None, description="production / development（调试版是 development）"
    )
    push_types: list | None = Field(
        default=None,
        sa_column=Column(JSON, nullable=True),
        description="这台设备支持的推送类型，如 [\"alert\"]",
    )
    push_key_id: str | None = Field(default=None, description="解密密钥的 key_id（随机值）")
    push_key: str | None = Field(default=None, description="解密密钥（SecretBox 加密存储）")
    push_permission: str | None = Field(
        default=None, description="系统通知权限：authorized / provisional / denied ……"
    )
    push_problem: str | None = Field(
        default=None, description="推送暴露的问题：bad_token（令牌和环境对不上等）"
    )
    push_registered_at: datetime | None = Field(default=None, description="最近一次登记时间")

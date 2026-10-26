from __future__ import annotations

import urllib.parse
from datetime import UTC, datetime
from typing import Any, Literal

from pydantic import Field, field_serializer

from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.services.auth_factory import required_fields
from movieclaw_db.models.site_credential import AuthType, ConfigStatus, SiteCredential
from movieclaw_db.models.site_torrent import SiteSyncCursor
from movieclaw_db.models.site_user_profile import SiteUserProfile
from movieclaw_tracker.registry import SiteConfig

# ---------------------------------------------------------------------------
# 目录（可选项）相关
# ---------------------------------------------------------------------------


class AuthTypeRequirement(BaseModel):
    """某授权类型及其要求用户填写的字段，供前端渲染表单。"""

    auth_type: AuthType
    required_fields: list[str] = Field(description="该授权类型需要填写的字段名")


class CatalogItem(BaseModel):
    """目录项：一个系统支持的可配置站点。"""

    site_id: str
    display_name: str
    base_url: str
    supported_auth_types: list[AuthTypeRequirement] = Field(
        description="支持的授权类型及各自的必填字段"
    )

    @classmethod
    def from_config(cls, config: SiteConfig) -> CatalogItem:
        """从 registry 的 SiteConfig 构造目录项，附带每种授权类型的必填字段。"""
        reqs = [
            AuthTypeRequirement(
                auth_type=AuthType(t),
                required_fields=list(required_fields(AuthType(t))),
            )
            for t in config.supported_auth_types
        ]
        return cls(
            site_id=config.site_id,
            display_name=config.display_name,
            base_url=config.base_url,
            supported_auth_types=reqs,
        )


# ---------------------------------------------------------------------------
# 已配置站点相关
# ---------------------------------------------------------------------------


class SiteUserProfileView(BaseModel):
    """站点用户资料快照的对外视图（数据来源见 SiteUserProfile 模型）。

    上传/下载量只回传字节数，由前端统一格式化；``ratio`` 为 None 表示站点
    未提供（与 0.0 —— 真实无上传 —— 含义不同，前端应显示为"—"）。
    """

    username: str
    user_class: str = ""
    uploaded_bytes: int = 0
    downloaded_bytes: int = 0
    ratio: float | None = None
    bonus: float | None = None
    seeding_count: int = 0
    leeching_count: int = 0
    fetched_at: datetime

    @field_serializer("fetched_at")
    def _serialize_utc(self, value: datetime) -> str:
        """库内 naive UTC 补时区标记再输出，理由见 ConfiguredSite._serialize_utc。"""
        if value.tzinfo is None:
            value = value.replace(tzinfo=UTC)
        return value.isoformat()

    @classmethod
    def from_model(cls, row: SiteUserProfile) -> SiteUserProfileView:
        return cls(
            username=row.username,
            user_class=row.user_class,
            uploaded_bytes=row.uploaded_bytes,
            downloaded_bytes=row.downloaded_bytes,
            ratio=row.ratio,
            bonus=row.bonus,
            seeding_count=row.seeding_count,
            leeching_count=row.leeching_count,
            fetched_at=row.fetched_at,
        )


class ConfiguredSite(BaseModel):
    """已配置站点的对外视图（**脱敏**：绝不回传 cookie/api_key/密码）。"""

    site_id: str
    auth_type: AuthType
    enabled: bool
    status: ConfigStatus
    usable: bool = Field(description="是否可用 = 已启用且验证通过（status=active）")
    protected: bool = Field(
        default=False, description="站点保护开关：订阅链路绕开该站，手动搜索/下载不受影响"
    )
    boost_enabled: bool = Field(default=False, description="自动刷分享率开关")
    boost_paused: bool = Field(
        default=False,
        description="刷流暂停中：做种压到极低上传限速，停止汰换与拉新种（任务保留）",
    )
    boost_budget_bytes: int = Field(default=0, description="刷流存储预算（字节）")
    boost_hold_days: int = Field(default=3, description="刷流汰换最低保留天数；0=不保护")
    boost_downloader_id: int | None = Field(
        default=None, description="刷流投递的下载器 id；null=跟随默认下载器"
    )
    last_verified_at: datetime | None = Field(default=None, description="最近验证成功时间")
    last_checked_at: datetime | None = Field(default=None, description="最近验证尝试时间")
    last_error: str | None = Field(default=None, description="最近验证失败原因（清晰中文）")
    profile: SiteUserProfileView | None = Field(
        default=None, description="站点用户资料快照；从未验证成功过则为 null"
    )
    created_at: datetime
    updated_at: datetime

    @field_serializer("last_verified_at", "last_checked_at", "created_at", "updated_at")
    def _serialize_utc(self, value: datetime | None) -> str | None:
        """把库内的 naive UTC 时间序列化为**带 UTC 时区标记**的 ISO 串。

        全库时间统一存 naive UTC（见 movieclaw_db.models.base.utcnow）。若原样输出，
        得到的是无时区后缀的串（如 ``2026-07-09T10:00:00``）。前端 ``new Date()``
        会按 ECMAScript 规范把它当作**本地时间**解析，东八区用户于是看到
        "刚验证完却显示 8 小时前"的错位。这里补上 ``+00:00``，让前端正确按 UTC 解析。
        """
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=UTC)
        return value.isoformat()

    @classmethod
    def from_model(
        cls, row: SiteCredential, profile: SiteUserProfile | None = None
    ) -> ConfiguredSite:
        """从 ORM 记录构造脱敏视图。只挑选可公开字段，天然屏蔽敏感信息。

        ``profile`` 为该站点的用户资料快照（可选）——从未验证成功过的站点没有。
        """
        return cls(
            site_id=row.site_id,
            auth_type=row.auth_type,
            enabled=row.enabled,
            status=row.status,
            usable=row.enabled and row.status == ConfigStatus.ACTIVE,
            protected=row.protected,
            boost_enabled=row.boost_enabled,
            boost_paused=row.boost_paused,
            boost_budget_bytes=row.boost_budget_bytes,
            boost_hold_days=row.boost_hold_days,
            boost_downloader_id=row.boost_downloader_id,
            last_verified_at=row.last_verified_at,
            last_checked_at=row.last_checked_at,
            last_error=render_value(row.last_error_ref) if row.last_error_ref else row.last_error,
            profile=SiteUserProfileView.from_model(profile) if profile else None,
            created_at=row.created_at,
            updated_at=row.updated_at,
        )


class SiteSyncStatsView(BaseModel):
    """站点种子缓存与同步节奏的对外视图（数据来源见 SiteTorrent / SiteSyncCursor）。

    供站点配置页展示「本地缓存了多少、上次/下次什么时候同步」。可空语义：
    - ``last_sync_at`` 为 None = 从未同步过；
    - ``next_sync_at`` 为 None = 立即到期（新站等待首刷）；
    - ``last_error`` 为 None = 上次同步成功。
    """

    torrent_count: int = Field(description="该站点已缓存的种子数")
    tracking_since: datetime | None = Field(default=None, description="开始跟踪时间(t0)")
    last_sync_at: datetime | None = Field(default=None, description="上次同步完成时间")
    last_success_at: datetime | None = Field(
        default=None, description="上次同步成功时间；None=从未成功"
    )
    next_sync_at: datetime | None = Field(
        default=None, description="下次同步到期时刻；None=立即到期"
    )
    sync_interval_seconds: int | None = Field(default=None, description="当前自适应轮询间隔（秒）")
    last_new_count: int | None = Field(default=None, description="上次同步新增种子数")
    last_error: str | None = Field(default=None, description="上次同步失败原因；成功为 None")
    consecutive_failures: int = Field(default=0, description="连续同步失败次数；成功清零")

    @field_serializer("tracking_since", "last_sync_at", "last_success_at", "next_sync_at")
    def _serialize_utc(self, value: datetime | None) -> str | None:
        """库内 naive UTC 补时区标记再输出，理由见 ConfiguredSite._serialize_utc。"""
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=UTC)
        return value.isoformat()

    @classmethod
    def from_parts(cls, count: int, cursor: SiteSyncCursor | None) -> SiteSyncStatsView:
        """由「缓存计数 + 同步游标」组装视图。二者可能只有其一：
        刚加站还没同步过只有游标，游标被清但快照残留则只有计数。"""
        return cls(
            torrent_count=count,
            tracking_since=cursor.tracking_since if cursor else None,
            last_sync_at=cursor.last_sync_at if cursor else None,
            last_success_at=cursor.last_success_at if cursor else None,
            next_sync_at=cursor.next_sync_at if cursor else None,
            sync_interval_seconds=cursor.sync_interval_seconds if cursor else None,
            last_new_count=cursor.last_new_count if cursor else None,
            last_error=(
                render_value(cursor.last_error_ref) if cursor.last_error_ref else cursor.last_error
            )
            if cursor
            else None,
            consecutive_failures=cursor.consecutive_failures if cursor else 0,
        )


class SiteConfigCreate(BaseModel):
    """配置/更新站点的请求体。

    按所选 auth_type 填写对应字段；未用到的字段留空即可（服务端会校验必填项）：
    - cookie      → cookie 字符串
    - apikey      → api_key
    - credential  → username + password
    """

    site_id: str = Field(
        description="要配置的站点标识，须来自站点目录（CLI：mclaw site catalog）"
    )
    auth_type: AuthType = Field(description="选用的授权类型，须在该站点 supported 列表内")
    cookie: str | None = Field(default=None, description="COOKIE 模式：浏览器 cookie 字符串")
    api_key: str | None = Field(default=None, description="APIKEY 模式：API 密钥")
    username: str | None = Field(default=None, description="CREDENTIAL 模式：用户名")
    password: str | None = Field(default=None, description="CREDENTIAL 模式：密码")
    enabled: bool = Field(default=True, description="是否启用（默认启用）")


class SiteConfigUpdate(BaseModel):
    """更新站点授权信息的请求体（site_id 走路径参数，故此处不含）。"""

    auth_type: AuthType = Field(description="选用的授权类型，须在该站点 supported 列表内")
    cookie: str | None = Field(default=None, description="COOKIE 模式：浏览器 cookie 字符串")
    api_key: str | None = Field(default=None, description="APIKEY 模式：API 密钥")
    username: str | None = Field(default=None, description="CREDENTIAL 模式：用户名")
    password: str | None = Field(default=None, description="CREDENTIAL 模式：密码")
    enabled: bool = Field(default=True, description="true=启用 / false=停用")


class SiteStatusUpdate(BaseModel):
    """启用/停用请求体。"""

    enabled: bool = Field(description="true=启用 / false=停用（停用后不再参与搜索与同步）")


class SiteProtectionUpdate(BaseModel):
    """站点保护开关请求体（语义见 docs/design/site-protection-ratio-boost.md）。"""

    protected: bool = Field(
        description="true=保护（订阅链路绕开该站，手动搜索/下载不受影响）/ false=取消保护"
    )


class SiteRatioBoostUpdate(BaseModel):
    """自动刷分享率设置请求体。"""

    enabled: bool = Field(description="true=开启自动刷分享率 / false=关闭")
    budget_bytes: int | None = Field(
        default=None, description="刷流存储预算（字节，≥1 GiB）；None=不修改现有预算"
    )
    hold_days: int | None = Field(
        default=None,
        description="汰换最低保留天数（0～30；0=站点无 H&R、不设保护）；None=不修改",
    )
    downloader_id: int | None = Field(
        default=None,
        description=(
            "刷流投递的下载器 id（开启刷流时为该站选定，可与订阅用的默认下载器分开）；"
            "None=不修改。改选后只影响新抢的种子，已在做种的任务留在原下载器直到汰换"
        ),
    )


class SiteBoostPauseUpdate(BaseModel):
    """刷流暂停/恢复请求体。"""

    paused: bool = Field(
        description=(
            "true=暂停（做种压到极低上传限速、停止汰换与拉新种，任务与数据保留）"
            "/ false=恢复（解除限速，回到正常刷流节奏）"
        )
    )


class SiteBoostStatsView(BaseModel):
    """单个站点的刷流运行统计（数据来源见 RatioBoostTask 台账）。"""

    active_count: int = Field(default=0, description="在池刷流任务数")
    used_bytes: int = Field(default=0, description="在池任务占用的预算（字节）")
    budget_bytes: int = Field(default=0, description="当前预算（字节）")
    uploaded_bytes_total: int = Field(
        default=0, description="刷流累计上传量（含已汰换任务的历史贡献，字节）"
    )
    evicted_count: int = Field(default=0, description="累计汰换任务数")
    # 近期窗口指标（来自小时桶统计）：支撑"近 24 小时用 X GB 种子贡献 Y GB 上传"
    uploaded_bytes_24h: int = Field(default=0, description="近 24 小时上传量（字节）")
    avg_used_bytes_24h: int = Field(default=0, description="近 24 小时平均在池体积（字节）")
    uploaded_bytes_7d: int = Field(default=0, description="近 7 天上传量（字节）")
    avg_used_bytes_7d: int = Field(default=0, description="近 7 天平均在池体积（字节）")



# ---------------------------------------------------------------------------
# 刷流在池概况与清理（docs/design/site-protection-ratio-boost.md §2.9）
# ---------------------------------------------------------------------------


class BoostPoolTaskView(BaseModel):
    """在池刷流任务的清理相关状态（逐种子，供界面在对应行上标注）。"""

    info_hash: str = Field(description="种子 infohash（小写）")
    site_id: str = Field(description="站点标识")
    protected_until: datetime | None = Field(
        default=None,
        description="保留期到期时刻（站点保留天数与 H&R 考核时长取大）；null=现在删不涉及保留期",
    )
    cleanup_scheduled: bool = Field(
        default=False, description="已请求清理，等保留期满（或下载器恢复可达）后自动删除"
    )


class BoostPoolSiteView(BaseModel):
    """某站点在池刷流种子的概况：开关状态、体积、能否立即删。"""

    site_id: str = Field(description="站点标识")
    site_name: str = Field(description="站点显示名")
    boost_enabled: bool = Field(description="该站当前是否开着刷流（站点配置已删除时为 false）")
    boost_paused: bool = Field(description="该站刷流是否处于暂停")
    task_count: int = Field(description="在池种子数")
    size_bytes: int = Field(description="在池种子总体积（字节）")
    deletable_count: int = Field(description="现在就能删的种子数（已过保留期或未下完）")
    deletable_bytes: int = Field(description="现在就能删的体积（字节）")
    protected_count: int = Field(description="还在保留期内的种子数（现在删可能被记 H&R）")
    protected_bytes: int = Field(description="还在保留期内的体积（字节）")
    protected_until: datetime | None = Field(
        default=None, description="保留期内种子里最晚的到期时刻；null=没有保留期内的种子"
    )
    scheduled_count: int = Field(description="已请求清理、等待自动删除的种子数")


class BoostPoolView(BaseModel):
    """刷流在池概况：按站点汇总 + 逐种子的清理状态。"""

    sites: list[BoostPoolSiteView] = Field(default_factory=list, description="有在池种子的站点")
    tasks: list[BoostPoolTaskView] = Field(default_factory=list, description="在池种子的清理状态")


class BoostCleanupRequest(BaseModel):
    """清理残留刷流种子的请求体。"""

    site_ids: list[str] | None = Field(
        default=None, description="只清理这些站点；null=全部有在池种子的站点"
    )
    disable_boost: bool = Field(
        default=True,
        description="先关闭这些站点的刷流（不关的话引擎几分钟内会重新拉新种）",
    )
    force: bool = Field(
        default=False,
        description=(
            "true=保留期内的也立即删除（可能被站点记 H&R）；"
            "false=保留期内的先标记，到期后由引擎自动删除"
        ),
    )


class BoostCleanupResult(BaseModel):
    """清理结果。"""

    deleted_count: int = Field(description="已连数据删除的种子数")
    deleted_bytes: int = Field(description="已释放的体积（字节）")
    scheduled_count: int = Field(description="保留期内、已标记到期自动删除的种子数")
    scheduled_until: datetime | None = Field(
        default=None, description="标记的种子里最晚的到期时刻"
    )
    failed_count: int = Field(
        description="下载器不可达等原因这次没删成的种子数（已标记，下一轮巡检自动重试）"
    )
    disabled_sites: list[str] = Field(
        default_factory=list, description="本次顺带关闭了刷流的站点"
    )


# ---------------------------------------------------------------------------
# 站点代请求（site.proxy.request）
# ---------------------------------------------------------------------------


class SiteProxyRequest(BaseModel):
    """插件借宿主已认证会话对站点发出的一个请求（凭据不出宿主）。

    ``path`` 只能是站内相对路径（如 ``attendance.php``、``/api/member/updateLastBrowse``），
    完整 URL 由宿主按站点注册的域名拼接——插件无法指定任意主机，杜绝 SSRF。
    ``base`` 在站点自己的请求域名与网页域名之间选择（API 类站点两者不同）。
    ``headers`` 里与认证相关的头（cookie / authorization / x-api-key 等）会被剥除：
    认证头由宿主会话自动附加，插件传不进也覆盖不了。
    站点回 3xx 时**不跟随**，原样返回（目标在 ``headers.location``）：认证头只发给上面
    校验过的那一个 URL，不会因为站点的开放重定向被带到别的主机；想跟的话插件自己
    再发一次站内路径的请求。
    """

    method: Literal["GET", "POST"] = Field(description="HTTP 方法（保活场景只需要这两种）")
    path: str = Field(
        min_length=1,
        max_length=512,
        description="站内相对路径，以 / 或字母开头；不允许出现协议或 //",
    )
    base: Literal["web", "api"] = Field(
        default="web",
        description="用站点的网页域名（web）还是请求域名（api）拼 URL；两者相同时无差别",
    )
    headers: dict[str, str] = Field(
        default_factory=dict,
        max_length=16,
        description="插件补充的非敏感请求头（如 referer / content-type）",
    )
    body: dict[str, Any] | str | None = Field(
        default=None, description="POST 体：字典按 JSON 发送，字符串按原始内容发送"
    )
    timeout_seconds: float = Field(default=30.0, ge=1.0, le=120.0, description="超时（秒）")


class SiteProxyResponse(BaseModel):
    """站点代请求的响应（已脱敏：凭据相关响应头剥除，正文截断）。

    ``text`` 为正文文本（超出上限时截断，``truncated`` 置真）；JSON 响应会额外给
    解析后的 ``json_body``。二进制内容（图片、种子文件）不回传正文，``text``/``json_body``
    为 null。
    """

    status_code: int = Field(description="HTTP 状态码")
    headers: dict[str, str] = Field(description="安全响应头子集（content-type / location 等）")
    text: str | None = Field(default=None, description="正文文本；二进制内容为 null")
    json_body: Any = Field(default=None, description="JSON 响应解析后的对象；非 JSON 为 null")
    truncated: bool = Field(default=False, description="正文是否因超出上限被截断")


def proxy_path_error(path: str) -> str | None:
    """校验站内相对路径；不合规返回中文原因，合规返回 None。

    独立成函数便于单测覆盖全部拒绝分支。这里只挡「明显想指定别处」的形态
    （``//``、``scheme://``、反斜杠、CRLF）；文件名带点（``attendance.php``）是
    合法路径。真正的安全保证在 ``proxy_same_origin``：拼接后再验证最终 host
    仍等于站点域名，形态校验只是尽早给出可读错误。
    """
    if not path or not path.strip():
        return t("errors.sitePath.empty")
    if path.startswith("//"):
        return t("errors.sitePath.protocolRelative")
    if "://" in path:
        return t("errors.sitePath.scheme")
    if "\\" in path:
        return t("errors.sitePath.backslash")
    if any(ch in path for ch in ("\r", "\n", "\t")):
        return t("errors.sitePath.control")
    return None


def proxy_same_origin(base_url: str, url: str) -> bool:
    """拼接后的完整 URL 是否仍指向站点域名（防 SSRF 的最终防线）。

    相对路径拼接不会换 host，但 ``/\\evil.com``、被编码的协议等构造可能骗过
    简单拼接——统一 ``urlsplit`` 后按 scheme+hostname 比对，不一致即拒绝。
    """
    base = urllib.parse.urlsplit(base_url)
    final = urllib.parse.urlsplit(url)
    return base.scheme == final.scheme and (base.hostname or "") == (final.hostname or "")


def proxy_base_url(config: SiteConfig, base: Literal["web", "api"]) -> str:
    """按 base 选择拼 URL 的域名：web 用网页域名，api 用请求域名。

    独立成函数便于单测；未配置 web_base_url 时两者相同。
    """
    if base == "web" and config.web_base_url:
        return config.web_base_url.rstrip("/")
    return config.base_url.rstrip("/")


def join_proxy_url(base_url: str, path: str) -> str:
    """把站内相对路径拼到站点域名上。路径里的查询串原样保留。"""
    return f"{base_url}/{path.lstrip('/')}"


#: 插件传不进也覆盖不了的请求头：认证由宿主会话统一附加，这里统一剥除。
#: 键按小写比较。set-cookie / www-authenticate 属于响应头黑名单，不在此列。
PROXY_FORBIDDEN_REQUEST_HEADERS = frozenset(
    {
        "cookie",
        "authorization",
        "x-api-key",
        "proxy-authorization",
        "host",
    }
)

#: 不回传给插件的响应头：站点可能借它们下发新会话凭据。
PROXY_FORBIDDEN_RESPONSE_HEADERS = frozenset(
    {
        "set-cookie",
        "www-authenticate",
        "proxy-authenticate",
    }
)

#: 正文回传上限（字符）。保活/签到页面远小于此；超限截断并置 truncated。
PROXY_MAX_TEXT_CHARS = 512 * 1024

#: 判定为二进制（不回传正文）的 content-type 前缀。
PROXY_BINARY_PREFIXES = ("application/octet-stream", "image/", "application/x-bittorrent")


def sanitize_proxy_headers(
    headers: dict[str, str],
    forbidden: frozenset[str] = PROXY_FORBIDDEN_REQUEST_HEADERS,
) -> dict[str, str]:
    """剥除认证相关请求头；键按小写匹配。独立成函数便于单测。"""
    return {k: v for k, v in headers.items() if k.lower() not in forbidden}


def sanitize_proxy_response_headers(
    headers: Any,
    forbidden: frozenset[str] = PROXY_FORBIDDEN_RESPONSE_HEADERS,
) -> dict[str, str]:
    """从 httpx 响应头挑出安全子集（剥 set-cookie 等会话凭据头）。"""
    return {k: v for k, v in headers.items() if k.lower() not in forbidden}


def proxy_response_text(content: bytes, content_type: str) -> tuple[str | None, bool]:
    """按 content-type 决定正文回传形态：文本返回（可能截断），二进制返回 None。

    返回 (text, truncated)。
    """
    lowered = (content_type or "").split(";", 1)[0].strip().lower()
    if lowered.startswith(PROXY_BINARY_PREFIXES):
        return None, False
    try:
        text = content.decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001 - decode 带 errors="replace" 不会抛，防御性兜底
        return None, False
    if len(text) > PROXY_MAX_TEXT_CHARS:
        return text[:PROXY_MAX_TEXT_CHARS], True
    return text, False

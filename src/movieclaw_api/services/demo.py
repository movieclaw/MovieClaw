"""公开演示站模式（``MOVIECLAW_DEMO_MODE``）：只读守卫、登录页账号提示与访客隐私。

设计见 docs/design/demo-site.md。一句话：演示站把超管与几个成员的账号密码
直接公布在登录页，**任何访客都能以超管身份进来**——而超管在正常产品里等价于
服务器控制权（Agent 带 bash、浏览任意目录、接 PT 站点与下载器、应用内更新）。
所以这里的安全模型不是「挡住几个危险接口」，而是三条：

1. **写接口默认拒绝**：一切非 GET/HEAD/OPTIONS 请求一律 403，只放行
   ``ALLOWED_WRITE_OPERATIONS`` 里按 operation_id 显式登记的操作（登录态本身、
   播放链路、只读语义的查询与预览）。新增的写接口不登记就自动被挡——与路由
   分区（api/router.py）的「默认拒绝」同构，漏登记只会让演示站少个功能，
   不会多个口子；
2. **少量读接口也挡**（``BLOCKED_READ_OPERATIONS``）：浏览服务器目录、系统日志
   （含访客 IP）、插件令牌明文、PT 站点目录与种子搜索；
3. **访客之间互不可见**：别的访客的设备名、来源 IP 在输出时脱敏；能写入文字的
   接口本来就被第 1 条挡住——演示站上不出现任何用户生成的内容。

「发现」照常开放（TMDB / 豆瓣榜单），订阅面板也能打开预检，只有确认订阅这一步
被拒并给出说明——演示站不接 PT 站点与下载器，不会真的下载任何东西。

守卫挂在业务路由总装处（app.py），按请求实时读配置：不开演示模式时只多一次
布尔判断，行为与正常产品完全一致。Jellyfin 兼容层不在守卫范围内——它的写接口
只有播放状态（进度 / 已看 / 收藏）与转码协商，没有账号与媒体的写操作。
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import time
from collections import deque
from functools import lru_cache
from pathlib import Path

from pydantic import Field, ValidationError

from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import AppException
from movieclaw_api.schemas.base import BaseModel

logger = logging.getLogger("movieclaw_api.demo")

# 演示站拒绝请求时统一用这个业务码：客户端可据此区分「演示站只读」与
# 「权限不足」（FORBIDDEN），给出不同的提示语气
DEMO_READ_ONLY_CODE = "DEMO_READ_ONLY"

#: 演示资源站的 site_id（movieclaw_tracker/sites/configs/demo.yaml）
DEMO_SITE_ID = "demo"

_SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})

# ---------------------------------------------------------------------------
# 写接口白名单：演示站上唯一允许落库的操作
# ---------------------------------------------------------------------------
# 登记标准：只影响「访客自己这台设备 / 这个浏览器」的登录态，或只写当前账号
# 自己的播放状态，或者语义上是只读的查询 / 预览。改名、删除、上传、改配置、
# 发起下载一律不在此列。
ALLOWED_WRITE_OPERATIONS: frozenset[str] = frozenset(
    {
        # ---- 登录态本身 ----
        "auth.login",
        "auth.logout",
        "auth.device.login",  # 原生 App 用账号密码换设备令牌
        # 原生 App 扫码登录；服务层限制客户端类型，不能借此签发命令行或转码器凭据。
        "auth.device.authorize",
        "auth.device.token",
        "auth.devices.approve",
        "auth.devices.deny",
        "auth.devices.revoke-current",  # 原生 App 退出登录时注销自己这台
        "auth.accounts.switch",  # 网页多账号切换：体验不同角色的主要入口
        "auth.accounts.remove",  # 从本浏览器的账号列表移除：只作废本浏览器持有的令牌
        # ---- 播放链路：起播决策、会话、心跳、进度与诊断上报 ----
        "playback.decide",
        "playback.session.start",
        "playback.session.ping",
        "playback.session.stop",
        "playback.progress",
        "playback.marks.set",  # 收藏 / 已看：只落当前账号自己的播放状态
        "playback.metric.report",
        "playback.client-log",
        "reels.events",  # 刷片曝光与播放事件：只记行为，不修改媒体库
        # ---- AI 助手：对话走预设回复的演示模型，会话按设备隔离（services/demo_agent.py）----
        "session.start",
        "session.stop",
        "session.retry",
        # ---- 只读语义的 POST：查询与预览，不改任何数据 ----
        "search.titles",  # 发现页标题搜索（演示模式下不写搜索历史）
        "ui.subscriptions.preview-title",  # 订阅面板的预检；确认订阅仍被拒
        "library.items.preview-reidentification",
        "workflow.library.organize-files.preview",
        "workflow.library.transfer-items.preview",
        "workflow.library.reconcile-paths.preview",
        "workflow.library.consolidate-roots.preview",
    }
)

# ---------------------------------------------------------------------------
# 读接口黑名单：演示站上即便只读也不该给访客看的
# ---------------------------------------------------------------------------
_PT_MESSAGE = "演示站不提供 PT 站点、订阅下载相关的功能"
_SUBSCRIBE_MESSAGE = "演示站不会真的订阅和下载影片；自己部署 MovieClaw 后即可使用订阅"
BLOCKED_READ_OPERATIONS: dict[str, str] = {
    # 服务器文件系统：演示站的超管是公开的，不能让访客翻服务器目录
    "fs.browse": "演示站不开放服务器目录浏览",
    # 系统日志里有全体访客的来源 IP 与访问记录
    "logs.days": "演示站不开放系统日志（其中含有其他访客的访问记录）",
    "logs.read": "演示站不开放系统日志（其中含有其他访客的访问记录）",
    # 插件同步令牌明文：拿到它就能往站点凭据里写 Cookie
    "extension.token.show": "演示站不提供浏览器插件令牌",
    # PT 站点目录与种子搜索：演示站只展示开放授权内容，不接任何资源站
    "site.catalog": _PT_MESSAGE,
    "search.torrents": _PT_MESSAGE,
    "workflow.search.torrents.stream": _PT_MESSAGE,
    # 完整接口清单：公开账号登录后就能拿到，等于把 /docs 又开了出来
    "system.spec": "演示站不提供接口清单",
    # 转码诊断里有 ffmpeg 输出片段，带服务器上的文件路径
    "playback.session.diagnostics": "演示站不提供转码诊断信息",
    # 新播放记录含访客自报的引擎日志、环境与错误文字；统计的小样本 / 最差记录也会回显。
    "playback.attempt.get": "演示站不提供播放诊断记录（其中含有其他访客的日志）",
    "playback.stats.qoe": "演示站不提供播放诊断统计（其中含有其他访客的记录）",
}

# 按 operation_id 前缀给出更具体的拒绝理由（先匹配先用）；都不匹配时用通用文案。
# 只影响提示语，不影响判定——判定只看上面两张表。
_WRITE_MESSAGES: tuple[tuple[tuple[str, ...], str], ...] = (
    (("auth.password",), "演示账号的密码不能修改"),
    (("auth.profile", "auth.avatar"), "演示账号的昵称与头像不能修改"),
    (("members.",), "演示站不能新增、修改、停用或删除成员"),
    (("auth.bootstrap",), "演示站已完成初始化"),
    (("subscriptions.create",), _SUBSCRIBE_MESSAGE),
    (("playback.activity.",), "演示站不能结束其他人正在进行的播放"),
    (("share.", "shares.", "collection.share", "library.items.share"), "演示站不开放影片分享"),
    (
        ("auth.devices.", "auth.device.", "auth.tokens", "playback.device."),
        "演示站不能管理登录设备与令牌",
    ),
    (
        ("subscriptions.", "dl.", "site.", "rules.", "watch.", "library.missing.redownload"),
        _PT_MESSAGE,
    ),
    (
        ("session.",),
        "演示站的 AI 助手只能对话，不能改名、删除、分叉会话或上传图片",
    ),
    (("llm.",), "演示站使用预设回复的演示模型，不能接入或修改模型"),
    (
        (
            "mcp.",
            "channels.",
            "webhook.",
            "extension.",
            "library.subtitles.generate",
        ),
        "演示站不开放 AI 助手与外部集成",
    ),
    (
        (
            "app.",
            "net.",
            "scrape.",
            "transcode.",
            "appearance.",
            "ui.prefs",
            "playback.policy",
            "discover.region",
            "search.presets",
            "notices.",
            "jobs.",
        ),
        "演示站不能修改系统设置",
    ),
)
_GENERIC_WRITE_MESSAGE = "演示站为只读模式，此操作已禁用"
_DELETE_MESSAGE = "演示站禁止删除操作"
_MEDIA_MESSAGE = "演示站的媒体库与合集是只读的"


def is_demo_mode() -> bool:
    """当前进程是否以公开演示站模式运行（按请求实时读配置，测试可随时切换）。"""
    return get_settings().demo_mode


def ensure_app_pairing_allowed(client_type: str) -> None:
    """公开演示站仅允许原生 App 扫码登录，其他配对凭据继续拒绝。"""
    if is_demo_mode() and client_type not in {"tvos", "macos", "androidtv"}:
        raise AppException(
            code=DEMO_READ_ONLY_CODE,
            message="演示站仅支持 Apple TV、Android TV 和 Mac 扫码登录，不开放命令行或转码器配对",
            status_code=403,
        )


def rejection_for(method: str, operation_id: str) -> str | None:
    """演示模式下判定一个请求：放行返回 None，拒绝返回给人看的理由。

    ``operation_id`` 缺失（理论上不会出现：全部业务路由都有）按未登记处理——
    写请求一律拒绝，读请求放行。
    """
    if method.upper() in _SAFE_METHODS:
        return BLOCKED_READ_OPERATIONS.get(operation_id)
    if operation_id in ALLOWED_WRITE_OPERATIONS:
        return None
    for prefixes, message in _WRITE_MESSAGES:
        if operation_id.startswith(prefixes):
            return message
    if method.upper() == "DELETE" or operation_id.endswith((".delete", ".purge", ".remove")):
        return _DELETE_MESSAGE
    if operation_id.startswith(("library.", "workflow.library.", "collection.", "libraries.")):
        return _MEDIA_MESSAGE
    return _GENERIC_WRITE_MESSAGE


# ---------------------------------------------------------------------------
# 登录页公布的演示账号
# ---------------------------------------------------------------------------


class DemoAccount(BaseModel):
    """登录页公布的一个演示账号（deploy 时由 demo/accounts.json 提供）。"""

    username: str
    password: str
    label: str = Field(description="角色名，如「超级管理员」「家庭成员」")
    description: str = Field(default="", description="一句话说明这个角色能看到什么")


class DemoAccountsFile(BaseModel):
    """demo/accounts.json 的结构：登录页只读 notice 与 accounts，其余字段给建站脚本用。"""

    notice: str = ""
    accounts: list[DemoAccount] = Field(default_factory=list)


@lru_cache(maxsize=1)
def _load_accounts_file(path: str) -> DemoAccountsFile:
    """读取并缓存账号清单。文件缺失或格式错误时记日志并当作空清单——
    提示缺了不影响演示站只读，不能因为它起不来。"""
    if not path:
        return DemoAccountsFile()
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        return DemoAccountsFile.model_validate(raw)
    except (OSError, ValueError, ValidationError) as exc:
        logger.error("演示账号清单读取失败（%s）：%s；登录页将不列出演示账号", path, exc)
        return DemoAccountsFile()


def demo_accounts() -> DemoAccountsFile:
    """当前配置的演示账号清单；未开演示模式时恒为空。"""
    if not is_demo_mode():
        return DemoAccountsFile()
    return _load_accounts_file(get_settings().demo_accounts_file)


def is_public_account(username: str) -> bool:
    """用户名是否是登录页公开的演示账号（大小写不敏感）。

    用途：登录限速对公开账号不生效——密码本来就贴在登录页，防爆破没有意义；
    反倒是按用户名锁定会让一个故意输错密码的访客把全体访客锁在门外 5 分钟。
    """
    wanted = username.strip().lower()
    return any(account.username.lower() == wanted for account in demo_accounts().accounts)


# ---------------------------------------------------------------------------
# App Store 审核账号（demo-site.md §9）
# ---------------------------------------------------------------------------
# 审核员要把 App 里的每个功能真的用一遍，公开账号的只读守卫做不到。审核账号的
# 用户名密码只在部署环境里（MOVIECLAW_DEMO_REVIEW_*），不进仓库、不上登录页；
# 用它登录就是超管，登录时签发的那枚凭证记进审核名单，守卫认出名单里的凭证后
# 只按 REVIEW_BLOCKED_OPERATIONS 拦几条安全底线。名单存在 data/ 下，每日还原时
# 随设备行一起清空。存的是凭证的 sha256，不存明文。

#: 审核账号也不能做的事：换掉部署好的演示版本、改动预先接好的演示资源链路
_REVIEW_PIPELINE_MESSAGE = (
    "演示服务器的资源站点、下载器与自动入库规则是预先配置好的，不能在这里改动"
)
_REVIEW_VERSION_MESSAGE = "演示服务器的版本由部署固定，不能在应用内升级或回退"
REVIEW_BLOCKED_OPERATIONS: dict[str, str] = {
    "app.update.apply": _REVIEW_VERSION_MESSAGE,
    "app.update.rollback": _REVIEW_VERSION_MESSAGE,
    "app.update.model-apply": _REVIEW_VERSION_MESSAGE,
    "site.add": _REVIEW_PIPELINE_MESSAGE,
    "site.update": _REVIEW_PIPELINE_MESSAGE,
    "site.delete": _REVIEW_PIPELINE_MESSAGE,
    "dl.add": _REVIEW_PIPELINE_MESSAGE,
    "dl.update": _REVIEW_PIPELINE_MESSAGE,
    "dl.delete": _REVIEW_PIPELINE_MESSAGE,
    "watch.create": _REVIEW_PIPELINE_MESSAGE,
    "watch.update": _REVIEW_PIPELINE_MESSAGE,
    "watch.delete": _REVIEW_PIPELINE_MESSAGE,
}

_REVIEW_SESSIONS_FILE = "demo-review-sessions.json"
_review_hashes: set[str] | None = None


def review_enabled() -> bool:
    """演示模式下配置了审核密码才启用审核账号。"""
    settings = get_settings()
    return (
        settings.demo_mode
        and bool(settings.demo_review_password)
        and bool(settings.demo_review_username.strip())
    )


def is_review_username(username: str) -> bool:
    """用户名是否是审核账号（大小写不敏感）。"""
    wanted = get_settings().demo_review_username.strip().lower()
    return review_enabled() and username.strip().lower() == wanted


def check_review_password(username: str, password: str) -> bool:
    """审核账号的用户名与密码是否都对上（常量时间比较密码）。"""
    if not is_review_username(username):
        return False
    expected = get_settings().demo_review_password.encode()
    return hmac.compare_digest(password.encode(), expected)


def _review_sessions_path() -> Path:
    return Path(get_settings().data_dir) / _REVIEW_SESSIONS_FILE


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _review_hashes_loaded() -> set[str]:
    global _review_hashes
    if _review_hashes is None:
        try:
            raw = json.loads(_review_sessions_path().read_text(encoding="utf-8"))
            _review_hashes = {str(item) for item in raw}
        except (OSError, ValueError, TypeError):
            _review_hashes = set()
    return _review_hashes


def remember_review_token(token: str) -> None:
    """把审核账号登录时签发的凭证记进名单（写临时文件再替换，不留半截文件）。"""
    hashes = _review_hashes_loaded()
    hashes.add(_token_hash(token))
    path = _review_sessions_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(sorted(hashes)), encoding="utf-8")
    os.replace(tmp, path)
    logger.info("审核账号已登录（名单内凭证 %d 枚）", len(hashes))


def is_review_token(token: str | None) -> bool:
    """这枚凭证是不是审核账号登录时签发的。"""
    if not token or not review_enabled():
        return False
    return _token_hash(token) in _review_hashes_loaded()


def review_rejection_for(method: str, operation_id: str) -> str | None:
    """审核账号的请求：只拦安全底线，其余一律放行（读接口全部放行）。"""
    if method.upper() in _SAFE_METHODS:
        return None
    return REVIEW_BLOCKED_OPERATIONS.get(operation_id)


# ---------------------------------------------------------------------------
# 登录频率：按来源地址限
# ---------------------------------------------------------------------------
# 公开账号不走「按用户名连续失败锁定」（见 is_public_account），但每次登录都要
# 跑一次刻意很慢的密码哈希校验，成功后还会建一条登录设备、生成一套预置对话。
# 不设上限的话，一个脚本就能把 CPU 与磁盘拖垮。所以演示站对**全部**登录请求
# 按来源地址计数（随机用户名也要跑一次哈希，同样要算）：正常访客切几次角色
# 远用不到上限。取不到可信地址时（反代没配 FORWARDED_ALLOW_IPS）所有人落进
# 同一个桶，上限相应放宽——宁可高峰时让人稍等，也不让服务被拖死。
LOGIN_WINDOW_SECONDS = 600
LOGIN_LIMIT_PER_ADDRESS = 30
LOGIN_LIMIT_UNKNOWN_ADDRESS = 600
# 记录的地址数上限：超出时先丢已过窗口的，再丢最早的，防止海量地址注水内存
_MAX_LOGIN_ADDRESSES = 20000
_login_attempts: dict[str, deque[float]] = {}


def ensure_login_allowed(address: str) -> None:
    """演示模式下登录前调用：该来源地址近 10 分钟的登录次数超限时抛 429。

    未开演示模式时什么都不做。每次调用本身计一次（成功失败都算）。
    """
    if not is_demo_mode():
        return
    now = time.monotonic()
    limit = LOGIN_LIMIT_PER_ADDRESS if address else LOGIN_LIMIT_UNKNOWN_ADDRESS
    attempts = _login_attempts.get(address)
    if attempts is None:
        if len(_login_attempts) >= _MAX_LOGIN_ADDRESSES:
            _prune_login_attempts(now)
        attempts = _login_attempts[address] = deque()
    while attempts and now - attempts[0] > LOGIN_WINDOW_SECONDS:
        attempts.popleft()
    if len(attempts) >= limit:
        wait = int(LOGIN_WINDOW_SECONDS - (now - attempts[0])) + 1
        logger.warning("演示站登录过于频繁，来源 %s 已达 %d 次/10 分钟", address or "未知", limit)
        raise AppException(
            status_code=429,
            code="TOO_MANY_ATTEMPTS",
            message=f"登录过于频繁，请 {max(wait, 1)} 秒后再试",
        )
    attempts.append(now)


def _prune_login_attempts(now: float) -> None:
    stale = [
        key
        for key, attempts in _login_attempts.items()
        if not attempts or now - attempts[-1] > LOGIN_WINDOW_SECONDS
    ]
    for key in stale:
        del _login_attempts[key]
    # 全都还在窗口里：丢掉最早登记的一半（dict 保持插入顺序）
    if len(_login_attempts) >= _MAX_LOGIN_ADDRESSES:
        for key in list(_login_attempts)[: _MAX_LOGIN_ADDRESSES // 2]:
            del _login_attempts[key]


def reset_demo_state() -> None:
    """仅供测试：清掉账号清单缓存、登录计数与审核名单缓存。"""
    global _review_hashes
    _load_accounts_file.cache_clear()
    _login_attempts.clear()
    _review_hashes = None


# ---------------------------------------------------------------------------
# 访客隐私：别的访客的设备信息在输出时脱敏
# ---------------------------------------------------------------------------

# 设备名的替代文案：按客户端类型给一个中性称呼，既不泄露访客自填的设备名
# （可能是真名，也可能是故意填的不当文字），又不至于让列表完全看不懂
_DEVICE_KIND_LABELS = {
    "web": "网页浏览器",
    "ios": "iOS 设备",
    "tvos": "Apple TV",
    "macos": "Mac 设备",
    "android": "Android 设备",
    "androidtv": "Android TV",
    "cli": "命令行",
    "worker": "转码器",
    "manual": "手工令牌",
    "jellyfin": "播放器 App",
}


def anonymous_device_name(kind: str) -> str:
    """演示站上其他访客的设备在列表里的显示名。"""
    label = _DEVICE_KIND_LABELS.get(kind, "设备")
    # 中文与西文之间留空格：「其他访客的 iOS 设备」
    return f"其他访客的{' ' if label[:1].isascii() else ''}{label}"


def anonymous_playback_client(client: str, device_name: str) -> tuple[str, str]:
    """活动页 / 播放记录里的（客户端名, 设备名）脱敏。

    网页与原生 App 的客户端名、设备名是服务端按 User-Agent 认出来的固定文案
    （「MovieClaw iOS」「iPhone · iOS 26.0」），原样保留；Jellyfin 协议的客户端
    在请求头里自报名字，访客想填什么就是什么，一律换成中性称呼。
    """
    from movieclaw_api.services.playback.watch import _APP_CLIENTS, WEB_CLIENT_NAME

    trusted = {WEB_CLIENT_NAME, *(name for name, _device in _APP_CLIENTS.values())}
    if client in trusted:
        return client, device_name
    return "第三方播放器", "访客设备"

"""登录设备：统一的「人 × 设备」长期凭证（docs/design/login-devices.md）。

★ 一张表管所有长期凭证
----------------------
网页浏览器的登录会话、原生 App、命令行、转码器、网页手工创建的令牌，签发方式
各不相同：

- **输密码**：网页登录、App 登录（``/auth/login``、``/auth/device/login``）；
- **配对码批准**：命令行、转码器（``/auth/device/authorize`` → 人在网页 / App 上批准）；
- **手工创建**：给没有人能按批准的无人值守环境（``/auth/tokens``）。

但它们本质是同一件事——**一个人把自己的身份授权给一台客户端**——所以存储、
验证、列表、注销全部走本模块这一套。Jellyfin 播放器（Infuse 等）的设备凭证
暂时仍在 ``jellyfin_device`` 表（协议约束多），只在「我的设备」页上合并展示。

★ 两个维度，决定凭证能做什么
----------------------------
1. **客户端类型 → 能不能签发新凭证**（``KindSpec.interactive``）。人直接操作的
   第一方客户端（浏览器、App）可以批准配对、创建令牌；程序代为操作的客户端
   （命令行、转码器、手工令牌）不行，只能注销自己。这道闸防的是「令牌自我
   复制」：命令行令牌会以环境变量交给 Agent 和脚本，是最容易泄露的一类，
   若能给自己再签一枚，吊销原来那枚就止不住损。判断**按客户端类型、不按
   登录方式**——将来扫码登录、通行密钥上线，浏览器与 App 照样是人在操作。
2. **类别 → 改密时的去留**（``KindSpec.family``）。``login``（密码换来的：网页、
   App；Jellyfin 播放器同类）随改密下线；``paired``（配对 / 手工换来的：命令行、
   转码器、手工令牌）默认保留，改密对话框里可勾选一并注销——转码器常年无人
   值守，改个密码就停转码很难排查。

权限不落库：行里只记「属于谁」，能做什么在每次验签时按主人当前身份装配
（``services/auth.py`` 的 ``_device_principal``）。唯一例外是 ``scope``：转码器
的凭证被收窄到只能转码，这是客户端形态的上限，与人的权限取交集。
"""

from __future__ import annotations

import hashlib
import logging
import secrets
import time
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_db.engine import get_database
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.login_device import LoginDevice
from movieclaw_db.models.member import Member
from movieclaw_db.repositories.member_repo import MemberRepository

logger = logging.getLogger("movieclaw_api.login_devices")


@dataclass(frozen=True, slots=True)
class KindSpec:
    """一种客户端类型的固有属性。"""

    label: str
    #: 人直接操作的第一方客户端：可以签发新凭证（批准配对、创建令牌）
    interactive: bool
    #: login=密码换来的，随改密下线；paired=配对 / 手工换来的，改密默认保留
    family: str


KINDS: dict[str, KindSpec] = {
    "web": KindSpec("浏览器", interactive=True, family="login"),
    "ios": KindSpec("iOS App", interactive=True, family="login"),
    "tvos": KindSpec("Apple TV App", interactive=True, family="login"),
    "android": KindSpec("Android App", interactive=True, family="login"),
    "cli": KindSpec("命令行", interactive=False, family="paired"),
    "worker": KindSpec("转码器", interactive=False, family="paired"),
    "manual": KindSpec("手工令牌", interactive=False, family="paired"),
}
#: 用账号密码登录的原生 App（``/auth/device/login`` 只接受这几种）
APP_KINDS = ("ios", "tvos", "android")
#: 走配对码的客户端（``/auth/device/authorize`` 只接受这几种）。Apple TV 也在其中：
#: 电视上打字太痛苦，默认是「电视显示码、手机批准」（docs/design/tvos-app.md §5.1）。
#: 它配出来的仍是 ``tvos`` 这一种登录设备：人直接操作的客户端、改密时随之下线，
#: 与用账号密码登录的 Apple TV 完全同构——两种登录方式只是拿到同一种令牌的两条路
PAIRING_KINDS = ("cli", "worker", "tvos")

#: 令牌明文前缀：肉眼可辨认来源，误提交扫描器也好识别；也用来区分升级前
#: 签发的签名 Cookie（没有这个前缀）与表内令牌。
TOKEN_PREFIX = "mclaw_"

#: 「最近活跃」的落盘节流：同一台设备 60 秒内只写一次。精度够回答「这台
#: 设备还在用吗」，又不至于让每个请求都写一次库。
_TOUCH_INTERVAL_S = 60
#: 设备 id → 上次落盘时刻（time.monotonic）。纯进程内缓存，重启即重来。
_touched_at: dict[int, float] = {}

#: 设备名 / 版本 / 平台这类客户端自报字段的长度上限：只是展示用，截断即可。
_TEXT_LIMIT = 64
_UA_LIMIT = 256


def spec_of(kind: str) -> KindSpec:
    """客户端类型的固有属性；不认识的类型按最保守的「程序、配对类」处理。"""
    return KINDS.get(kind, KindSpec(kind, interactive=False, family="paired"))


def is_device_token(token: str) -> bool:
    """是不是表内令牌（升级前签发的签名会话 Cookie 没有这个前缀）。"""
    return token.startswith(TOKEN_PREFIX)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def playback_device_id(device_id: int) -> str:
    """登录设备在播放活动里的设备标识。

    活动页、取流会话、「注销此设备」都按这个标识找设备：网页和 App 的播放
    以前用客户端自报的浏览器 id，与任何凭证都对不上，活动页上永远注销不了；
    现在播放直接挂在登录设备名下，注销即连带停掉它正在播的流。
    """
    return f"ld-{device_id}"


def parse_playback_device_id(value: str) -> int | None:
    """``ld-<id>`` → 登录设备 id；不是这个形态返回 None。"""
    if not value.startswith("ld-"):
        return None
    raw = value[3:]
    return int(raw) if raw.isdigit() else None


def _clip(value: str | None, limit: int = _TEXT_LIMIT) -> str | None:
    if value is None:
        return None
    value = value.strip()
    return value[:limit] or None


# ---------------------------------------------------------------------------
# 签发
# ---------------------------------------------------------------------------


async def issue(
    session: AsyncSession,
    *,
    member_id: int,
    kind: str,
    name: str,
    scope: str = "full",
    installation_id: str | None = None,
    client_version: str | None = None,
    platform: str | None = None,
    user_agent: str | None = None,
    ip: str | None = None,
    expires_at: datetime | None = None,
    approver_device_id: int | None = None,
) -> tuple[str, LoginDevice]:
    """签发一枚设备令牌，返回 (明文, 行)。明文仅此一次，服务端只存哈希。

    带 ``installation_id`` 时，同一个人在同一台设备上的同类旧凭证先被替换：
    App 重新登录、命令行重新 ``mclaw login`` 都不该越积越多。换人登录同一台
    设备则各占一行——一台手机上登多个账号是正常用法（这点与 Jellyfin 的
    「同设备覆盖」不同）。

    ``approver_device_id``：配对时在 App 上点批准的那台，「新设备登录」不再提醒它。
    """
    installation_id = _clip(installation_id, 128)
    replaced: list[LoginDevice] = []
    if installation_id:
        replaced = await _delete_where(
            session,
            LoginDevice.member_id == member_id,
            LoginDevice.kind == kind,
            LoginDevice.installation_id == installation_id,
        )
        if replaced:
            logger.info(
                "同一设备重新登录，替换旧凭证：%s（%s）",
                replaced[0].name,
                spec_of(kind).label,
            )
    plaintext = TOKEN_PREFIX + secrets.token_urlsafe(32)
    now = utcnow()
    row = LoginDevice(
        member_id=member_id,
        kind=kind,
        name=_clip(name) or spec_of(kind).label,
        token_hash=hash_token(plaintext),
        scope=scope,
        installation_id=installation_id,
        client_version=_clip(client_version),
        platform=_clip(platform, 128),
        user_agent=_clip(user_agent, _UA_LIMIT),
        last_seen_at=now,
        last_seen_ip=ip or None,
        expires_at=expires_at,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    logger.info(
        "已签发设备凭证：%s（%s，id=%d，归属 %s）",
        row.name,
        spec_of(kind).label,
        row.id,
        "超管" if member_id == 0 else f"成员 #{member_id}",
    )
    # 新设备登录：告诉本人的其他设备（docs/design/cloud-push.md §5）。网页登录太频繁、
    # 同一台设备重新登录（替换旧凭证，或之前在这台上自己退出过）都不算新设备，不推
    if kind != "web" and not replaced:
        from movieclaw_api.services.push import events as push_events

        if not await push_events.returning_device(member_id, kind, installation_id):
            push_events.new_device(
                member_id=member_id,
                device_ids=frozenset(i for i in (row.id, approver_device_id) if i is not None),
                name=row.name,
                kind_label=spec_of(kind).label,
                ip=ip or None,
            )
    return plaintext, row


def describe_client(user_agent: str | None) -> str:
    """网页会话的默认设备名：「Chrome · macOS」；老版本 App 走网页登录时是
    「MovieClaw iOS · iPhone · iOS 26.0」。只是展示，用户可以改名。"""
    from movieclaw_api.services.playback.watch import web_client_info

    info = web_client_info(device_id="", user_agent=user_agent)
    if info.version:
        return f"{info.name} · {info.device_name}"
    return info.device_name


async def issue_web_session(
    *,
    member_id: int,
    ttl_seconds: int,
    user_agent: str | None,
    ip: str | None,
) -> str:
    """网页登录：签发一枚浏览器会话令牌（写进 HttpOnly Cookie）。

    有效期沿用改造前的语义（7 天 / 记住我 30 天）；顺手清掉已过期的网页会话，
    免得不退出登录、直接关浏览器的会话在表里越积越多。
    """
    async with get_database().session() as session:
        await purge_expired(session)
        token, _row = await issue(
            session,
            member_id=member_id,
            kind="web",
            name=describe_client(user_agent),
            user_agent=user_agent,
            ip=ip,
            expires_at=utcnow() + timedelta(seconds=ttl_seconds),
        )
    return token


# ---------------------------------------------------------------------------
# 验证
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class ResolvedDevice:
    """验签结果：设备行 + 主人（超管时 ``member`` 为 None）。"""

    device: LoginDevice
    member: Member | None


async def resolve(token: str) -> ResolvedDevice | None:
    """令牌 → 设备与主人；令牌不存在 / 已过期 / 主人已停用或删除都返回 None。

    主人每次现查：成员被停用立刻失效，能力开关的调整立刻生效——这是「权限
    在验签时装配」的全部代价，一次按主键的读取。
    """
    if not is_device_token(token):
        return None
    async with get_database().session() as session:
        device = (
            await session.execute(
                select(LoginDevice).where(LoginDevice.token_hash == hash_token(token))
            )
        ).scalar_one_or_none()
        if device is None:
            return None
        if device.expires_at is not None and device.expires_at <= utcnow():
            return None
        if device.member_id == 0:
            return ResolvedDevice(device=device, member=None)
        member = await MemberRepository(session).get(device.member_id)
    if member is None or member.status != "active":
        return None
    return ResolvedDevice(device=device, member=member)


async def touch(device: LoginDevice, *, ip: str | None, user_agent: str | None) -> None:
    """记下设备的最近活跃（时间、来源地址、User-Agent），按分钟粒度落盘。"""
    assert device.id is not None
    await touch_id(device.id, ip=ip, user_agent=user_agent)


async def touch_id(device_id: int, *, ip: str | None, user_agent: str | None) -> None:
    """同 ``touch``，按 id 记。转码器只在握手时验一次凭证，之后收到它的每条控制消息
    （心跳、任务状态）都调这里，「最近活跃」才跟得上它真实的在线时间。"""
    now = time.monotonic()
    if now - _touched_at.get(device_id, 0.0) < _TOUCH_INTERVAL_S:
        return
    _touched_at[device_id] = now
    async with get_database().session() as session:
        row = await session.get(LoginDevice, device_id)
        if row is None:
            return
        row.last_seen_at = utcnow()
        if ip:
            row.last_seen_ip = ip
        if user_agent:
            row.user_agent = _clip(user_agent, _UA_LIMIT)
        await session.commit()


# ---------------------------------------------------------------------------
# 查询 / 改名
# ---------------------------------------------------------------------------


async def list_devices(session: AsyncSession, *, member_id: int | None) -> list[LoginDevice]:
    """某个人的全部设备（``member_id=None`` 表示全体，管理员视角）。已过期的不列。"""
    stmt = select(LoginDevice)
    if member_id is not None:
        stmt = stmt.where(LoginDevice.member_id == member_id)
    now = utcnow()
    rows = (await session.execute(stmt)).scalars().all()
    return [r for r in rows if r.expires_at is None or r.expires_at > now]


async def get_device(session: AsyncSession, device_id: int) -> LoginDevice | None:
    return await session.get(LoginDevice, device_id)


async def rename(session: AsyncSession, device: LoginDevice, name: str) -> LoginDevice:
    device.name = _clip(name) or device.name
    device.updated_at = utcnow()
    await session.commit()
    await session.refresh(device)
    return device


async def count_by_member(session: AsyncSession) -> dict[int, int]:
    """每个人的设备数（成员管理页用）。"""
    counts: dict[int, int] = {}
    for row in await list_devices(session, member_id=None):
        counts[row.member_id] = counts.get(row.member_id, 0) + 1
    return counts


# ---------------------------------------------------------------------------
# 注销
# ---------------------------------------------------------------------------


async def _delete_where(session: AsyncSession, *conditions) -> list[LoginDevice]:  # type: ignore[no-untyped-def]
    rows = list((await session.execute(select(LoginDevice).where(*conditions))).scalars().all())
    if not rows:
        return []
    await session.execute(delete(LoginDevice).where(LoginDevice.id.in_([r.id for r in rows])))  # type: ignore[union-attr]
    await session.commit()
    await _after_revoke(rows)
    return rows


async def _after_revoke(rows: list[LoginDevice]) -> None:
    """凭证删掉之后的连带动作：它正在播的流停掉、转码器的连接断开。

    只删凭证不断连接，被注销的转码器会一直干活到下次重连才发现自己被踢了；
    被注销的手机也会把正在播的片子一直播完。注销是这套设计唯一的事后止损
    手段，必须立刻生效。
    """
    from movieclaw_api.services.playback.remote_worker import get_remote_worker_registry
    from movieclaw_api.services.playback.session import get_session_manager
    from movieclaw_playback import activity
    from movieclaw_playback.streaming import stop_device_streams

    registry = get_remote_worker_registry()
    for row in rows:
        assert row.id is not None
        _touched_at.pop(row.id, None)
        device_key = playback_device_id(row.id)
        activity.report_stop(device_key)
        stop_device_streams(device_key)
        await get_session_manager().stop_for_device(device_key, reason="设备已被注销")
        if row.scope == "transcode":
            await registry.disconnect_device(row.id, "转码器凭证已被注销，请重新配对")


async def revoke(session: AsyncSession, device: LoginDevice) -> None:
    """注销一台设备：凭证立即失效，在播的流与转码连接一并断开。"""
    await _delete_where(session, LoginDevice.id == device.id)
    logger.info("已注销设备：%s（%s，id=%s）", device.name, spec_of(device.kind).label, device.id)


async def revoke_token(token: str) -> None:
    """按令牌明文注销（退出登录用）。令牌不在表里（升级前的签名 Cookie）就什么都不做。"""
    if not is_device_token(token):
        return
    async with get_database().session() as session:
        await _delete_where(session, LoginDevice.token_hash == hash_token(token))


async def revoke_for_member(
    session: AsyncSession,
    member_id: int,
    *,
    families: tuple[str, ...] = ("login", "paired"),
    except_id: int | None = None,
) -> list[LoginDevice]:
    """注销一个人的设备（按类别筛），``except_id`` 是要保留的当前设备。

    改密：``families=("login",)`` 踢掉密码换来的，配对的默认保留；
    停用 / 全部下线：两类都踢。
    """
    kinds = [k for k, spec in KINDS.items() if spec.family in families]
    conditions = [LoginDevice.member_id == member_id, LoginDevice.kind.in_(kinds)]  # type: ignore[attr-defined]
    if except_id is not None:
        conditions.append(LoginDevice.id != except_id)
    rows = await _delete_where(session, *conditions)
    if rows:
        logger.info(
            "已注销%s的 %d 台设备：%s",
            "超管" if member_id == 0 else f"成员 #{member_id} ",
            len(rows),
            "、".join(r.name for r in rows),
        )
    return rows


async def purge_expired(session: AsyncSession) -> int:
    """删掉已过期的网页会话（直接关浏览器、没点退出登录的那些）。"""
    now = utcnow()
    result = await session.execute(
        delete(LoginDevice).where(
            LoginDevice.expires_at.is_not(None),  # type: ignore[union-attr]
            LoginDevice.expires_at <= now,  # type: ignore[operator]
        )
    )
    await session.commit()
    return int(result.rowcount or 0)  # type: ignore[attr-defined]


def reset_state() -> None:
    """清空进程内的活跃节流缓存（仅供测试隔离）。"""
    _touched_at.clear()

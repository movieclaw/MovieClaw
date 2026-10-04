"""App 的推送登记（docs/design/cloud-push.md §4）。

App 用这台设备自己的凭证调 ``PUT /push/me/registration``，把 APNs 令牌、Bundle ID、
环境、支持的推送类型、``key_id``、密钥和系统通知权限交给实例，存在 ``login_device``
行上（密钥加密）。所以：

- 只有 App 类设备（ios / tvos / android）能登记，网页会话、命令行没有推送；
- 退出登录、注销设备、删除成员时登记随行删除，不会留下一个还能推到别人手机上的登记；
- 中继说令牌失效（``unregistered``）就清掉登记，App 下次启动会重新登记。
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import func, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.push import crypto
from movieclaw_db.crypto import get_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import LoginDevice, utcnow

logger = logging.getLogger("movieclaw_api.push.registration")

#: 能登记推送的设备类型。Apple TV（``tvos``）与 Mac App（``macos``）刻意不在其中：
#: 它们本期不接推送、不会来登记（cloud-push.md §11），放进来反而让「我的设备」给它们挂上
#: 「还没有开启通知，打开 App 后会自动开启」这种兑现不了的提示。等它们真接了 APNs 再加
PUSH_KINDS = ("ios", "android")
PERMISSIONS = ("authorized", "provisional", "ephemeral", "denied", "not_determined")
ENVIRONMENTS = ("production", "development")
#: 实例会发的推送类型（中继还支持别的，但实例目前只用这两种）
KNOWN_TYPES = ("alert", "background")

_TOKEN_PATTERN = re.compile(r"^[0-9a-fA-F]{32,400}$")
_TOPIC_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$")


@dataclass(frozen=True)
class Registration:
    """一次登记请求（已校验）。``token`` 为空表示只上报权限状态。"""

    permission: str
    token: str | None = None
    topic: str | None = None
    environment: str | None = None
    types: tuple[str, ...] = ()
    key_id: str | None = None
    key: str | None = None


def validate(
    *,
    permission: str,
    token: str | None,
    topic: str | None,
    environment: str | None,
    types: list[str] | None,
    key_id: str | None,
    key: str | None,
) -> Registration:
    """校验 App 交上来的登记；不合规抛 400（说明给开发者看，App 不会展示给用户）。"""
    if permission not in PERMISSIONS:
        raise BadRequestException(f"permission 只能是 {' / '.join(PERMISSIONS)}")
    provided = [v for v in (token, key_id, key) if v]
    if not provided:
        return Registration(permission=permission)
    if len(provided) != 3:
        raise BadRequestException("token、key_id、key 三个要么都有，要么都没有")
    assert token and key_id and key
    if not _TOKEN_PATTERN.fullmatch(token):
        raise BadRequestException("token 必须是 32–400 位的十六进制字符串")
    if not topic or not _TOPIC_PATTERN.fullmatch(topic):
        raise BadRequestException("topic 必须是 App 的 Bundle ID")
    if environment not in ENVIRONMENTS:
        raise BadRequestException("environment 只能是 production 或 development")
    if not crypto.KEY_ID_PATTERN.fullmatch(key_id):
        raise BadRequestException("key_id 必须是 11 个 base64url 字符")
    try:
        crypto.decode_key(key)
    except ValueError as exc:
        raise BadRequestException("key 必须是 32 字节密钥的 base64url") from exc
    kinds = tuple(t for t in dict.fromkeys(types or ["alert"]) if t in KNOWN_TYPES)
    return Registration(
        permission=permission,
        token=token.lower(),
        topic=topic,
        environment=environment,
        types=kinds or ("alert",),
        key_id=key_id,
        key=key,
    )


async def save(session: AsyncSession, device: LoginDevice, reg: Registration) -> LoginDevice:
    """把登记写到设备行上。

    只上报权限、不带令牌时：权限是关着的（``denied`` / ``not_determined``）就清掉令牌；
    权限开着就保留已有的令牌——App 冷启动时可能先上报权限、稍后才拿到 APNs 令牌，
    这时清掉，中间这段的推送就丢了。令牌真失效了中继会说 ``unregistered``。
    """
    device.push_permission = reg.permission
    device.push_registered_at = utcnow()
    if reg.token:
        if device.push_token != reg.token or device.push_environment != reg.environment:
            device.push_problem = None  # 换了令牌或环境，之前的 bad_token 不再成立
        device.push_token = reg.token
        device.push_topic = reg.topic
        device.push_environment = reg.environment
        device.push_types = list(reg.types)
        device.push_key_id = reg.key_id
        device.push_key = get_secret_box().encrypt(reg.key or "")
    elif reg.permission in ("denied", "not_determined"):
        _clear_push_fields(device, keep_permission=True)
    session.add(device)
    await session.commit()
    await session.refresh(device)
    logger.info(
        "设备「%s」登记推送：%s，权限 %s",
        device.name,
        f"{device.push_topic}（{device.push_environment}）" if reg.token else "未提供令牌",
        reg.permission,
    )
    return device


def _clear_push_fields(device: LoginDevice, *, keep_permission: bool) -> None:
    device.push_token = None
    device.push_topic = None
    device.push_environment = None
    device.push_types = None
    device.push_key_id = None
    device.push_key = None
    device.push_problem = None
    if not keep_permission:
        device.push_permission = None
        device.push_registered_at = None


async def clear(session: AsyncSession, device: LoginDevice) -> None:
    """App 在这台设备上关掉了这台服务器的通知：清掉整条登记。"""
    _clear_push_fields(device, keep_permission=False)
    session.add(device)
    await session.commit()


async def mark_unregistered(device_id: int, token: str) -> None:
    """中继说令牌失效（App 被卸载或关了通知）：清掉登记，App 下次启动会重新登记。

    只在登记的还是这个令牌时才清：发送途中 App 已经换了新令牌重新登记，就不能动。
    """
    async with get_database().session() as session:
        await session.execute(
            update(LoginDevice)
            .where(LoginDevice.id == device_id, LoginDevice.push_token == token)
            .values(
                push_token=None,
                push_topic=None,
                push_environment=None,
                push_types=None,
                push_key_id=None,
                push_key=None,
                push_problem=None,
            )
        )
        await session.commit()


async def mark_problem(device_id: int, problem: str | None, token: str) -> None:
    """标记这台设备的推送问题（同上，只针对发出时用的令牌）。"""
    async with get_database().session() as session:
        await session.execute(
            update(LoginDevice)
            .where(LoginDevice.id == device_id, LoginDevice.push_token == token)
            .values(push_problem=problem)
        )
        await session.commit()


def decrypt_key(device: LoginDevice) -> bytes | None:
    """设备的解密密钥；没有或解不开返回 None（这台设备就不发）。"""
    if not device.push_key:
        return None
    try:
        return crypto.decode_key(get_secret_box().decrypt(device.push_key))
    except Exception:  # noqa: BLE001 -- 主密钥换过等情况：这台设备跳过，等 App 重新登记
        logger.warning("设备「%s」的推送密钥解不开，跳过（App 重新登记后恢复）", device.name)
        return None


async def registered_devices(
    session: AsyncSession, *, member_ids: set[int] | None = None
) -> list[LoginDevice]:
    """有推送令牌的 App 类设备；``member_ids`` 为 None 时取全部。"""
    stmt = select(LoginDevice).where(
        LoginDevice.push_token.is_not(None),  # type: ignore[union-attr]
        LoginDevice.kind.in_(PUSH_KINDS),  # type: ignore[attr-defined]
    )
    if member_ids is not None:
        if not member_ids:
            return []
        stmt = stmt.where(LoginDevice.member_id.in_(member_ids))  # type: ignore[attr-defined]
    return list((await session.execute(stmt.order_by(LoginDevice.id))).scalars().all())


async def newest_registrations(session: AsyncSession, tokens: set[str]) -> dict[str, datetime]:
    """这些设备令牌各自最近一次登记的时间（同一台手机上登了几个账号时取最新的）。"""
    if not tokens:
        return {}
    rows = await session.execute(
        select(LoginDevice.push_token, func.max(LoginDevice.push_registered_at))  # type: ignore[call-overload]
        .where(LoginDevice.push_token.in_(tokens))  # type: ignore[union-attr]
        .group_by(LoginDevice.push_token)
    )
    return {str(token): at for token, at in rows.all() if token and at is not None}


async def device_counts() -> list[dict]:
    """上报用：有推送登记的设备按平台和 App 版本汇总（不带设备名、型号、IP）。"""
    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(LoginDevice.kind, LoginDevice.client_version, func.count())  # type: ignore[call-overload]
                .where(
                    LoginDevice.push_token.is_not(None),  # type: ignore[union-attr]
                    LoginDevice.kind.in_(PUSH_KINDS),  # type: ignore[attr-defined]
                )
                .group_by(LoginDevice.kind, LoginDevice.client_version)
            )
        ).all()
    return [
        {"platform": str(kind), "app_version": str(version or ""), "count": int(count)}
        for kind, version, count in rows
    ]

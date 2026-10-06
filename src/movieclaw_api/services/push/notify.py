"""把一个事件变成发给每个人、每台手机的推送（docs/design/cloud-push.md §5、§6）。

业务侧只调 ``notify(...)``：给事件键、收件人、怎么写文案。这里负责：

1. 按个人偏好筛掉关了这个事件的人；
2. 取他们登记过推送的设备，跳过系统通知权限被关掉的、不收提醒类推送的；
3. **同一台手机（APNs 令牌相同）只推一条**：一台 iPad 上登了家里两个人，不响两次；
4. 每台设备用自己的密钥加密明文（标出来自哪台服务器、推给哪个账号）；
5. 交给分发器发出去。

全程在后台任务里，任何失败只记日志。
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.push import crypto, preferences, registration
from movieclaw_api.services.push.dispatcher import Outcome, Outgoing, build_message, deliver, spawn
from movieclaw_db.engine import get_database
from movieclaw_db.models import LoginDevice, Member, utcnow

logger = logging.getLogger("movieclaw_api.push.notify")

#: 同一台手机上，比最新的登记旧这么久的账号登记当作已经不在这台手机上（见 ``prepare``）
STALE_REGISTRATION = timedelta(days=7)


@dataclass(frozen=True)
class AlertContent:
    """一条提醒的内容（明文里的字段，见 push-payload.md §3.1）。"""

    title: str
    body: str = ""
    subtitle: str = ""
    #: 带签名的配图相对路径（services/push/images.py），None = 不带图
    image: str | None = None
    #: 点开后的网页站内路径，网页和 App 用同一套路由
    open: str | None = None
    #: 通知分组（threadIdentifier）；App 会再按服务器分开，不同服务器的通知不混在一组
    thread: str | None = None
    #: 要不要在手机上标出来源（push-payload.md §3.1 的 ``source``）：None = 不标（内容类，
    #: 点开时 App 自动切过去）；"server" = 手机连了不止一台服务器时标服务器名（管理员告警）；
    #: "account" = 同一台服务器上登了不止一个账号时标账号名（账号安全，服务器名已写进正文）
    source: str | None = None
    #: 打扰级别（APNs 的 interruption-level）：passive = 不响不亮屏，只进通知中心（进度更新、
    #: 开始下载这类）；active = 正常响；time-sensitive = 专注模式下也提醒（账号安全）
    level: str = "active"
    #: 在系统通知摘要里排第几（0~1，APNs 的 relevance-score）；None = 不填
    relevance: float | None = None
    #: 通知类别（App 按它挂快捷操作、长按时的展开界面）
    category: str | None = None
    #: 长按时的快捷操作：``{"id", "title", "open"?}``，App 点了按 ``id`` 处理
    actions: list[dict] | None = None
    #: 长按时的集数格子：``{"season", "cells"}``（cards.py 的 ``grid``）
    grid: dict | None = None


#: 按收件人写文案：同一事件对不同的人可能跳到不同的页面（比如各自能看到的库）。
#: 返回 None 表示这个人不该收到（比如他看不到这部片）。
ContentBuilder = Callable[[AsyncSession, int], Awaitable[AlertContent | None]]
#: 收件人：现成的成员 id 集合，或在后台会话里现查（订阅的关注者等）
Recipients = set[int] | Callable[[AsyncSession], Awaitable[set[int]]]


async def server_identity() -> dict:
    """明文里的 ``server``：Jellyfin 兼容层的服务器 ID 和名称（连接云时用的名称优先）。"""
    from movieclaw_api.settings import CloudSetting, get_setting_store
    from movieclaw_api.settings.schemas import get_jellyfin_compat

    compat = await get_jellyfin_compat()
    cloud = await get_setting_store().get(CloudSetting)
    return {"id": compat.server_id, "name": cloud.instance_name or compat.server_name}


async def _account_names(session: AsyncSession, member_ids: set[int]) -> dict[int, str]:
    from movieclaw_api.services.auth import get_admin_account

    names: dict[int, str] = {}
    if 0 in member_ids:
        admin = await get_admin_account()
        names[0] = admin.nickname or admin.username or "管理员"
    others = {m for m in member_ids if m}
    if others:
        rows = await session.execute(select(Member).where(Member.id.in_(others)))  # type: ignore[union-attr]
        for member in rows.scalars():
            if member.id is not None:
                names[member.id] = member.nickname or member.username
    return names


def _plaintext(content: AlertContent, *, server: dict, account: dict) -> dict:
    message: dict = {"v": 1, "type": "alert", "title": content.title}
    if content.subtitle:
        message["subtitle"] = content.subtitle
    if content.body:
        message["body"] = content.body
    if content.image:
        message["image"] = content.image
    if content.open:
        message["open"] = content.open
    if content.thread:
        message["thread"] = content.thread
    if content.source:
        message["source"] = content.source
    if content.category:
        message["category"] = content.category
    if content.actions:
        message["actions"] = content.actions
    if content.grid:
        message["grid"] = content.grid
    if content.level != "passive":
        message["sound"] = "default"
    message["server"] = server
    message["account"] = account
    message["sent_at"] = int(utcnow().timestamp())
    return message


def _deliverable(device: LoginDevice) -> bool:
    return (
        bool(device.push_token and device.push_topic and device.push_environment)
        and device.push_permission != "denied"
        and "alert" in (device.push_types or ["alert"])
    )


async def prepare(
    session: AsyncSession,
    *,
    event: str | None,
    member_ids: set[int],
    build: ContentBuilder,
    exclude_device_ids: frozenset[int] = frozenset(),
    collapse: tuple[str, str] | None = None,
) -> list[Outgoing]:
    """算出这次要发的每一条（已加密）。``event`` 为 None 表示不看偏好（测试推送）。"""
    recipients = (
        await preferences.wants(session, member_ids, event) if event is not None else member_ids
    )
    if not recipients:
        return []
    devices = [
        d
        for d in await registration.registered_devices(session, member_ids=recipients)
        if d.id is not None and d.id not in exclude_device_ids and _deliverable(d)
    ]
    if not devices:
        return []
    server = await server_identity()
    names = await _account_names(session, {d.member_id for d in devices})
    collapse_value = None
    if collapse is not None:
        from movieclaw_api.services.push.images import collapse_key

        collapse_value = crypto.collapse_id(await collapse_key(), *collapse)
    contents: dict[int, AlertContent | None] = {}
    seen_tokens: set[str] = set()
    outgoing: list[Outgoing] = []
    # 同一台手机（同一个 APNs 令牌）登了几个账号时只推一条，用最近登记过的那个账号的
    # 密钥：App 每次打开都给手机上的每个账号重新登记，已经从手机上删掉的账号不会再登记，
    # 它的密钥手机上也没有了。比这台手机最新的登记旧了一周以上的，当它已经不在这台手机上
    newest = await registration.newest_registrations(
        session, {(d.push_token or "").lower() for d in devices}
    )
    epoch = datetime(1970, 1, 1)
    for device in sorted(
        devices,
        key=lambda d: (-(d.push_registered_at or epoch).timestamp(), d.member_id, d.id or 0),
    ):
        token = (device.push_token or "").lower()
        if token in seen_tokens:
            continue
        latest = newest.get(token)
        registered = device.push_registered_at or epoch
        if latest is not None and latest - registered > STALE_REGISTRATION:
            continue
        if device.member_id not in contents:
            contents[device.member_id] = await build(session, device.member_id)
        content = contents[device.member_id]
        if content is None:
            continue
        key = registration.decrypt_key(device)
        if key is None or not device.push_key_id:
            continue
        plaintext = crypto.fit_alert(
            _plaintext(
                content,
                server=server,
                account={
                    "id": str(device.member_id),
                    "name": names.get(device.member_id, ""),
                },
            )
        )
        payload = crypto.seal(plaintext, key=key, key_id=device.push_key_id)
        message = build_message(
            token=token,
            topic=device.push_topic or "",
            environment=device.push_environment or "production",
            payload=payload,
            collapse_id=collapse_value,
            level=content.level,
            relevance=content.relevance,
        )
        seen_tokens.add(token)
        outgoing.append(
            Outgoing(
                device_id=device.id or 0,
                device_name=device.name,
                topic=device.push_topic or "",
                message=message,
                expires_at=message["expires_at"],
            )
        )
    return outgoing


def notify(
    event: str,
    recipients: Recipients,
    build: ContentBuilder,
    *,
    exclude_device_ids: frozenset[int] = frozenset(),
    collapse: tuple[str, str] | None = None,
) -> None:
    """业务侧唯一入口：后台推送，不阻塞、不抛错。

    ``build(session, member_id)`` 给每个收件人写文案；返回 None 表示这个人不该收到。
    查询都在后台任务自己的会话里做，调用方的会话提交之后就可以关掉。
    """

    async def _run() -> None:
        try:
            async with get_database().session() as session:
                member_ids = (
                    recipients if isinstance(recipients, set) else await recipients(session)
                )
                items = await prepare(
                    session,
                    event=event,
                    member_ids=member_ids,
                    build=build,
                    exclude_device_ids=exclude_device_ids,
                    collapse=collapse,
                )
            if not items:
                return
            outcomes = await deliver(items)
            logger.info(
                "App 推送「%s」：%s",
                preferences.EVENTS_BY_KEY[event].title
                if event in preferences.EVENTS_BY_KEY
                else event,
                "、".join(f"{o.device_name}={o.result}" for o in outcomes),
            )
        except Exception:  # noqa: BLE001 -- 推送绝不能影响业务主链路
            logger.exception("App 推送失败（已忽略）")

    spawn(_run())


async def send_test(member_id: int) -> list[Outcome]:
    """给这个人自己的设备发一条测试通知（同步返回每台的结果）。"""

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        return AlertContent(
            title="测试通知",
            body="能看到这条，说明这台设备能收到这台服务器的通知。",
            open="/settings/notifications",
            thread="system",
        )

    async with get_database().session() as session:
        items = await prepare(session, event=None, member_ids={member_id}, build=build)
    return await deliver(items)

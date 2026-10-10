"""业务事件 → App 推送（docs/design/cloud-push.md §5）。

产生点在 ``session.commit()`` 之后调这里的函数，只传 id 和现成的文字；查询都在推送
自己的后台会话里做。规则：

- 订阅类（入库、开始下载、洗版）推给**订阅的人**：发起人（空为管理员）+ 关注者；
- 收件人**看不到的条目一律不推**：走 ``assert_item_visible``（库可见范围 + 内容分级）；
- 新设备登录推给账号本人，不推给刚登录的那台；
- 待处理事项推给管理员，同一个问题的新通知替换旧的（collapse_id）。
"""

from __future__ import annotations

import asyncio
import functools
import hashlib
import logging
import time
from datetime import timedelta

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.services.push.images import image_path
from movieclaw_api.services.push.notify import AlertContent, notify, server_identity
from movieclaw_db.models import utcnow

logger = logging.getLogger("movieclaw_api.push.events")


def _never_raise(func):  # type: ignore[no-untyped-def]
    """产生点在业务链路上：推送这边出任何错都只记日志，不能把业务打断。"""

    @functools.wraps(func)
    def wrapper(*args, **kwargs):  # type: ignore[no-untyped-def]
        try:
            func(*args, **kwargs)
        except Exception:  # noqa: BLE001
            logger.exception("准备 App 推送失败（已忽略）")

    return wrapper


# ----------------------------------------------------------------------
# 收件人与可见性
# ----------------------------------------------------------------------


async def _principal(session: AsyncSession, member_id: int):  # type: ignore[no-untyped-def]
    """按成员 id 造一个请求主体，给可见性判定用；成员不在或停用返回 None。"""
    from movieclaw_api.services.auth import Principal
    from movieclaw_db.repositories.member_repo import MemberRepository

    if member_id == 0:
        return Principal(kind="admin", name="admin", is_admin=True)
    member = await MemberRepository(session).get(member_id)
    if member is None or member.status != "active":
        return None
    return Principal(
        kind="member", name=member.username, member_id=member.id, is_admin=False, member=member
    )


async def _item_visible(session: AsyncSession, member_id: int, item_id: int) -> bool:
    from movieclaw_api.services.library.access import assert_item_visible

    principal = await _principal(session, member_id)
    if principal is None:
        return False
    try:
        await assert_item_visible(session, principal, item_id)
    except NotFoundException:
        return False
    return True


async def _library_path(
    session: AsyncSession, member_id: int, item_id: int, unit: tuple[int, int] | None
) -> str | None:
    """这个人能看到的、放着这部片的库里的条目页；找不到返回 None。"""
    from movieclaw_api.services.library.access import visible_library_ids
    from movieclaw_db.models import LibraryFile

    principal = await _principal(session, member_id)
    if principal is None:
        return None
    visible = await visible_library_ids(session, principal)
    rows = await session.execute(
        select(LibraryFile.library_id).where(  # type: ignore[call-overload]
            LibraryFile.media_item_id == item_id,
            LibraryFile.library_id.is_not(None),  # type: ignore[union-attr]
        )
    )
    libraries = sorted({int(lid) for lid in rows.scalars() if lid is not None and lid in visible})
    if not libraries:
        return None
    path = f"/library/{libraries[0]}/item/{item_id}"
    if unit is not None and unit != (0, 0):
        path += f"?season={unit[0]}&episode={unit[1]}"
    return path


def subscribers(subscription_id: int):  # type: ignore[no-untyped-def]
    """订阅的人：发起人（空为管理员）+ 关注者。"""

    async def resolve(session: AsyncSession) -> set[int]:
        from movieclaw_db.models import Subscription, SubscriptionFollower

        subscription = await session.get(Subscription, subscription_id)
        if subscription is None:
            return set()
        members = {subscription.created_by_member_id or 0}
        rows = await session.execute(
            select(SubscriptionFollower.member_id).where(  # type: ignore[call-overload]
                SubscriptionFollower.subscription_id == subscription_id
            )
        )
        members.update(int(m) for m in rows.scalars())
        return members

    return resolve


def _display_title(title: str, year: int | None) -> str:
    return title.strip() or (f"{year} 年的作品" if year else "一部作品")


def _lazy_image(image_url: str | None):  # type: ignore[no-untyped-def]
    """配图地址签一次、给所有收件人共用（签名在后台任务里做，不占业务链路）。"""
    cache: dict[str, str | None] = {}

    async def get() -> str | None:
        if "v" not in cache:
            cache["v"] = await image_path(image_url)
        return cache["v"]

    return get


# ----------------------------------------------------------------------
# 订阅类事件：只投事件，合并与文案在推送事件中枢里做（hub.py、cards.py）
# ----------------------------------------------------------------------


def _units(units: list[tuple[int, int]]) -> tuple[tuple[int, int], ...]:
    return tuple((int(s), int(e)) for s, e in units)


@_never_raise
def imported(*, subscription_id: int, item_id: int, units: list[tuple[int, int]]) -> None:
    """订阅的这几集整理进媒体库了：进这部剧的卡（cards.py）。"""
    from movieclaw_api.services.push.hub import Imported, emit

    emit(Imported(subscription_id=subscription_id, item_id=item_id, units=_units(units)))


@_never_raise
def download_started(
    *,
    subscription_id: int,
    item_id: int,
    units: list[tuple[int, int]],
    detail: str,
    upgrade: bool,
    skip_member_id: int | None = None,
    source: str = "",
    spec: str = "",
) -> None:
    """订阅找到资源、交给下载器了。``skip_member_id``：手动选种时点下载的人，不推给他。

    ``source``、``spec`` 是 IM 消息里的来源与规格（App 推送不用）。
    """
    from movieclaw_api.services.push.hub import Started, emit

    emit(
        Started(
            subscription_id=subscription_id,
            item_id=item_id,
            units=_units(units),
            detail=detail,
            upgrade=upgrade,
            skip_member_id=skip_member_id,
            source=source,
            spec=spec,
        )
    )


@_never_raise
def identity_skipped(*, subscription_id: int, item_id: int, title: str, message: str) -> None:
    """同名资源已自动跳过：只知会订阅者，点通知查看订阅，不提供下载操作。"""
    async def build(session: AsyncSession, member_id: int) -> AlertContent | None:
        if not await _item_visible(session, member_id, item_id):
            return None
        return AlertContent(
            title=title, body=message, open=f"/subscriptions/{subscription_id}",
            thread=f"subscription:{subscription_id}",
        )

    notify(
        "identity_skipped", subscribers(subscription_id), build,
        collapse=("identity-skipped", str(subscription_id)),
    )


@_never_raise
def upgraded(
    *,
    subscription_id: int,
    item_id: int,
    unit: tuple[int, int],
    old_label: str,
    new_label: str,
) -> None:
    """订阅的一集换成了更好的版本（同一个订阅一分钟内的合成一条，cards.py）。"""
    from movieclaw_api.services.push.hub import Upgraded, emit

    emit(
        Upgraded(
            subscription_id=subscription_id,
            item_id=item_id,
            unit=(int(unit[0]), int(unit[1])),
            old_label=old_label,
            new_label=new_label,
        )
    )


# ----------------------------------------------------------------------
# 账号安全
# ----------------------------------------------------------------------


@_never_raise
def new_device(
    *,
    member_id: int,
    device_ids: frozenset[int],
    name: str,
    kind_label: str,
    ip: str | None,
) -> None:
    """有新的设备登录了这个账号：告诉本人的其他设备。

    ``device_ids`` 是不用告诉的设备：刚登录的那台、在 App 上批准这次配对的那台。
    """
    where = f"，来源 {ip}" if ip else ""

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        # 安全提醒一定要说清是哪台服务器：不知道在哪，就没法判断是不是自己、去哪注销
        server = (await server_identity())["name"]
        return AlertContent(
            title="新设备登录了你的账号",
            body=(
                f"你在「{server}」上的账号刚在新设备登录：「{name}」（{kind_label}）{where}。"
                "不是你本人的话，去「账号 → 设备」注销它。"
            ),
            open="/settings/devices",
            thread="account",
            source="account",
            # 账号安全：专注模式下也要提醒（App 有「时效性通知」能力）
            level="time-sensitive",
        )

    notify("new_device", {member_id}, build, exclude_device_ids=device_ids)


#: 自己退出登录的设备记多久：这段时间里同一台登录回来，不算新设备
_SIGNED_OUT_TTL = timedelta(days=30)
_SIGNED_OUT_LIMIT = 500


def _installation_key(member_id: int, kind: str, installation_id: str) -> str:
    raw = f"{member_id}:{kind}:{installation_id}".encode()
    return hashlib.sha256(raw).hexdigest()[:32]


async def remember_signed_out(member_id: int, kind: str, installation_id: str | None) -> None:
    """这台设备自己退出了登录：之后同一台登录回来不算新设备。出错只记日志。"""
    if not installation_id:
        return
    try:
        from movieclaw_api.settings import get_setting_store
        from movieclaw_api.settings.cloud import SignedOutDevices

        store = get_setting_store()
        data = (await store.get(SignedOutDevices)).model_copy(deep=True)
        now = utcnow()
        entries = {k: v for k, v in data.entries.items() if now - v < _SIGNED_OUT_TTL}
        entries[_installation_key(member_id, kind, installation_id)] = now
        if len(entries) > _SIGNED_OUT_LIMIT:
            entries = dict(sorted(entries.items(), key=lambda kv: kv[1])[-_SIGNED_OUT_LIMIT:])
        data.entries = entries
        await store.set(data)
    except Exception:  # noqa: BLE001
        logger.exception("记录退出登录的设备失败（已忽略）")


async def returning_device(member_id: int, kind: str, installation_id: str | None) -> bool:
    """这台设备之前自己退出过、现在登录回来了（用掉这条记录）。出错按「不是」算。"""
    if not installation_id:
        return False
    try:
        from movieclaw_api.settings import get_setting_store
        from movieclaw_api.settings.cloud import SignedOutDevices

        store = get_setting_store()
        data = await store.get(SignedOutDevices)
        key = _installation_key(member_id, kind, installation_id)
        at = data.entries.get(key)
        if at is None or utcnow() - at >= _SIGNED_OUT_TTL:
            return False
        data = data.model_copy(deep=True)
        del data.entries[key]
        await store.set(data)
        return True
    except Exception:  # noqa: BLE001
        logger.exception("读取退出登录的设备失败（已忽略）")
        return False


# ----------------------------------------------------------------------
# 待处理事项（管理员）
# ----------------------------------------------------------------------


def notice_path(source: str, payload: dict) -> str:
    """待处理事项的跳转：能修它的页面（与网页、App 的待处理列表同一套映射）。"""
    if source == "subscription":
        subscription_id = payload.get("subscription_id")
        return f"/subscriptions/{subscription_id}" if subscription_id else "/subscriptions"
    if source == "plugin":
        # 插件可以带一个站内路径指向能修它的地方（插件包回滚 → 插件管理页）；没带就定位到
        # 插件页里它那一行（docs/design/plugin-page-tiers.md §4.1）
        href = payload.get("action_href")
        if isinstance(href, str) and href.startswith("/") and not href.startswith("//"):
            return href
        entry_id = payload.get("entry_id")
        return f"/settings/plugins?module={entry_id}" if entry_id else "/settings/plugins"
    return {
        "ingest": "/settings/import-watch",
        "downloader": "/settings/downloaders",
        "site": "/settings/sites",
        "cloud": "/settings/cloud",
    }.get(source, "/settings")


#: 同一个问题多久最多推一次：下载器、站点时好时坏时，问题会反复消退又复发，每次都响
#: 就成了刷屏。只在内存里，重启后最多多推一次
_ALERT_COOLDOWN_S = 6 * 3600
_alert_pushed_at: dict[str, float] = {}
#: 新出现的问题先等这么久再推：问题常常一冒就是一串（一次挂载故障 = 一条目录级告警 +
#: 每个卡住的种子一条），等它们出齐、收编好只推根因那条；这段时间里自己好了的也不推
_ALERT_DELAY_S = 90.0
_alert_queue: list[str] = []
_alert_flush: asyncio.TimerHandle | None = None
#: 一个订阅底下按种子各亮一条的告警：按订阅算冷却，不按种子
_PER_SUBSCRIPTION_ALERTS = ("subscription.ambiguous:", "subscription.landing:")


def _alert_family(dedupe_key: str) -> str:
    for prefix in _PER_SUBSCRIPTION_ALERTS:
        if dedupe_key.startswith(prefix):
            return prefix + dedupe_key[len(prefix) :].split(":", 1)[0]
    return dedupe_key


@_never_raise
def system_alert(*, dedupe_key: str, source: str, title: str, message: str, payload: dict) -> None:
    """待处理事项新出现或复发：等一会儿，和同一时间冒出来的一起推给管理员。"""
    global _alert_flush
    from movieclaw_api.services.push.dispatcher import spawn

    if dedupe_key not in _alert_queue:
        _alert_queue.append(dedupe_key)
    if _alert_flush is not None:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return  # 没有事件循环（命令行工具里）：不推

    def fire() -> None:
        global _alert_flush
        _alert_flush = None
        spawn(_send_alerts())

    _alert_flush = loop.call_later(_ALERT_DELAY_S, fire)


async def _send_alerts() -> None:
    """把攒下的待处理事项推出去：只推还亮着的、不在根因底下的、冷却期外的。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeSeverity, NoticeStatus, SystemNotice

    keys = list(_alert_queue)
    _alert_queue.clear()
    if not keys:
        return
    async with get_database().session() as session:
        rows = (
            (
                await session.execute(
                    select(SystemNotice).where(
                        SystemNotice.dedupe_key.in_(keys),  # type: ignore[attr-defined]
                        SystemNotice.status == NoticeStatus.ACTIVE.value,
                    )
                )
            )
            .scalars()
            .all()
        )
        parents = {
            str(row.payload.get("grouped_under"))
            for row in rows
            if isinstance(row.payload, dict) and row.payload.get("grouped_under")
        }
        active_parents = set(
            (
                await session.execute(
                    select(SystemNotice.dedupe_key).where(  # type: ignore[call-overload]
                        SystemNotice.dedupe_key.in_(parents),  # type: ignore[attr-defined]
                        SystemNotice.status == NoticeStatus.ACTIVE.value,
                    )
                )
            ).scalars()
        )
    now = time.monotonic()
    due: list[SystemNotice] = []
    for row in rows:
        payload = row.payload if isinstance(row.payload, dict) else {}
        if payload.get("grouped_under") in active_parents:
            continue  # 收在根因底下：推根因那条就够了
        family = _alert_family(row.dedupe_key)
        last = _alert_pushed_at.get(family)
        if last is not None and now - last < _ALERT_COOLDOWN_S:
            continue
        _alert_pushed_at[family] = now
        due.append(row)
    if not due:
        return
    # 严重的在前，同样严重的按出现先后
    due.sort(key=lambda r: (r.severity != NoticeSeverity.ERROR.value, keys.index(r.dedupe_key)))
    first = due[0]
    first_payload = first.payload if isinstance(first.payload, dict) else {}
    # 有严重的（下载器、站点整个不可用这类）就用时效性：专注模式下也要让管理员知道
    level = "time-sensitive" if first.severity == NoticeSeverity.ERROR.value else "active"
    if len(due) == 1:
        content = AlertContent(
            title=first.title,
            body=first.message,
            open=notice_path(first.source, first_payload),
            thread="system",
            source="server",
            level=level,
        )
        collapse = ("notice", first.dedupe_key)
    else:
        names = "；".join(r.title for r in due[:3])
        content = AlertContent(
            title=f"有 {len(due)} 个问题需要处理",
            body=names + ("等" if len(due) > 3 else ""),
            open=notice_path(first.source, first_payload),
            thread="system",
            source="server",
            level=level,
        )
        collapse = ("notice", "batch")

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        return content

    notify("system_alert", {0}, build, collapse=collapse)


def reset_state() -> None:
    """测试用：清掉内存里的推送状态（剧卡、冷却中的告警）。"""
    global _alert_flush
    from movieclaw_api.services.push import hub

    hub.reset_state()
    _alert_pushed_at.clear()
    _alert_queue.clear()
    if _alert_flush is not None:
        _alert_flush.cancel()
        _alert_flush = None


# ----------------------------------------------------------------------
# 有新版本（管理员）
# ----------------------------------------------------------------------


@_never_raise
def new_version(*, version: str, compatible: bool) -> None:
    """MovieClaw 发布了新版本：推给管理员（调用方保证每个版本只调一次）。"""

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        how = (
            "在「设置 → 更新与维护」里一键更新"
            if compatible
            else "这个版本要更新 Docker 镜像，步骤见「设置 → 更新与维护」"
        )
        return AlertContent(
            title=f"MovieClaw {version} 可以更新了",
            body=how,
            open="/settings/app",
            thread="update",
            source="server",
        )

    notify("new_version", {0}, build, collapse=("update", "app"))


# ----------------------------------------------------------------------
# 使用建议（管理员）
# ----------------------------------------------------------------------


@_never_raise
def reel_clips_suggested() -> None:
    """开关关着时有人刷片、放了大图预告：建议管理员开启片段预切（调用方保证只调一次）。"""

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        return AlertContent(
            title="开启片段预切，预告和刷片更流畅",
            body="家里已经有人在刷片或看电视大图预告了。在「设置 → 播放」打开片段预切，"
            "起播更快、不卡顿。",
            open="/settings/playback",
            thread="tips",
            source="server",
        )

    notify("usage_tip", {0}, build, collapse=("tip", "reel-clips"))

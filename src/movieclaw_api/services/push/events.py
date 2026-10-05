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
from collections.abc import Callable
from dataclasses import dataclass, field, replace
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


def _season_name(season: int) -> str:
    return "特别篇" if season == 0 else f"第 {season} 季"


def episode_label(units: list[tuple[int, int]]) -> str:
    """单元描述（给人看）：电影为空；「第 2 季第 7 集」「第 1 季 8 集」「12 集」。"""
    episodes = sorted({u for u in units if u != (0, 0)})
    if not episodes:
        return ""
    if len(episodes) == 1:
        season, episode = episodes[0]
        return f"{_season_name(season)}第 {episode} 集"
    seasons = {s for s, _ in episodes}
    if len(seasons) == 1:
        return f"{_season_name(next(iter(seasons)))} {len(episodes)} 集"
    return f"{len(episodes)} 集"


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


#: 最近推过「入库」的 (成员, 条目, 季, 集) → 时间（电影是 (0, 0)）。「入库完成」和
#: 「媒体库有新片」对同一个人说的是同一件事，订阅对账、手动下载入库、新片检查又先后
#: 不定：谁先推了，后来的就不再推给这个人；同一批被对账两次也不会响两次。
#: 只在内存里：服务恰好在这几分钟里重启，最坏是多收一条。
_notified_units: dict[tuple[int, int, int, int], float] = {}
_NOTIFIED_TTL_S = 6 * 3600


def claim_units(
    member_id: int, item_id: int, units: list[tuple[int, int]]
) -> list[tuple[int, int]]:
    """这些单元里还没推给过这个人的（按原顺序），并记为已推。"""
    now = time.monotonic()
    for key, at in list(_notified_units.items()):
        if now - at > _NOTIFIED_TTL_S:
            del _notified_units[key]
    fresh = []
    for season, episode in dict.fromkeys(units or [(0, 0)]):
        key = (member_id, item_id, season, episode)
        if key not in _notified_units:
            _notified_units[key] = now
            fresh.append((season, episode))
    return fresh


async def _imported_content(
    session: AsyncSession,
    member_id: int,
    *,
    item_id: int,
    name: str,
    kind: str,
    units: list[tuple[int, int]],
    image,  # type: ignore[no-untyped-def]
) -> AlertContent:
    """「入库完成」的文案（订阅入库、手动下载入库共用）。

    点开到这个人能看到的库里的这一部 / 这一集。
    """
    single = units[0] if len(units) == 1 else None
    path = await _library_path(session, member_id, item_id, single)
    label = episode_label(units)
    if kind == "tv" and label:
        return AlertContent(
            title=f"{name} 更新了",
            body=f"{label}已入库，点开就能看",
            image=await image(),
            open=path,
            thread=f"item-{item_id}",
        )
    return AlertContent(
        title=f"{name} 已入库",
        body="点开就能看",
        image=await image(),
        open=path,
        thread=f"item-{item_id}",
    )


# ----------------------------------------------------------------------
# 订阅类事件
# ----------------------------------------------------------------------

#: 「入库完成」「洗版完成」按订阅攒一攒再发：直接下进库目录的季包是一集一集入账的，
#: 每入账一集就对账一次；整季洗版也是一集一集验证的——不攒的话十集就响十次。
#: 同一个订阅这么久没有新的就发出去，一直有新的也最多等 _MERGE_MAX_S
_MERGE_QUIET_S = 60.0
_MERGE_MAX_S = 600.0


@dataclass
class _Merging:
    """一个订阅正在攒的一条推送。"""

    started: float
    units: list[tuple[int, int]] = field(default_factory=list)
    #: 洗版：每个单元的「旧版本 → 新版本」
    changes: dict[tuple[int, int], tuple[str, str]] = field(default_factory=dict)
    handle: asyncio.TimerHandle | None = None


_merging: dict[tuple[str, int], _Merging] = {}


def _merge(
    key: tuple[str, int],
    add: Callable[[_Merging], None],
    send: Callable[[_Merging], None],
) -> None:
    """把这次的单元并进 ``key`` 正在攒的那条，安静一会儿再 ``send``。"""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:  # 没有事件循环（命令行工具里）：直接发
        merging = _Merging(started=0.0)
        add(merging)
        send(merging)
        return
    now = loop.time()
    merging = _merging.get(key)
    if merging is None:
        merging = _merging[key] = _Merging(started=now)
    add(merging)
    if merging.handle is not None:
        merging.handle.cancel()

    def fire() -> None:
        if _merging.get(key) is merging:
            del _merging[key]
        try:
            send(merging)
        except Exception:  # noqa: BLE001
            logger.exception("发送 App 推送失败（已忽略）")

    delay = max(0.0, min(_MERGE_QUIET_S, merging.started + _MERGE_MAX_S - now))
    merging.handle = loop.call_later(delay, fire)


@_never_raise
def imported(
    *,
    subscription_id: int,
    item_id: int,
    title: str,
    year: int | None,
    kind: str,
    units: list[tuple[int, int]],
    image_url: str | None,
) -> None:
    """订阅的内容整理进媒体库了（同一个订阅一分钟内的合成一条）。"""

    def add(merging: _Merging) -> None:
        merging.units.extend(u for u in units if u not in merging.units)

    def send(merging: _Merging) -> None:
        _send_imported(
            subscription_id=subscription_id,
            item_id=item_id,
            name=_display_title(title, year),
            kind=kind,
            units=sorted(merging.units),
            image_url=image_url,
        )

    _merge(("imported", subscription_id), add, send)


def _send_imported(
    *,
    subscription_id: int,
    item_id: int,
    name: str,
    kind: str,
    units: list[tuple[int, int]],
    image_url: str | None,
) -> None:
    image = _lazy_image(image_url)

    async def build(session: AsyncSession, member_id: int) -> AlertContent | None:
        if not await _item_visible(session, member_id, item_id):
            return None
        fresh = claim_units(member_id, item_id, units)
        if not fresh:
            return None  # 这几集刚推过（手动下载入库或「媒体库有新片」）
        content = await _imported_content(
            session, member_id, item_id=item_id, name=name, kind=kind, units=fresh, image=image
        )
        return replace(
            content,
            open=content.open or f"/subscriptions/{subscription_id}",
            thread=f"subscription-{subscription_id}",
        )

    notify("imported", subscribers(subscription_id), build)


@_never_raise
def download_started(
    *,
    subscription_id: int,
    item_id: int,
    title: str,
    year: int | None,
    units: list[tuple[int, int]],
    detail: str,
    upgrade: bool,
    image_url: str | None,
    skip_member_id: int | None = None,
) -> None:
    """订阅找到资源、交给下载器了。``skip_member_id``：手动选种时点下载的人，不推给他。"""
    image = _lazy_image(image_url)
    label = episode_label(units)
    name = _display_title(title, year)
    verb = "开始洗版下载" if upgrade else "开始下载"
    resolve = subscribers(subscription_id)

    async def recipients(session: AsyncSession) -> set[int]:
        return await resolve(session) - {skip_member_id}

    async def build(session: AsyncSession, member_id: int) -> AlertContent | None:
        if not await _item_visible(session, member_id, item_id):
            return None
        return AlertContent(
            title=f"{verb}：{name}",
            body=" · ".join(part for part in (label, detail) if part),
            image=await image(),
            open=f"/subscriptions/{subscription_id}",
            thread=f"subscription-{subscription_id}",
        )

    notify("download_started", recipients, build)


@_never_raise
def upgraded(
    *,
    subscription_id: int,
    item_id: int,
    title: str,
    year: int | None,
    unit: tuple[int, int],
    old_label: str,
    new_label: str,
    image_url: str | None,
) -> None:
    """订阅的内容换成了更好的版本（同一个订阅一分钟内的合成一条）。"""

    def add(merging: _Merging) -> None:
        if unit not in merging.units:
            merging.units.append(unit)
        merging.changes[unit] = (old_label, new_label)

    def send(merging: _Merging) -> None:
        image = _lazy_image(image_url)
        name = _display_title(title, year)
        label = episode_label(sorted(merging.units))
        pairs = set(merging.changes.values())
        # 每集都是同样的升级就写出来；各不相同只说换成了更好的版本
        change = f"{next(iter(pairs))[0]} → {next(iter(pairs))[1]}" if len(pairs) == 1 else ""

        async def build(session: AsyncSession, member_id: int) -> AlertContent | None:
            if not await _item_visible(session, member_id, item_id):
                return None
            return AlertContent(
                title=f"洗版完成：{name}",
                body=" · ".join(part for part in (label, change) if part) or "换成了更好的版本",
                image=await image(),
                open=f"/subscriptions/{subscription_id}",
                thread=f"subscription-{subscription_id}",
            )

        notify("upgraded", subscribers(subscription_id), build)

    _merge(("upgraded", subscription_id), add, send)


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
    if len(due) == 1:
        content = AlertContent(
            title=first.title,
            body=first.message,
            open=notice_path(first.source, first_payload),
            thread="system",
            source="server",
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
        )
        collapse = ("notice", "batch")

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        return content

    notify("system_alert", {0}, build, collapse=collapse)


def reset_state() -> None:
    """测试用：清掉内存里的推送状态（攒着的、冷却中的、推过的单元）。"""
    global _alert_flush
    for merging in _merging.values():
        if merging.handle is not None:
            merging.handle.cancel()
    _merging.clear()
    _notified_units.clear()
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

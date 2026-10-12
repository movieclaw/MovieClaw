"""剧卡：一个人、一部剧的一批下载只占一张通知卡（docs/design/cloud-push.md §5.1）。

只在推送事件中枢（hub.py）的消费者里运行，状态不加锁。

**一张卡的一生**（同一个 ``collapse_id``，手机上原地替换，不新增）：

1. 开始下载（被动，不响）：同一部剧 30 秒内投递的种子合成一条；
2. 首集入库后：在路上的集（订阅里已投递、还没入库的）都到了、安静 2 分钟 → 直接收尾；
   15 分钟还没到齐 → 先发「可以先看了」（响）；
3. 之后每批新入库原地更新进度（被动，不响），最多 5 分钟一次；
4. 收尾：全部到齐（响；离上次响不到 15 分钟就不响），或剩下的 2 小时没进展 →
   说清楚哪几集还没下好（响）。收尾后同一部剧再来新集是新的一批。

所以每批最多响两次：「可以先看」和「全部到齐」。

**三条入库链路共用这张卡**：订阅入库、手动下载入库、「媒体库有新片」。同一个人、同一集只出现
在一张卡上（收尾后 6 小时内再报同一集的不再推）。只是「媒体库有新片」来的（不是自己订阅、
下载的）安静送达。

**IM** 是同一个人的另一个渠道：这个人的卡发出去时也发到他的 IM（notify 里按偏好筛），
只是进度更新不发——IM 消息不能原地替换，每次进度都会是新的一条。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.push import card_content, hub
from movieclaw_api.services.push.card_content import Snapshot
from movieclaw_api.services.push.hub import (
    Downloaded,
    Imported,
    LibraryArrivals,
    Started,
    Tick,
    Unit,
    Upgraded,
)
from movieclaw_api.services.push.labels import units_text
from movieclaw_db.engine import get_database
from movieclaw_db.models import utcnow

logger = logging.getLogger("movieclaw_api.push.cards")

#: 同一部剧这么久没有新投递，就发「开始下载」
STARTED_QUIET_S = 30.0
#: 这么久没有新入库算一批到齐（在路上的也都到了时）
QUIET_S = 120.0
#: 首集入库后最多等这么久发「可以先看了」
PARTIAL_WAIT_S = 15 * 60.0
#: 进度更新至少隔这么久
PROGRESS_GAP_S = 5 * 60.0
#: 收尾离上次响铃不到这么久，就不再响
RING_GAP_S = 15 * 60.0
#: 剩下的集这么久没进展，就收尾说清楚
STUCK_S = 2 * 3600.0
#: 只有「开始下载」、一直没入库的卡留这么久
STALE_S = 48 * 3600.0
#: 收尾后这么久里再报同一集的，不再推给同一个人
RECENT_S = 6 * 3600.0
#: 一条汇总里点名的片数
NAMED_IN_SUMMARY = 3

#: 卡的键：(成员, 条目)
Key = tuple[int, int]


@dataclass
class Card:
    key: Key
    opened: float
    started: list[Unit] = field(default_factory=list)
    started_at: float | None = None
    started_pending: bool = False
    detail: str = ""
    upgrade: bool = False
    subscription_id: int | None = None
    arrived: list[Unit] = field(default_factory=list)
    first_arrival: float | None = None
    last_arrival: float | None = None
    #: 已经在推出去的消息里说过的
    announced: set[Unit] = field(default_factory=set)
    partial_sent: bool = False
    last_sent: float | None = None
    last_ring: float | None = None
    loud: bool = False
    timer: object | None = None
    due: float | None = None

    @property
    def member_id(self) -> int:
        return self.key[0]

    @property
    def item_id(self) -> int:
        return self.key[1]


_cards: dict[Key, Card] = {}
#: 收尾过的单元：(成员, 条目) → {单元: 收尾时间}
_recent: dict[tuple[int, int], dict[Unit, float]] = {}


def reset_state() -> None:
    for card in _cards.values():
        _cancel(card)
    _cards.clear()
    _recent.clear()
    for merging in _upgrades.values():
        if merging.timer is not None:
            merging.timer.cancel()  # type: ignore[attr-defined]
    _upgrades.clear()


# ----------------------------------------------------------------------
# 系统事件 → 剧卡（通知规则的聚合器，engine.py 调；只投进中枢队列，不阻塞）
# ----------------------------------------------------------------------


def _unit_pairs(media: Any, units: Any) -> tuple[Unit, ...]:
    """事件里的季集 → 剧卡的单元；电影在剧卡里是 (0, 0)。"""
    pairs = tuple((u.season, u.episode) for u in units)
    if not pairs and media.kind == "movie":
        return ((0, 0),)
    return pairs


def on_event(name: str, payload: Any) -> None:
    if name == "subscription.download_started":
        hub.emit(
            Started(
                subscription_id=payload.subscription_id,
                item_id=payload.media.id,
                units=_unit_pairs(payload.media, payload.units),
                detail=payload.torrent.resolution or "",
                upgrade=payload.upgrade,
                skip_member_id=payload.actor_member_id,
            )
        )
    elif name == "subscription.fulfilled":
        # 只报还在订阅范围里的季集（用户从订阅里去掉的顺带入库了，不是他在等的）
        units = _unit_pairs(payload.media, payload.requested_units)
        if units:
            hub.emit(
                Imported(
                    subscription_id=payload.subscription_id,
                    item_id=payload.media.id,
                    units=units,
                )
            )
    elif name == "download.imported":
        hub.emit(
            Downloaded(
                member_id=payload.member_id,
                library_id=payload.library_id,
                items=tuple(
                    (i.media.id, tuple((u.season, u.episode) for u in i.units))
                    for i in payload.items
                ),
            )
        )
    elif name == "library.items.arrived":
        hub.emit(
            LibraryArrivals(
                library_id=payload.library_id,
                items=tuple(
                    (i.media.id, _unit_pairs(i.media, i.units)) for i in payload.items
                ),
            )
        )
    elif name == "subscription.upgraded":
        unit = payload.unit
        hub.emit(
            Upgraded(
                subscription_id=payload.subscription_id,
                item_id=payload.media.id,
                unit=(unit.season, unit.episode) if unit is not None else (0, 0),
                old_label=payload.old_label,
                new_label=payload.new_label,
            )
        )


# ----------------------------------------------------------------------
# 事件入口（hub 的消费者调）
# ----------------------------------------------------------------------


async def handle(event: object) -> None:
    if isinstance(event, Tick):
        if event.key and event.key[0] == "upgrade":
            await _flush_upgrade(event.key[1])
        else:
            await _tick(event.key)  # type: ignore[arg-type]
    elif isinstance(event, Started):
        await _on_started(event)
    elif isinstance(event, Imported):
        await _on_imported(event)
    elif isinstance(event, Downloaded):
        await _on_downloaded(event)
    elif isinstance(event, LibraryArrivals):
        await _on_library(event)
    elif isinstance(event, Upgraded):
        _on_upgraded(event)


async def _audience(
    session: AsyncSession, members: set[int], item_id: int, event: str | None
) -> list[int]:
    """这些人里：打开了这个事件（None 不看开关）、没静音这部、看得到这部的。"""
    from movieclaw_api.services.push import preferences
    from movieclaw_api.services.push.audience import item_visible

    if event is not None:
        members = await preferences.wants(session, members, event)
    muted = await preferences.muted_items(session, members)
    result = []
    for member_id in sorted(members):
        if item_id in muted.get(member_id, set()):
            continue
        if await item_visible(session, member_id, item_id):
            result.append(member_id)
    return result


async def _on_started(event: Started) -> None:
    from movieclaw_api.services.push.audience import subscribers

    async with get_database().session() as session:
        members = await subscribers(event.subscription_id)(session)
        members.discard(event.skip_member_id)  # type: ignore[arg-type]
        audience = await _audience(session, members, event.item_id, None)
    for member_id in audience:
        card = _card((member_id, event.item_id))
        card.started.extend(u for u in event.units if u not in card.started)
        card.started_at = hub.now()
        card.started_pending = True
        card.detail = event.detail or card.detail
        card.upgrade = event.upgrade
        card.subscription_id = card.subscription_id or event.subscription_id
        if not card.arrived:
            _wake(card, card.started_at + STARTED_QUIET_S)


async def _on_imported(event: Imported) -> None:
    from movieclaw_api.services.push.audience import subscribers

    async with get_database().session() as session:
        members = await subscribers(event.subscription_id)(session)
        audience = await _audience(session, members, event.item_id, "subscription.fulfilled")
    for member_id in audience:
        _arrive((member_id, event.item_id), list(event.units), loud=True, sub=event.subscription_id)


async def _on_downloaded(event: Downloaded) -> None:
    """手动下载入库完了：一部就进这部的卡，一次下了好几部（合集）合成一条汇总。"""
    from movieclaw_api.services.push import downloads

    member_id = event.member_id
    async with get_database().session() as session:
        mine: dict[int, list[Unit]] = {}
        for item_id, item_units in event.items:
            if await _audience(session, {member_id}, item_id, "subscription.fulfilled"):
                fresh = _fresh(member_id, item_id, list(item_units))
                if fresh:
                    mine[item_id] = fresh
    if not mine:
        return
    if len(mine) == 1:
        item_id, item_units = next(iter(mine.items()))
        _arrive((member_id, item_id), item_units, loud=True)
        return
    for item_id, item_units in mine.items():
        _remember(member_id, item_id, item_units)
    downloads.announce_summary(member_id, event.library_id, list(mine))


async def _on_library(event: LibraryArrivals) -> None:
    """「媒体库有新片」：每个人只剩一部要说的进这部的卡（安静送达），好几部合成一条汇总。"""
    from movieclaw_api.services.push import arrivals

    async with get_database().session() as session:
        members = await arrivals.recipients(event.library_id)(session)
        per_member: dict[int, dict[int, list[Unit]]] = {}
        for item_id, units in event.items:
            for member_id in await _audience(session, members, item_id, None):
                fresh = _fresh(member_id, item_id, list(units))
                if fresh:
                    per_member.setdefault(member_id, {})[item_id] = fresh
    for member_id, items in per_member.items():
        if len(items) == 1:
            item_id, units = next(iter(items.items()))
            _arrive((member_id, item_id), units, loud=False)
            continue
        for item_id, units in items.items():
            _remember(member_id, item_id, units)
        arrivals.announce_summary(event.library_id, member_id, items)


# ----------------------------------------------------------------------
# 状态机
# ----------------------------------------------------------------------


def _card(key: Key) -> Card:
    card = _cards.get(key)
    if card is None:
        card = _cards[key] = Card(key=key, opened=hub.now())
    return card


def _fresh(member_id: int, item_id: int, units: list[Unit]) -> list[Unit]:
    """这些单元里还没在这个人的卡上出现过的（正开着的卡、6 小时内收尾的卡）。"""
    now = hub.now()
    recent = _recent.get((member_id, item_id), {})
    for unit, at in list(recent.items()):
        if now - at > RECENT_S:
            del recent[unit]
    card = _cards.get((member_id, item_id))
    seen = set(recent) | set(card.arrived if card else ())
    return [u for u in dict.fromkeys(units or [(0, 0)]) if u not in seen]


def _remember(member_id: int, item_id: int, units: list[Unit]) -> None:
    now = hub.now()
    recent = _recent.setdefault((member_id, item_id), {})
    for unit in units:
        recent[unit] = now


def _arrive(key: Key, units: list[Unit], *, loud: bool, sub: int | None = None) -> None:
    member_id, item_id = key
    units = _fresh(member_id, item_id, units)
    card = _cards.get(key)
    new = [u for u in units if card is None or u not in card.arrived]
    if not new:
        return
    card = card or _card(key)
    now = hub.now()
    card.arrived.extend(new)
    card.first_arrival = card.first_arrival or now
    card.last_arrival = now
    card.loud = card.loud or loud
    card.subscription_id = card.subscription_id or sub
    _wake(card, now + QUIET_S, force=True)


def _wake(card: Card, at: float, *, force: bool = False) -> None:
    """``at`` 时再看一眼这张卡。已经约了更早的就不动（``force``：改约到 ``at``）。"""
    if card.timer is not None and card.due is not None and card.due <= at and not force:
        return
    _cancel(card)
    card.due = at
    card.timer = hub.later(at - hub.now(), Tick(card.key))


def _cancel(card: Card) -> None:
    if card.timer is not None:
        card.timer.cancel()  # type: ignore[attr-defined]
    card.timer = None
    card.due = None


async def _tick(key: Key) -> None:
    card = _cards.get(key)
    if card is None:
        return
    card.timer = None
    card.due = None
    now = hub.now()
    if not card.arrived:
        if card.started_pending:
            due = (card.started_at or now) + STARTED_QUIET_S
            if now < due:
                return _wake(card, due)
            card.started_pending = False
            card.last_sent = now
            _send(card, Snapshot(**_base(card), phase="started"))
        if now - card.opened >= STALE_S:
            _close(card)
            return
        return _wake(card, card.opened + STALE_S)

    async with get_database().session() as session:
        subscriptions = await card_content.subscription_ids(session, card.member_id, card.item_id)
        pipe = await card_content.pipeline(session, subscriptions, card.item_id, utcnow())
    inflight = pipe.inflight - set(card.arrived)
    assert card.first_arrival is not None and card.last_arrival is not None
    quiet_due = card.last_arrival + QUIET_S

    if not inflight:
        if now < quiet_due:
            return _wake(card, quiet_due)
        quiet = card.last_ring is not None and now - card.last_ring < RING_GAP_S
        _send(card, _snapshot(card, "final", inflight, pipe.missing, quiet_finish=quiet))
        _close(card)
        return

    if not card.partial_sent:
        due = card.first_arrival + PARTIAL_WAIT_S
        if now < due:
            return _wake(card, due)
        card.partial_sent = True
        card.last_ring = now if card.loud else card.last_ring
        _send(card, _snapshot(card, "partial", inflight, pipe.missing))
        card.announced = set(card.arrived)
        card.last_sent = now
        return _wake(card, card.last_arrival + STUCK_S)

    stuck_due = card.last_arrival + STUCK_S
    if now >= stuck_due:
        _send(card, _snapshot(card, "stuck", inflight, pipe.missing))
        _close(card)
        return
    if set(card.arrived) - card.announced:
        due = max(quiet_due, (card.last_sent or 0.0) + PROGRESS_GAP_S)
        if now >= due:
            _send(card, _snapshot(card, "progress", inflight, pipe.missing))
            card.announced = set(card.arrived)
            card.last_sent = now
        else:
            return _wake(card, min(due, stuck_due))
    _wake(card, stuck_due)


def _base(card: Card) -> dict:
    return {
        "item_id": card.item_id,
        "arrived": tuple(card.arrived),
        "started": tuple(card.started),
        "detail": card.detail,
        "upgrade": card.upgrade,
        "loud": card.loud,
        "subscription_id": card.subscription_id,
    }


def _snapshot(
    card: Card,
    phase: str,
    inflight: set[Unit],
    missing: set[Unit],
    *,
    quiet_finish: bool = False,
) -> Snapshot:
    return Snapshot(
        **_base(card),
        phase=phase,
        inflight=tuple(sorted(inflight)),
        missing=tuple(sorted(missing - set(card.arrived))),
        quiet_finish=quiet_finish,
    )


def _close(card: Card) -> None:
    _cancel(card)
    _cards.pop(card.key, None)
    if card.arrived:
        _remember(card.member_id, card.item_id, card.arrived)


def _send(card: Card, snap: Snapshot) -> None:
    from movieclaw_api.services.push.notify import notify

    member_id = card.member_id
    if snap.phase == "started":
        event = "subscription.download_started"
    else:
        event = "subscription.fulfilled" if snap.loud else "library.items.arrived"

    async def build(session: AsyncSession, recipient: int):  # type: ignore[no-untyped-def]
        return await card_content.build(session, recipient, snap)

    notify(
        event,
        {member_id},
        build,
        collapse=("card", f"{member_id}:{card.item_id}"),
        to_im=snap.phase != "progress",
    )


# ----------------------------------------------------------------------
# 洗版完成（按订阅合并，被动）
# ----------------------------------------------------------------------

#: 洗版是一集一集验证的：同一个订阅这么久没有新的就发，一直有新的最多等这么久
UPGRADE_QUIET_S = 60.0
UPGRADE_MAX_S = 600.0


@dataclass
class _Upgrades:
    item_id: int
    started: float
    changes: dict[Unit, tuple[str, str]] = field(default_factory=dict)
    timer: object | None = None


_upgrades: dict[int, _Upgrades] = {}


def _on_upgraded(event: Upgraded) -> None:
    now = hub.now()
    merging = _upgrades.get(event.subscription_id)
    if merging is None:
        merging = _upgrades[event.subscription_id] = _Upgrades(item_id=event.item_id, started=now)
    merging.changes[event.unit] = (event.old_label, event.new_label)
    if merging.timer is not None:
        merging.timer.cancel()  # type: ignore[attr-defined]
    delay = max(0.0, min(UPGRADE_QUIET_S, merging.started + UPGRADE_MAX_S - now))
    merging.timer = hub.later(delay, Tick(("upgrade", event.subscription_id)))


async def _flush_upgrade(subscription_id: int) -> None:
    from movieclaw_api.services.channel_push import tmdb_push_image_url
    from movieclaw_api.services.push.audience import (
        display_title,
        lazy_image,
        subscribers,
    )
    from movieclaw_api.services.push.notify import AlertContent, notify
    from movieclaw_db.models import MediaItem

    merging = _upgrades.pop(subscription_id, None)
    if merging is None:
        return
    async with get_database().session() as session:
        item = await session.get(MediaItem, merging.item_id)
        if item is None:
            return
        audience = await _audience(
            session, await subscribers(subscription_id)(session), merging.item_id, None
        )
    units = sorted(merging.changes)
    label = units_text(units)
    pairs = set(merging.changes.values())
    # 每集都是同样的升级就写出来；各不相同只说换成了更好的版本
    change = " → ".join(next(iter(pairs))) if len(pairs) == 1 else ""
    image = lazy_image(tmdb_push_image_url(item.backdrop_path, item.poster_path))
    name = display_title(item.title, item.year)

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        return AlertContent(
            title=f"洗版完成：{name}",
            body=" · ".join(part for part in (label, change) if part) or "换成了更好的版本",
            image=await image(),
            open=f"/subscriptions/{subscription_id}",
            thread=f"item-{merging.item_id}",
            level="passive",
            relevance=0.3,
        )

    if audience:
        notify("subscription.upgraded", set(audience), build)

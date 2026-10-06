"""剧卡的文案（docs/design/cloud-push.md §5.1）：一部剧的一批下载在每个人手机上怎么写。

状态机（cards.py）只决定**什么时候**发、发哪个阶段；这里在推送自己的后台任务里查事实、
写文案，按收件人各写各的：

- **阶段**：开始下载 → 可以先看了（还有集在路上）→ 进度（静默）→ 收尾（全部到齐 / 卡住）；
- **按观看进度**（``playback_state``，与「接下来继续」同一口径）：正好追到上一集说「接着看」
  并附下一集的播出日期；落后好几集提醒还有几集没看、点开到他该看的那一集；还没开始看从第 1 集
  开始；30 天没看过（弃剧）的改成安静送达；
- **整季、全剧**：已入库的覆盖了 TMDB 上这一季的全部集，写「第 1 季已全部入库」；剧已完结、
  每一季都齐了写「全剧已入库」；
- **长按**：快捷操作（播放第 N 集 / 查看全部剧集 / 这部剧不再提醒）与集数格子。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.push.labels import (
    Unit,
    by_season,
    count_text,
    season_name,
    unit_text,
    units_text,
)
from movieclaw_api.services.push.notify import AlertContent
from movieclaw_db.models import (
    MediaEpisode,
    MediaItem,
    MediaSeason,
    PlaybackState,
    Subscription,
    SubscriptionFollower,
    WantedItem,
    WantedStatus,
    utcnow,
)

#: 投递后这么久还没入库的不算「在路上」：早就卡死的种子不该拖住每一张新卡
INFLIGHT_WINDOW = timedelta(hours=48)
#: 播出这么久还没找到资源才说「没找到」：追新剧播出当天资源还没出是常态
MISSING_GRACE = timedelta(days=2)
#: 这么久没看过这部剧算弃剧：它的更新安静送达
ABANDONED = timedelta(days=30)
#: 最近这么久看过算「在追」：通知摘要里排在最前
WATCHING = timedelta(days=14)
#: 一次小更新最多几集（按「第 8 集来了」写；更多的按一批写）
SMALL_UPDATE = 3
#: 集数格子最多几格（一季几百集的日播剧不画）
GRID_MAX = 200
#: 剧集已完结的 TMDB 状态
ENDED = ("Ended", "Canceled")


# ----------------------------------------------------------------------
# 事实
# ----------------------------------------------------------------------


async def subscription_ids(session: AsyncSession, member_id: int | None, item_id: int) -> list[int]:
    """这部片上这个人订阅（发起或关注）的订阅；``member_id`` 为 None 时是这部片的全部订阅。"""
    rows = (
        await session.execute(
            select(Subscription.id, Subscription.created_by_member_id).where(  # type: ignore[call-overload]
                Subscription.media_item_id == item_id
            )
        )
    ).all()
    if member_id is None:
        return [int(r[0]) for r in rows]
    mine = {int(sid) for sid, creator in rows if (creator or 0) == member_id}
    others = [int(sid) for sid, _ in rows if int(sid) not in mine]
    if others:
        followed = (
            await session.execute(
                select(SubscriptionFollower.subscription_id).where(  # type: ignore[call-overload]
                    SubscriptionFollower.subscription_id.in_(others),  # type: ignore[attr-defined]
                    SubscriptionFollower.member_id == member_id,
                )
            )
        ).scalars()
        mine.update(int(s) for s in followed)
    return sorted(mine)


@dataclass
class Pipeline:
    """订阅里还没入库的集：在路上的（已投递、48 小时内）和播出好几天还没找到资源的。"""

    inflight: set[Unit] = field(default_factory=set)
    missing: set[Unit] = field(default_factory=set)


async def pipeline(
    session: AsyncSession, subscriptions: list[int], item_id: int, now: datetime
) -> Pipeline:
    result = Pipeline()
    if not subscriptions:
        return result
    rows = (
        await session.execute(
            select(  # type: ignore[call-overload]
                WantedItem.season_number,
                WantedItem.episode_number,
                WantedItem.status,
                WantedItem.grabbed_at,
                WantedItem.air_date,
            ).where(
                WantedItem.media_item_id == item_id,
                WantedItem.subscription_id.in_(subscriptions),  # type: ignore[attr-defined]
                WantedItem.in_scope.is_(True),  # type: ignore[attr-defined]
                WantedItem.status != WantedStatus.IMPORTED.value,
            )
        )
    ).all()
    aired_before = (now - MISSING_GRACE).date()
    pending = (WantedStatus.GRABBED.value, WantedStatus.DOWNLOADED.value)
    for season, episode, status, grabbed_at, air_date in rows:
        unit = (int(season), int(episode))
        if status in pending:
            if grabbed_at is not None and grabbed_at >= now - INFLIGHT_WINDOW:
                result.inflight.add(unit)
        elif status == WantedStatus.WANTED.value and air_date and air_date <= aired_before:
            result.missing.add(unit)
    return result


async def season_totals(session: AsyncSession, item_id: int) -> dict[int, int]:
    """季 → 一共几集（TMDB 宣称的集数和分集表取大的；不知道的季不在里面）。"""
    totals: dict[int, int] = {}
    for season, count in (
        await session.execute(
            select(MediaSeason.season_number, MediaSeason.episode_count).where(  # type: ignore[call-overload]
                MediaSeason.media_item_id == item_id
            )
        )
    ).all():
        if count:
            totals[int(season)] = int(count)
    for season, count in (
        await session.execute(
            select(MediaEpisode.season_number, func.count())  # type: ignore[call-overload]
            .where(MediaEpisode.media_item_id == item_id)
            .group_by(MediaEpisode.season_number)
        )
    ).all():
        totals[int(season)] = max(totals.get(int(season), 0), int(count))
    return totals


async def in_place_units(session: AsyncSession, member_id: int, item_id: int) -> dict[Unit, int]:
    """这个人能看到的库里，这部片在位的单元 → 落点库。"""
    from movieclaw_api.services.library.access import member_visible_ids
    from movieclaw_api.services.playback_up_next import _in_place_units

    visible = await member_visible_ids(session, member_id)
    return (await _in_place_units(session, [item_id], set(visible))).get(item_id, {})


@dataclass
class Viewer:
    """这个人看这部剧看到哪了。"""

    #: fresh 还没开始看 / caught_up 正好追到 / behind 落后几集 / abandoned 弃剧
    kind: str
    #: 最近播放的单元
    anchor: Unit | None = None
    #: 该看的下一集（点开、播放都到这里）
    next_unit: Unit | None = None
    #: 从该看的那集到这批最后一集，没看完的
    unwatched: list[Unit] = field(default_factory=list)
    #: 看完了的单元
    played: set[Unit] = field(default_factory=set)
    #: 最近两周看过
    watching: bool = False


def _regular_first(unit: Unit) -> tuple[bool, int, int]:
    """排序键：正片在前、特别篇在后。"""
    return (unit[0] == 0, unit[0], unit[1])


async def viewer(
    session: AsyncSession,
    member_id: int,
    item_id: int,
    available: dict[Unit, int],
    new_units: list[Unit],
    now: datetime,
) -> Viewer:
    """按「接下来继续」的口径算这个人的位置：锚点（最近播放的单元）起第一个没看完、在位的单元。"""
    from movieclaw_api.services.playback_up_next import _states, _unfinished

    states = {
        unit: state
        for (_, unit), state in (await _states(session, member_id, [item_id])).items()
        if unit[0] >= 0 and unit[1] >= 0
    }
    played = {unit for unit, (done, _) in states.items() if done}
    anchor_row = (
        await session.execute(
            select(  # type: ignore[call-overload]
                PlaybackState.season_number,
                PlaybackState.episode_number,
                PlaybackState.last_played_at,
            )
            .where(
                PlaybackState.member_id == member_id,
                PlaybackState.media_item_id == item_id,
                PlaybackState.last_played_at.is_not(None),  # type: ignore[union-attr]
                PlaybackState.season_number >= 0,
                PlaybackState.episode_number >= 0,
            )
            .order_by(PlaybackState.last_played_at.desc(), PlaybackState.id.desc())  # type: ignore[union-attr]
            .limit(1)
        )
    ).first()
    ordered = sorted(available, key=_regular_first)
    if anchor_row is None:
        return Viewer(kind="fresh", next_unit=ordered[0] if ordered else None, played=played)
    anchor = (int(anchor_row[0]), int(anchor_row[1]))
    last_played: datetime = anchor_row[2]
    if last_played < now - ABANDONED:
        return Viewer(kind="abandoned", anchor=anchor, played=played)
    pending = sorted(u for u in available if u >= anchor and _unfinished(states.get(u)))
    watching = last_played >= now - WATCHING
    first_new = min(new_units) if new_units else None
    if not pending or first_new is None or pending[0] >= first_new:
        next_unit = pending[0] if pending else first_new
        return Viewer(
            kind="caught_up",
            anchor=anchor,
            next_unit=next_unit,
            played=played,
            watching=watching,
        )
    last_new = max(new_units)
    return Viewer(
        kind="behind",
        anchor=anchor,
        next_unit=pending[0],
        unwatched=[u for u in pending if u <= last_new],
        played=played,
        watching=watching,
    )


async def next_air(
    session: AsyncSession, item_id: int, after: Unit, today: date
) -> tuple[int, date] | None:
    """``after`` 之后的下一集（同一季）还没播：返回集号和播出日期；没有就 None。"""
    row = (
        await session.execute(
            select(MediaEpisode.episode_number, MediaEpisode.air_date)  # type: ignore[call-overload]
            .where(
                MediaEpisode.media_item_id == item_id,
                MediaEpisode.season_number == after[0],
                MediaEpisode.episode_number > after[1],
            )
            .order_by(MediaEpisode.episode_number)
            .limit(1)
        )
    ).first()
    if row is None or row[1] is None or row[1] < today:
        return None
    return int(row[0]), row[1]


async def episode_still(session: AsyncSession, item_id: int, unit: Unit) -> str | None:
    return (
        await session.execute(
            select(MediaEpisode.still_path).where(  # type: ignore[call-overload]
                MediaEpisode.media_item_id == item_id,
                MediaEpisode.season_number == unit[0],
                MediaEpisode.episode_number == unit[1],
            )
        )
    ).scalar_one_or_none()


# ----------------------------------------------------------------------
# 文案
# ----------------------------------------------------------------------


@dataclass(frozen=True)
class Snapshot:
    """状态机交给文案的一张剧卡此刻的样子（发送那一刻定下，后台任务里慢慢写）。"""

    phase: str  # started / partial / progress / final / stuck
    item_id: int
    #: 这一批已经入库的（累计）
    arrived: tuple[Unit, ...] = ()
    #: 「开始下载」的集
    started: tuple[Unit, ...] = ()
    detail: str = ""
    upgrade: bool = False
    #: 还在路上的、播出好几天还没找到的
    inflight: tuple[Unit, ...] = ()
    missing: tuple[Unit, ...] = ()
    #: 收件人主动要的（订阅、手动下载）；只是「媒体库有新片」的为假，安静送达
    loud: bool = True
    #: 收尾离上次响铃不到 15 分钟：这次不再响
    quiet_finish: bool = False
    subscription_id: int | None = None


def _date_text(day: date) -> str:
    return f"{day.month} 月 {day.day} 日"


def _play_path(item_id: int, unit: Unit | None) -> str:
    if unit is None or unit == (0, 0):
        return f"/play/{item_id}"
    return f"/play/{item_id}/s{unit[0]:02d}e{unit[1]:02d}"


def _grid(
    season: int,
    totals: dict[int, int],
    available: dict[Unit, int],
    played: set[Unit],
    inflight: set[Unit],
    missing: set[Unit],
) -> dict | None:
    """一季的集数格子：``s`` 看过、``d`` 已入库、``w`` 下载中、``m`` 没找到、``-`` 其他。"""
    known = [u[1] for u in (*available, *inflight, *missing) if u[0] == season]
    total = max([totals.get(season, 0), *known])
    if total <= 1 or total > GRID_MAX:
        return None
    cells = []
    for episode in range(1, total + 1):
        unit = (season, episode)
        if unit in available:
            cells.append("s" if unit in played else "d")
        elif unit in inflight:
            cells.append("w")
        elif unit in missing:
            cells.append("m")
        else:
            cells.append("-")
    return {"season": season, "cells": "".join(cells)}


async def build(
    session: AsyncSession, member_id: int, snap: Snapshot, now: datetime | None = None
) -> AlertContent | None:
    """给这个人写这一阶段的剧卡；他看不到这部片返回 None。"""
    from movieclaw_api.services.push.events import (
        _display_title,
        _item_visible,
        _lazy_image,
        _library_path,
    )

    now = now or utcnow()
    if not await _item_visible(session, member_id, snap.item_id):
        return None
    item = await session.get(MediaItem, snap.item_id)
    if item is None:
        return None
    name = _display_title(item.title, item.year)
    arrived = sorted(set(snap.arrived))
    movie = item.kind != "tv" or not by_season(arrived or list(snap.started))
    thread = f"item-{snap.item_id}"
    backdrop = _image(item)

    if snap.phase == "started":
        return await _started(session, member_id, snap, item, name, movie, thread, backdrop)

    available = await in_place_units(session, member_id, snap.item_id)
    totals = await season_totals(session, snap.item_id) if not movie else {}
    who = await viewer(session, member_id, snap.item_id, available, arrived, now)
    regular = {s for s in (*totals, *(u[0] for u in available), *(u[0] for u in arrived)) if s > 0}
    multi = len(regular) > 1

    def label(units: list[Unit] | set[Unit], *, full: bool = False) -> str:
        return units_text(units, with_season=multi, totals=totals if full else None)

    def one(unit: Unit) -> str:
        return unit_text(unit, with_season=multi)

    # 点开、播放到这个人该看的那一集；弃剧的到剧集页
    target = None if who.kind == "abandoned" else who.next_unit
    if target is not None and target not in available:
        target = None
    page = await _library_path(session, member_id, snap.item_id, None)
    open_path = await _library_path(session, member_id, snap.item_id, target) or page
    if open_path is None and snap.subscription_id:
        open_path = f"/subscriptions/{snap.subscription_id}"

    def tail() -> str:
        if who.kind == "abandoned" or target is None or target == (0, 0):
            return "点开就能看"
        if who.kind == "fresh":
            return f"点开从{one(target)}开始"
        return f"点开接着看{one(target)}"

    level = "active" if snap.loud and who.kind != "abandoned" else "passive"
    single_image: Unit | None = None

    if movie and snap.phase in ("partial", "progress"):
        return None  # 电影只有一个单元，没有「先看」
    newcomer = await _newcomer(session, item, snap, arrived, available, label, tail)
    if newcomer is not None:
        title, body = newcomer
    elif movie:
        title, body = f"{name} 已入库", "点开就能看"
    elif snap.phase in ("partial", "progress"):
        title = f"{name} 可以先看了"
        body = f"{label(arrived)}已入库，其余 {len(snap.inflight)} 集还在下载"
        if snap.phase == "progress":
            level = "passive"
    elif snap.phase == "stuck":
        title = f"{name} {label(arrived)}已入库"
        body = f"{label(set(snap.inflight))}还没下好，下好了再告诉你"
    else:
        title, body, single_image = await _final(
            session,
            item,
            name,
            arrived,
            available,
            totals,
            who,
            snap,
            label,
            one,
            tail,
            now,
        )
        if snap.quiet_finish:
            level = "passive"

    image_url = backdrop
    if single_image is not None:
        still = await episode_still(session, snap.item_id, single_image)
        if still:
            from movieclaw_api.services.channel_push import tmdb_push_image_url

            image_url = tmdb_push_image_url(still, None)

    actions: list[dict] = []
    if target is not None or movie:
        play_unit = None if movie else target
        actions.append(
            {
                "id": "play",
                "title": "播放" if movie else f"播放{one(target)}",  # type: ignore[arg-type]
                "open": _play_path(snap.item_id, play_unit),
            }
        )
    if not movie and page:
        actions.append({"id": "open", "title": "查看全部剧集", "open": page})
    actions.append(
        {
            "id": "mute",
            "title": "这部片不再提醒" if movie else "这部剧不再提醒",
            "item": snap.item_id,
        }
    )
    grid = None
    if not movie:
        seasons = by_season(arrived)
        main = max(seasons, key=lambda s: (len(seasons[s]), s)) if seasons else None
        if main is not None:
            grid = _grid(main, totals, available, who.played, set(snap.inflight), set(snap.missing))
    return AlertContent(
        title=title,
        body=body,
        image=await _lazy_image(image_url)(),
        open=open_path,
        thread=thread,
        level=level,
        relevance=_relevance(level, who),
        category="item",
        actions=actions,
        grid=grid,
    )


async def _newcomer(
    session: AsyncSession,
    item: MediaItem,
    snap: Snapshot,
    arrived: list[Unit],
    available: dict[Unit, int],
    label,  # type: ignore[no-untyped-def]
    tail,  # type: ignore[no-untyped-def]
) -> tuple[str, str] | None:
    """「媒体库有新片」来的、库里以前没有这部：「新片：流浪地球 2 / 已加入『电影』，点开就能看」。

    自己订阅、下载的不这么写（他知道是什么），已有剧集的更新按观看进度写。
    """
    from movieclaw_db.models import Library

    if snap.loud or snap.phase != "final" or not available or not set(available) <= set(arrived):
        return None
    library = await session.get(Library, next(iter(available.values())))
    if library is None:
        return None
    videos = library.kind not in ("movie", "tv")  # 「其他」库：家庭录像、课程这类，不叫「片」
    kind = "新视频" if videos else "新剧" if item.kind == "tv" else "新片"
    scope = label(arrived)
    body = f"已加入「{library.name}」" + (f"，{scope}" if scope else "") + f"，{tail()}"
    return f"{kind}：{item.title}", body


async def _started(
    session: AsyncSession,
    member_id: int,
    snap: Snapshot,
    item: MediaItem,
    name: str,
    movie: bool,
    thread: str,
    image_url: str | None,
) -> AlertContent:
    from movieclaw_api.services.push.events import _lazy_image

    started = sorted(set(snap.started))
    verb = "开始洗版下载" if snap.upgrade else "开始下载"
    label = "" if movie else units_text(started, with_season=True)
    head = " · ".join(part for part in (label, snap.detail) if part)
    if snap.upgrade:
        body = head or "换成更好的版本"
    else:
        promise = "第一批下好就告诉你" if len(started) > 1 else "下好就告诉你"
        body = f"{head}，{promise}" if head else promise
    return AlertContent(
        title=f"{name} {verb}",
        body=body,
        image=await _lazy_image(image_url)(),
        open=f"/subscriptions/{snap.subscription_id}" if snap.subscription_id else None,
        thread=thread,
        level="passive",
        relevance=0.3,
    )


async def _final(
    session: AsyncSession,
    item: MediaItem,
    name: str,
    arrived: list[Unit],
    available: dict[Unit, int],
    totals: dict[int, int],
    who: Viewer,
    snap: Snapshot,
    label,  # type: ignore[no-untyped-def]
    one,  # type: ignore[no-untyped-def]
    tail,  # type: ignore[no-untyped-def]
    now: datetime,
) -> tuple[str, str, Unit | None]:
    """收尾：全剧 / 整季 / 小更新（按观看进度说话）/ 一批。返回标题、正文、配单集剧照的单元。"""
    seasons = by_season(arrived)

    def complete(season: int) -> bool:
        total = totals.get(season, 0)
        return bool(total) and all((season, e) in available for e in range(1, total + 1))

    regular = sorted(s for s in totals if s > 0)
    if item.status in ENDED and regular and all(complete(s) for s in regular):
        episodes = sum(totals[s] for s in regular)
        scope = f"全 {episodes} 集" if len(regular) == 1 else f"{len(regular)} 季 {episodes} 集"
        return f"{name} 全剧已入库", f"{scope}都能看了，{tail()}", None
    if len(seasons) == 1:
        season = next(iter(seasons))
        if season > 0 and complete(season) and len(arrived) > 1:
            return (
                f"{name} {season_name(season)}已全部入库",
                f"{totals[season]} 集都能看了，{tail()}",
                None,
            )
        if len(arrived) <= SMALL_UPDATE:
            upcoming = None
            if who.kind == "caught_up":
                upcoming = await next_air(session, item.id or 0, arrived[-1], now.date())
            title, body = _small_update(name, arrived, available, who, label, one, upcoming)
            return title, body, arrived[-1]
    missing = sorted(u for u in snap.missing if u[0] in seasons)
    if missing:
        return (
            f"{name} {label(arrived, full=True)}已入库",
            f"{label(missing)}还没找到资源，找到了再告诉你",
            None,
        )
    return f"{name} {label(arrived, full=True)}已入库", tail(), None


def _small_update(name, arrived, available, who, label, one, upcoming):  # type: ignore[no-untyped-def]
    """一两集的更新（周更）：按这个人看到哪了说话。``upcoming`` 是下一集的集号和播出日期。"""
    batch = label(arrived)
    if who.kind == "abandoned":
        return f"{name} {batch}已入库", units_text(arrived, with_season=True)
    if who.kind == "fresh":
        season = arrived[0][0]
        so_far = sorted(u for u in available if u[0] == season) or arrived
        start = who.next_unit or (so_far[0] if so_far else arrived[0])
        return (
            f"{name} 更新到{one(arrived[-1])}了",
            f"{label(so_far)}都能看，点开从{one(start)}开始",
        )
    if who.kind == "behind":
        return (
            f"{name} {batch}来了",
            f"你还有{label(who.unwatched)}没看，点开接着看{one(who.next_unit)}",
        )
    body = f"你看到{one(who.anchor)}，正好接上" if who.anchor else "点开就能看"
    if upcoming is not None:
        episode, day = upcoming
        body += f" · {one((arrived[-1][0], episode))} {_date_text(day)}更新"
    return f"{name} {batch}来了", body


def _relevance(level: str, who: Viewer) -> float:
    if level == "passive":
        return 0.2 if who.kind == "abandoned" else 0.3
    if who.watching:
        return 1.0
    return 0.8 if who.kind == "fresh" else 0.6


def _image(item: MediaItem) -> str | None:
    from movieclaw_api.services.channel_push import tmdb_push_image_url

    return tmdb_push_image_url(item.backdrop_path, item.poster_path)


__all__ = ["Snapshot", "build", "count_text"]

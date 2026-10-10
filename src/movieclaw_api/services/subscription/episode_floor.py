"""集数下限：TMDB 少录集数时让订阅继续追（issue #640，docs/design/subscription-episode-floor.md）。

TMDB 对国产剧常只录了一部分集（真实案例：6 集 vs 实际 27 集）。期望集合 E
只认 TMDB 的集，订阅下完第 6 集就判「已收齐」，站点上的第 7 集被当成"不覆盖
任何缺口"静默丢弃，连手动选种都投不出去。

三件事，都挂在订阅上（只影响这一个订阅，填错也不污染条目元数据）：

- **下限** ``episode_floors``：用户确认的「本季至少 N 集」。``expected_units``
  把超出 TMDB 的部分展开成占位单元，TMDB 补全后同号单元自然接上；
- **证据** ``episode_evidence``：站点种子声明了超出的集号（含「全 N 集」）、
  豆瓣集数更多——系统只记录，绝不自己改 E；
- **提示**：证据多于当前已知集数且未被忽略时挂在订阅详情上，并阻止订阅判
  「已收齐」——否则订阅一完成用户就不再点开，提示永远没人看见。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models import (
    ActivityType,
    MediaEpisode,
    MediaItem,
    SiteTorrent,
    Subscription,
    SubscriptionActivity,
    SubscriptionStatus,
)
from movieclaw_db.repositories import SubscriptionRepository
from movieclaw_media.models import MediaKind

logger = logging.getLogger("movieclaw_api.subscription.episode_floor")

# 单季集数上限：防手滑与识别噪声（长寿剧如海贼王一千一百多集也够用）
FLOOR_MAX = 2000


@dataclass(frozen=True)
class EpisodeHint:
    """一条待确认的集数提示：证据说本季比现在追的更多。"""

    season_number: int
    known_count: int  # TMDB 已录到的最大集号
    floor: int | None  # 当前已设的下限
    suggested: int  # 证据给出的集数（站点与豆瓣取大）
    site_episode: int | None
    site_title: str | None
    douban_count: int | None


def _int(value: Any) -> int | None:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def floors_of(subscription: Subscription) -> dict[int, int]:
    """订阅的集数下限 {季号: 集数}（JSON 键是字符串，这里统一转回整数）。"""
    floors: dict[int, int] = {}
    for season, count in (subscription.episode_floors or {}).items():
        season_number, number = _int(season), _int(count)
        if season_number is not None and number is not None:
            floors[season_number] = number
    return floors


def tracks_season(subscription: Subscription, season_number: int) -> bool:
    """该季是否在订阅范围内：勾选了，或开着自动续订（特别季除外）。"""
    return season_number in set(subscription.selected_seasons) or (
        subscription.follow_future and season_number != 0
    )


async def season_episode_max(session: AsyncSession, media_item_id: int) -> dict[int, int]:
    """TMDB 已录的每季最大集号 {季号: 集号}（集数据唯一事实源 media_episode）。"""
    rows = await session.execute(
        select(MediaEpisode.season_number, func.max(MediaEpisode.episode_number))
        .where(MediaEpisode.media_item_id == media_item_id)
        .group_by(MediaEpisode.season_number)
    )
    return {season: number for season, number in rows.all() if number}


def _season_evidence(subscription: Subscription) -> dict[int, dict[str, Any]]:
    raw = (subscription.episode_evidence or {}).get("seasons") or {}
    result: dict[int, dict[str, Any]] = {}
    for season, entry in raw.items():
        season_number = _int(season)  # 特别季不收证据，0 在这里一并滤掉
        if season_number is not None and isinstance(entry, dict):
            result[season_number] = entry
    return result


def _update_evidence(subscription: Subscription, season_number: int, **fields: Any) -> None:
    """改一季的证据。整体重新赋值：JSON 列原地改字典不会被识别为脏数据。"""
    evidence = dict(subscription.episode_evidence or {})
    seasons = dict(evidence.get("seasons") or {})
    entry = dict(seasons.get(str(season_number)) or {})
    entry.update(fields)
    seasons[str(season_number)] = entry
    evidence["seasons"] = seasons
    subscription.episode_evidence = evidence


def pending_hints(subscription: Subscription, known_max: dict[int, int]) -> list[EpisodeHint]:
    """待确认的集数提示：证据 > max(TMDB 已录, 已设下限)，且大于用户忽略过的值。"""
    if subscription.kind != MediaKind.TV.value:
        return []
    floors = floors_of(subscription)
    hints: list[EpisodeHint] = []
    for season_number, entry in sorted(_season_evidence(subscription).items()):
        if not tracks_season(subscription, season_number):
            continue
        site, douban = _int(entry.get("site")), _int(entry.get("douban"))
        suggested = max(site or 0, douban or 0)
        known = known_max.get(season_number, 0)
        floor = floors.get(season_number)
        if suggested <= max(known, floor or 0) or suggested <= (_int(entry.get("dismissed")) or 0):
            continue
        hints.append(
            EpisodeHint(
                season_number=season_number,
                known_count=known,
                floor=floor,
                suggested=suggested,
                site_episode=site,
                site_title=entry.get("site_title") if site else None,
                douban_count=douban,
            )
        )
    return hints


def dismiss_hint(subscription: Subscription, season_number: int, known_max: dict[int, int]) -> bool:
    """忽略某季的提示：记下当前证据值，只有更大的新证据才会再次提示。"""
    hint = next(
        (h for h in pending_hints(subscription, known_max) if h.season_number == season_number),
        None,
    )
    if hint is None:
        return False
    _update_evidence(subscription, season_number, dismissed=hint.suggested)
    return True


# ---------------------------------------------------------------------------
# 站点证据：种子声明了 TMDB 之外的集号
# ---------------------------------------------------------------------------


async def record_episode_overflow(
    session: AsyncSession,
    torrents: list[SiteTorrent],
    *,
    subscription_ids: set[int] | None = None,
) -> None:
    """扫一批种子，记下"身份对得上、集号却超出 TMDB"的证据。

    只看每个订阅**最新一季**：更早的季超出 TMDB 多半是动画的绝对集号，
    不是漏录。只记录与提示，不改 E——集数要用户确认才生效。
    """
    from movieclaw_api.services.subscription.core import recompute_subscription_status
    from movieclaw_api.services.subscription.matching import media_identity, to_candidate
    from movieclaw_matcher import match_identity

    candidates = [
        candidate
        for candidate in map(to_candidate, torrents)
        if candidate is not None and (candidate.attrs.episodes or candidate.attrs.episodes_total)
    ]
    if not candidates:
        return
    query = select(Subscription).where(
        Subscription.kind == MediaKind.TV.value,
        Subscription.status != SubscriptionStatus.PAUSED,
    )
    if subscription_ids is not None:
        query = query.where(Subscription.id.in_(subscription_ids))  # type: ignore[union-attr]
    subscriptions = list((await session.execute(query)).scalars().all())
    if not subscriptions:
        return

    repo = SubscriptionRepository(session)
    for subscription in subscriptions:
        known_max = await season_episode_max(session, subscription.media_item_id)
        tracked = sorted(s for s in known_max if s != 0 and tracks_season(subscription, s))
        if not tracked:
            continue
        latest = tracked[-1]
        entry = _season_evidence(subscription).get(latest, {})
        baseline = max(
            known_max[latest], floors_of(subscription).get(latest, 0), _int(entry.get("site")) or 0
        )
        item = await session.get(MediaItem, subscription.media_item_id)
        if item is None:
            continue
        identity = await media_identity(session, item, season_numbers=tuple(tracked))
        best: tuple[int, str] | None = None
        for candidate in candidates:
            match = match_identity(candidate, identity)
            if match is None or match.id_conflict:
                continue
            seen = max((e for s, e in match.episodes if s == latest), default=0)
            declared = match.declared_total or 0
            if declared and (
                match.pack_seasons == frozenset({latest})
                or (match.is_complete_series and len(tracked) == 1)
            ):
                seen = max(seen, declared)
            if baseline < seen <= FLOOR_MAX and (best is None or seen > best[0]):
                best = (seen, candidate.title)
        if best is None:
            continue
        seen, title = best
        _update_evidence(subscription, latest, site=seen, site_title=title)
        session.add(subscription)
        assert subscription.id is not None
        await repo.add_activity(
            SubscriptionActivity(
                subscription_id=subscription.id,
                type=ActivityType.EPISODE_HINT,
                message=(
                    f"站点出现了第 {latest} 季第 {seen} 集的资源（{title}），"
                    f"但 TMDB 只录了 {known_max[latest]} 集；"
                    "如果这部剧确实更长，可在订阅里调整集数继续追"
                ),
                payload={"season": latest, "site_episode": seen, "tmdb_count": known_max[latest]},
            )
        )
        logger.info(
            "《%s》站点出现 S%02dE%02d，超出 TMDB 的 %d 集，已记为集数证据",
            item.title,
            latest,
            seen,
            known_max[latest],
        )
        # 已收齐的订阅要退回追踪，提示才有人看得到
        await recompute_subscription_status(session, subscription, item)
    await session.commit()


# ---------------------------------------------------------------------------
# 豆瓣证据：豆瓣集数多于 TMDB
# ---------------------------------------------------------------------------


def set_douban_ref(subscription: Subscription, douban_id: str, season_number: int) -> None:
    """记下豆瓣条目对应的 TMDB 季。豆瓣按季拆条目，季号只有创建那一刻知道。"""
    evidence = dict(subscription.episode_evidence or {})
    evidence["douban_ref"] = {"id": douban_id, "season": season_number}
    subscription.episode_evidence = evidence


def douban_season(
    subscription: Subscription, item: MediaItem, known_max: dict[int, int]
) -> tuple[str, int] | None:
    """(豆瓣 ID, 对应季号)。没有创建时的季映射就只认单季剧——多季剧对不上季，宁可不比。"""
    ref = (subscription.episode_evidence or {}).get("douban_ref")
    if isinstance(ref, dict) and ref.get("id") and _int(ref.get("season")):
        return str(ref["id"]), int(ref["season"])
    regular = [season for season in known_max if season != 0]
    if item.douban_id and len(regular) == 1:
        return item.douban_id, regular[0]
    return None


async def refresh_douban_evidence(
    session: AsyncSession, subscription: Subscription, item: MediaItem
) -> bool:
    """取豆瓣集数记为证据（走豆瓣详情的持久缓存）。返回证据是否有变化。

    失败只记日志：豆瓣是锦上添花，不能拖住订阅创建或元数据刷新。
    """
    if subscription.kind != MediaKind.TV.value or item.id is None:
        return False
    known_max = await season_episode_max(session, item.id)
    target = douban_season(subscription, item, known_max)
    if target is None:
        return False
    douban_id, season_number = target
    from movieclaw_api.services.media_discover import get_douban_media_service

    try:
        count = await get_douban_media_service().episode_count(douban_id)
    except Exception:  # noqa: BLE001 -- 豆瓣不可用不影响订阅
        logger.warning("豆瓣集数获取失败：%s", douban_id, exc_info=True)
        return False
    if count is None or count > FLOOR_MAX:
        return False
    if _int(_season_evidence(subscription).get(season_number, {}).get("douban")) == count:
        return False
    _update_evidence(subscription, season_number, douban=count)
    session.add(subscription)
    if count > known_max.get(season_number, 0):
        assert subscription.id is not None
        await SubscriptionRepository(session).add_activity(
            SubscriptionActivity(
                subscription_id=subscription.id,
                type=ActivityType.EPISODE_HINT,
                message=(
                    f"豆瓣显示第 {season_number} 季共 {count} 集，"
                    f"TMDB 只录了 {known_max.get(season_number, 0)} 集；"
                    "可在订阅里确认按豆瓣集数继续追"
                ),
                payload={"season": season_number, "douban_count": count},
            )
        )
    return True


async def refresh_douban_evidence_by_id(subscription_id: int) -> None:
    """后台入口：自开会话取豆瓣证据并重算状态（订阅创建后调用，不阻塞创建请求）。"""
    from movieclaw_api.services.subscription.core import recompute_subscription_status
    from movieclaw_db.engine import get_database

    async with get_database().session() as session:
        subscription = await session.get(Subscription, subscription_id)
        if subscription is None:
            return
        item = await session.get(MediaItem, subscription.media_item_id)
        if item is None:
            return
        if await refresh_douban_evidence(session, subscription, item):
            await recompute_subscription_status(session, subscription, item)
            await session.commit()


_douban_tasks: set[asyncio.Task] = set()


def refresh_douban_evidence_soon(subscription_id: int) -> None:
    """把豆瓣取数挪出订阅创建请求（豆瓣限速 1 次/秒，冷缓存时要等）。

    没有运行中的事件循环时静默跳过，元数据刷新会兜底复查。
    """
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return

    async def _run() -> None:
        try:
            await refresh_douban_evidence_by_id(subscription_id)
        except Exception:  # noqa: BLE001 -- 后台锦上添花，失败等刷新兜底
            logger.warning("订阅 #%s 的豆瓣集数取数失败", subscription_id, exc_info=True)

    task = loop.create_task(_run())
    _douban_tasks.add(task)
    task.add_done_callback(_douban_tasks.discard)

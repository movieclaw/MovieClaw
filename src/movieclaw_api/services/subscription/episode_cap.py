"""订阅上限：一季上千集时，只订阅一部分（docs/design/subscription-episode-cap.md）。

TMDB 里一季可以有上千集（名侦探柯南 1186 集、国产漫剧动辄 1000+）。整季展开成
上千个工单，既占磁盘与入库后处理，也未必看得完。上限是用户确认的「这一季先订阅
哪一段」——一个窗口 ``{start, end}``，**期望集合 E 定义的一部分**：

- 完结的超长季从第 1 集订起：``{start: 1, end: 20}``，超出的集不在 E，「继续订阅」
  就是把 end 改大一次，``SubscriptionService.update`` 的 diff 负责补工单；
- 在播的超长季订最新的一批：``{start: 已播-19, end: None}``，end 不设上界，
  之后播出的集照常纳入——**上限不再与追新互斥**（追新进来的集只受 start 限制），
  「往前再订」就是把 start 改小；

清除窗口（``{}``）就回到今天的整季行为。与 ``episode_floor`` 方向相反：下限纠正
「这季其实有几集」（事实），窗口是「我先订阅这一段」（节奏）。
"""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.subscription.episode_floor import (
    FLOOR_MAX,
    floors_of,
    tracks_season,
)
from movieclaw_db.models import MediaEpisode, Subscription

# 单季上限的取值范围同集数下限：防手滑，长寿剧一千多集也够用
CAP_MAX = FLOOR_MAX


def _positive_int(value: object) -> int | None:
    try:
        number = int(value)  # type: ignore[call-overload]
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


@dataclass(frozen=True)
class EpisodeCap:
    """一季的订阅窗口：从第 ``start`` 集起（含），到第 ``end`` 集（含）。

    ``end=None`` 不设上界，之后播出的集照常纳入（追新与上限不再互斥）。
    ``start=1`` 且 ``end=None`` 等于整季，等价于不设窗口，不该存下来。
    """

    start: int = 1
    end: int | None = None

    def covers(self, episode_number: int) -> bool:
        return episode_number >= self.start and (self.end is None or episode_number <= self.end)

    @property
    def is_head_only(self) -> bool:
        """「从第 start 集起」的在播窗口：没有上界，新集自动进来。"""
        return self.end is None


def caps_of(subscription: Subscription) -> dict[int, EpisodeCap]:
    """订阅的集数窗口 {季号: EpisodeCap}。

    落库形态 ``{季号: {"start": x, "end": y}}``；键是字符串、这里统一转回整数。
    旧值是纯集号（只订到第 N 集的上限），读作 ``{start: 1, end: N}``。
    """
    caps: dict[int, EpisodeCap] = {}
    for season, value in (subscription.episode_caps or {}).items():
        season_number = _positive_int(season)
        if season_number is None:
            continue
        if isinstance(value, dict):
            start = _positive_int(value.get("start")) or 1
            end = _positive_int(value.get("end"))
            caps[season_number] = EpisodeCap(start=start, end=end)
            continue
        number = _positive_int(value)
        if number is not None:
            caps[season_number] = EpisodeCap(start=1, end=number)
    return caps


def known_max_of(episodes: list[MediaEpisode]) -> dict[int, int]:
    """每季已录的最大集号 {季号: 集号}。"""
    known_max: dict[int, int] = {}
    for episode in episodes:
        known_max[episode.season_number] = max(
            known_max.get(episode.season_number, 0), episode.episode_number
        )
    return known_max


@dataclass(frozen=True)
class EpisodeWindow:
    """被订阅窗口截断的一季：从第 ``start`` 集起到 ``end``（``None``=含今后新集），
    本季已录 ``total`` 集。"""

    season_number: int
    start: int
    end: int | None
    total: int


def airing_season(media_status: str | None, aired: dict[int, int]) -> int | None:
    """剧还在播（TMDB ``Returning Series``）时最近一个开播的季；否则 None。

    与网页订阅弹层的「在播季」同口径。不设上界的窗口据此分两种读法：在播季是
    「最新 N 集」（之后播出的照常进来），完结季是「从第 N 集起」（issue #950）。
    """
    if media_status != "Returning Series":
        return None
    started = [season for season, count in aired.items() if season > 0 and count > 0]
    return max(started) if started else None


def windows_of(subscription: Subscription, known_max: dict[int, int]) -> list[EpisodeWindow]:
    """订阅范围内被窗口截断的季。

    总集数取 TMDB 已录的最大集号与集数下限中大的那个（下限撑起的占位集也算本季的集）。
    窗口盖住整季的季没有被截断，不在其中。
    """
    if not subscription.episode_caps:
        return []
    floors = floors_of(subscription)
    windows: list[EpisodeWindow] = []
    for season_number, cap in sorted(caps_of(subscription).items()):
        if not tracks_season(subscription, season_number):
            continue
        total = max(known_max.get(season_number, 0), floors.get(season_number, 0))
        if cap.start > 1 or (cap.end is not None and cap.end < total):
            windows.append(EpisodeWindow(season_number, cap.start, cap.end, total))
    return windows


async def season_episode_max_many(
    session: AsyncSession, media_item_ids: list[int]
) -> dict[int, dict[int, int]]:
    """批量取每个条目、每季的最大集号 {条目: {季号: 集号}}——订阅列表一次分组查完。"""
    if not media_item_ids:
        return {}
    rows = await session.execute(
        select(
            MediaEpisode.media_item_id,
            MediaEpisode.season_number,
            func.max(MediaEpisode.episode_number),
        )
        .where(MediaEpisode.media_item_id.in_(media_item_ids))  # type: ignore[attr-defined]
        .group_by(MediaEpisode.media_item_id, MediaEpisode.season_number)
    )
    result: dict[int, dict[int, int]] = {}
    for item_id, season, number in rows.all():
        if number:
            result.setdefault(item_id, {})[season] = number
    return result

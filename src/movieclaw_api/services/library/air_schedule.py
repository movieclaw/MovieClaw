"""剧集详情页的播出日历（issue #547）：一季的播出排期 + 与媒体库、订阅的对照。

数据全部来自本地：播出日期是刮削落库的 ``media_episode.air_date``，拥有状态
是库存台账，入库预告是订阅工单上已有的发布预测——打开详情页不发任何外部请求，
与「自足媒体库」一致。

只在当前季还有今天或以后的播出日期时给出（返回 None 时客户端整块不显示）：
已完结、季间空档、TMDB 没给分集日期的剧都没有可画的排期。日历按季走，与
分集区的季选择同步。
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.schemas.library import EpisodeArrivalView, SeasonAirScheduleView
from movieclaw_api.services.subscription.core import (
    _DEFAULT_RELEASE_TO_IMPORT_MINUTES,
    _forecast_predicted_at,
    _median_pipeline_minutes,
)
from movieclaw_api.services.subscription.matching import publish_calendar_date
from movieclaw_db.models import MediaItem, MediaMetadata, utcnow
from movieclaw_db.models.subscription import SubscriptionStatus, WantedStatus
from movieclaw_db.repositories.subscription_repo import SubscriptionRepository

# 首播地与站点日历（东八区）同一天的地区：这些地区的 air_date 直接当本地日期读。
# 其余地区（欧美等）的「10-28 播出」在国内往往已是 10-29，客户端在日期旁标注地区
_SAME_DAY_REGIONS = frozenset({"CN", "HK", "TW", "MO", "SG", "MY", "PH", "JP", "KR"})

# 更新规律只看近期：长剧开播时的周播、后来改日更，取最近三周才是"现在怎么更"
_CADENCE_LOOKBACK = timedelta(days=21)


async def build_season_air_schedule(
    session: AsyncSession,
    item: MediaItem,
    season_number: int,
    episodes: list[tuple[int, date | None, bool]],
) -> SeasonAirScheduleView | None:
    """``episodes`` 为本季每集的 (集号, 播出日期, 库里有没有)，取自分集清单本身，
    保证日历与分集卡说的是同一份数据。"""
    if season_number == 0 or item.id is None:
        return None
    today = publish_calendar_date(utcnow())
    dated = [(number, aired) for number, aired, _owned in episodes if aired is not None]
    if not any(aired >= today for _number, aired in dated):
        return None

    recent = {aired.weekday() for _number, aired in dated if aired >= today - _CADENCE_LOOKBACK}
    # 每集都有日期才敢说哪天完结：漏了日期的集可能排在最后
    complete = len(dated) == len(episodes)
    last_air_date = max(aired for _number, aired in dated) if complete else None

    metadata = (
        await session.execute(select(MediaMetadata).where(MediaMetadata.media_item_id == item.id))
    ).scalar_one_or_none()
    origins = [str(code).upper() for code in (metadata.origin_countries if metadata else []) or []]
    region = origins[0] if origins and not _SAME_DAY_REGIONS.intersection(origins) else None

    subscription_id, missing, arrivals = await _subscription_view(
        session, item.id, season_number, episodes, today
    )
    return SeasonAirScheduleView(
        today=today,
        region=region,
        weekdays=sorted(recent),
        last_air_date=last_air_date,
        subscription_id=subscription_id,
        missing_episodes=missing,
        arrivals=arrivals,
    )


async def _subscription_view(
    session: AsyncSession,
    media_item_id: int,
    season_number: int,
    episodes: list[tuple[int, date | None, bool]],
    today: date,
) -> tuple[int | None, list[int], list[EpisodeArrivalView]]:
    """订阅对本季的说法：缺了哪几集、哪几集在路上/预计何时入库。

    「缺集」只认订阅范围内、已经播出却还在找的工单——没订阅的剧库里没有的
    集不算缺（用户没打算追），订阅起始集之前的也不算。
    """
    repo = SubscriptionRepository(session)
    subscription = await repo.get_by_media_item(media_item_id)
    if subscription is None or subscription.id is None:
        return None, [], []
    owned = {number for number, _aired, has in episodes if has}
    air_by_number = {number: aired for number, aired, _has in episodes}
    rows = [
        row
        for row in await repo.list_wanted(subscription.id, in_scope_only=True)
        if row.season_number == season_number and row.episode_number not in owned
    ]
    timings = await repo.imported_timings_many([subscription.id])
    release_to_import = _median_pipeline_minutes(
        timings,
        start_field="grabbed_at",
        end_field="imported_at",
        fallback=_DEFAULT_RELEASE_TO_IMPORT_MINUTES,
        maximum=timedelta(days=7),
    )
    now = utcnow()
    missing: list[int] = []
    arrivals: list[EpisodeArrivalView] = []
    for row in rows:
        aired = air_by_number.get(row.episode_number) or row.air_date
        if row.status == WantedStatus.GRABBED and row.info_hash is not None:
            arrivals.append(
                EpisodeArrivalView(episode_number=row.episode_number, stage="downloading")
            )
        elif row.status == WantedStatus.DOWNLOADED and row.info_hash is not None:
            arrivals.append(
                EpisodeArrivalView(episode_number=row.episode_number, stage="organizing")
            )
        elif row.status == WantedStatus.WANTED and aired is not None:
            if aired < today:
                missing.append(row.episode_number)
            elif subscription.status == SubscriptionStatus.ACTIVE:
                arrivals.append(
                    EpisodeArrivalView(
                        episode_number=row.episode_number,
                        stage="waiting",
                        expected_at=_expected_import_at(row, release_to_import, now),
                    )
                )
    return subscription.id, sorted(missing), arrivals


def _expected_import_at(row, release_to_import: int, now: datetime) -> datetime | None:
    """站点发布预测 + 本订阅「投递→入库」中位耗时；预测不稳或时刻已过给 None
    （客户端改说「等待资源」，不报一个过去的时刻）。"""
    forecast = row.release_forecast if isinstance(row.release_forecast, dict) else {}
    if forecast.get("confidence") == "volatile":
        return None
    predicted = _forecast_predicted_at(row)
    if predicted is None:
        return None
    expected = predicted + timedelta(minutes=release_to_import)
    return expected if expected > now else None

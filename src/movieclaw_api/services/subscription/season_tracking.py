"""订阅对一季的追踪说法，供媒体库详情页的播出日历（issue #547）经获取领域接口取用。

「缺集」只认订阅范围内、已经播出却还在找的工单——没订阅的剧库里没有的集不算缺
（用户没打算追），订阅起始集之前的也不算。入库预告 = 站点发布预测 + 本订阅
「投递→入库」中位耗时；预测不稳或时刻已过不给时刻（客户端改说「等待资源」）。
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.library.acquisition import EpisodeArrival, SeasonTracking
from movieclaw_api.services.subscription.core import (
    _DEFAULT_RELEASE_TO_IMPORT_MINUTES,
    _forecast_predicted_at,
    _median_pipeline_minutes,
)
from movieclaw_db.models import WantedItem, utcnow
from movieclaw_db.models.subscription import SubscriptionStatus, WantedStatus
from movieclaw_db.repositories.subscription_repo import SubscriptionRepository


async def season_tracking(
    session: AsyncSession,
    media_item_id: int,
    season_number: int,
    air_dates: dict[int, date | None],
    owned: set[int],
    today: date,
) -> SeasonTracking | None:
    repo = SubscriptionRepository(session)
    subscription = await repo.get_by_media_item(media_item_id)
    if subscription is None or subscription.id is None:
        return None
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
    arrivals: list[EpisodeArrival] = []
    for row in rows:
        aired = air_dates.get(row.episode_number) or row.air_date
        if row.status == WantedStatus.GRABBED and row.info_hash is not None:
            arrivals.append(EpisodeArrival(row.episode_number, "downloading"))
        elif row.status == WantedStatus.DOWNLOADED and row.info_hash is not None:
            arrivals.append(EpisodeArrival(row.episode_number, "organizing"))
        elif row.status == WantedStatus.WANTED and aired is not None:
            if aired < today:
                missing.append(row.episode_number)
            elif subscription.status == SubscriptionStatus.ACTIVE:
                arrivals.append(
                    EpisodeArrival(
                        row.episode_number,
                        "waiting",
                        _expected_import_at(row, release_to_import, now),
                    )
                )
    return SeasonTracking(tracker_id=subscription.id, missing=sorted(missing), arrivals=arrivals)


def _expected_import_at(row: WantedItem, release_to_import: int, now: datetime) -> datetime | None:
    forecast = row.release_forecast if isinstance(row.release_forecast, dict) else {}
    if forecast.get("confidence") == "volatile":
        return None
    predicted = _forecast_predicted_at(row)
    if predicted is None:
        return None
    expected = predicted + timedelta(minutes=release_to_import)
    return expected if expected > now else None

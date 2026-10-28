"""剧集详情页的播出日历（issue #547）：一季的播出排期 + 与媒体库、订阅的对照。

排期来自本地刮削落库的 ``media_episode.air_date``，拥有状态是库存台账；缺集与入库预告
是获取领域的事，只经 ``acquisition`` 接口要（没有获取领域时就没有这两项）。打开详情页不发
任何外部请求，与「自足媒体库」一致。

只在当前季还有今天或以后的播出日期时给出（返回 None 时客户端整块不显示）：
已完结、季间空档、TMDB 没给分集日期的剧都没有可画的排期。日历按季走，与
分集区的季选择同步。
"""

from __future__ import annotations

from datetime import date, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.schemas.library import EpisodeArrivalView, SeasonAirScheduleView
from movieclaw_api.services.library import acquisition
from movieclaw_db.models import MediaItem, MediaMetadata, utcnow
from movieclaw_tracker.datetime_utils import DEFAULT_SITE_TIMEZONE

# 「今天」按站点业务日历（与订阅判断已播 / 待播同一口径），不按服务器时区
_SITE_CALENDAR = ZoneInfo(DEFAULT_SITE_TIMEZONE)

# 首播地与站点日历（东八区）同一天的地区：这些地区的 air_date 直接当本地日期读。
# 其余地区（欧美等）的「10-28 播出」在国内往往已是 10-29，客户端在日期旁标注地区
_SAME_DAY_REGIONS = frozenset({"CN", "HK", "TW", "MO", "SG", "MY", "PH", "JP", "KR"})

# 更新规律只看近期：长剧开播时的周播、后来改日更，取最近三周才是"现在怎么更"
_CADENCE_LOOKBACK = timedelta(days=21)


def site_today() -> date:
    return utcnow().replace(tzinfo=ZoneInfo("UTC")).astimezone(_SITE_CALENDAR).date()


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
    today = site_today()
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

    tracking = await acquisition.current().season_tracking(
        session,
        item.id,
        season_number,
        {number: aired for number, aired, _owned in episodes},
        {number for number, _aired, owned in episodes if owned},
        today,
    )
    return SeasonAirScheduleView(
        today=today,
        region=region,
        weekdays=sorted(recent),
        last_air_date=last_air_date,
        subscription_id=tracking.tracker_id if tracking else None,
        missing_episodes=tracking.missing if tracking else [],
        arrivals=[
            EpisodeArrivalView(
                episode_number=a.episode_number,
                stage=a.stage,  # type: ignore[arg-type]
                expected_at=a.expected_at,
            )
            for a in (tracking.arrivals if tracking else [])
        ],
    )

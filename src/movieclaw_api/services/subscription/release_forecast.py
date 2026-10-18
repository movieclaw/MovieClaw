"""基于既有种子索引推导追新资源发布时间，并生成临时站点探测计划。

这里刻意不建立 observation / hint 表：``site_torrent`` 已经保存了站点、种子
发布时间与首次发现时间，是不可变的原始观测；本模块只把可重算的调度结论保存到
``wanted_item.release_forecast``。站点探测是否已经执行则由
``SiteSyncCursor.last_sync_at`` 判断，普通轮询也会自然消费已经经过的探测点。

不用机器学习，只使用同季较早单集的发布时间：把历史单集按目标播出日期平移后取
中位数。一个样本即可从 E2 开始给出宽窗口，样本增多后用滚动回测误差收紧窗口。
两条经 NAS 真实数据回放（2026-10，341 集）得出的修正：

- **同时段分组**：国产剧常一天两集，单数集傍晚发、双数集零点发。把两种时段混在
  一起取中位数，单数集会被系统性预测晚约 6 小时。目标集只参考「当天第几集」相同
  的历史集（没有同序位样本时才退回全部）。
- **稳健窗口**：TMDB 播出日错一天、首播几集一起发，都会在回测里留下 ±24h 以上的
  残差；旧算法取残差 min/max，一个异常值就把窗口撑过 12h、整集停止探测（回放里
  约 30% 的集因此不探测，其中多数其实预测得很准）。偏离超过 12h 的样本视为播出日
  异常，不参与预测值与窗口。

探测也从「窗口 20/50/80% 三个点」改为集中在资源最可能出现的时段：稳定剧集在
预测点前后每 5 分钟、之后逐步拉开，不稳定的在窗内每 10 分钟铺开，窗口后 24 小时
每小时追踪（找到即停，见 ``_primary_probes``）。回放结果：发布到发现的中位延迟
约 2h → 10 分钟，一小时内发现的比例 32% → 72%。

同时保存几种「影子」预测（含旧算法）的结论，资源真正出现后统一打分写回快照并
记日志（``evaluate_release_forecasts``），用于在真实数据上继续比较预测机制。

开销口径：重算的工作量只与「这部剧的相关种子」成正比，与索引总量无关。每部剧
先在 SQLite 里按别名子串预筛（site_torrent.match_text + 覆盖索引，扫描在 C 层
完成、不占 Python 解释器），只把几十行可能相关的种子交给匹配内核细查；同步收尾
还会先看本轮新种里有没有这部剧的单集观测，没有就不重算（见 refresh_release_forecasts）。
此前每轮把近 90 天几万行种子全部读进 Python 逐行解析、匹配，NAS 上一轮 9–15 秒，
放进线程也照样和接口抢解释器锁，撞上时起播相关接口慢 10–100 倍。
"""

from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from statistics import median, median_low
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy import Row, func, or_, union
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm.exc import StaleDataError
from sqlmodel import select

from movieclaw_api.services.subscription.matching import (
    load_season_titles,
    publish_calendar_date,
    to_candidate,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    ConfigStatus,
    MediaEpisode,
    MediaItem,
    SiteCredential,
    SiteSyncCursor,
    SiteTorrent,
    Subscription,
    SubscriptionStatus,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_matcher import MediaIdentity, TorrentCandidate, match_identity
from movieclaw_matcher.identity import alias_needles
from movieclaw_tracker.datetime_utils import DEFAULT_SITE_TIMEZONE

logger = logging.getLogger("movieclaw_api.subscription.release_forecast")

# 快照结构版本：客户端按它判断能否展示预测窗口，字段只增不改时不升
FORECAST_VERSION = 1
# 当前驱动探测的预测算法；影子算法见 _EXPERIMENTS
FORECAST_ALGORITHM = "slot_robust"
# 单站两次预测探测的最小间隔：与常规同步的下限（5 分钟）一致。最密的探测只出现在
# 预测点前后约一小时内，窗外都是每小时一次
FORECAST_MIN_INTERVAL = timedelta(minutes=5)
_OBSERVATION_LOOKBACK = timedelta(days=90)
_MAX_HISTORY_EPISODES = 4
# 稳健窗口的滚动回测最多看同时段最近几集
_ROBUST_BACKTEST_EPISODES = 5
_MAX_WINDOW = timedelta(hours=12)
# 偏离中位超过它的样本视为播出日异常（TMDB 日期错、首播打包发），不参与预测
_DATE_ANOMALY = timedelta(hours=12)
_EARLY_RELEASE_TOLERANCE = timedelta(days=2)
_LATE_RELEASE_TOLERANCE = timedelta(days=7)
# 首选站探测。stable：相对预测点的分钟偏移，预测点前后每 5 分钟、之后逐步拉开——
# 稳定剧集的残差是尖峰（四分位 -5～+27 分钟），探测要花在尖峰上而不是均匀铺满窗口
_STABLE_PROBE_OFFSETS = tuple(
    timedelta(minutes=minutes)
    for minutes in (-30, -15, -10, -5, 0, 5, 10, 15, 20, 27, 35, 45, 57, 70)
)
# 其余等级与 stable 尖峰之后：窗内按此步长均匀补齐（窗口过长时放宽，单窗最多约 24 次）
_DENSE_PROBE_STEP = timedelta(minutes=10)
_MAX_DENSE_PROBES = 24
_SPARSE_PROBE_STEP = timedelta(hours=1)
# 非 stable 的窗前稀疏探测（stable 的窗前已由负偏移覆盖）
_LEAD_HOURS = 3
_TAIL_HOURS = 24
_VOLATILE_SPAN = timedelta(hours=6)
# 首个单集观测出现后再等这么久才评估：给其他站点的常规同步留时间补上更早的发布
_EVALUATION_SETTLE = timedelta(hours=6)
_EVALUATION_LOOKBACK_DAYS = 10
_LOG_TIMEZONE = ZoneInfo(DEFAULT_SITE_TIMEZONE)


@dataclass(frozen=True)
class _ObservedRelease:
    """一个站点对某个明确单集的发布时间观测。"""

    season_number: int
    episode_number: int
    air_date: date
    site_id: str
    torrent_row_id: int
    publish_time: datetime
    first_seen_at: datetime | None = None


@dataclass(frozen=True)
class _HistoryUnit:
    """历史单集及其跨站最早发布时间。

    ``slot`` 是该集在同季同播出日里的序位（0 起）：一天两集时单数集与双数集
    发布时段不同，预测只参考同序位的历史集。
    """

    season_number: int
    episode_number: int
    air_date: date
    publish_time: datetime
    slot: int = 0


@dataclass(frozen=True)
class _Prediction:
    """一种预测机制对目标集的结论（窗口为相对 predicted_at 的偏移）。"""

    predicted_at: datetime
    confidence: str
    lower: timedelta
    upper: timedelta
    basis: list[_HistoryUnit]


def _as_utc_text(value: datetime) -> str:
    """数据库中的 naive UTC 转为带偏移的 ISO 文本，避免前端按本地时间误读。"""
    return value.replace(tzinfo=UTC).isoformat()


def _parse_utc_text(value: object) -> datetime | None:
    """预测 JSON 时间转回数据库约定的 naive UTC；坏快照直接视为不可用。"""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed
    return parsed.astimezone(UTC).replace(tzinfo=None)


def _local_text(value: datetime) -> str:
    """日志里的时间按站点日历时区展示，便于和站点页面、用户作息直接对照。"""
    return value.replace(tzinfo=UTC).astimezone(_LOG_TIMEZONE).strftime("%m-%d %H:%M")


def _weighted_median(values: list[datetime]) -> datetime:
    """按历史新旧赋予 1..N 权重，取中位点；近期发布节奏对预测影响更大。"""
    weighted: list[datetime] = []
    for weight, value in enumerate(values, start=1):
        weighted.extend([value] * weight)
    return sorted(weighted)[(len(weighted) - 1) // 2]


def _project(history: list[_HistoryUnit], target_air_date: date) -> datetime:
    projected = [
        unit.publish_time + timedelta(days=(target_air_date - unit.air_date).days)
        for unit in history
    ]
    return _weighted_median(projected)


def _window_offsets(history: list[_HistoryUnit]) -> tuple[str, timedelta, timedelta]:
    """按样本量和滚动回测误差给出置信等级及预测窗口偏移。"""
    if len(history) == 1:
        return "bootstrap", timedelta(hours=-2), timedelta(hours=8)
    if len(history) == 2:
        return "growing", timedelta(minutes=-90), timedelta(hours=6)

    residuals: list[timedelta] = []
    for index in range(1, len(history)):
        current = history[index]
        predicted = _project(history[:index], current.air_date)
        residuals.append(current.publish_time - predicted)

    lower = min(min(residuals) - timedelta(minutes=30), timedelta(hours=-1))
    upper = max(max(residuals) + timedelta(minutes=30), timedelta(hours=1))
    if upper - lower > _MAX_WINDOW:
        # 发布时刻不稳定时仍保留预测供观察，但不生成额外站点探测，避免无谓刷站。
        return "volatile", timedelta(hours=-6), timedelta(hours=6)
    return "stable", lower, upper


def _offset(unit: _HistoryUnit) -> timedelta:
    """发布时刻相对播出日零点（库内 naive UTC 口径）的偏移；平移到目标日即预测。"""
    return unit.publish_time - datetime.combine(unit.air_date, time())


def _at_offset(target_air_date: date, offset: timedelta) -> datetime:
    return datetime.combine(target_air_date, time()) + offset


def _slot_sequence(history: list[_HistoryUnit], slot: int | None) -> list[_HistoryUnit]:
    """同序位的历史集；没有同序位样本（如首次一天两集）时退回全部历史。"""
    if slot is None:
        return history
    return [unit for unit in history if unit.slot == slot] or history


def _robust_window(sequence: list[_HistoryUnit]) -> tuple[str, timedelta, timedelta]:
    """滚动回测给窗口：每集用它之前至多四集的中位偏移预测，播出日异常的残差剔除。"""
    recent = sequence[-_ROBUST_BACKTEST_EPISODES:]
    residuals: list[timedelta] = []
    for index in range(1, len(recent)):
        prior = recent[max(0, index - _MAX_HISTORY_EPISODES) : index]
        residual = _offset(recent[index]) - median_low([_offset(unit) for unit in prior])
        if abs(residual) <= _DATE_ANOMALY:
            residuals.append(residual)
    if len(residuals) < 2:
        if len(recent) <= 1:
            return "bootstrap", timedelta(hours=-2), timedelta(hours=8)
        return "growing", timedelta(minutes=-90), timedelta(hours=6)
    lower = min(min(residuals) - timedelta(minutes=30), timedelta(hours=-1))
    upper = max(max(residuals) + timedelta(minutes=30), timedelta(hours=1))
    if upper - lower > _MAX_WINDOW:
        return "volatile", -_VOLATILE_SPAN, _VOLATILE_SPAN
    return "stable", lower, upper


def _predict_robust(
    history: list[_HistoryUnit], target_air_date: date, slot: int | None
) -> _Prediction:
    """同时段 + 稳健：取同序位最近四集，剔除偏离中位超过 12h 的样本后取中位偏移。"""
    sequence = _slot_sequence(history, slot)
    recent = sequence[-_MAX_HISTORY_EPISODES:]
    center = median_low([_offset(unit) for unit in recent])
    basis = [unit for unit in recent if abs(_offset(unit) - center) <= _DATE_ANOMALY]
    predicted_at = _at_offset(target_air_date, median_low([_offset(unit) for unit in basis]))
    confidence, lower, upper = _robust_window(sequence)
    return _Prediction(predicted_at, confidence, lower, upper, basis)


def _predict_v1(history: list[_HistoryUnit], target_air_date: date) -> _Prediction:
    """2026-10 之前的算法：最近四集（不分时段）加权中位，窗口取回测残差极值。"""
    recent = history[-_MAX_HISTORY_EPISODES:]
    confidence, lower, upper = _window_offsets(recent)
    return _Prediction(_project(recent, target_air_date), confidence, lower, upper, recent)


def _predict_point(
    pick: Callable[[list[timedelta]], timedelta],
) -> Callable[[list[_HistoryUnit], date, int | None], _Prediction]:
    """只给点预测、不给窗口的影子机制（窗口沿用 bootstrap 宽度，仅作记录）。"""

    def predict(
        history: list[_HistoryUnit], target_air_date: date, slot: int | None
    ) -> _Prediction:
        recent = _slot_sequence(history, slot)[-_MAX_HISTORY_EPISODES:]
        offset = pick([_offset(unit) for unit in recent])
        return _Prediction(
            _at_offset(target_air_date, offset),
            "point",
            timedelta(hours=-2),
            timedelta(hours=8),
            recent,
        )

    return predict


# 影子预测：不驱动探测，只把结论写进快照，资源出现后与实际发布时刻对照打分
_EXPERIMENTS: dict[str, Callable[[list[_HistoryUnit], date, int | None], _Prediction]] = {
    "v1": lambda history, air_date, _slot: _predict_v1(history, air_date),
    "robust_any_slot": lambda history, air_date, _slot: _predict_robust(history, air_date, None),
    "slot_last": _predict_point(lambda offsets: offsets[-1]),
    "slot_earliest": _predict_point(min),
}


def _episode_slots(episodes: list[MediaEpisode]) -> dict[tuple[int, int], int]:
    """每集在同季同播出日里的序位（0 起）。"""
    by_day: dict[tuple[int, date], list[int]] = defaultdict(list)
    for episode in episodes:
        if episode.air_date is not None:
            by_day[(episode.season_number, episode.air_date)].append(episode.episode_number)
    slots: dict[tuple[int, int], int] = {}
    for (season_number, _air_date), numbers in by_day.items():
        for index, number in enumerate(sorted(numbers)):
            slots[(season_number, number)] = index
    return slots


def _dense_points(start: datetime, end: datetime, step: timedelta) -> list[datetime]:
    points: list[datetime] = []
    current = start
    while current <= end:
        points.append(current)
        current += step
    return points


def _primary_probes(
    *, start: datetime, end: datetime, predicted_at: datetime, confidence: str
) -> list[datetime]:
    """首选站的探测计划：探测集中在资源最可能出现的时段，窗后每小时追踪。

    - stable：预测点前后每 5 分钟、之后逐步拉开（_STABLE_PROBE_OFFSETS），再按 10 分钟
      补齐到窗口结束；
    - bootstrap / growing：预测本身不准，窗内每 10 分钟均匀铺开，窗前 3 小时每小时一次；
    - volatile：预测点前后 6 小时每小时一次。

    NAS 回放（341 集）：与「窗内每 15 分钟 + 窗前 6 小时」相比，中位发现延迟
    13.7 → 9.8 分钟、5 分钟内发现 21% → 37%，每集访问 14.4 → 8.6 次。

    「找到即停」不在这里表达：工单一旦投递就不再是 wanted，读取端自然不再产出它的
    探测点。窗后追踪覆盖「比预测晚」——回放里这是除窗口外最大的一类漏网，否则只能
    等最长 6 小时的常规同步。
    """
    if confidence == "volatile":
        start, end = predicted_at - _VOLATILE_SPAN, predicted_at + _VOLATILE_SPAN
        points = _dense_points(start, end, _SPARSE_PROBE_STEP)
    elif confidence == "stable":
        near = [predicted_at + offset for offset in _STABLE_PROBE_OFFSETS]
        points = [point for point in near if point <= predicted_at or point <= end]
        points += _dense_points(near[-1] + _DENSE_PROBE_STEP, end, _DENSE_PROBE_STEP)
    else:
        step = max(_DENSE_PROBE_STEP, (end - start) / _MAX_DENSE_PROBES)
        points = [start - _SPARSE_PROBE_STEP * hours for hours in range(_LEAD_HOURS, 0, -1)]
        points += _dense_points(start, end, step)
    tail = [end + _SPARSE_PROBE_STEP * hours for hours in range(1, _TAIL_HOURS + 1)]
    return sorted(set(points + tail))


def _secondary_probes(*, start: datetime, end: datetime, confidence: str) -> list[datetime]:
    """次选站只在窗口中后段补两次，防首选站这一集恰好没发。"""
    if confidence == "volatile":
        return []
    return [start + (end - start) * fraction for fraction in (0.5, 0.8)]


def _first_snapshot(forecast: dict[str, Any]) -> dict[str, Any]:
    """冻结首次预测，后续可直接计算命中率而不被滚动修正覆盖。"""
    return {
        "generated_at": forecast["generated_at"],
        "predicted_at": forecast["predicted_at"],
        "window_start": forecast["window_start"],
        "window_end": forecast["window_end"],
        "confidence": forecast["confidence"],
        "sample_count": forecast["sample_count"],
    }


def _same_forecast(left: dict[str, Any], right: dict[str, Any]) -> bool:
    """忽略生成时间、冻结副本与事后评估，只比较会影响调度的预测结论。"""
    ignored = {"generated_at", "first", "evaluation"}
    return (
        {key: value for key, value in left.items() if key not in ignored}
        == {key: value for key, value in right.items() if key not in ignored}
    )


# 观测只用得上这几列（to_candidate 的输入 + 观测的 id/站点/发布时间）：按列取 Core 行
# 而不是装配整行 ORM 对象——同样 4 万行，装配 3 秒缩到 1 秒，垃圾回收要扫的对象也少一大截
_CANDIDATE_COLUMNS = (
    SiteTorrent.id,
    SiteTorrent.site_id,
    SiteTorrent.torrent_id,
    SiteTorrent.title,
    SiteTorrent.subtitle,
    SiteTorrent.category,
    SiteTorrent.attrs,
    SiteTorrent.imdb_id,
    SiteTorrent.douban_id,
    SiteTorrent.size_bytes,
    SiteTorrent.seeders,
    SiteTorrent.is_free,
    SiteTorrent.hit_and_run,
    SiteTorrent.download_url,
    SiteTorrent.publish_time,
    SiteTorrent.created_at,
)


def _identity_for(
    item: MediaItem, episodes: list[MediaEpisode], season_titles: tuple[str, ...]
) -> MediaIdentity:
    """条目在匹配内核视角下的身份（季号取自本条目的全部单集）。"""
    return MediaIdentity(
        kind=item.kind,
        year=item.year,
        aliases=tuple(item.aliases),
        imdb_id=item.imdb_id,
        douban_id=item.douban_id,
        season_numbers=tuple(sorted({episode.season_number for episode in episodes})),
        season_titles=season_titles,
    )


def _candidate_ids(identity: MediaIdentity, *, since: datetime, after_id: int | None):
    """可能属于该条目的种子行 id（SQL 子查询），是 match_identity 命中的必要条件。

    - 别名子串：走覆盖索引 (publish_time, match_text)，扫描在 SQLite 的 C 层完成、
      不占 Python 解释器；任何别名能命中的行，归一化后的别名一定是它 match_text
      的子串（口径见 movieclaw_matcher.identity 的「派生数据缓存与必要条件预筛」）；
    - match_text 为 NULL 的行（旧版本写入、尚未计算）一律纳入细查，不会漏；
    - 外部 ID 相等是另一条独立的命中路径，单独查出后取并集。

    ``after_id`` 只看这个 id 之后新入库的行（同步收尾的"按变化触发"）。
    """
    window = [
        SiteTorrent.publish_time.is_not(None),  # type: ignore[union-attr]
        SiteTorrent.publish_time >= since,
    ]
    if after_id is not None:
        window.append(SiteTorrent.id > after_id)  # type: ignore[operator]
    maybe_alias = [SiteTorrent.match_text.is_(None)] + [  # type: ignore[union-attr]
        func.instr(SiteTorrent.match_text, needle) > 0 for needle in alias_needles(identity)
    ]
    selects = [select(SiteTorrent.id).where(*window, or_(*maybe_alias))]
    if identity.imdb_id:
        selects.append(
            select(SiteTorrent.id).where(*window, SiteTorrent.imdb_id == identity.imdb_id)
        )
    if identity.douban_id:
        selects.append(
            select(SiteTorrent.id).where(*window, SiteTorrent.douban_id == identity.douban_id)
        )
    return union(*selects) if len(selects) > 1 else selects[0]


async def _load_item_candidates(
    session: AsyncSession,
    identity: MediaIdentity,
    *,
    since: datetime,
    after_id: int | None = None,
) -> list[tuple[Row, TorrentCandidate]]:
    """读取并解析可能属于该条目的种子（预筛后通常只有几十行，直接在这里解析）。"""
    rows = (
        await session.execute(
            select(*_CANDIDATE_COLUMNS).where(
                SiteTorrent.id.in_(_candidate_ids(identity, since=since, after_id=after_id))  # type: ignore[union-attr]
            )
        )
    ).all()
    parsed: list[tuple[Row, TorrentCandidate]] = []
    invalid = 0
    for row in rows:
        try:
            candidate = to_candidate(row)
        except ValueError:
            invalid += 1
            continue
        if candidate is not None:
            parsed.append((row, candidate))
    if invalid:
        logger.warning(
            "生成资源发布时间预测时跳过 %s 条属性格式异常的种子索引，请检查富化数据",
            invalid,
        )
    return parsed


def _observations_for_item(
    *,
    identity: MediaIdentity,
    episodes: list[MediaEpisode],
    candidates: list[tuple[Row, TorrentCandidate]],
) -> list[_ObservedRelease]:
    """从 site_torrent 提取本条目的单集发布观测。

    列出了具体集号的合集（"S01E05-E06"、枚举完整的"全 40 集"）只记最后一集：合集
    发布时最后一集一定已经出了，是那一集「最晚可得时间」的有效样本；前面几集早有
    单集发布，不能拿合集时间代表它们。只标季不标集的整季包没有集号，不参与。
    NAS 回放（2026-10，372 集）：计入合集后中位发现延迟 18.2 → 11.8 分钟，首播期
    只有合集、没有单集样本的剧也能更早给出预测。
    """
    air_dates = {
        (episode.season_number, episode.episode_number): episode.air_date
        for episode in episodes
        if episode.air_date is not None
    }
    if not air_dates:
        return []

    earliest: dict[tuple[int, int, str], _ObservedRelease] = {}
    for row, candidate in candidates:
        match = match_identity(candidate, identity)
        if match is None or not match.episodes:
            continue
        season_number, episode_number = max(match.episodes)
        air_date = air_dates.get((season_number, episode_number))
        if air_date is None or row.publish_time is None or row.id is None:
            continue
        # 搜索结果可能带回播出数月后的重发/洗版；它属于该集资源，却不是首发
        # 节奏样本。给跨时区提前发布留两天、站点延迟留七天，超出即排除。
        if not (
            air_date - _EARLY_RELEASE_TOLERANCE
            <= publish_calendar_date(row.publish_time)
            <= air_date + _LATE_RELEASE_TOLERANCE
        ):
            continue
        observation = _ObservedRelease(
            season_number=season_number,
            episode_number=episode_number,
            air_date=air_date,
            site_id=row.site_id,
            torrent_row_id=row.id,
            publish_time=row.publish_time,
            first_seen_at=row.created_at,
        )
        key = (season_number, episode_number, row.site_id)
        previous = earliest.get(key)
        # 同一时刻发了多个种子时取 id 最小的一条：结论不依赖 SQL 的返回顺序
        if previous is None or (observation.publish_time, observation.torrent_row_id) < (
            previous.publish_time,
            previous.torrent_row_id,
        ):
            earliest[key] = observation

    return list(earliest.values())


def _build_forecast(
    *,
    wanted: WantedItem,
    observations: list[_ObservedRelease],
    now: datetime,
    slots: dict[tuple[int, int], int] | None = None,
) -> dict[str, Any] | None:
    """为一个未来单集生成可解释预测；没有同季前序单集样本时返回 None。

    ``slots`` 是各集的当日序位（见 ``_episode_slots``）；缺省时视为一天一集。
    """
    if wanted.air_date is None:
        return None
    slots = slots or {}

    previous = [
        observation
        for observation in observations
        if observation.season_number == wanted.season_number
        and observation.episode_number < wanted.episode_number
        and observation.air_date < wanted.air_date
    ]
    if not previous:
        return None

    by_unit: dict[tuple[int, int], list[_ObservedRelease]] = defaultdict(list)
    for observation in previous:
        by_unit[(observation.season_number, observation.episode_number)].append(observation)

    history = [
        _HistoryUnit(
            season_number=unit_observations[0].season_number,
            episode_number=unit_observations[0].episode_number,
            air_date=unit_observations[0].air_date,
            publish_time=min(item.publish_time for item in unit_observations),
            slot=slots.get(
                (unit_observations[0].season_number, unit_observations[0].episode_number), 0
            ),
        )
        for unit_observations in by_unit.values()
    ]
    history.sort(key=lambda unit: (unit.air_date, unit.episode_number))
    target_slot = slots.get((wanted.season_number, wanted.episode_number), 0)

    prediction = _predict_robust(history, wanted.air_date, target_slot)
    predicted_at = prediction.predicted_at
    confidence, lower, upper = prediction.confidence, prediction.lower, prediction.upper
    basis = prediction.basis
    window_start = predicted_at + lower
    window_end = predicted_at + upper
    basis_keys = {(unit.season_number, unit.episode_number) for unit in basis}
    selected_observations = [
        observation
        for observation in previous
        if (observation.season_number, observation.episode_number) in basis_keys
    ]

    global_publish = {
        (unit.season_number, unit.episode_number): unit.publish_time for unit in basis
    }
    site_history: dict[str, list[_ObservedRelease]] = defaultdict(list)
    for observation in selected_observations:
        site_history[observation.site_id].append(observation)

    latest_key = (basis[-1].season_number, basis[-1].episode_number)
    # 快照保留完整站点排名；读取时再从“当前启用站点”中取前两个。这样站点被
    # 停用后可自动回落到下一名，不必另建提示表或等待预测重算。
    ranked_sites = sorted(
        site_history,
        key=lambda site_id: (
            latest_key not in {
                (item.season_number, item.episode_number) for item in site_history[site_id]
            },
            -len(site_history[site_id]),
            median(
                (
                    item.publish_time
                    - global_publish[(item.season_number, item.episode_number)]
                ).total_seconds()
                for item in site_history[site_id]
            ),
            site_id,
        ),
    )

    sites: list[dict[str, Any]] = []
    for site_id in ranked_sites:
        site_observations = site_history[site_id]
        lag_seconds = median(
            (
                item.publish_time
                - global_publish[(item.season_number, item.episode_number)]
            ).total_seconds()
            for item in site_observations
        )
        site_predicted = predicted_at + timedelta(seconds=lag_seconds)
        # 探测点不入快照：读取端按站点窗口与当前启用站点的名次现算（见
        # _forecast_site_probes），排名靠前的站点停用时下一名自动接任首探
        sites.append(
            {
                "site_id": site_id,
                "predicted_at": _as_utc_text(site_predicted),
                "window_start": _as_utc_text(site_predicted + lower),
                "window_end": _as_utc_text(site_predicted + upper),
                "lag_minutes": round(lag_seconds / 60),
                "coverage_count": len(site_observations),
            }
        )

    experiments: dict[str, dict[str, Any]] = {}
    for name, predict in _EXPERIMENTS.items():
        shadow = predict(history, wanted.air_date, target_slot)
        entry: dict[str, Any] = {
            "predicted_at": _as_utc_text(shadow.predicted_at),
            "confidence": shadow.confidence,
        }
        if shadow.confidence != "point":
            entry["window_start"] = _as_utc_text(shadow.predicted_at + shadow.lower)
            entry["window_end"] = _as_utc_text(shadow.predicted_at + shadow.upper)
        experiments[name] = entry

    forecast: dict[str, Any] = {
        "version": FORECAST_VERSION,
        "algorithm": FORECAST_ALGORITHM,
        "generated_at": _as_utc_text(now),
        "target_air_date": wanted.air_date.isoformat(),
        "predicted_at": _as_utc_text(predicted_at),
        "window_start": _as_utc_text(window_start),
        "window_end": _as_utc_text(window_end),
        "confidence": confidence,
        "sample_count": len(basis),
        "slot": target_slot,
        "cadence_days": (wanted.air_date - history[-1].air_date).days,
        "basis_units": [
            [unit.season_number, unit.episode_number] for unit in basis
        ],
        "basis_torrent_row_ids": sorted(
            {observation.torrent_row_id for observation in selected_observations}
        ),
        "sites": sites,
        "experiments": experiments,
    }
    existing = wanted.release_forecast
    same_target = (
        isinstance(existing, dict)
        and existing.get("version") == FORECAST_VERSION
        and existing.get("target_air_date") == wanted.air_date.isoformat()
    )
    if same_target and isinstance(existing.get("first"), dict):
        forecast["first"] = existing["first"]
    else:
        forecast["first"] = _first_snapshot(forecast)
    if same_target and isinstance(existing.get("evaluation"), dict):
        forecast["evaluation"] = existing["evaluation"]
    return forecast


def _describe_forecast(item: MediaItem, wanted: WantedItem, forecast: dict[str, Any]) -> str:
    """一行可读的预测摘要（日志用）：结论、窗口、依据，以及影子预测的分歧。"""
    predicted = _parse_utc_text(forecast["predicted_at"])
    start = _parse_utc_text(forecast["window_start"])
    end = _parse_utc_text(forecast["window_end"])
    assert predicted is not None and start is not None and end is not None
    shadows = []
    for name, entry in forecast.get("experiments", {}).items():
        shadow_at = _parse_utc_text(entry.get("predicted_at"))
        if shadow_at is not None:
            shadows.append(f"{name}={round((shadow_at - predicted).total_seconds() / 60):+d}分")
    sites = "、".join(site["site_id"] for site in forecast["sites"][:2]) or "无"
    return (
        f"《{item.title}》S{wanted.season_number:02d}E{wanted.episode_number:02d} "
        f"预测 {_local_text(predicted)}（窗口 {_local_text(start)}～{_local_text(end)}，"
        f"{forecast['confidence']}，样本 {forecast['basis_units']}，"
        f"当日第 {forecast['slot'] + 1} 集），首探 {sites}；"
        f"影子相对偏差 {' '.join(shadows) or '无'}"
    )


async def refresh_release_forecasts(
    session: AsyncSession,
    *,
    media_item_ids: set[int] | None = None,
    new_since_id: int | None = None,
) -> int:
    """刷新活跃剧集订阅范围内的单集预测快照，返回实际变化的工单数。

    只处理 ``wanted`` 状态且已定档的剧集工单；暂停、完成、已投递工单不会生成
    新探测。``in_scope`` 已表达用户是否订阅该集，自动续订只影响未来范围扩张，
    不得影响现有范围的预测与探测。已过期工单的旧快照无需删除，调度读取时会按
    窗口截止时间忽略。

    ``new_since_id``（同步收尾用）：只重算「这个 id 之后新入库的种子里出现了本剧
    单集观测」的条目。预测只取决于观测，新种没带来观测就不可能改变结论；别名、
    季名、种子补 ID、重新富化、观测滑出 90 天这些不经过新种的变化，由每小时兜底
    的全量刷新与各自的单条目触发覆盖（与此前「一小时内反映」的时效相同）。
    """
    statement = (
        select(WantedItem, Subscription)
        .join(Subscription, WantedItem.subscription_id == Subscription.id)  # type: ignore[arg-type]
        .where(
            WantedItem.status == WantedStatus.WANTED,
            WantedItem.in_scope.is_(True),  # type: ignore[attr-defined]
            WantedItem.air_date.is_not(None),  # type: ignore[union-attr]
            Subscription.kind == "tv",
            Subscription.status == SubscriptionStatus.ACTIVE,
        )
    )
    if media_item_ids is not None:
        if not media_item_ids:
            return 0
        statement = statement.where(WantedItem.media_item_id.in_(media_item_ids))  # type: ignore[union-attr]

    rows = (await session.execute(statement)).all()
    if not rows:
        return 0

    now = utcnow()
    today = now.date()
    grouped: dict[int, list[WantedItem]] = defaultdict(list)
    for wanted, _subscription in rows:
        # 昨日之前的窗口必然已经结束，不再花代价重算；旧快照会被读取端忽略。
        if wanted.air_date is not None and wanted.air_date >= today - timedelta(days=1):
            grouped[wanted.media_item_id].append(wanted)

    if not grouped:
        return 0
    changed = 0
    since = now - _OBSERVATION_LOOKBACK
    for media_item_id, wanted_items in grouped.items():
        item = await session.get(MediaItem, media_item_id)
        if item is None:
            continue
        episodes = list(
            (
                await session.execute(
                    select(MediaEpisode).where(MediaEpisode.media_item_id == media_item_id)
                )
            )
            .scalars()
            .all()
        )
        identity = _identity_for(item, episodes, await load_season_titles(session, media_item_id))
        slots = _episode_slots(episodes)
        if new_since_id is not None and not _observations_for_item(
            identity=identity,
            episodes=episodes,
            candidates=await _load_item_candidates(
                session, identity, since=since, after_id=new_since_id
            ),
        ):
            continue  # 本轮新种里没有这部剧的单集观测：预测不可能变化
        observations = _observations_for_item(
            identity=identity,
            episodes=episodes,
            candidates=await _load_item_candidates(session, identity, since=since),
        )
        for wanted in wanted_items:
            forecast = _build_forecast(
                wanted=wanted, observations=observations, now=now, slots=slots
            )
            existing = wanted.release_forecast
            if forecast is None:
                if existing is not None:
                    wanted.release_forecast = None
                    wanted.updated_at = now
                    session.add(wanted)
                    changed += 1
                continue
            if isinstance(existing, dict) and _same_forecast(existing, forecast):
                continue
            logger.info("发布预测更新：%s", _describe_forecast(item, wanted, forecast))
            wanted.release_forecast = forecast
            wanted.updated_at = now
            session.add(wanted)
            changed += 1

    if changed:
        await session.commit()
        logger.info("已更新 %s 个订阅单集的资源发布时间预测", changed)
    return changed


def _score(entry: object, actual: datetime) -> dict[str, Any] | None:
    """一条预测（主预测、首次预测或影子预测）相对实际发布时刻的误差与窗口命中。"""
    if not isinstance(entry, dict):
        return None
    predicted = _parse_utc_text(entry.get("predicted_at"))
    if predicted is None:
        return None
    result: dict[str, Any] = {"error_minutes": round((actual - predicted).total_seconds() / 60)}
    start = _parse_utc_text(entry.get("window_start"))
    end = _parse_utc_text(entry.get("window_end"))
    if start is not None and end is not None:
        result["in_window"] = start <= actual <= end
    return result


def _evaluation(
    wanted: WantedItem, forecast: dict[str, Any], unit_observations: list[_ObservedRelease]
) -> dict[str, Any]:
    """事后评估：误差为「实际 - 预测」（正数表示资源比预测晚）。"""
    first = min(unit_observations, key=lambda item: (item.publish_time, item.torrent_row_id))
    actual = first.publish_time
    seen = [item for item in unit_observations if item.first_seen_at is not None]
    first_seen = min(seen, key=lambda item: item.first_seen_at or actual) if seen else None
    evaluation: dict[str, Any] = {
        "evaluated_at": _as_utc_text(utcnow()),
        "algorithm": forecast.get("algorithm", "v1"),
        "confidence": forecast.get("confidence"),
        "actual_publish_at": _as_utc_text(actual),
        "first_site": first.site_id,
        "site_count": len({item.site_id for item in unit_observations}),
        **(_score(forecast, actual) or {}),
        "first_forecast": _score(forecast.get("first"), actual),
        "experiments": {
            name: score
            for name, entry in (forecast.get("experiments") or {}).items()
            if (score := _score(entry, actual)) is not None
        },
    }
    if first_seen is not None and first_seen.first_seen_at is not None:
        evaluation["first_seen_at"] = _as_utc_text(first_seen.first_seen_at)
        evaluation["first_seen_site"] = first_seen.site_id
        evaluation["discovery_minutes"] = round(
            (first_seen.first_seen_at - actual).total_seconds() / 60
        )
    sites = forecast.get("sites")
    if isinstance(sites, list) and sites and isinstance(sites[0], dict):
        top = sites[0]
        evaluation["top_site"] = top.get("site_id")
        top_release = [item for item in unit_observations if item.site_id == top.get("site_id")]
        evaluation["top_site_published"] = bool(top_release)
        if top_release:
            evaluation["top_site_score"] = _score(
                top, min(item.publish_time for item in top_release)
            )
    if wanted.grabbed_at is not None:
        evaluation["grabbed_minutes"] = round((wanted.grabbed_at - actual).total_seconds() / 60)
    return evaluation


def _describe_evaluation(item: MediaItem, wanted: WantedItem, evaluation: dict[str, Any]) -> str:
    actual = _parse_utc_text(evaluation["actual_publish_at"])
    assert actual is not None

    def scored(score: object) -> str:
        if not isinstance(score, dict):
            return "无"
        hit = score.get("in_window")
        mark = "" if hit is None else ("窗内" if hit else "窗外")
        return f"{score['error_minutes']:+d}分{mark}"

    shadows = " ".join(
        f"{name}={scored(score)}" for name, score in evaluation["experiments"].items()
    )
    discovery = evaluation.get("discovery_minutes")
    grabbed = evaluation.get("grabbed_minutes")
    top = evaluation.get("top_site")
    top_text = (
        f"首探 {top} {scored(evaluation.get('top_site_score'))}"
        if evaluation.get("top_site_published")
        else f"首探 {top} 未发"
    )
    return (
        f"《{item.title}》S{wanted.season_number:02d}E{wanted.episode_number:02d}："
        f"实际首发 {_local_text(actual)}（{evaluation['first_site']}，共 "
        f"{evaluation['site_count']} 站），{evaluation['algorithm']} 误差 "
        f"{scored(evaluation)}（{evaluation['confidence']}），首次预测 "
        f"{scored(evaluation.get('first_forecast'))}；{top_text}；发现延迟 "
        f"{'未知' if discovery is None else f'{discovery} 分'}，投递 "
        f"{'未投递' if grabbed is None else f'{grabbed} 分'}；影子 {shadows or '无'}"
    )


async def evaluate_release_forecasts(session: AsyncSession) -> int:
    """给资源已出现的追新预测打分，结果写回快照 ``evaluation`` 并记一行日志。

    预测机制的实验数据就靠它积累：主预测、首次预测与各影子预测在同一集上的误差
    并排保存，可直接在库里统计。只评估一次；首个单集观测出现 6 小时后才评估，
    给其他站点的常规同步留出补上更早发布的时间。观测口径同预测（单集，以及合集的
    最后一集）；只标季不标集的整季包没有集号，只被它覆盖的集不会评估。返回本轮
    评估的工单数。
    """
    now = utcnow()
    rows = (
        await session.execute(
            select(WantedItem, MediaItem)
            .join(Subscription, WantedItem.subscription_id == Subscription.id)  # type: ignore[arg-type]
            .join(MediaItem, WantedItem.media_item_id == MediaItem.id)  # type: ignore[arg-type]
            .where(
                WantedItem.release_forecast.is_not(None),  # type: ignore[union-attr]
                WantedItem.air_date >= now.date() - timedelta(days=_EVALUATION_LOOKBACK_DAYS),  # type: ignore[operator]
                # 还没到可能提前发布的日子就不必读观测
                WantedItem.air_date <= now.date() + _EARLY_RELEASE_TOLERANCE,  # type: ignore[operator]
                Subscription.kind == "tv",
            )
        )
    ).all()
    pending: dict[int, list[WantedItem]] = defaultdict(list)
    items: dict[int, MediaItem] = {}
    for wanted, item in rows:
        forecast = wanted.release_forecast
        if (
            not isinstance(forecast, dict)
            or "evaluation" in forecast
            or forecast.get("version") != FORECAST_VERSION
            or wanted.air_date is None
            or forecast.get("target_air_date") != wanted.air_date.isoformat()
        ):
            continue
        pending[wanted.media_item_id].append(wanted)
        items[wanted.media_item_id] = item

    evaluated = 0
    since = now - _OBSERVATION_LOOKBACK
    for media_item_id, wanted_items in pending.items():
        item = items[media_item_id]
        episodes = list(
            (
                await session.execute(
                    select(MediaEpisode).where(MediaEpisode.media_item_id == media_item_id)
                )
            )
            .scalars()
            .all()
        )
        identity = _identity_for(item, episodes, await load_season_titles(session, media_item_id))
        by_unit: dict[tuple[int, int], list[_ObservedRelease]] = defaultdict(list)
        for observation in _observations_for_item(
            identity=identity,
            episodes=episodes,
            candidates=await _load_item_candidates(session, identity, since=since),
        ):
            by_unit[(observation.season_number, observation.episode_number)].append(observation)
        for wanted in wanted_items:
            unit_observations = by_unit.get((wanted.season_number, wanted.episode_number))
            if not unit_observations:
                continue
            seen_times = [o.first_seen_at for o in unit_observations if o.first_seen_at is not None]
            if seen_times and now < min(seen_times) + _EVALUATION_SETTLE:
                continue
            forecast = wanted.release_forecast
            assert isinstance(forecast, dict)
            evaluation = _evaluation(wanted, forecast, unit_observations)
            # JSON 列按引用比较，整体换新 dict 才会落库
            wanted.release_forecast = {**forecast, "evaluation": evaluation}
            session.add(wanted)
            evaluated += 1
            logger.info("发布预测评估：%s", _describe_evaluation(item, wanted, evaluation))

    if evaluated:
        await session.commit()
    return evaluated


# fire-and-forget 任务的强引用集合：asyncio 只持弱引用，不留强引用的话
# 任务可能在执行前被垃圾回收（与 wanted_search._kick_tasks 同一套路）。
_refresh_tasks: set[asyncio.Task] = set()
# 排队中（还没开始执行）的条目：同一条目连续触发（创建→调整→恢复）只跑一次。
# 开始执行后就从这里移除——执行中再触发要重新排一次，本次可能读不到之后的变化
_queued_ids: set[int] = set()
# 正在执行的条目。与 _queued_ids 一起回答「这个条目的预测是不是还在路上」，
# 详情页据此决定要不要稍后再取一次（见 forecast_refresh_pending）
_running_ids: set[int] = set()
# 串行执行：同一时刻只跑一份刷新，写入不互相覆盖；排队中的同条目触发合并进一次
_refresh_lock = asyncio.Lock()


def forecast_refresh_pending(media_item_id: int) -> bool:
    """该条目是否有排队中或执行中的后台预测刷新。

    订阅创建/调整/恢复后预测要晚几秒才落库，这期间详情页读到的是旧快照或空快照。
    返回 True 时前端应稍后重取，而不是把「待播出」当成最终结论展示。
    """
    return media_item_id in _queued_ids or media_item_id in _running_ids


async def _refresh_once(media_item_ids: set[int]) -> None:
    """后台刷新的执行体：自开会话，失败只记日志（定时任务会兜底全量重算）。"""
    async with _refresh_lock:
        _queued_ids.difference_update(media_item_ids)
        _running_ids.update(media_item_ids)
        try:
            try:
                async with get_database().session() as session:
                    await refresh_release_forecasts(session, media_item_ids=media_item_ids)
            except StaleDataError:
                # 装载工单到提交之间有订阅被删（典型场景：订阅后立刻取消），UPDATE
                # 对不上行，整批回滚——同批其他条目的预测也跟着丢了。这不是故障，
                # 换新会话按最新数据重算一次：已删的自然查不到，其余照常写入
                logger.info(
                    "刷新条目 %s 的预测期间有订阅被删除，按最新数据重算一次",
                    sorted(media_item_ids),
                )
                async with get_database().session() as session:
                    await refresh_release_forecasts(session, media_item_ids=media_item_ids)
        except Exception:  # noqa: BLE001 -- 环境未就绪（如关停中）时静默降级
            logger.warning(
                "后台刷新条目 %s 的资源发布时间预测失败，等待定时任务兜底",
                sorted(media_item_ids),
                exc_info=True,
            )
        finally:
            _running_ids.difference_update(media_item_ids)


def refresh_release_forecasts_soon(media_item_ids: set[int]) -> None:
    """把预测刷新挪出请求路径（订阅创建/调整/恢复共用的唯一触发点）。

    预测快照是可重算的派生值，晚几秒落库对功能没有影响：首页预告在快照缺席时
    按播出日期兜底，站点探测计划也只在到点时才读取它。而刷新要读条目、单集与
    种子索引并逐条细查——用户点一下「订阅」没有理由等这个。请求会话在响应后
    即关闭，所以这里必须自开会话。
    没有运行中的事件循环时（如同步脚本）静默跳过，交给定时任务兜底。
    """
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    new_ids = set(media_item_ids) - _queued_ids
    if not new_ids:
        return  # 同条目的刷新已在排队，合并进那一次
    _queued_ids.update(new_ids)
    task = loop.create_task(_refresh_once(new_ids))
    _refresh_tasks.add(task)
    task.add_done_callback(_refresh_tasks.discard)


def _candidate_observed_at(wanted: WantedItem) -> datetime | None:
    """智能等待里首次观测到候选的时刻；没有候选（或非智能订阅）时为 None。"""
    state = wanted.selection_state
    if not isinstance(state, dict):
        return None
    return _parse_utc_text(state.get("first_observed_at"))


def _forecast_site_probes(
    wanted: WantedItem, *, site_ids: set[str], now: datetime
) -> dict[str, list[datetime]]:
    """读取一个工单在当前有效站点上的原始探测点，保持与调度器相同的站点取舍。

    探测点按站点窗口现算：当前启用站点里排名第一的走完整计划（窗前/窗内/窗后），
    第二名只在窗口中后段补两次。窗后追踪也结束后，快照不再产生访问。

    已经观测到候选（智能等待中，工单仍是 wanted）时降为首选站每小时一次：资源已经
    到手，密集探测只剩「等更好的版本」这点价值，交给每小时一次与常规同步即可。
    """
    forecast = wanted.release_forecast
    if not isinstance(forecast, dict):
        return {}
    if forecast.get("version") != FORECAST_VERSION:
        return {}
    if wanted.air_date is None or forecast.get("target_air_date") != wanted.air_date.isoformat():
        return {}
    confidence = forecast.get("confidence")
    sites = forecast.get("sites")
    if not isinstance(confidence, str) or not isinstance(sites, list):
        return {}

    observed_at = _candidate_observed_at(wanted)
    result: dict[str, list[datetime]] = {}
    eligible_sites = [
        site
        for site in sites
        if isinstance(site, dict) and site.get("site_id") in site_ids
    ][:2]
    for rank, site in enumerate(eligible_sites):
        start = _parse_utc_text(site.get("window_start"))
        end = _parse_utc_text(site.get("window_end"))
        predicted_at = _parse_utc_text(site.get("predicted_at"))
        if start is None or end is None or predicted_at is None:
            continue
        if observed_at is not None:
            if rank > 0:
                continue
            last = max(end + _SPARSE_PROBE_STEP * _TAIL_HOURS, observed_at)
            probes = _dense_points(observed_at + _SPARSE_PROBE_STEP, last, _SPARSE_PROBE_STEP)
        elif rank == 0:
            probes = _primary_probes(
                start=start, end=end, predicted_at=predicted_at, confidence=confidence
            )
        else:
            probes = _secondary_probes(start=start, end=end, confidence=confidence)
        if probes and probes[-1] >= now - FORECAST_MIN_INTERVAL:
            result[str(site["site_id"])] = sorted(set(probes))
    return result


def effective_forecast_probe_at(
    probes: list[datetime], *, last_sync_at: datetime | None
) -> datetime | None:
    """把原始预测点换算成站点真正可执行的下一探测时间。

    上次同步之后的探测点才算未消费；即使预测点已到，也必须遵守单站 5 分钟
    礼貌间隔（FORECAST_MIN_INTERVAL）。调度器与页面共用本函数，避免两边分别计算后发生时间漂移。
    """
    pending = sorted(
        probe for probe in probes if last_sync_at is None or probe > last_sync_at
    )
    if not pending:
        return None
    if last_sync_at is None:
        return pending[0]
    return max(pending[0], last_sync_at + FORECAST_MIN_INTERVAL)


async def forecast_probe_times_by_site(
    session: AsyncSession, *, site_ids: set[str]
) -> dict[str, list[datetime]]:
    """读取当前有效的站点探测点；返回值可直接合并到既有同步规划器。

    这里只筛选业务状态与快照有效性，不记录“已消费”状态。同步规划器用站点游标的
    ``last_sync_at`` 跳过旧探测点，因此一次普通同步同样能够消费它们。是否自动续订
    与这里无关：只要工单仍在当前订阅范围内，就必须继续探测。
    """
    if not site_ids:
        return {}
    rows = await session.execute(
        select(WantedItem)
        .join(Subscription, WantedItem.subscription_id == Subscription.id)  # type: ignore[arg-type]
        .where(
            WantedItem.status == WantedStatus.WANTED,
            WantedItem.in_scope.is_(True),  # type: ignore[attr-defined]
            WantedItem.release_forecast.is_not(None),  # type: ignore[union-attr]
            Subscription.kind == "tv",
            Subscription.status == SubscriptionStatus.ACTIVE,
        )
    )
    now = utcnow()
    result: dict[str, set[datetime]] = defaultdict(set)
    for wanted in rows.scalars().all():
        for site_id, probes in _forecast_site_probes(
            wanted, site_ids=site_ids, now=now
        ).items():
            result[site_id].update(probes)
    return {site_id: sorted(values) for site_id, values in result.items()}


async def next_forecast_probe_times_by_wanted(
    session: AsyncSession, *, wanted_items: list[WantedItem]
) -> dict[int, datetime]:
    """按工单返回与调度器一致的下一有效探测时间，供首页计算预计入库时间。"""
    if not wanted_items:
        return {}
    credentials = (
        (
            await session.execute(
                select(SiteCredential).where(
                    SiteCredential.enabled.is_(True),  # type: ignore[attr-defined]
                    SiteCredential.status == ConfigStatus.ACTIVE,
                )
            )
        )
        .scalars()
        .all()
    )
    active_site_ids = {credential.site_id for credential in credentials}
    if not active_site_ids:
        return {}
    cursors = (
        (
            await session.execute(
                select(SiteSyncCursor).where(
                    SiteSyncCursor.site_id.in_(active_site_ids)  # type: ignore[attr-defined]
                )
            )
        )
        .scalars()
        .all()
    )
    cursor_by_site = {cursor.site_id: cursor for cursor in cursors}
    now = utcnow()
    result: dict[int, datetime] = {}
    for wanted in wanted_items:
        if wanted.id is None:
            continue
        effective: list[datetime] = []
        for site_id, probes in _forecast_site_probes(
            wanted, site_ids=active_site_ids, now=now
        ).items():
            cursor = cursor_by_site.get(site_id)
            due_at = effective_forecast_probe_at(
                probes,
                last_sync_at=cursor.last_sync_at if cursor is not None else None,
            )
            if due_at is not None:
                effective.append(due_at)
        if effective:
            # 已到期但尚未等到下一轮全局 tick 时，从“现在”起估算，不回传过去时间。
            result[wanted.id] = max(min(effective), now)
    return result


__all__ = [
    "FORECAST_MIN_INTERVAL",
    "FORECAST_VERSION",
    "FORECAST_ALGORITHM",
    "effective_forecast_probe_at",
    "evaluate_release_forecasts",
    "forecast_probe_times_by_site",
    "next_forecast_probe_times_by_wanted",
    "refresh_release_forecasts",
]

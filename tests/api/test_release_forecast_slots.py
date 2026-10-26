"""发布预测 v2：同时段分组、稳健窗口、探测计划与事后评估。

样本取自 NAS 真实数据（2026-09《兰香如故》）：一天两集，单数集约 18:00 发、
双数集次日 00:05 前后发（时间均为北京时间，库内存 naive UTC）。
"""

from __future__ import annotations

from datetime import date, datetime, time, timedelta

from movieclaw_api.services.subscription import (
    evaluate_release_forecasts,
    forecast_probe_times_by_site,
    refresh_release_forecasts,
)
from movieclaw_api.services.subscription import release_forecast as rf
from movieclaw_db.models import SiteTorrent, TorrentSource, WantedItem, utcnow

from .test_subscription_release_forecast import _seed_target, db  # noqa: F401

_BJ = timedelta(hours=8)


def _bj(day: date, hour: int, minute: int) -> datetime:
    """北京时间 → 库内 naive UTC。"""
    return datetime.combine(day, time(hour, minute)) - _BJ


def _obs(episode: int, air: date, publish: datetime, site: str = "ssd") -> rf._ObservedRelease:
    return rf._ObservedRelease(
        season_number=1,
        episode_number=episode,
        air_date=air,
        site_id=site,
        torrent_row_id=episode,
        publish_time=publish,
    )


def _two_per_day(days: int, start: date) -> tuple[list[rf._ObservedRelease], dict]:
    """连续若干天、每天两集：单数集当天 18:01，双数集次日 00:07。"""
    observations = []
    slots = {}
    for index in range(days):
        air = start + timedelta(days=index)
        odd, even = 2 * index + 1, 2 * index + 2
        observations.append(_obs(odd, air, _bj(air, 18, 1)))
        observations.append(_obs(even, air, _bj(air + timedelta(days=1), 0, 7)))
        slots[(1, odd)] = 0
        slots[(1, even)] = 1
    return observations, slots


def _wanted(episode: int, air: date) -> WantedItem:
    return WantedItem(
        subscription_id=1,
        media_item_id=1,
        season_number=1,
        episode_number=episode,
        air_date=air,
        status="wanted",
    )


def _predicted(forecast: dict, key: str = "predicted_at") -> datetime:
    value = rf._parse_utc_text(forecast[key])
    assert value is not None
    return value


def test_two_episodes_per_day_predicts_each_slot_separately() -> None:
    """单数集按单数集的时段预测：旧算法把它预测到零点，晚了 6 小时。"""
    start = date(2026, 9, 13)
    observations, slots = _two_per_day(4, start)
    target_day = start + timedelta(days=4)
    slots[(1, 9)] = 0
    slots[(1, 10)] = 1
    now = _bj(target_day, 9, 0)

    odd = rf._build_forecast(
        wanted=_wanted(9, target_day), observations=observations, now=now, slots=slots
    )
    even = rf._build_forecast(
        wanted=_wanted(10, target_day), observations=observations, now=now, slots=slots
    )
    assert odd is not None and even is not None

    assert _predicted(odd) == _bj(target_day, 18, 1)
    assert odd["slot"] == 0
    assert odd["basis_units"] == [[1, 1], [1, 3], [1, 5], [1, 7]]
    assert odd["confidence"] == "stable"
    assert _predicted(even) == _bj(target_day + timedelta(days=1), 0, 7)
    # 旧算法（影子 v1）不分时段：单数集被拉到双数集的零点档
    v1_error = _predicted(odd["experiments"]["v1"]) - _bj(target_day, 18, 1)
    assert v1_error >= timedelta(hours=5)


def test_date_anomaly_does_not_disable_probing() -> None:
    """一集晚了整整一天（TMDB 播出日错位）不该把窗口撑成 volatile、停掉探测。"""
    start = date(2026, 9, 1)
    observations = [
        _obs(
            episode,
            start + timedelta(days=episode - 1),
            _bj(start + timedelta(days=episode - 1), 18, 0),
        )
        for episode in range(1, 7)
    ]
    # E4 晚了 26 小时：残差远超 12h，视为播出日异常
    observations[3] = _obs(4, start + timedelta(days=3), _bj(start + timedelta(days=4), 20, 0))
    target_day = start + timedelta(days=6)
    forecast = rf._build_forecast(
        wanted=_wanted(7, target_day), observations=observations, now=_bj(target_day, 9, 0)
    )
    assert forecast is not None
    assert forecast["confidence"] == "stable"
    assert _predicted(forecast) == _bj(target_day, 18, 0)
    assert [1, 4] not in forecast["basis_units"]
    assert forecast["experiments"]["v1"]["confidence"] == "volatile"


def test_primary_site_probes_densely_and_chases_after_window() -> None:
    start = datetime(2026, 10, 17, 10, 0)
    predicted = start + timedelta(hours=1)
    end = start + timedelta(hours=2)
    probes = rf._primary_probes(start=start, end=end, predicted_at=predicted, confidence="stable")
    near = [round((p - predicted).total_seconds() / 60) for p in probes if p <= end]
    # 稳定剧集：探测集中在预测点前后（每 5 分钟），之后逐步拉开；窗前不再每小时空探
    assert near == [-30, -15, -10, -5, 0, 5, 10, 15, 20, 27, 35, 45, 57]
    tail = [p for p in probes if p > end]
    assert tail == [end + timedelta(hours=h) for h in range(1, 25)]

    # 窗口更长时，尖峰之后按 10 分钟补齐到窗口结束
    long_end = predicted + timedelta(hours=2)
    longer = rf._primary_probes(
        start=start, end=long_end, predicted_at=predicted, confidence="stable"
    )
    assert [p for p in longer if predicted + timedelta(minutes=70) < p <= long_end] == [
        predicted + timedelta(minutes=m) for m in range(80, 121, 10)
    ]

    # 不稳定的预测：窗内每 10 分钟铺开，窗前 3 小时每小时一次
    growing = rf._primary_probes(start=start, end=end, predicted_at=predicted, confidence="growing")
    assert [p for p in growing if p < start] == [start - timedelta(hours=h) for h in (3, 2, 1)]
    assert [p for p in growing if start <= p <= end] == [
        start + timedelta(minutes=10 * i) for i in range(13)
    ]

    # 宽窗口放宽步长：窗内最多约 24 次
    wide = rf._primary_probes(
        start=start, end=start + timedelta(hours=10), predicted_at=start, confidence="bootstrap"
    )
    assert len([p for p in wide if start <= p <= start + timedelta(hours=10)]) <= 25

    # volatile 也不再完全放弃：预测点前后 6 小时每小时一次
    volatile = rf._primary_probes(start=start, end=end, predicted_at=start, confidence="volatile")
    assert start - timedelta(hours=6) in volatile and start + timedelta(hours=6) in volatile
    assert rf._secondary_probes(start=start, end=end, confidence="volatile") == []


def test_reader_gives_secondary_site_two_mid_window_probes() -> None:
    now = datetime(2026, 10, 17, 9, 0)
    start = now + timedelta(hours=1)

    def site(site_id: str) -> dict[str, str]:
        return {
            "site_id": site_id,
            "predicted_at": rf._as_utc_text(start),
            "window_start": rf._as_utc_text(start),
            "window_end": rf._as_utc_text(start + timedelta(hours=2)),
        }

    wanted = _wanted(5, date(2026, 10, 17))
    wanted.release_forecast = {
        "version": 1,
        "target_air_date": "2026-10-17",
        "confidence": "stable",
        "sites": [site("disabled"), site("a"), site("b"), site("c")],
    }
    probes = rf._forecast_site_probes(wanted, site_ids={"a", "b", "c"}, now=now)
    assert set(probes) == {"a", "b"}  # 停用站跳过，取当前启用站点的前两名
    # 首选站：尖峰 14 个偏移点 + 10 分钟补齐到窗口结束 5 个 + 窗后 24 个
    assert len(probes["a"]) == 14 + 5 + 24
    assert probes["b"] == [start + timedelta(minutes=60), start + timedelta(minutes=96)]

    # 窗后追踪也结束很久的快照不再产生访问
    later = start + timedelta(hours=30)
    assert rf._forecast_site_probes(wanted, site_ids={"a"}, now=later) == {}


def test_probes_drop_to_hourly_once_candidate_observed() -> None:
    """智能等待中已观测到候选：首选站降为每小时一次，次选站不再补探。"""
    now = datetime(2026, 10, 17, 9, 0)
    start = now + timedelta(hours=1)
    observed = start + timedelta(minutes=10)
    window = {
        "predicted_at": rf._as_utc_text(start),
        "window_start": rf._as_utc_text(start),
        "window_end": rf._as_utc_text(start + timedelta(hours=2)),
    }
    wanted = _wanted(5, date(2026, 10, 17))
    wanted.release_forecast = {
        "version": 1,
        "target_air_date": "2026-10-17",
        "confidence": "stable",
        "sites": [{"site_id": "a", **window}, {"site_id": "b", **window}],
    }
    wanted.selection_state = {"first_observed_at": observed.isoformat()}

    probes = rf._forecast_site_probes(wanted, site_ids={"a", "b"}, now=observed)
    assert set(probes) == {"a"}
    gaps = {b - a for a, b in zip(probes["a"], probes["a"][1:], strict=False)}
    assert probes["a"][0] == observed + timedelta(hours=1) and gaps == {timedelta(hours=1)}
    # 每小时一次持续到原计划窗后追踪结束
    tail_end = start + timedelta(hours=2 + 24)
    assert tail_end - timedelta(hours=1) < probes["a"][-1] <= tail_end


async def test_evaluation_scores_forecast_once_after_release(db) -> None:  # noqa: F811
    """资源出现 6 小时后给主预测与影子预测打分，写回快照且只评估一次。"""
    async with db.session() as session:
        wanted, _expected = await _seed_target(session, cadence_days=1)
        await refresh_release_forecasts(session, media_item_ids={wanted.media_item_id})
        assert wanted.release_forecast is not None
        assert "evaluation" not in wanted.release_forecast

        # 首次发现于 7 小时前（已过 6 小时沉淀期），站点发布比发现早 12 分钟
        first_seen = utcnow() - timedelta(hours=7)
        actual = first_seen - timedelta(minutes=12)
        torrent = SiteTorrent(
            site_id="site-a",
            torrent_id="episode-2",
            title="Test Show S01E02 1080p WEB-DL",
            attrs={
                "media_type": "tv",
                "year": utcnow().year,
                "seasons": [1],
                "episodes": [2],
                "resolution": "1080p",
            },
            enrich_version=1,
            source=TorrentSource.LIST,
            publish_time=actual,
            created_at=utcnow() - timedelta(hours=1),
        )
        session.add(torrent)
        await session.commit()
        # 发现后不足 6 小时：等其他站补齐，不评估
        assert await evaluate_release_forecasts(session) == 0

        torrent.created_at = first_seen
        session.add(torrent)
        await session.commit()
        assert await evaluate_release_forecasts(session) == 1
        stored = await session.get(WantedItem, wanted.id)
        assert stored is not None
        evaluation = stored.release_forecast["evaluation"]
        predicted = _predicted(stored.release_forecast)
        assert evaluation["error_minutes"] == round((actual - predicted).total_seconds() / 60)
        assert evaluation["discovery_minutes"] == 12
        assert evaluation["first_forecast"]["error_minutes"] == evaluation["error_minutes"]
        assert evaluation["first_site"] == "site-a"
        assert evaluation["top_site_published"] is True
        assert set(evaluation["experiments"]) == set(stored.release_forecast["experiments"])

        # 只评估一次；重算预测不会冲掉评估结果
        assert await evaluate_release_forecasts(session) == 0
        await refresh_release_forecasts(session, media_item_ids={wanted.media_item_id})
        stored = await session.get(WantedItem, wanted.id)
        assert stored is not None and "evaluation" in stored.release_forecast


async def test_forecast_probes_reach_scheduler(db) -> None:  # noqa: F811
    """新快照（不再存 probe_times）经读取端现算后仍能驱动站点同步规划。"""
    async with db.session() as session:
        wanted, _expected = await _seed_target(session, cadence_days=1)
        await refresh_release_forecasts(session, media_item_ids={wanted.media_item_id})
        assert "probe_times" not in wanted.release_forecast["sites"][0]
        probes = await forecast_probe_times_by_site(session, site_ids={"site-a"})
    assert probes["site-a"], "首选站应有探测点"
    window_end = _predicted(wanted.release_forecast["sites"][0], "window_end")
    assert max(probes["site-a"]) == window_end + timedelta(hours=24)

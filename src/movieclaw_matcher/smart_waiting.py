"""发布证据只缩短默认等待；历史预测区分品质升级与同组跟随。"""

from datetime import UTC, datetime, timedelta


def utc(value: datetime) -> datetime:
    return value.astimezone(UTC).replace(tzinfo=None) if value.tzinfo else value


def publication_anchor(candidates, now):
    # 站点时间是声明，不伪装成本系统的观测。未来/无效日期不能启动或延长计时。
    times = [
        utc(c.publish_time)
        for c in candidates
        if c.publish_time and datetime(2000, 1, 1) <= utc(c.publish_time) <= now
    ]
    return min(times) if times else None


def predict_release(history, *, policy, episode, anchor, now, following, best_quality):
    """只用此前独立单集的同类时间差。镜像按单集去重，合包不作频率样本。

    history 已通过身份检查。published_at 是站点声明；observed_at 控制当时可见性。
    最近八集至少三集支持，成熟样本命中率至少 80%，最近两集不能连续缺失。
    这只是有条件的等待依据，不是目标版本一定存在的概率声明。
    """
    from movieclaw_matcher.smart import RESOLUTION_RANK, TARGET_SOURCE_RANK, weighted_median

    first, arrivals, qualities = {}, {}, {}
    for fact in history:
        number = fact["episode"]
        at, observed = (
            utc(datetime.fromisoformat(fact["published_at"])),
            utc(datetime.fromisoformat(fact["observed_at"])),
        )
        if number >= episode or observed > now or not datetime(2000, 1, 1) <= at <= now:
            continue
        first[number] = min(first.get(number, at), at)
        key = fact.get("series")
        if key:
            arrivals.setdefault(key, {})[number] = min(arrivals.get(key, {}).get(number, at), at)
            qualities[key] = tuple(fact["quality"])
    recent = sorted(first)[-8:]
    predictions = []
    for key, releases in arrivals.items():
        quality = qualities[key]
        target = (
            quality[0] >= RESOLUTION_RANK[policy.resolution]
            and quality[1] >= TARGET_SOURCE_RANK[policy.source]
        )
        if not target and (key != following or quality < best_quality):
            continue
        samples = [n for n in recent if n in releases]
        if len(samples) < 3:
            continue
        lags = [(releases[n] - first[n]).total_seconds() for n in samples]
        center = weighted_median(lags)
        errors = [abs(lags[i] - weighted_median(lags[:i])) for i in range(2, len(lags))]
        radius = max(1800, max(errors, default=0))
        if radius > 10800:
            continue
        upper = center + radius
        mature = [n for n in recent if (now - first[n]).total_seconds() >= upper]
        hits = [
            n for n in mature if n in releases and (releases[n] - first[n]).total_seconds() <= upper
        ]
        if (
            not mature
            or len(hits) / len(mature) < 0.8
            or (len(mature) >= 2 and not any(n in hits for n in mature[-2:]))
        ):
            continue
        predictions.append(
            {
                "start": (anchor + timedelta(seconds=max(0, center - radius))).isoformat(),
                "end": (anchor + timedelta(seconds=upper)).isoformat(),
                "episodes": samples,
                "lag_seconds": center,
                "confidence": "historical_support",
                "basis": "published_at",
                "series": key,
                "purpose": "target_quality" if target else "following",
                "mature_samples": len(mature),
                "on_time_samples": len(hits),
            }
        )
    return (
        min(
            predictions,
            key=lambda p: (
                p["purpose"] != "target_quality",
                -len(p["episodes"]),
                p["end"],
                p["series"],
            ),
        )
        if predictions
        else None
    )

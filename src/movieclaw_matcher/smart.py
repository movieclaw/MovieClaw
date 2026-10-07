"""智能选择的确定性内核。时间、候选与历史均由调用方显式提供。"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from movieclaw_matcher.models import QualitySnapshot, TorrentCandidate, UpgradeSource

ALGORITHM_VERSION = 1
SOURCE_RANK = {
    "hdtv": 1,
    "dvd": 1,
    "webrip": 2,
    "bdrip": 2,
    "hdrip": 2,
    "web-dl": 3,
    "blu-ray": 4,
    "uhd blu-ray": 4,
    "hd-dvd": 4,
    "remux": 5,
    "disc": 6,
}
RESOLUTION_RANK = {"480p": 1, "576p": 2, "720p": 3, "1080p": 4, "1440p": 5, "2160p": 6}
TARGET_SOURCE_RANK = {"web-dl": 3, "blu-ray": 4, "remux": 5}


class SmartPreferences(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    resolution: Literal["1080p", "2160p"] = "2160p"
    source: Literal["web-dl", "blu-ray", "remux"] = "web-dl"
    wait_seconds: int = Field(default=7200, ge=0, le=604800)
    allow_upgrade: bool = True
    strict_resolution: bool = False


class SmartPolicy(SmartPreferences):
    algorithm_version: Literal[1] = ALGORITHM_VERSION
    profile_revision: int = Field(ge=1)
    kind: Literal["movie", "tv"]

    @property
    def upgrade_source(self) -> UpgradeSource | None:
        return UpgradeSource(self.source) if self.allow_upgrade else None

    @property
    def upgrade_keep_old(self) -> bool:
        return False

    @property
    def target_label(self) -> str:
        source = {"web-dl": "WEB-DL", "blu-ray": "蓝光", "remux": "Remux"}[self.source]
        return f"{self.resolution} {source}"


def quality_vector(attrs: object) -> tuple[int | None, int | None]:
    resolution = RESOLUTION_RANK.get((getattr(attrs, "resolution", None) or "").casefold())
    source = SOURCE_RANK.get((getattr(attrs, "media_source", None) or "").casefold())
    if getattr(attrs, "remux", False):
        source = 5
    return resolution, source


def target_met(attrs: object, policy: SmartPolicy) -> bool:
    resolution, source = quality_vector(attrs)
    return (
        resolution is not None
        and source is not None
        and resolution >= RESOLUTION_RANK[policy.resolution]
        and source >= TARGET_SOURCE_RANK[policy.source]
    )


def verified_target_met(snapshot: QualitySnapshot, policy: SmartPolicy) -> bool:
    return bool(
        snapshot.resolution_verified
        and snapshot.source_evidence in {"consistent_declaration", "manual", "disc"}
        and target_met(snapshot, policy)
    )


def is_upgrade(incoming: object, current: object, policy: SmartPolicy) -> bool:
    if not policy.allow_upgrade or target_met(current, policy):
        return False
    new, old = quality_vector(incoming), quality_vector(current)
    if any(v is None for v in (*new, *old)):
        return False
    return all(a >= b for a, b in zip(new, old, strict=True)) and new != old


def eligible(candidate: TorrentCandidate, policy: SmartPolicy) -> bool:
    resolution, source = quality_vector(candidate.attrs)
    # 首版只接受已识别的高清正片，未知不是“无限制”。不自动追逐 8K。
    if resolution is None or source is None or resolution < 3 or source < 2:
        return False
    if resolution > RESOLUTION_RANK[policy.resolution]:
        return False
    if policy.strict_resolution and candidate.attrs.resolution != policy.resolution:
        return False
    return candidate.seeders is None or candidate.seeders > 0


def series_key(candidate: TorrentCandidate) -> str | None:
    return series_key_attrs(candidate.attrs)


def series_key_attrs(attrs: object) -> str | None:
    if not attrs.release_group or None in quality_vector(attrs):
        return None
    base = "|".join(
        (
            attrs.release_group.strip().casefold(),
            attrs.resolution.casefold(),
            str(quality_vector(attrs)[1]),
        )
    )

    codec = (getattr(attrs, "video_codec", None) or "").casefold()
    codec = {
        "h.264": "avc",
        "h264": "avc",
        "x264": "avc",
        "h.265": "hevc",
        "h265": "hevc",
        "x265": "hevc",
    }.get(codec, codec)
    platforms = sorted(p.casefold() for p in getattr(attrs, "platforms", []))
    return base + (f"|{codec}|{','.join(platforms)}" if codec or platforms else "")


class SelectionState(BaseModel):
    model_config = ConfigDict(extra="forbid")
    anchor: datetime
    deadline: datetime
    observation_end: datetime
    anchor_source: Literal["first_seen", "published_at"] = "first_seen"
    first_observed_at: datetime | None = None
    manual_extended: bool = False
    wait_explanation: str | None = None
    identity_explanation: str | None = None
    reason: str = "observing"
    candidate_key: str | None = None
    candidate_title: str | None = None
    forced_candidate: str | None = None
    target_reached: bool = False
    quality_evidence: dict | None = None
    choice_explanation: str | None = None
    prediction: dict | None = None
    following: str | None = None
    selected_series: str | None = None


class SelectionDecision(BaseModel):
    action: Literal["wait", "download", "no_candidate", "stop"]
    state: SelectionState | None
    candidate_key: str | None = None
    next_at: datetime | None = None
    reason: str


def candidate_key(candidate: TorrentCandidate) -> str:
    return f"{candidate.site_id}/{candidate.torrent_id}"


def decide(
    policy: SmartPolicy,
    candidates: list[TorrentCandidate],
    *,
    now: datetime,
    first_seen: datetime | None = None,
    state: SelectionState | None = None,
    following: str | None = None,
    current: QualitySnapshot | None = None,
    prediction: dict | None = None,
    reliability: dict[str, int] | None = None,
    coverage: dict[str, list[int]] | None = None,
    release_history: list[dict] | None = None,
    episode: int = 1,
) -> SelectionDecision:
    """固定截止永不滚动。影片/单集在同一输入下与候选顺序无关。"""
    if state and state.target_reached:
        if current is not None:
            return SelectionDecision(action="stop", state=state, reason="target_reached")
        # 共享库存对账已把单元重新判为缺失；补缺不是重新开启洗版。
        state = state.model_copy(update={"target_reached": False}, deep=True)
    if current is not None and (not policy.allow_upgrade or target_met(current, policy)):
        return SelectionDecision(action="stop", state=state, reason="upgrade_stopped")
    pool = [c for c in candidates if eligible(c, policy)]
    if current is not None:
        pool = [c for c in pool if is_upgrade(c.attrs, current, policy)]
    # 确定性排序；免费与镜像数量不作为品质或可靠性的证据。
    pool.sort(
        key=lambda c: (
            -(quality_vector(c.attrs)[0] or 0),
            -(quality_vector(c.attrs)[1] or 0),
            -(coverage or {}).get(candidate_key(c), [0, 0])[0],
            -(reliability or {}).get(series_key(c), 0),
            -(coverage or {}).get(candidate_key(c), [0, 0])[1],
            -(c.seeders or 0),
            series_key(c) or "",
            candidate_key(c),
        )
    )
    if not pool:
        if state:
            state = state.model_copy(deep=True)
            state.reason = (
                "deadline_no_candidate" if now >= state.deadline else "no_eligible_candidate"
            )
            state.candidate_key, state.candidate_title = None, None
            state.forced_candidate = None
        return SelectionDecision(
            action="no_candidate",
            state=state,
            reason=state.reason if state else "no_eligible_candidate",
            next_at=state.deadline if state and state.deadline > now else None,
        )
    from movieclaw_matcher.smart_waiting import predict_release, publication_anchor

    published = publication_anchor(pool, now)
    observed = min(first_seen or now, now)
    anchor = min(observed, published) if published else observed
    source = "published_at" if published and published <= observed else "first_seen"
    if state is None:
        deadline = anchor + timedelta(seconds=policy.wait_seconds)
        state = SelectionState(
            anchor=anchor,
            anchor_source=source,
            first_observed_at=observed,
            deadline=deadline,
            observation_end=min(
                deadline,
                anchor
                + timedelta(
                    seconds=min(policy.wait_seconds, 21600 if policy.kind == "movie" else 1800)
                ),
            ),
        )
    state = state.model_copy(deep=True)
    state.following = following
    state.first_observed_at = state.first_observed_at or observed
    # 兼容已存在的人工延期状态；新发现的旧发布时间不得覆盖用户决定。
    state.manual_extended = state.manual_extended or state.reason == "user_extended"
    if not state.manual_extended and anchor < state.anchor:
        state.anchor, state.anchor_source = anchor, source
        state.deadline = min(state.deadline, anchor + timedelta(seconds=policy.wait_seconds))
        state.observation_end = min(
            state.observation_end,
            state.deadline,
            anchor + timedelta(seconds=21600 if policy.kind == "movie" else 1800),
        )
    if release_history is not None:
        prediction = predict_release(
            release_history,
            policy=policy,
            episode=episode,
            anchor=state.anchor,
            now=now,
            following=following,
            best_quality=quality_vector(pool[0].attrs),
        )
        state.prediction = prediction
        if not prediction and not state.manual_extended:
            state.observation_end = min(
                state.observation_end,
                state.anchor + timedelta(seconds=21600 if policy.kind == "movie" else 1800),
            )
    elif prediction:
        state.prediction = prediction
    if state.prediction and not state.manual_extended:
        end = datetime.fromisoformat(state.prediction["end"])
        state.observation_end = end if end <= state.deadline else min(now, state.observation_end)
    state.wait_explanation = (
        "已保留用户手动延长的等待时间。"
        if state.manual_extended
        else "历史到达窗口超出等待上限，不耗尽预算；选择当前合格候选，品质目标保持不变。"
        if state.prediction and datetime.fromisoformat(state.prediction["end"]) > state.deadline
        else "历史到达窗口已经结束；重新核验当前合格候选，不重新计时。"
        if state.prediction and datetime.fromisoformat(state.prediction["end"]) <= now
        else "同季此前独立单集的发布延迟提供等待依据；到期仍无目标版本，就选择当前合格候选。"
        if state.prediction
        else "按已匹配资源的最早站点发布时间计算，转载、合包和新建订阅不重新计时。"
        if state.anchor_source == "published_at"
        else "发布时间不明确，只进行一次有上限的观察；不会把本次发现时间当作发布时间。"
    )
    chosen = pool[0]
    followed = next((c for c in pool if following and series_key(c) == following), None)
    if current is not None:
        reason = "quality_upgrade"
    elif state.forced_candidate:
        chosen = next((c for c in pool if candidate_key(c) == state.forced_candidate), None)
        if chosen is None:
            state.forced_candidate = None
            state.reason = "manual_candidate_unavailable"
            state.candidate_key, state.candidate_title = candidate_key(pool[0]), pool[0].title
            return SelectionDecision(
                action="no_candidate",
                state=state,
                reason=state.reason,
                next_at=max(now, min(state.observation_end, state.deadline)),
            )
        reason = "manual_download"
    elif now >= state.deadline:
        if followed and quality_vector(followed.attrs) == quality_vector(chosen.attrs):
            chosen = followed
        reason = "deadline_fallback"
    elif (
        followed
        and quality_vector(chosen.attrs) > quality_vector(followed.attrs)
        and target_met(chosen.attrs, policy)
    ):
        reason = "target_available"
    elif (
        state.prediction
        and state.prediction.get("purpose") == "target_quality"
        and not target_met(chosen.attrs, policy)
        and now < state.observation_end
    ):
        state.reason = "waiting_target"
        state.candidate_key, state.candidate_title = candidate_key(chosen), chosen.title
        return SelectionDecision(
            action="wait", state=state, reason=state.reason, next_at=state.observation_end
        )
    elif followed:
        chosen, reason = followed, "followed_series"
    elif not following and target_met(chosen.attrs, policy):
        reason = "target_available"
    elif now >= state.observation_end:
        reason = (
            "published_window_elapsed"
            if state.anchor_source == "published_at"
            else "observation_finished"
        )
    else:
        state.reason = "waiting_series" if following else "observing"
        state.candidate_key = candidate_key(chosen)
        state.candidate_title = chosen.title
        return SelectionDecision(
            action="wait",
            state=state,
            reason=state.reason,
            next_at=state.observation_end,
        )
    group_count, resource_count = (coverage or {}).get(candidate_key(chosen), [1, 1])
    verified = (reliability or {}).get(series_key(chosen), 0)
    state.choice_explanation = (
        "优先分辨率与片源；同品质延续跟随版本，再比较版本覆盖、核验记录、"
        "单包覆盖和做种数；仍相同时按固定标识选择。"
        f"本版本覆盖 {group_count} 集，本资源拟覆盖 {resource_count} 集；"
        + (
            f"有 {verified} 集成功核验记录。"
            if verified
            else "暂无成功核验记录，不推断制作组品质。"
        )
        + f"做种数：{chosen.seeders if chosen.seeders is not None else '未知'}。"
    )
    state.selected_series = series_key(chosen)
    state.reason, state.candidate_key, state.candidate_title = (
        reason,
        candidate_key(chosen),
        chosen.title,
    )
    return SelectionDecision(
        action="download", state=state, candidate_key=candidate_key(chosen), reason=reason
    )


def predict_window(
    observations: list[tuple[int, str, datetime]],
    *,
    series: str,
    episode: int,
    anchor: datetime,
    now: datetime,
) -> dict | None:
    """只使用当前集之前、当时已见的独立单集。同一发布的跨站镜像只算一次。"""
    first, arrivals = {}, {}
    for number, key, seen in observations:
        if number >= episode or seen > now:
            continue
        first[number] = min(first.get(number, seen), seen)
        if key == series:
            arrivals[number] = min(arrivals.get(number, seen), seen)
    history = sorted(arrivals)[-8:]
    if len(history) < 3:
        return None
    lags = [(arrivals[n] - first[n]).total_seconds() for n in history]
    center = weighted_median(lags)
    # 每个历史预测只使用它之前的样本；不会把未来误差带进过去。
    errors = [abs(lags[i] - weighted_median(lags[:i])) for i in range(2, len(lags))]
    radius = max(1800, max(errors, default=1800))
    if radius > 10800:
        return None
    return {
        "start": (anchor + timedelta(seconds=max(0, center - radius))).isoformat(),
        "end": (anchor + timedelta(seconds=center + radius)).isoformat(),
        "episodes": history,
        "lag_seconds": center,
        "confidence": "limited" if len(history) < 5 else "observed",
        "basis": "first_seen",
        "series": series,
    }


def weighted_median(values: list[float]) -> float:
    """近期样本权重依次为 1..N；规则固定在算法版本内。"""
    pairs = sorted((value, i + 1) for i, value in enumerate(values))
    half = sum(weight for _, weight in pairs) / 2
    cumulative = 0
    for value, weight in pairs:
        cumulative += weight
        if cumulative >= half:
            return value
    return pairs[-1][0]

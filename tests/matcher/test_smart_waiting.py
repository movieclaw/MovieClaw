from dataclasses import replace
from datetime import timedelta

import pytest
from tests.matcher.test_smart import NOW, candidate

from movieclaw_matcher.smart import SmartPolicy, decide, series_key

POLICY = SmartPolicy(kind="tv", profile_revision=1, wait_seconds=21600)


def history(*, misses=(), lag=3600, future=False):
    result = []
    for episode in range(1, 6):
        published = NOW - timedelta(days=7 - episode)
        for group, resolution, delay in [("LOW", "1080p", 0), ("HIGH", "2160p", lag)]:
            if group == "HIGH" and episode in misses:
                continue
            result.append(
                dict(
                    episode=episode,
                    series=series_key(candidate(group=group, resolution=resolution)),
                    quality=[6 if group == "HIGH" else 4, 3],
                    published_at=(published + timedelta(seconds=delay)).isoformat(),
                    observed_at=(NOW + timedelta(hours=1) if future else NOW).isoformat(),
                )
            )
    return result


def test_old_episode_new_subscription_and_repack_do_not_restart_wait():
    old = replace(candidate(), publish_time=NOW - timedelta(days=10))
    pack = replace(candidate("pack", group="Pack"), publish_time=NOW - timedelta(minutes=5))
    for pool in [[old, pack], [pack, old]]:
        result = decide(POLICY, pool, now=NOW, first_seen=NOW)
        assert result.action == "download"
        assert result.state.anchor == old.publish_time
        assert result.state.first_observed_at == NOW
        assert result.state.anchor_source == "published_at"


def test_existing_wait_shortens_but_manual_extension_survives_earlier_evidence():
    initial = decide(POLICY, [candidate()], now=NOW)
    old = replace(candidate(), publish_time=NOW - timedelta(days=10))
    assert decide(POLICY, [old], now=NOW, state=initial.state).action == "download"
    extended = initial.state.model_copy(
        update={
            "reason": "user_extended",
            "deadline": NOW + timedelta(hours=8),
            "observation_end": NOW + timedelta(hours=8),
        }
    )
    result = decide(POLICY, [old], now=NOW, state=extended, release_history=[])
    assert result.action == "wait" and result.state.manual_extended
    again = decide(
        POLICY, [old], now=NOW + timedelta(hours=1), state=result.state, release_history=[]
    )
    assert again.action == "wait" and again.state.deadline == extended.deadline


@pytest.mark.parametrize("published", [None, NOW + timedelta(days=1)])
def test_unknown_or_future_timestamp_has_one_bounded_window(published):
    c = replace(candidate(), publish_time=published)
    result = decide(POLICY, [c], now=NOW)
    assert result.action == "wait" and result.state.anchor_source == "first_seen"
    result = decide(POLICY, [c], now=NOW + timedelta(minutes=31), state=result.state)
    assert result.action == "download" and result.state.anchor == NOW


def test_target_prediction_can_wait_even_when_lower_quality_followed_version_exists():
    low = replace(candidate(group="LOW"), publish_time=NOW)
    result = decide(
        POLICY, [low], now=NOW, following=series_key(low), episode=6, release_history=history()
    )
    assert result.action == "wait" and result.reason == "waiting_target"
    assert result.next_at == NOW + timedelta(minutes=90)
    target = replace(
        candidate("high", "2160p", group="HIGH"), publish_time=NOW + timedelta(hours=1)
    )
    chosen = decide(
        POLICY,
        [low, target],
        now=target.publish_time,
        state=result.state,
        following=series_key(low),
        episode=6,
        release_history=history(),
    )
    assert chosen.action == "download" and chosen.candidate_key == "test/high"


@pytest.mark.parametrize(
    "facts",
    [
        history(misses=(4, 5)),
        history(future=True),
        history()[:4],
        [x for x in history() if x["quality"][0] == 4],
    ],
)
def test_missing_late_or_insufficient_history_cannot_justify_quality_wait(facts):
    low = replace(candidate(group="LOW"), publish_time=NOW - timedelta(hours=1))
    result = decide(POLICY, [low], now=NOW, episode=6, release_history=facts)
    assert result.action == "download" and result.state.prediction is None


def test_mirrors_do_not_increase_samples_and_budget_does_not_force_wait():
    facts = history()[:4] * 12
    low = replace(candidate(), publish_time=NOW)
    result = decide(POLICY, [low], now=NOW, episode=6, release_history=facts)
    assert result.state.prediction is None
    result = decide(
        POLICY.model_copy(update={"wait_seconds": 1800}),
        [low],
        now=NOW,
        episode=6,
        release_history=history(),
    )
    assert result.action == "download"  # 有证据的到达窗口超出用户预算，不白等半小时。


def test_strict_no_resource_and_future_episode_do_not_start_quality_countdown():
    result = decide(
        POLICY.model_copy(update={"strict_resolution": True}),
        [replace(candidate(), publish_time=NOW - timedelta(days=10))],
        now=NOW,
    )
    assert result.action == "no_candidate" and result.state is None
    assert decide(POLICY, [], now=NOW).state is None


def test_prediction_failure_releases_fallback_and_does_not_renew_window():
    low = replace(candidate(), publish_time=NOW)
    waiting = decide(POLICY, [low], now=NOW, episode=6, release_history=history())
    due = waiting.next_at
    fallback = decide(
        POLICY, [low], now=due, state=waiting.state, episode=6, release_history=history()
    )
    assert fallback.action == "download"
    assert fallback.state.deadline == waiting.state.deadline


def test_prediction_withdrawal_shortens_wait_when_latest_evidence_contradicts_it():
    low = replace(candidate(), publish_time=NOW)
    waiting = decide(POLICY, [low], now=NOW, episode=6, release_history=history())
    result = decide(
        POLICY,
        [low],
        now=NOW + timedelta(minutes=31),
        state=waiting.state,
        episode=6,
        release_history=history(misses=(4, 5)),
    )
    assert result.action == "download" and result.state.prediction is None


def test_chronological_evidence_waits_for_target_without_using_future_arrival():
    from pydantic import TypeAdapter

    from movieclaw_matcher import RuleSetSpec, TorrentCandidate
    from movieclaw_matcher.smart_replay_events import replay_events

    events = []
    for episode in range(1, 7):
        anchor = NOW - timedelta(days=6 - episode)
        for label, resolution, delay in [("low", "1080p", 0), ("high", "2160p", 3600)]:
            at = anchor + timedelta(seconds=delay)
            raw = candidate(f"{label}-{episode}", resolution=resolution, group=label)
            attrs = raw.attrs.model_copy(update={"episodes": [episode], "seasons": [1]})
            raw = replace(raw, attrs=attrs, publish_time=at)
            events.append(
                {
                    "kind": "resource",
                    "episode": episode,
                    "observed_at": at.isoformat(),
                    "candidate": TypeAdapter(TorrentCandidate).dump_python(raw, mode="json"),
                }
            )
    early = replay_events(
        events, POLICY, RuleSetSpec(), episode=6, end_at=NOW + timedelta(minutes=45)
    )
    assert early["strategies"]["evidence"]["submissions"] == 0
    assert early["strategies"]["fixed_wait"]["decision_wait_seconds"] == [1800]
    full = replay_events(events, POLICY, RuleSetSpec(), episode=6, end_at=NOW + timedelta(hours=2))
    report = full["strategies"]["evidence"]
    assert report["decision_wait_seconds"] == [3600]
    assert report["declared_target_met"] == 1
    assert report["matched_imports"] == 0  # 选择不是下载或入库成功证明。

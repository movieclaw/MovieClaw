from datetime import datetime, timedelta
from itertools import permutations, product

from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher import (
    QualitySnapshot,
    TorrentCandidate,
    compare_upgrade,
    covered_by_existing,
    provably_at_cutoff,
)
from movieclaw_matcher.smart import SmartPolicy, decide, is_upgrade, target_met

NOW = datetime(2026, 10, 7, 12)
POLICY = SmartPolicy(kind="tv", profile_revision=1, source="blu-ray")


def candidate(name="a", resolution="1080p", source="WEB-DL", group="A"):
    return TorrentCandidate(
        site_id="test",
        torrent_id=name,
        title=name,
        subtitle="",
        attrs=TorrentAttrs(resolution=resolution, media_source=source, release_group=group),
        seeders=10,
    )


def test_quality_axes_and_three_consumers_agree():
    for old_res, old_source, new_res, new_source in product(
        [None, "1080p", "2160p"],
        [None, "WEB-DL", "Blu-ray", "Remux"],
        [None, "1080p", "2160p"],
        [None, "WEB-DL", "Blu-ray", "Remux"],
    ):
        old = QualitySnapshot(
            resolution=old_res,
            media_source=old_source,
            resolution_verified=True,
            source_evidence="consistent_declaration",
        )
        new = candidate(resolution=new_res, source=new_source)
        better = is_upgrade(new.attrs, old, POLICY)
        assert compare_upgrade(new, old, POLICY).accepted == better
        assert covered_by_existing([old], new.attrs, POLICY) == (not better)
        assert provably_at_cutoff(old, POLICY) == target_met(old, POLICY)
    assert not is_upgrade(
        candidate(resolution="2160p").attrs,
        QualitySnapshot(resolution="1080p", media_source="Blu-ray"),
        POLICY,
    )
    assert not target_met(candidate(resolution="2160p").attrs, POLICY)


def test_permutations_refresh_and_deadline_are_stable():
    pool = [candidate("b"), candidate("a"), candidate("z", "720p")]
    outputs = [decide(POLICY, list(p), now=NOW) for p in permutations(pool)]
    assert all(o == outputs[0] for o in outputs)
    state = outputs[0].state
    assert state.candidate_key == "test/a"
    for minutes in [1, 2, 10, 29]:
        result = decide(POLICY, pool, now=NOW + timedelta(minutes=minutes), state=state)
        assert result.action == "wait"
        assert result.state.deadline == state.deadline
    result = decide(POLICY, pool, now=NOW + timedelta(minutes=30), state=state)
    assert result.action == "download"
    assert result.reason == "observation_finished"


def test_hourly_budgets_set_real_deadlines_and_zero_downloads_immediately():
    for kind, hours in product(("movie", "tv"), (0, 1, 3, 7, 24, 25, 72, 96, 168)):
        policy = POLICY.model_copy(update={"kind": kind, "wait_seconds": hours * 3600})
        first = decide(policy, [candidate()], now=NOW)
        assert first.state.deadline == NOW + timedelta(hours=hours)
        assert first.state.observation_end <= first.state.deadline
        assert first.action == ("download" if hours == 0 else "wait")
        expired = decide(policy, [candidate()], now=first.state.deadline, state=first.state)
        assert expired.action == "download" and expired.reason == "deadline_fallback"


def test_strict_minimum_never_relaxes_and_no_new_window_after_deadline():
    first = decide(POLICY, [candidate()], now=NOW)
    state = first.state
    strict = POLICY.model_copy(update={"strict_resolution": True})
    result = decide(strict, [candidate()], now=NOW + timedelta(days=1), state=state)
    assert result.action == "no_candidate"
    result = decide(
        strict, [candidate(resolution="2160p")], now=NOW + timedelta(days=1), state=state
    )
    assert result.action == "download"
    assert result.state.deadline == state.deadline


def test_target_quality_precedes_lower_quality_followed_series():
    from movieclaw_matcher.smart import series_key

    followed = candidate("a")
    high = candidate("b", "2160p", "Blu-ray", "B")
    result = decide(POLICY, [high, followed], following=series_key(followed), now=NOW)
    assert result.candidate_key == "test/b"


def test_upgrade_disabled_and_same_quality_stop():
    current = QualitySnapshot(resolution="1080p", media_source="WEB-DL")
    disabled = POLICY.model_copy(update={"allow_upgrade": False})
    assert (
        decide(disabled, [candidate(resolution="2160p")], now=NOW, current=current).action == "stop"
    )
    assert not is_upgrade(candidate(group="B").attrs, current, POLICY)


def test_predictor_deduplicates_mirrors_excludes_future_and_sparse_samples():
    from movieclaw_matcher.smart import predict_window

    history = []
    for ep in range(1, 5):
        first = NOW - timedelta(days=5 - ep)
        history.extend([(ep, "b", first), (ep, "a", first + timedelta(hours=2))] * 3)
    forecast = predict_window(history, series="a", episode=5, anchor=NOW, now=NOW)
    assert forecast["episodes"] == [1, 2, 3, 4] and forecast["lag_seconds"] == 7200
    assert (
        predict_window(
            history + [(6, "a", NOW + timedelta(days=1))],
            series="a",
            episode=5,
            anchor=NOW,
            now=NOW,
        )
        == forecast
    )
    assert predict_window(history, series="a", episode=3, anchor=NOW, now=NOW) is None


def test_series_unknown_fields_are_not_wildcards_and_success_beats_seed_count():
    from dataclasses import replace

    from movieclaw_matcher.smart import series_key

    one = candidate("one", group="A")
    known = replace(one, attrs=one.attrs.model_copy(update={"video_codec": "HEVC"}))
    assert series_key(one) != series_key(known)
    alias = replace(known, attrs=known.attrs.model_copy(update={"video_codec": "x265"}))
    assert series_key(alias) == series_key(known)
    rival = replace(candidate("two", group="B"), seeders=1000)
    result = decide(
        POLICY.model_copy(update={"wait_seconds": 0}),
        [rival, one],
        now=NOW,
        reliability={series_key(one): 3},
    )
    assert result.candidate_key == "test/one"


def test_frozen_decision_replays_exactly_and_compares_three_strategies():
    from pydantic import TypeAdapter

    from movieclaw_matcher import RuleSetSpec
    from movieclaw_matcher.smart_replay import compare_decisions

    pool = [candidate()]
    inputs = {
        "policy": POLICY.model_dump(mode="json"),
        "now": NOW.isoformat(),
        "first_seen": NOW.isoformat(),
        "state": None,
        "following": None,
        "current": None,
        "prediction": None,
        "reliability": {},
        "candidates": TypeAdapter(list[TorrentCandidate]).dump_python(pool, mode="json"),
    }
    record = {"inputs": inputs, "outcome": decide(POLICY, pool, now=NOW).model_dump(mode="json")}
    report = compare_decisions([record], RuleSetSpec())
    assert report["exact_replay_mismatches"] == 0
    assert report["strategies"]["rules"]["selected"] == 1
    assert (
        report["strategies"]["fixed_wait"]["wait"]
        == report["strategies"]["prediction"]["wait"]
        == 1
    )
    assert all(row["deadline_violations"] == 0 for row in report["strategies"].values())


def test_target_latch_stops_washing_but_does_not_block_inventory_gap_repair():
    policy = POLICY.model_copy(update={"wait_seconds": 0})
    state = decide(policy, [candidate()], now=NOW).state.model_copy(update={"target_reached": True})
    current = QualitySnapshot(resolution="2160p", media_source="Blu-ray")
    assert decide(policy, [candidate()], now=NOW, state=state, current=current).action == "stop"
    repaired = decide(policy, [candidate()], now=NOW, state=state, current=None)
    assert repaired.action == "download" and not repaired.state.target_reached
    assert repaired.state.deadline == state.deadline


def test_event_replay_has_independent_clocks_and_no_counterfactual_import_claims():
    from pydantic import TypeAdapter

    from movieclaw_matcher import RuleSetSpec
    from movieclaw_matcher.smart_replay_events import replay_events

    def arrival(at, value, ep):
        return {
            "observed_at": at.isoformat(),
            "kind": "resource",
            "episode": ep,
            "candidate": TypeAdapter(TorrentCandidate).dump_python(value, mode="json"),
        }

    events = []
    for ep in range(1, 5):
        start = NOW - timedelta(days=5 - ep)
        events += [
            arrival(start, candidate(f"low-{ep}", group="B"), ep),
            arrival(start + timedelta(hours=2), candidate(f"high-{ep}", "2160p"), ep),
        ]
    events += [
        arrival(NOW, candidate("low", group="B"), 5),
        arrival(NOW + timedelta(hours=2), candidate("high", "2160p"), 5),
        {
            "observed_at": (NOW + timedelta(hours=2, minutes=10)).isoformat(),
            "kind": "imported",
            "candidate_key": "test/high",
            "downloaded_bytes": 123,
            "quality": QualitySnapshot(
                resolution="2160p",
                media_source="WEB-DL",
                resolution_verified=True,
                source_evidence="consistent_declaration",
            ).model_dump(),
        },
    ]
    policy = SmartPolicy(kind="tv", profile_revision=1, wait_seconds=10800)
    result = replay_events(
        events,
        policy,
        RuleSetSpec(),
        end_at=NOW + timedelta(hours=4),
        episode=5,
        following="a|2160p|3",
    )
    old, fixed, predicted = [result["strategies"][n] for n in ("rules", "fixed_wait", "prediction")]
    assert old["decision_wait_seconds"] == [0]
    assert fixed["decision_wait_seconds"] == [1800]
    assert predicted["decision_wait_seconds"] == [7200]
    assert predicted["verified_target_met"] == 1 and predicted["measured_downloaded_bytes"] == 123
    assert fixed["matched_imports"] == 0 and fixed["measured_downloaded_bytes"] is None
    assert fixed["pending_without_observed_outcome"] == 1
    # 回放结束后的资源不能提前进入候选，也不能凭后验信息改变当时决策。
    early = replay_events(
        events,
        policy,
        RuleSetSpec(),
        end_at=NOW + timedelta(minutes=20),
        episode=5,
        following="a|2160p|3",
    )
    assert early["strategies"]["prediction"]["submissions"] == 0
    assert early["strategies"]["prediction"]["trace"][-1]["action"] == "wait"


def test_event_replay_pause_preserves_anchor_and_explicit_extension_only():
    from pydantic import TypeAdapter

    from movieclaw_matcher import RuleSetSpec
    from movieclaw_matcher.smart_replay_events import replay_events

    events = [
        {"observed_at": NOW.isoformat(), "kind": "pause"},
        {
            "observed_at": NOW.isoformat(),
            "kind": "resource",
            "candidate": TypeAdapter(TorrentCandidate).dump_python(candidate(), mode="json"),
        },
        {"observed_at": (NOW + timedelta(hours=4)).isoformat(), "kind": "resume"},
    ]
    result = replay_events(events, POLICY, RuleSetSpec(), end_at=NOW + timedelta(hours=5))
    for name in ("fixed_wait", "prediction"):
        selected = [t for t in result["strategies"][name]["trace"] if t["action"] == "download"]
        assert len(selected) == 1
        assert selected[0]["at"] == (NOW + timedelta(hours=4)).isoformat()
        assert selected[0]["deadline"] == (NOW + timedelta(hours=2)).isoformat()


def test_equal_quality_groups_have_deterministic_evidence_and_seed_tiebreaks():
    from dataclasses import replace

    from movieclaw_matcher.smart import series_key

    policy = POLICY.model_copy(update={"wait_seconds": 0})
    a = replace(candidate("z", group="A"), seeders=80)
    b = replace(candidate("a", group="B"), seeders=40)
    c = replace(candidate("b", group="C"), seeders=80)
    for pool in permutations([a, b, c]):
        assert decide(policy, list(pool), now=NOW).candidate_key == "test/z"
        # 3 个独立单集成功核验胜过未知；镜像未加分。
        assert (
            decide(policy, list(pool), now=NOW, reliability={series_key(b): 3}).candidate_key
            == "test/a"
        )
        assert (
            decide(policy, list(pool), now=NOW, following=series_key(c)).candidate_key == "test/b"
        )
    cov = {"test/z": [18, 4], "test/a": [18, 18], "test/b": [4, 4]}
    assert decide(policy, [a, b, c], now=NOW, coverage=cov).candidate_key == "test/a"

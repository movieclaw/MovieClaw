"""单作品单单元的时间序列回放。输入须已通过共同身份与覆盖范围检查。

资源事件只在 observed_at 后可见。每套策略独立推进等待与在途状态。
未实际下载的反事实候选没有入库结果；报告将其保留为删失样本。
"""

from dataclasses import replace
from datetime import datetime, timedelta
from itertools import groupby

from pydantic import TypeAdapter

from movieclaw_matcher import IdentityMatch, QualitySnapshot, RuleSetSpec, TorrentCandidate
from movieclaw_matcher.decision import pick_best
from movieclaw_matcher.rules import evaluate_rules
from movieclaw_matcher.smart import (
    SmartPolicy,
    candidate_key,
    decide,
    eligible,
    predict_window,
    quality_vector,
    series_key,
    target_met,
    verified_target_met,
)


def replay_events(
    events: list[dict],
    policy: SmartPolicy,
    rules: RuleSetSpec,
    *,
    end_at: datetime,
    episode: int = 1,
    following: str | None = None,
) -> dict:
    """事件：resource / remove / pause / resume / extend / imported / tick。

    resource 含 candidate，可选 episode（默认当前单元）；同一 key 更新属性。
    imported 含 candidate_key、quality，可选 downloaded_bytes。仅匹配本策略
    在途候选时计实际结果。所有输入为同作品同季已观测事实，不外推下载成功。
    """
    ordered = sorted(events, key=lambda event: datetime.fromisoformat(event["observed_at"]))
    grouped = [
        (at, list(group))
        for at, group in groupby(
            ordered, key=lambda event: datetime.fromisoformat(event["observed_at"])
        )
        if at <= end_at
    ]
    return {
        "algorithm_version": policy.algorithm_version,
        "events": sum(len(batch) for _, batch in grouped),
        "end_at": end_at.isoformat(),
        "scope": "single_unit_observed_events; unmatched_counterfactual_outcomes_are_unknown",
        "strategies": {
            name: _replay_strategy(grouped, policy, rules, end_at, episode, following, name)
            for name in ("rules", "fixed_wait", "prediction", "evidence")
        },
    }


def _replay_strategy(grouped, policy, rules, end_at, episode, following, name):
    candidates, observations, trace, release_history = {}, [], [], []
    state = current = pending = first_seen = next_at = None
    followed, paused = following, False
    submitted = imports = declared_met = measured_met = 0
    measured_bytes, bytes_known, waited = 0, 0, []

    def evaluate(now):
        nonlocal state, pending, first_seen, next_at, followed, submitted, declared_met
        next_at = None
        if paused or pending:
            return
        choices = list(candidates.values())
        if first_seen is None and any(eligible(c, policy) for c in choices):
            first_seen = now
        if name == "rules":
            # 首次选择对照；旧规则的洗版执行不在离线纯决策里伪造。
            if current is not None:
                return
            best = pick_best([(c, IdentityMatch(), evaluate_rules(c, rules)) for c in choices])
            chosen = best[0] if best else None
            action, reason = ("download", "rules") if chosen else ("no_candidate", "rules")
        else:
            prediction = (
                predict_window(
                    observations,
                    series=followed,
                    episode=episode,
                    anchor=state.anchor if state else first_seen or now,
                    now=now,
                )
                if name == "prediction" and followed
                else None
            )
            decision = decide(
                policy,
                [replace(c, publish_time=None) for c in choices]
                if name == "fixed_wait"
                else choices,
                now=now,
                first_seen=first_seen,
                state=state,
                following=followed,
                current=current,
                prediction=prediction,
                release_history=release_history if name == "evidence" else None,
                episode=episode,
            )
            state, next_at = decision.state, decision.next_at
            chosen = candidates.get(decision.candidate_key)
            action, reason = decision.action, decision.reason
        trace.append(
            {
                "at": now.isoformat(),
                "action": action,
                "reason": reason,
                "candidate_key": candidate_key(chosen) if chosen else None,
                "deadline": state.deadline.isoformat() if state else None,
            }
        )
        if chosen:
            submitted += 1
            declared_met += int(target_met(chosen.attrs, policy))
            pending = candidate_key(chosen)
            waited.append(max(0, (now - (first_seen or now)).total_seconds()))
            if policy.kind == "tv" and followed is None:
                followed = series_key(chosen)

    for at, batch in grouped + [(end_at, [])]:
        # 同时刻的事实先合并，再作一次选择，避免批内排列改变结果。
        while next_at is not None and next_at < at:
            due = next_at
            evaluate(due)
            if next_at is not None and next_at <= due:
                raise ValueError("回放决策未推进下次评估时间")
        for event in batch:
            kind = event["kind"]
            if kind == "resource":
                candidate = TypeAdapter(TorrentCandidate).validate_python(event["candidate"])
                unit = event.get("episode", episode)
                if unit == episode:
                    candidates[candidate_key(candidate)] = candidate
                    if first_seen is None and eligible(candidate, policy):
                        first_seen = at
                if eligible(candidate, policy) and (series := series_key(candidate)):
                    observations.append((unit, series, at))
                if (
                    eligible(candidate, policy)
                    and candidate.publish_time
                    and len(candidate.attrs.episodes) == 1
                    and not candidate.attrs.complete
                ):
                    release_history.append(
                        {
                            "episode": unit,
                            "series": series_key(candidate),
                            "quality": list(quality_vector(candidate.attrs)),
                            "published_at": candidate.publish_time.isoformat(),
                            "observed_at": at.isoformat(),
                        }
                    )
            elif kind == "remove":
                candidates.pop(event["candidate_key"], None)
            elif kind == "pause":
                paused = True
            elif kind == "resume":
                paused = False
            elif kind == "extend":
                seconds = event["seconds"]
                if not isinstance(seconds, int) or seconds <= 0:
                    raise ValueError("延期必须为正整数秒")
                if state is not None:
                    state.deadline += timedelta(seconds=seconds)
                    state.observation_end = state.deadline
                    state.manual_extended = True
            elif kind == "imported":
                if pending == event["candidate_key"]:
                    current = QualitySnapshot.model_validate(event["quality"])
                    pending = None
                    imports += 1
                    reached = verified_target_met(current, policy)
                    measured_met += int(reached)
                    if state is not None:
                        state.target_reached = reached
                    if event.get("downloaded_bytes") is not None:
                        measured_bytes += event["downloaded_bytes"]
                        bytes_known += 1
            elif kind != "tick":
                raise ValueError(f"不支持的回放事件：{kind}")
        evaluate(at)
    return {
        "submissions": submitted,
        "declared_target_met": declared_met,
        "matched_imports": imports,
        "verified_target_met": measured_met,
        "decision_wait_seconds": waited,
        "pending_without_observed_outcome": int(bool(pending)),
        "measured_downloaded_bytes": measured_bytes if bytes_known else None,
        "imports_with_byte_measurement": bytes_known,
        "trace": trace,
    }


if __name__ == "__main__":
    import argparse
    import json
    from pathlib import Path

    parser = argparse.ArgumentParser(description="按已观测事件回放三套订阅选择策略")
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    payload = json.loads(args.input.read_text())
    report = replay_events(
        payload["events"],
        SmartPolicy.model_validate(payload["policy"]),
        RuleSetSpec.model_validate(payload.get("rules", {})),
        end_at=datetime.fromisoformat(payload["end_at"]),
        episode=payload.get("episode", 1),
        following=payload.get("following"),
    )
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

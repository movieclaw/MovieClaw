"""只消费冻结的决策输入；离线回放没有数据库、站点或下载器副作用。"""

from datetime import datetime, timedelta

from pydantic import TypeAdapter

from movieclaw_matcher import IdentityMatch, QualitySnapshot, RuleSetSpec, TorrentCandidate
from movieclaw_matcher.decision import pick_best
from movieclaw_matcher.rules import evaluate_rules
from movieclaw_matcher.smart import SelectionState, SmartPolicy, decide, target_met


def replay_decision(inputs: dict, *, prediction: bool = True):
    policy = SmartPolicy.model_validate(inputs["policy"])
    state = SelectionState.model_validate(inputs["state"]) if inputs.get("state") else None
    if not prediction and state:
        state.prediction = None
        state.observation_end = min(
            state.deadline,
            state.anchor + timedelta(seconds=21600 if policy.kind == "movie" else 1800),
        )
    return decide(
        policy,
        TypeAdapter(list[TorrentCandidate]).validate_python(inputs["candidates"]),
        now=datetime.fromisoformat(inputs["now"]),
        first_seen=datetime.fromisoformat(inputs["first_seen"]),
        state=state,
        following=inputs.get("following"),
        current=QualitySnapshot.model_validate(inputs["current"])
        if inputs.get("current")
        else None,
        prediction=inputs.get("prediction") if prediction else None,
        reliability=inputs.get("reliability"),
        coverage=inputs.get("coverage"),
        release_history=inputs.get("release_history") if prediction else None,
        episode=inputs.get("episode", 1),
    )


def compare_decisions(records: list[dict], rules: RuleSetSpec) -> dict:
    """同一可见候选集的决策比较；不是下载成功率或历史完整事件仿真。"""
    result = {
        "samples": len(records),
        "exact_replay_mismatches": 0,
        "strategies": {},
        "scope": "decision_snapshots_only; no measured import, bytes or unobserved arrivals",
    }
    for name in ("rules", "fixed_wait", "prediction"):
        report = {
            "selected": 0,
            "declared_target_met": 0,
            "wait": 0,
            "decision_wait_seconds": [],
            "deadline_violations": 0,
        }
        for record in records:
            inputs = record["inputs"]
            candidates = TypeAdapter(list[TorrentCandidate]).validate_python(inputs["candidates"])
            policy = SmartPolicy.model_validate(inputs["policy"])
            if name == "rules":
                # 输入已通过共同身份过滤；单单元回放不推测包的其他单元状态。
                best = pick_best(
                    [(c, IdentityMatch(), evaluate_rules(c, rules)) for c in candidates]
                )
                chosen = best[0] if best else None
                decision = None
            else:
                decision = replay_decision(inputs, prediction=name == "prediction")
                chosen = next(
                    (
                        c
                        for c in candidates
                        if f"{c.site_id}/{c.torrent_id}" == decision.candidate_key
                    ),
                    None,
                )
                if name == "prediction" and record.get("outcome") != decision.model_dump(
                    mode="json"
                ):
                    result["exact_replay_mismatches"] += 1
                if decision.action == "wait":
                    report["wait"] += 1
                    if decision.state.deadline <= datetime.fromisoformat(inputs["now"]):
                        report["deadline_violations"] += 1
                if chosen and decision.state:
                    report["decision_wait_seconds"].append(
                        max(
                            0,
                            (
                                datetime.fromisoformat(inputs["now"]) - decision.state.anchor
                            ).total_seconds(),
                        )
                    )
            if chosen:
                report["selected"] += 1
                report["declared_target_met"] += int(target_met(chosen.attrs, policy))
        result["strategies"][name] = report
    return result

"""开放契约的表面快照（plugin-kernel.md §5.4）。

第三方插件按契约版本区间声明依赖（``^1.0``），所以开放契约的结构变化必须体现在版本上：

- 结构变了（多字段、改说明以外的任何变化），版本却没变 → 失败；
- 破坏性变化（删掉契约、删字段、改字段类型、新增必填字段）而主版本没升 → 失败。

改了契约并按规则升了版本后，用 ``python -m movieclaw_sdk.surface --write`` 刷新快照一起提交。
"""

from __future__ import annotations

import json

from movieclaw_sdk.surface import SNAPSHOT, surface

HINT = (
    "改了开放契约：按规则升版本（破坏性变化升主版本），"
    "再运行 python -m movieclaw_sdk.surface --write"
)


def _props(schema: object) -> tuple[dict, set]:
    if not isinstance(schema, dict):
        return {}, set()
    return schema.get("properties") or {}, set(schema.get("required") or [])


def breaking(old: object, new: object) -> list[str]:
    """顶层结构里的破坏性变化：删字段、改字段、新增必填字段。"""
    old_props, old_required = _props(old)
    new_props, new_required = _props(new)
    if not old_props and not new_props:
        # 不是对象结构（如 tuple 结果）：任何变化都按破坏性处理
        return ["结构变了"] if old != new else []
    reasons: list[str] = []
    for name, spec in old_props.items():
        if name not in new_props:
            reasons.append(f"删除了字段 {name}")
        elif spec != new_props[name]:
            reasons.append(f"字段 {name} 的类型变了")
    for name in sorted(new_required - old_required):
        reasons.append(f"新增必填字段 {name}")
    return reasons


def test_open_contracts_match_the_snapshot() -> None:
    old = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    new = surface()
    problems: list[str] = []
    for name, before in old.items():
        after = new.get(name)
        if after is None:
            problems.append(f"{name}：开放契约被删除（破坏性变化，第三方插件会失效）")
            continue
        old_major, old_minor = map(int, before["version"].split("."))
        new_major, new_minor = map(int, after["version"].split("."))
        if (new_major, new_minor) < (old_major, old_minor):
            problems.append(f"{name}：版本不能回退（{before['version']} → {after['version']}）")
            continue
        shape_old = {k: v for k, v in before.items() if k not in ("doc", "version")}
        shape_new = {k: v for k, v in after.items() if k not in ("doc", "version")}
        if shape_old == shape_new:
            continue
        if before["version"] == after["version"]:
            problems.append(f"{name}：结构变了但版本还是 {after['version']}")
            continue
        reasons = [
            f"{part}：{reason}"
            for part in ("payload", "result", "item")
            for reason in breaking(before.get(part), after.get(part))
        ]
        if before.get("mode") != after.get("mode") or before.get("delivery") != after.get(
            "delivery"
        ):
            reasons.append("分发模式变了")
        if reasons and new_major == old_major:
            problems.append(f"{name}：破坏性变化须升主版本（{'；'.join(reasons)}）")
    assert not problems, "\n".join(problems) + f"\n{HINT}"
    # 新增的开放契约也要进快照（让表面始终是全量的、可审阅的）
    added = sorted(set(new) - set(old))
    assert not added, f"新增了开放契约 {added}，请刷新快照\n{HINT}"


def test_breaking_rules() -> None:
    old = {"properties": {"a": {"type": "integer"}, "b": {"type": "string"}}, "required": ["a"]}
    assert breaking(old, old) == []
    # 新增可选字段：不算破坏
    additive = {**old, "properties": {**old["properties"], "c": {"type": "string"}}}
    assert breaking(old, additive) == []
    assert breaking(old, {"properties": {"a": {"type": "integer"}}, "required": ["a"]}) == [
        "删除了字段 b"
    ]
    assert breaking(old, {**old, "properties": {**old["properties"], "a": {"type": "string"}}}) == [
        "字段 a 的类型变了"
    ]
    assert breaking(old, {**additive, "required": ["a", "c"]}) == ["新增必填字段 c"]


def test_changed_payload_without_a_version_bump_fails(monkeypatch) -> None:
    import copy

    from movieclaw_sdk import surface as module

    current = module.surface()
    changed = copy.deepcopy(current)
    payload = changed["subscription.candidates.filter"]["payload"]
    payload["properties"].pop("purpose")
    monkeypatch.setattr(module, "surface", lambda: changed)
    monkeypatch.setitem(globals(), "surface", lambda: changed)
    try:
        test_open_contracts_match_the_snapshot()
    except AssertionError as exc:
        assert "结构变了但版本还是 1.0" in str(exc)
    else:
        raise AssertionError("改了结构不升版本应当失败")
    # 升了次版本但删了字段：破坏性变化须升主版本
    changed["subscription.candidates.filter"]["version"] = "1.1"
    try:
        test_open_contracts_match_the_snapshot()
    except AssertionError as exc:
        assert "破坏性变化须升主版本" in str(exc) and "删除了字段 purpose" in str(exc)
    else:
        raise AssertionError("破坏性变化只升次版本应当失败")
    # 升了主版本：通过
    changed["subscription.candidates.filter"]["version"] = "2.0"
    test_open_contracts_match_the_snapshot()

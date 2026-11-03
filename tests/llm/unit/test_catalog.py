"""模型目录纯函数：投影、思考推导、按字段合并、资格与菜单规则（docs/design/llm-model-catalog.md）。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from movieclaw_llm.catalog import (
    DEFAULT_SHOWN,
    MAX_LISTED,
    build_catalog,
    default_shown,
    derive_thinking,
    listing_model_fields,
    match_catalog_id,
    project_catalog,
    public_model_fields,
    sanitize_listing,
    visible_ids,
)
from movieclaw_llm.models import ModelInfo, ProviderPreset
from movieclaw_llm.providers import list_presets

SNAPSHOT = Path(__file__).parents[3] / "src/movieclaw_llm/providers/catalog"


def _raw(**over) -> dict:
    base = {
        "name": "M",
        "tool_call": True,
        "reasoning": False,
        "release_date": "2026-01-01",
        "modalities": {"input": ["text"], "output": ["text"]},
        "limit": {"context": 128000, "output": 8192},
    }
    base.update(over)
    return base


def _preset(models: list[ModelInfo] | None = None, **over) -> ProviderPreset:
    return ProviderPreset(
        id="p", display_name="P", protocol="openai_chat", models=models or [], **over
    )


# -- 思考推导 -----------------------------------------------------------------


def test_effort_with_none_supports_off_without_off_body():
    control, budget = derive_thinking(
        [{"type": "effort", "values": ["none", "low", "medium", "high", "xhigh", "max"]}],
        ["effort"],
        None,
    )
    assert control.kind == "effort"
    assert control.levels == ["low", "medium", "high", "xhigh", "max"]
    assert control.supports_off and control.off_body is None and budget is None


def test_effort_plus_toggle_uses_provider_off_body():
    off = {"thinking": {"type": "disabled"}}
    control, _ = derive_thinking(
        [{"type": "toggle"}, {"type": "effort", "values": ["low", "high", "max"]}],
        ["effort", "toggle"],
        off,
    )
    assert control.levels == ["low", "high", "max"]
    assert control.supports_off and control.off_body == off


def test_effort_plus_toggle_without_off_body_has_no_off():
    """服务商没声明怎么关，就不发明关闭线协议。"""
    control, _ = derive_thinking(
        [{"type": "toggle"}, {"type": "effort", "values": ["high", "max"]}], ["effort"], None
    )
    assert not control.supports_off


def test_prefer_order_picks_budget_first():
    options = [
        {"type": "toggle"},
        {"type": "effort", "values": ["low", "medium", "xhigh"]},
        {"type": "budget_tokens", "min": 0, "max": 262144},
    ]
    control, budget = derive_thinking(options, ["budget_tokens", "effort", "toggle"], None)
    assert control.kind == "budget" and control.supports_off and budget == 262144
    assert ModelInfo(id="x", thinking_control=control, max_thinking_tokens=budget).thinking_levels


def test_toggle_only_and_nothing():
    control, _ = derive_thinking([{"type": "toggle"}], ["effort", "toggle"], None)
    assert control.kind == "toggle" and control.supports_off
    assert derive_thinking([], ["effort"], None) == (None, None)


# -- 字段转换 -----------------------------------------------------------------


def test_public_fields_mapping():
    fields = public_model_fields(
        _raw(
            reasoning=True,
            reasoning_options=[{"type": "effort", "values": ["low", "high"]}],
            interleaved={"field": "reasoning_content"},
            temperature=False,
            modalities={"input": ["text", "image", "pdf"], "output": ["text"]},
            limit={"context": 1000, "output": 100, "input": 900},
            status="deprecated",
            cost={"input": 0.5, "output": 2, "cache_read": 0},
            release_date="2026-10-17T00:00",
        ),
        ["effort"],
        None,
    )
    assert fields["context_window"] == 1000
    assert fields["max_output_tokens"] == 100 and fields["max_input_tokens"] == 900
    assert fields["supports_thinking"] and fields["fixed_sampling"]
    assert fields["modalities"] == ["text", "image"]
    assert fields["deprecated"] and fields["released"] == "2026-10-17"
    assert fields["cost"].input == 0.5 and fields["cost"].cache_read is None
    assert fields["thinking_control"].levels == ["low", "high"]


def test_public_fields_reasoning_false_has_no_menu_and_zero_cost_unknown():
    fields = public_model_fields(
        _raw(reasoning_options=[{"type": "toggle"}], cost={"input": 0, "output": 0}),
        ["toggle"],
        None,
    )
    assert "thinking_control" not in fields and "cost" not in fields
    assert "supports_thinking" not in fields  # 没有 interleaved 就不声明


def test_listing_fields_openrouter_shape():
    fields = listing_model_fields(
        {
            "id": "x/y",
            "name": "X: Y",
            "context_length": 1048576,
            "top_provider": {"max_completion_tokens": 131072},
            "architecture": {"input_modalities": ["text", "image"]},
            "pricing": {"prompt": "0.00000025", "completion": "0.000001"},
            "supported_parameters": ["max_tokens", "temperature"],
        }
    )
    assert fields["context_window"] == 1048576 and fields["max_output_tokens"] == 131072
    assert fields["modalities"] == ["text", "image"]
    assert fields["cost"].input == 0.25 and fields["cost"].output == 1.0
    assert fields["supports_tools"] is False
    assert fields["display_name"] == "X: Y"
    # 只有 id 的条目（绝大多数服务商）什么都不给，也不借用 name/created
    assert listing_model_fields({"id": "a", "created": 1, "name": "a"}) == {}


def test_sanitize_listing():
    entries = [{"id": "ok"}, {"id": "ok"}, {"id": "has space"}, {"id": ""}, {"id": 3}, "x"]
    entries.append({"id": "a" * 257})
    assert [e["id"] for e in sanitize_listing(entries)] == ["ok"]
    many = [{"id": f"m{i}"} for i in range(MAX_LISTED + 10)]
    assert len(sanitize_listing(many)) == MAX_LISTED


def test_project_catalog_keeps_only_needed_fields_and_rejects_bad_shapes():
    api = {
        "a": {"name": "A", "api": "https://a.example/v1", "models": {"m": {**_raw(), "x": 1}}},
        "b": {"name": "B", "models": {}},
    }
    projected = project_catalog(api, ["a", "missing"])
    assert set(projected) == {"a"}
    assert "x" not in projected["a"]["models"]["m"]
    with pytest.raises(ValueError):
        project_catalog({"a": {"models": []}}, ["a"])
    with pytest.raises(ValueError):
        project_catalog({"a": {"models": {"m": {"limit": [1]}}}}, ["a"])
    with pytest.raises(ValueError):
        project_catalog([], ["a"])


def test_match_catalog_id_normalizes_url():
    index = [{"id": "siliconflow-cn", "api": "https://api.siliconflow.cn/v1"}, {"id": "x"}]
    assert match_catalog_id("HTTPS://api.siliconflow.cn/v1/", index) == "siliconflow-cn"
    assert match_catalog_id("https://relay.example/v1", index) is None
    assert match_catalog_id(None, index) is None


# -- 合并与资格 ---------------------------------------------------------------


def test_layers_merge_by_field_and_custom_wins():
    preset = _preset(
        [ModelInfo(id="m", context_window=2000, thinking_control=None)],
        thinking_prefer=["toggle"],
    )
    public = {"m": _raw(reasoning=True, reasoning_options=[{"type": "toggle"}], name="Nice")}
    extras = [ModelInfo(id="m", max_output_tokens=50)]
    (entry,) = build_catalog(
        preset=preset, protocol="openai_chat", public_models=public, listing=None, extras=extras
    )
    model = entry.model
    assert model.context_window == 2000  # 预设显式覆盖公共目录
    assert model.thinking_control is None  # 预设显式写 null 也算覆盖
    assert model.max_output_tokens == 50  # 补录只覆盖自己写的字段
    assert model.display_name == "Nice"  # 其余字段仍来自公共目录
    assert model.sources == ["custom", "preset", "public"]


def test_eligibility_filters_non_chat_and_toolless_but_keeps_custom():
    public = {
        "emb": _raw(type="embedding"),
        "img": _raw(modalities={"input": ["text"], "output": ["image"]}),
        "notool": _raw(tool_call=False),
        "chat": _raw(),
        "mine": _raw(type="embedding"),
    }
    listing = [{"id": k} for k in public] + [{"id": "mystery"}]
    entries = build_catalog(
        preset=_preset(),
        protocol="openai_chat",
        public_models=public,
        listing=listing,
        extras=[ModelInfo(id="mine", context_window=1000)],
    )
    by_id = {e.id: e for e in entries}
    assert set(by_id) == {"chat", "mine", "mystery"}
    assert not by_id["mystery"].known  # 查不到参数：列出但参数未知
    assert by_id["mine"].custom


def test_responses_only_models_dropped_on_chat_protocol():
    preset = _preset([ModelInfo(id="r", context_window=1, requires_responses_for_tools=True)])
    kwargs = {"preset": preset, "public_models": {}, "listing": None, "extras": []}
    assert build_catalog(protocol="openai_chat", **kwargs) == []
    assert len(build_catalog(protocol="openai_responses", **kwargs)) == 1


def test_borrow_only_when_no_public_entry():
    calls = []

    def borrow(model_id):
        calls.append(model_id)
        return _raw() if model_id == "gpt-x" else None

    entries = build_catalog(
        preset=_preset(),
        protocol="openai_chat",
        public_models={},
        listing=[{"id": "gpt-x"}, {"id": "local"}],
        extras=[],
        borrow=borrow,
    )
    by_id = {e.id: e for e in entries}
    assert by_id["gpt-x"].known and by_id["gpt-x"].model.sources == ["borrowed"]
    assert not by_id["local"].known


# -- 菜单规则 -----------------------------------------------------------------


def _listed(n: int, start_day: int = 1) -> tuple[dict, list[dict]]:
    public = {f"m{i}": _raw(release_date=f"2026-01-{start_day + i:02d}") for i in range(n)}
    return public, [{"id": k} for k in public]


def test_without_preset_shows_newest_n():
    public, listing = _listed(DEFAULT_SHOWN + 5)
    public["m0"]["status"] = "deprecated"
    public["new"] = _raw(release_date="2026-12-01", status="deprecated")
    listing.append({"id": "new"})
    entries = build_catalog(
        preset=_preset(), protocol="openai_chat", public_models=public, listing=listing, extras=[]
    )
    assert entries[0].id == "new"  # 按发布日期新 → 旧排序
    shown = default_shown(entries)
    assert len(shown) == DEFAULT_SHOWN
    assert "new" not in shown and f"m{DEFAULT_SHOWN + 4}" in shown


def test_with_preset_only_newer_models_join():
    public, listing = _listed(5)  # m0..m4 发布于 01-01..01-05
    preset = _preset(
        [ModelInfo(id="m2", context_window=10), ModelInfo(id="gone", context_window=10)]
    )
    entries = build_catalog(
        preset=preset, protocol="openai_chat", public_models=public, listing=listing, extras=[]
    )
    assert [e.id for e in entries[:2]] == ["m2", "gone"]  # 预设按 yaml 顺序在前
    gone = next(e for e in entries if e.id == "gone")
    assert gone.listed is False
    # 比预设里最新的（m2，01-03）还新的才默认出现；「列表未包含」的预设模型照常显示
    # （各家列表是否列全未逐家实测，不拿它缩小升级前的菜单）
    assert default_shown(entries) == {"m2", "gone", "m3", "m4"}


def test_no_listing_keeps_all_preset_models():
    preset = _preset([ModelInfo(id=f"p{i}", context_window=1) for i in range(20)])
    entries = build_catalog(
        preset=preset, protocol="openai_chat", public_models={}, listing=None, extras=[]
    )
    assert all(e.listed is None for e in entries)
    assert len(default_shown(entries)) == 20  # 升级前菜单里的预设模型一个不少


def test_visibility_show_hide_and_pinned():
    public, listing = _listed(3)
    listing.append({"id": "unknown"})
    entries = build_catalog(
        preset=_preset(), protocol="openai_chat", public_models=public, listing=listing, extras=[]
    )
    visibility = {"show": ["unknown"], "hide": ["m2", "m1"]}
    shown = visible_ids(entries, visibility, pinned=["m1", "not-here"])
    # 参数未知的「显示」无效；隐藏生效；AI 设定引用的 m1 隐藏了也显示
    assert shown == {"m0", "m1"}


# -- 回归：预设模型的行为参数不受公共目录影响 ---------------------------------


def _bundled(catalog_id: str | None) -> dict:
    path = SNAPSHOT / f"{catalog_id}.json"
    if not catalog_id or not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))["models"]


#: 公共目录可以为预设模型补的字段：展示元数据，以及协议层不使用的 max_input_tokens
_METADATA = {"display_name", "released", "deprecated", "cost", "sources", "max_input_tokens"}


@pytest.mark.parametrize("preset", [p for p in list_presets() if p.models], ids=lambda p: p.id)
def test_preset_models_unchanged_by_public_catalog(preset):
    """预设 yaml 是 2026-10-13 人工核实的修正层：合并后行为参数必须与升级前一致。

    每周同步快照后若这里失败，说明公共目录给某个预设模型补了 yaml 没写的字段——
    在 yaml 里把该字段显式写出来（想表达「没有」就写 null）。
    """
    entries = {
        e.id: e
        for e in build_catalog(
            preset=preset,
            protocol=preset.protocol,
            public_models=_bundled(preset.catalog_id),
            listing=None,
            extras=[],
        )
    }
    for model in preset.models:
        merged = entries[model.id].model
        before = model.model_dump(exclude=_METADATA)
        after = merged.model_dump(exclude=_METADATA)
        assert after == before, model.id
        if model.max_input_tokens is not None:
            assert merged.max_input_tokens == model.max_input_tokens

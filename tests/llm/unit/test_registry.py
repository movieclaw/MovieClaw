"""预设注册表：yaml 加载与关键字段。"""

import pytest

from movieclaw_llm.exceptions import LlmRoutingError
from movieclaw_llm.providers import get_preset, list_presets


def test_builtin_presets_loaded():
    ids = {p.id for p in list_presets()}
    assert {"openai", "bailian", "deepseek", "kimi", "glm", "openai_compat"} <= ids


def test_official_channel_presets_have_fixed_endpoints():
    """官方直连渠道：端点固定（设置页据此隐藏端点输入框）、思考走 reasoning_content。"""
    expected = {
        "deepseek": "https://api.deepseek.com",
        "kimi": "https://api.moonshot.cn/v1",
        "glm": "https://open.bigmodel.cn/api/paas/v4",
    }
    for preset_id, base_url in expected.items():
        preset = get_preset(preset_id)
        assert preset.base_url == base_url
        assert preset.compat.thinking_field == "reasoning_content"
        assert not preset.requires_base_url
        assert preset.models, f"官方渠道「{preset_id}」的模型目录不应为空"


def test_bailian_preset_dialect():
    preset = get_preset("bailian")
    assert preset.protocol == "openai_chat"
    assert preset.base_url == "https://dashscope.aliyuncs.com/compatible-mode/v1"
    assert preset.compat.thinking_field == "reasoning_content"
    flagship = next(m for m in preset.models if m.id == "qwen3.8-max")
    assert flagship.supports_thinking
    assert flagship.max_thinking_tokens == 262144
    assert flagship.max_output_tokens == 131072
    # 3.8 代起旗舰原生多模态；上代 qwen3.7-max 仍在售（多处测试以它为默认模型）
    assert flagship.modalities == ["text", "image", "video"]
    assert any(m.id == "qwen3.7-max" for m in preset.models)


def test_preset_model_ids_are_unique_and_preserve_provider_namespace():
    """三方模型的斜杠属于上游模型 ID，不能删除命名空间或制造重复条目。"""
    for preset in list_presets():
        ids = [m.id for m in preset.models]
        assert len(ids) == len(set(ids))
        assert all(model_id and model_id.strip() == model_id for model_id in ids)
    assert any(m.id == "MiniMax/MiniMax-M3" for m in get_preset("bailian").models)


def test_unknown_preset_raises_chinese_error():
    with pytest.raises(LlmRoutingError, match="未知的供应商类型"):
        get_preset("nonexistent")


def test_openai_current_models_and_reasoning_capabilities():
    preset = get_preset("openai")
    assert preset.base_url == "https://api.openai.com/v1"
    models = {m.id: m for m in preset.models}
    for model_id in ("gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"):
        model = models[model_id]
        assert model.context_window == 1050000
        assert model.max_output_tokens == 128000
        assert model.modalities == ["text", "image"]
        assert "max" in model.thinking_levels
        assert ("off" in model.thinking_levels) == (model_id in {"gpt-6-sol", "gpt-6-luna"})
        assert model.requires_responses_for_tools == (model_id in {"gpt-6-astra", "gpt-6.1-sol"})
    assert {"gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"} <= models.keys()
    assert "max" in models["gpt-5.6-luna"].thinking_levels


def test_latest_provider_specs_keep_defaults_limits_and_channels_distinct():
    def model(provider, model_id):
        return next(m for m in get_preset(provider).models if m.id == model_id)

    qwen = model("bailian", "qwen3.8-max")
    assert (qwen.context_window, qwen.max_input_tokens, qwen.max_input_tokens_thinking) == (
        1000000,
        991808,
        983616,
    )
    omni = model("bailian", "qwen3.8-omni-flash")
    assert omni.modalities == ["text", "image", "audio", "video"]
    assert omni.thinking_levels == ["off", "low", "medium", "xhigh"]
    flash = model("deepseek", "deepseek-flash")
    assert flash.modalities == ["text", "image"]
    assert flash.max_output_tokens == 393216
    assert flash.thinking_levels == ["off", "low", "high", "max"]
    assert model("deepseek", "deepseek-v4-flash").modalities == flash.modalities
    assert model("glm", "glm-5.3-flashx").modalities == ["text", "image", "video"]
    kimi = model("kimi", "kimi-k3")
    assert kimi.max_output_tokens == 1048576
    assert kimi.default_output_tokens == 131072
    assert kimi.max_tokens_parameter == "max_completion_tokens"
    code = model("kimi", "kimi-k2.7-code")
    assert code.max_output_tokens is None
    assert code.default_output_tokens == 32768
    assert code.thinking_levels == []  # 官方不能关闭思考
    assert model("bailian", "kimi-k2.7-code").max_output_tokens == 16384
    assert model("bailian", "kimi-k2.6").max_thinking_tokens is None
    assert model("bailian", "kimi-k2.6").thinking_levels == ["off"]

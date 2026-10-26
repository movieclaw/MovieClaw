"""Localize LLM presentation at the API boundary without changing routing facts."""

from movieclaw_api.i18n import messages
from movieclaw_api.i18n.stored import reference
from movieclaw_llm.exceptions import LlmError
from movieclaw_llm.models import ProviderPreset


def preset_name(preset: ProviderPreset):
    key = f"settings.llm.preset.{'openaiCompat' if preset.id == 'openai_compat' else preset.id}"
    if messages("zh-Hans").get(key) == preset.display_name:
        return reference(key)
    return preset.display_name


def error_reference(error: LlmError):
    if not error.message_ref:
        return str(error)
    return {
        "message": str(error),
        **reference(error.message_ref["message_key"], **error.message_ref["params"]),
    }

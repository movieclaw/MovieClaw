"""Render stored message references without rewriting legacy Chinese history."""

from functools import lru_cache

from fastapi.encoders import jsonable_encoder

from movieclaw_api.i18n import messages, parse_message, t, use_locale
from movieclaw_api.i18n.metadata import localized_text


@lru_cache(maxsize=1)
def legacy_keys() -> dict[str, str]:
    candidates: dict[str, list[str]] = {}
    for key, source in messages("zh-Hans").items():
        if all(isinstance(node, str) for node in parse_message(source)):
            candidates.setdefault("".join(parse_message(source)), []).append(key)
    # Infer only when every candidate renders identically in all supported languages.
    english = messages("en")
    return {
        source: keys[0]
        for source, keys in candidates.items()
        if len({english.get(key, source) for key in keys}) == 1
    }


def stored_message(text: str, key: str | None = None, params: dict | None = None) -> str:
    key = key or legacy_keys().get(text)
    if not key or key not in messages("zh-Hans"):
        return text

    return t(key, **{name: render_value(value) for name, value in (params or {}).items()})


def reference(key: str, **params) -> dict:
    """A JSON-safe reference for a nested reason or label in stored parameters."""
    return {"message_key": key, "params": jsonable_encoder(params, custom_encoder={Exception: str})}


def render_value(value):
    if isinstance(value, dict) and "message_text" in value:
        return localized_text(value["message_text"], value.get("message_localized"))
    if isinstance(value, dict) and "message_key" in value:
        return stored_message(
            value.get("message", ""),
            value["message_key"],
            value.get("params", value.get("message_params")),
        )
    if isinstance(value, dict) and "message_list" in value:
        return t(value["separator_key"]).join(render_value(item) for item in value["message_list"])
    return value


def source_text(key: str, **params) -> str:
    """A message rendered in the source language (Chinese), for values stored or compared as text.

    Readers get their own language through ``stored_message`` at response time.
    """
    return stored_fields(key, **params)["message"]


def source_render(value) -> str:
    """Render a stored reference (or plain text) in the source language."""
    with use_locale("zh-Hans"):
        return render_value(value)


def stored_fields(key: str, **params) -> dict:
    """Keep a Chinese rollback value beside the reference in a JSON history field."""
    params = jsonable_encoder(params, custom_encoder={Exception: str})
    with use_locale("zh-Hans"):
        source = stored_message("", key, params)
    return {"message": source, "message_key": key, "message_params": params}


def keyed_error(cls: type[Exception], key: str, /, *args, **params) -> Exception:
    """An exception whose text is the Chinese source and that carries its catalog reference.

    ``exception_fields`` passes ``message_key``/``message_params`` on, so the HTTP error is
    rendered in the reader's language while logs and ``str()`` keep the source text.
    """
    fields = stored_fields(key, **params)
    error = cls(fields["message"], *args)
    error.message_key = key  # type: ignore[attr-defined]
    error.message_params = fields["message_params"]  # type: ignore[attr-defined]
    return error


def exception_reference(error: BaseException) -> dict | str:
    """An exception as a message parameter: its reference when keyed, else its own text."""
    key = getattr(error, "message_key", None)
    if key:
        params = getattr(error, "message_params", None) or getattr(error, "params", None) or {}
        return reference(key, **params)
    return getattr(error, "message", None) or str(error)


def reference_fields(ref: dict) -> dict:
    """``stored_fields`` for a reference built earlier with ``reference()``."""
    return stored_fields(ref["message_key"], **ref["params"])


def localize_fields(value):
    """Copy marked JSON history; never change a cached or ORM-owned dictionary."""
    if isinstance(value, list):
        return [localize_fields(item) for item in value]
    if not isinstance(value, dict):
        return value
    result = {name: localize_fields(child) for name, child in value.items()}
    for field in (
        "message", "label", "title", "reason", "source_desc", "error", "detail",
        "route_reason", "rule_set_reason", "warning",
    ):
        text = value.get(field)
        key = value.get(f"{field}_key")
        if isinstance(text, str) and (field == "message" or key):
            result[field] = stored_message(
                text,
                key,
                value.get(f"{field}_params", value.get("message_params", value.get("params"))),
            )
    # Domain summaries retain a legacy string list beside their marked messages.
    for field, references in (("errors", "error_messages"), ("reasons", "reason_messages")):
        if value.get(references):
            result[field] = [item["message"] for item in result[references]]
    return result

"""Locale-independent decision messages; the protocol layer renders them."""

from typing import Any

Text = str | dict[str, Any]


def reference(key: str, **params: Any) -> dict[str, Any]:
    return {"message_key": key, "params": params}

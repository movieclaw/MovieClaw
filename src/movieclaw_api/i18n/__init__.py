"""Request-local language selection and ICU messages; no process-global locale mutation."""

import json
import re
from contextlib import contextmanager
from contextvars import ContextVar
from functools import lru_cache
from pathlib import Path

from babel import Locale
from babel.numbers import format_decimal
from pyicumessageformat import Parser

from movieclaw_kernel.observe import current_locale as current_locale

current_timezone: ContextVar[str] = ContextVar("current_timezone", default="UTC")
LOCALES = Path(__file__).resolve().parents[1] / "locales"


def normalize_locale(value: str) -> str | None:
    if re.fullmatch(r"zh(?:-[a-z0-9]{1,8})*", value, re.I):
        return "zh-Hans"
    if re.fullmatch(r"en(?:-[a-z0-9]{1,8})*", value, re.I):
        return "en"
    return None


def negotiate(accept_language: str | None) -> str:
    # 不带语言头的是还没本地化的客户端（Android、桌面、鸿蒙、CLI、插件），保持原来的中文；
    # 带了头但都不支持（如 fr）才回落英文
    if not (accept_language or "").strip():
        return "zh-Hans"
    candidates = []
    for part in (accept_language or "").split(","):
        tag, *parameters = part.strip().split(";")
        quality = next((p.strip()[2:] for p in parameters if p.strip().startswith("q=")), "1")
        if not re.fullmatch(r"(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)", quality):
            continue
        q = float(quality)
        locale = normalize_locale(tag)
        if locale and 0 < q <= 1:
            candidates.append((q, locale))
    return max(candidates, key=lambda item: item[0])[1] if candidates else "en"


@contextmanager
def use_locale(locale: str, timezone: str | None = None):
    token = current_locale.set(normalize_locale(locale) or "en")
    timezone_token = current_timezone.set(timezone or current_timezone.get())
    try:
        yield
    finally:
        current_locale.reset(token)
        current_timezone.reset(timezone_token)


@lru_cache(maxsize=2)
def messages(locale: str) -> dict[str, str]:
    result = {}

    def flatten(value, prefix):
        if isinstance(value, str):
            result[prefix] = value
        else:
            for key, child in value.items():
                flatten(child, f"{prefix}.{key}")

    for path in (LOCALES / locale).glob("*.json"):
        flatten(json.loads(path.read_text()), path.stem)
    return result


@lru_cache(maxsize=4096)
def parse_message(message: str) -> list:
    return Parser().parse(message)


def render(message: str, locale: str, params: dict) -> str:
    """The supported ICU subset is arguments, number, plural and select (including nesting)."""
    babel_locale = Locale.parse(locale, sep="-")

    def visit(nodes, offsets):
        result = []
        for node in nodes:
            if isinstance(node, str):
                result.append(node)
                continue
            name = node["name"]
            value = params[name]
            kind = node.get("type")
            if kind in ("plural", "select"):
                options = node["options"]
                offset = node.get("offset", 0)
                selector = str(value) if kind == "select" else f"={value}"
                if kind == "plural" and selector not in options:
                    selector = babel_locale.plural_form(value - offset)
                result.append(
                    visit(
                        options.get(selector, options["other"]),
                        {**offsets, name: offset} if kind == "plural" else offsets,
                    )
                )
            elif kind == "number":
                if node.get("hash"):
                    value -= offsets.get(name, 0)
                result.append(format_decimal(value, format=node.get("format"), locale=babel_locale))
            elif kind is None:
                result.append(str(value))
            else:
                raise ValueError(f"Unsupported ICU argument type: {kind}")
        return "".join(result)

    return visit(parse_message(message), {})


def t(key: str, **params) -> str:
    locale = current_locale.get()
    source = messages("zh-Hans")
    message = messages(locale).get(key, source[key])
    return render(message, locale, params)

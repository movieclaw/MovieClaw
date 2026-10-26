"""Localized manifest annotations, resolved on a copy at the response boundary."""

from copy import deepcopy
from html import escape
from html.parser import HTMLParser
from typing import Any

from movieclaw_api.i18n import current_locale, normalize_locale


def localized_text(default: str, translations: Any) -> str:
    if not isinstance(translations, dict):
        return default
    locale = current_locale.get()
    candidates = [translations.get(locale)]
    candidates.extend(
        value for tag, value in translations.items() if normalize_locale(tag) == locale
    )
    for value in candidates:
        if isinstance(value, dict):
            value = value.get("value")
        elif hasattr(value, "value"):
            value = value.value
        if isinstance(value, str) and value.strip():
            return value
    return default


def localized_schema(schema: dict[str, Any]) -> dict[str, Any]:
    result = deepcopy(schema)

    def visit(node):
        if not isinstance(node, dict):
            return
        for field in ("title", "description"):
            if field in node or f"{field}_localized" in node:
                node[field] = localized_text(node.get(field, ""), node.get(f"{field}_localized"))
        for field in (
            "properties",
            "patternProperties",
            "$defs",
            "definitions",
            "dependentSchemas",
        ):
            children = node.get(field)
            if isinstance(children, dict):
                for child in children.values():
                    visit(child)
        for field in (
            "items",
            "additionalProperties",
            "additionalItems",
            "contains",
            "not",
            "if",
            "then",
            "else",
            "propertyNames",
            "unevaluatedProperties",
            "unevaluatedItems",
        ):
            child = node.get(field)
            if isinstance(child, list):
                for item in child:
                    visit(item)
            else:
                visit(child)
        for field in ("allOf", "anyOf", "oneOf", "prefixItems"):
            for child in node.get(field, []):
                visit(child)

    visit(result)
    return result


def localized_html(source: str) -> str:
    """Set the document language without rewriting scripts or other markup."""
    locale = current_locale.get()
    lines = source.splitlines(keepends=True)

    class Document(HTMLParser):
        html = None
        doctype_end = 0

        def absolute_offset(self):
            line, column = self.getpos()
            return sum(map(len, lines[: line - 1])) + column

        def handle_starttag(self, tag, attrs):
            if tag == "html" and self.html is None:
                start = self.absolute_offset()
                attributes = [(name, value) for name, value in attrs if name != "lang"]
                attributes.append(("lang", locale))
                markup = (
                    "<html"
                    + "".join(
                        f' {name}="{escape(value, quote=True)}"'
                        if value is not None
                        else f" {name}"
                        for name, value in attributes
                    )
                    + ">"
                )
                self.html = (start, start + len(self.get_starttag_text()), markup)

        def handle_decl(self, decl):
            if decl.lower().startswith("doctype"):
                self.doctype_end = self.absolute_offset() + len(decl) + 3

    document = Document()
    document.feed(source)
    if document.html is not None:
        start, end, markup = document.html
        return source[:start] + markup + source[end:]
    position = document.doctype_end
    return source[:position] + f'<html lang="{locale}">' + source[position:] + "</html>"

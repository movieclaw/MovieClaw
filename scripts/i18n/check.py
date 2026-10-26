"""Validate catalogs and the migration ratchet. Run from any directory with the dev environment."""

from __future__ import annotations

import ast
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

from pyicumessageformat import Parser

# The checker is also imported directly by its tests.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from apple_catalogs import check_apple  # noqa: E402
from metadata_sources import (  # noqa: E402
    check_builtin_sources,
    check_channel_sources,
    check_manifest_sources,
)
from swift_strings import literals as swift_literals  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HAN = re.compile(r"[\u3400-\u9fff]")


def flatten(value: dict, prefix: str = "") -> dict[str, str]:
    result = {}
    for key, child in value.items():
        name = f"{prefix}.{key}" if prefix else key
        if isinstance(child, dict):
            result.update(flatten(child, name))
        else:
            if not isinstance(child, str):
                raise ValueError(f"Non-string message: {name}")
            result[name] = child
    return result


def parameters(message: str) -> set[str]:
    def visit(nodes):
        result = set()
        for node in nodes:
            if isinstance(node, dict):
                result.add(node["name"])
                result.update(visit(node.get("contents", [])))
                for option in node.get("options", {}).values():
                    result.update(visit(option))
        return result

    try:
        return visit(Parser({"allow_tags": True}).parse(message))
    except SyntaxError:
        # Server messages render without rich-text tags, so "<placeholder>" is literal text there.
        return visit(Parser().parse(message))


def call_parameters(node: ast.Call) -> tuple[str, set[str]] | None:
    """Check explicit call arguments; dynamic **params remain runtime-validated."""
    name = getattr(node.func, "id", "")
    if name in {"t", "stored_fields", "reference", "source_text"} and node.args:
        key = node.args[0]
        if any(kw.arg is None for kw in node.keywords):
            return None
        names = {kw.arg for kw in node.keywords}
    elif name in {"keyed_error", "keyed"} and len(node.args) >= 2:
        # keyed_error(ExceptionClass, "key", *constructor_args, **params)
        key = node.args[1]
        if any(kw.arg is None for kw in node.keywords):
            return None
        names = {kw.arg for kw in node.keywords}
    else:
        key = next((kw.value for kw in node.keywords if kw.arg == "message_key"), None)
        params = next(
            (kw.value for kw in node.keywords if kw.arg in {"params", "message_params"}), None
        )
        if params is None:
            names = set()
        elif isinstance(params, ast.Dict) and all(
            isinstance(name, ast.Constant) and isinstance(name.value, str) for name in params.keys
        ):
            names = {name.value for name in params.keys}
        else:
            return None
    if isinstance(key, ast.Constant) and isinstance(key.value, str):
        return key.value, names
    return None


def check_catalogs() -> list[str]:
    errors = []
    all_english = {}
    web_source = {}
    server_source = {}
    web_english = {}
    web_parameters = {}
    terms_path = ROOT / "scripts/i18n/terms.json"
    terms = json.loads(terms_path.read_text()) if terms_path.exists() else {}
    for directory in (ROOT / "apps/web/locales", ROOT / "src/movieclaw_api/locales"):
        paths = list((directory / "zh-Hans").glob("*.json"))
        if {p.name for p in paths} != {p.name for p in (directory / "en").glob("*.json")}:
            errors.append(f"{directory}: namespace sets differ")
        for path in paths:
            source = flatten(json.loads(path.read_text()))
            english = flatten(json.loads((directory / "en" / path.name).read_text()))
            meta = json.loads((directory / "_meta" / path.name).read_text())
            if source.keys() != english.keys() or source.keys() != meta.keys():
                errors.append(f"{path}: message/metadata key sets differ")
            for key, text in source.items():
                name = f"{path.stem}.{key}"
                if not re.fullmatch(r"[a-z][a-zA-Z0-9]*(?:\.[a-z][a-zA-Z0-9]*){1,3}", name):
                    errors.append(f"Invalid semantic key: {name}")
                if meta.get(key, {}).get("sourceHash") != hashlib.sha256(text.encode()).hexdigest():
                    errors.append(f"Stale English: {name}")
                translated = english.get(key, "")
                allowed_terms = terms.get(name, terms.get(text))
                if allowed_terms is not None and translated.lower() not in allowed_terms:
                    errors.append(f"Glossary mismatch: {name}")
                if directory.parts[-2] == "web":
                    web_english[name] = translated
                if HAN.search(translated) or re.search(r"[，。！？：；「」《》、]", translated):
                    errors.append(f"English contains Chinese text/punctuation: {name}")
                try:
                    source_parameters = parameters(text)
                    if directory.parts[-2] == "web":
                        web_parameters[name] = source_parameters
                    if source_parameters != parameters(translated):
                        errors.append(f"Parameter mismatch: {name}")
                except (ValueError, SyntaxError) as exc:
                    errors.append(f"Invalid ICU: {name}: {exc}")
                if name in all_english and all_english[name] != translated:
                    errors.append(f"Cross-platform English mismatch: {name}")
                all_english[name] = translated
                (web_source if directory.parts[-2] == "web" else server_source)[name] = text
    errors.extend(check_builtin_sources(ROOT, server_source))
    errors.extend(check_manifest_sources(ROOT))
    errors.extend(check_channel_sources(ROOT))
    originals = json.loads((ROOT / "scripts/i18n/migrations.json").read_text())
    for key, original in originals.items():
        if web_source.get(key) != original:
            errors.append(f"Chinese changed during migration: {key}")
    server_originals = ROOT / "scripts/i18n/server-migrations.json"
    if server_originals.exists():
        for key, original in json.loads(server_originals.read_text()).items():
            if server_source.get(key) != original:
                errors.append(f"Server Chinese changed during migration: {key}")
    server_paths = [
        path
        for package in (
            "movieclaw_api",
            "movieclaw_playback",
            "movieclaw_jellyfin",
            "movieclaw_media",
            "movieclaw_matcher",
            "movieclaw_scheduler",
            "movieclaw_downloader",
            "movieclaw_tracker",
            "movieclaw_mcp",
        )
        for path in (ROOT / "src" / package).rglob("*.py")
    ]
    for name, message in server_source.items():
        # t(key, **params) takes the message key positionally: a "{key}" parameter can't be passed.
        if "key" in parameters(message):
            errors.append(f"{name}: rename the {{key}} parameter (it collides with t(key, ...))")
    for path in server_paths:
        for node in ast.walk(ast.parse(path.read_text())):
            keys = []
            fields = {"message_key", "title_key", "description_key", "label_key", "separator_key"}
            if isinstance(node, ast.Call):
                arguments = call_parameters(node)
                if arguments and arguments[0] in server_source:
                    name, supplied = arguments
                    for locale, catalog in (("zh-Hans", server_source), ("en", all_english)):
                        expected = parameters(catalog[name])
                        for keyword in node.keywords:
                            if (
                                keyword.arg in {"title_key", "label_key"}
                                and isinstance(keyword.value, ast.Constant)
                                and keyword.value.value in catalog
                            ):
                                expected |= parameters(catalog[keyword.value.value])
                        if supplied != expected:
                            errors.append(
                                f"{path.relative_to(ROOT)}:{node.lineno}: "
                                f"{locale} call parameters differ: {name}"
                            )
                if (
                    isinstance(node.func, ast.Name)
                    and node.func.id in {"t", "stored_fields", "reference"}
                    and node.args
                ):
                    keys.append(node.args[0])
                keys.extend(kw.value for kw in node.keywords if kw.arg in fields)
                if getattr(node.func, "id", "") in {"Rule", "Aggregator"}:
                    keys.extend(
                        kw.value
                        for kw in node.keywords
                        if kw.arg in {"title", "description", "group"}
                        and isinstance(kw.value, ast.Constant)
                        and str(kw.value.value).startswith("notify.")
                    )
            elif isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Attribute) and target.attr == "extent_key"
                for target in node.targets
            ):
                keys.extend(
                    value
                    for value in ast.walk(node.value)
                    if isinstance(value, ast.Constant) and isinstance(value.value, str)
                )
            elif isinstance(node, ast.Dict):
                keys.extend(
                    value
                    for name, value in zip(node.keys, node.values, strict=True)
                    if isinstance(name, ast.Constant) and name.value in fields
                )
            for key in keys:
                if (
                    isinstance(key, ast.Constant)
                    and isinstance(key.value, str)
                    and key.value not in server_source
                ):
                    errors.append(f"{path.relative_to(ROOT)}: unknown key {key.value}")
    apple_originals = ROOT / "scripts/i18n/apple-migrations.json"
    if apple_originals.exists():
        catalogs = {}
        for identifier, original in json.loads(apple_originals.read_text()).items():
            path, key = (
                identifier.split(":", 1)
                if ":" in identifier
                else ("Shared/Localizable.xcstrings", identifier)
            )
            if path not in catalogs:
                catalogs[path] = json.loads((ROOT / "apps/apple" / path).read_text())
            catalog = catalogs[path]
            value = catalog["strings"].get(key, {}).get("localizations", {}).get("zh-Hans", {})
            if value.get("stringUnit", {}).get("value") != original:
                errors.append(f"Apple Chinese changed during migration: {key}")
    errors.extend(check_apple(ROOT, web_english, web_parameters, terms))
    return errors


def unused_keys() -> list[str]:
    """Conservative hints only: dynamic keys and generated/system consumers need review."""
    warnings = []
    for base, resources, extension in (
        (ROOT / "apps/web", "locales/zh-Hans", ".tsx"),
        (ROOT / "src/movieclaw_api", "locales/zh-Hans", ".py"),
    ):
        directories = [base / part for part in ("app", "components", "lib", "themes", "theme-sdk")]
        if extension == ".tsx":
            directories.append(ROOT / "plugins/netflix/src")
        paths = (
            [
                p
                for directory in directories
                for p in directory.rglob("*")
                if p.suffix in {".ts", extension}
            ]
            if extension == ".tsx"
            else list(base.rglob("*.py"))
        )
        if base.name == "movieclaw_api":
            paths += [
                path
                for package in (
                    "movieclaw_playback",
                    "movieclaw_jellyfin",
                    "movieclaw_media",
                    "movieclaw_matcher",
                    "movieclaw_scheduler",
                    "movieclaw_downloader",
                    "movieclaw_tracker",
                    "movieclaw_mcp",
                )
                for path in (ROOT / "src" / package).rglob("*.py")
            ]
        source = "\n".join(path.read_text() for path in paths)
        # Index quoted references once instead of rescanning every source file for every key.
        references = set(re.findall(r"(?=[\"']([^\"'\n]*)[\"'])", source))
        for catalog in (base / resources).glob("*.json"):
            for key in flatten(json.loads(catalog.read_text())):
                name = f"{catalog.stem}.{key}"
                # Translation functions can be scoped to any namespace depth.
                suffixes = [
                    ".".join(name.split(".")[index:]) for index in range(len(name.split(".")))
                ]
                if not any(suffix in references for suffix in suffixes):
                    warnings.append(f"Possibly unused key: {base.relative_to(ROOT)}:{name}")
    base = ROOT / "apps/apple"
    source = "\n".join(
        path.read_text()
        for path in base.rglob("*.swift")
        if not any(
            part.endswith("Tests") or part in {".build", "DerivedData", "SourcePackages"}
            for part in path.parts
        )
    )
    for catalog in base.glob("*/Localizable.xcstrings"):
        for key in json.loads(catalog.read_text())["strings"]:
            pieces = key.split(".")
            symbol = pieces[0] + "".join(piece[0].upper() + piece[1:] for piece in pieces[1:])
            if f".{symbol}" not in source and f'"{key}"' not in source:
                warnings.append(f"Possibly unused key: {catalog.relative_to(ROOT)}:{key}")
    return warnings


API_DOC_CALLS = {
    "Field",
    "Query",
    "Path",
    "Body",
    "Header",
    "Form",
    "File",
    "Cookie",
    "APIRouter",
    "FastAPI",
}
ROUTE_METHODS = {
    "get",
    "post",
    "put",
    "patch",
    "delete",
    "head",
    "options",
    "api_route",
    "websocket",
}
API_DOC_ARGUMENTS = {"description", "summary", "examples", "response_description"}


def api_doc_nodes(tree: ast.AST) -> set[int]:
    """OpenAPI documentation (schema field and route descriptions) is developer- and model-facing.

    It feeds the API docs and the generated agent tool catalog, which stay in the source language
    (docs/design/i18n.md §8.4), so it is not counted as untranslated interface text.
    """
    found: set[int] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = (
            func.id
            if isinstance(func, ast.Name)
            else func.attr
            if isinstance(func, ast.Attribute)
            else ""
        )
        if name not in API_DOC_CALLS and not (
            isinstance(func, ast.Attribute) and name in ROUTE_METHODS
        ):
            continue
        for keyword in node.keywords:
            if keyword.arg in API_DOC_ARGUMENTS:
                found.update(id(child) for child in ast.walk(keyword.value))
    return found


def keyed_fallback_nodes(tree: ast.AST) -> set[int]:
    """Chinese fallback text passed beside its catalog key (`title=` with `title_key=`,
    a message with `message_key=`) is the rollback copy of a migrated message."""
    found: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Dict):
            # The same pairing in a dict literal: {"label": "重试", "label_key": "..."}.
            # A reference beside the text ("label_ref", "_title_ref") is the same pairing.
            keys = {key.value for key in node.keys if isinstance(key, ast.Constant)}
            for key, value in zip(node.keys, node.values, strict=True):
                if isinstance(key, ast.Constant) and keys & {
                    f"{key.value}_key",
                    f"{key.value}_ref",
                    f"_{key.value}_ref",
                }:
                    found.update(id(child) for child in ast.walk(value))
            continue
        if not isinstance(node, ast.Call):
            continue
        names = {keyword.arg for keyword in node.keywords if keyword.arg}
        for keyword in node.keywords:
            if keyword.arg and f"{keyword.arg}_key" in names:
                found.update(id(child) for child in ast.walk(keyword.value))
        if "message_key" in names and node.args:
            found.update(id(child) for child in ast.walk(node.args[0]))
    return found


REGEX_FUNCTIONS = {
    "compile",
    "search",
    "match",
    "fullmatch",
    "sub",
    "subn",
    "findall",
    "finditer",
    "split",
}
LOG_NAMES = {"logger", "logging", "log", "_logger", "_log"}


def excluded_nodes(tree: ast.AST) -> set[int]:
    """String constants that are not interface text: docstrings and bare string statements,
    log calls, regex patterns (parsing data), OpenAPI documentation, setting-domain and built-in
    plugin titles, and keyed fallbacks."""
    found = api_doc_nodes(tree) | keyed_fallback_nodes(tree)
    for node in ast.walk(tree):
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
            found.add(id(node.value))
        # A setting domain's title only labels the descriptor in code; no view renders it. A
        # built-in plugin's declared title is its identity: views render plugins.builtins.*
        # (BUILTIN_MESSAGE_KEYS, guarded by test_i18n_builtin_metadata)
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id
            in (
                "register_setting",
                "plugin",
            )
        ):
            for keyword in node.keywords:
                if keyword.arg == "title":
                    found.add(id(keyword.value))
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        owner = node.func.value
        if isinstance(owner, ast.Name) and owner.id.lower() in LOG_NAMES:
            found.update(id(child) for child in ast.walk(node))
        if (
            isinstance(owner, ast.Name)
            and owner.id == "re"
            and node.func.attr in REGEX_FUNCTIONS
            and node.args
        ):
            found.update(id(child) for child in ast.walk(node.args[0]))
    return found


def baseline() -> dict[str, int]:
    counts = json.loads(
        subprocess.check_output(["node", str(ROOT / "scripts/i18n/web-baseline.mjs")])
    )
    for path in (ROOT / "src/movieclaw_api").rglob("*.py"):
        tree = ast.parse(path.read_text())
        docstrings = excluded_nodes(tree)
        lines = path.read_text().splitlines()
        count = sum(
            1
            for node in ast.walk(tree)
            if isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and id(node) not in docstrings
            and HAN.search(node.value)
            and not any(
                "i18n-ignore" in line for line in lines[max(0, node.lineno - 2) : node.lineno]
            )
        )
        if count:
            counts[str(path.relative_to(ROOT))] = count
    for path in (ROOT / "apps/apple").rglob("*.swift"):
        if any(part in path.parts for part in (".build", "DerivedData", "SourcePackages")) or any(
            part.endswith("Tests") for part in path.parts
        ):
            continue
        source = path.read_text()
        count = 0
        for literal in swift_literals(source):
            line_start = source.rfind("\n", 0, literal.start) + 1
            previous_start = source.rfind("\n", 0, max(0, line_start - 1)) + 1
            line_end = source.find("\n", literal.end)
            if (
                HAN.search(literal.text)
                and "i18n-ignore"
                not in source[previous_start : line_end if line_end >= 0 else None]
            ):
                count += 1
        if count:
            counts[str(path.relative_to(ROOT))] = count
    return dict(sorted(counts.items()))


def main() -> int:
    errors = check_catalogs()
    current = baseline()
    baseline_path = ROOT / "scripts/i18n/baseline.json"
    if "--write-baseline" in sys.argv:
        baseline_path.write_text(json.dumps(current, ensure_ascii=False, indent=2) + "\n")
    else:
        previous = json.loads(baseline_path.read_text())
        for path, count in current.items():
            if count > previous.get(path, 0):
                errors.append(f"Bare Chinese increased: {path}: {previous.get(path, 0)} -> {count}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    for warning in unused_keys():
        print(warning, file=sys.stderr)
    print("i18n catalogs, Chinese preservation and ratchet passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

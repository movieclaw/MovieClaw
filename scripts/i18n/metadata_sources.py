"""Validate declared translation provenance against application-owned metadata sources."""

from __future__ import annotations

import ast
import hashlib
import json
import re
import tomllib
from pathlib import Path

HAN = re.compile(r"[\u3400-\u9fff，。！？：；「」《》、]")

# Distributables that must still install on older hosts, whose strict manifest model rejects
# `*_localized` (see the host-contract baseline job in .github/workflows/watch-presence.yml).
OLDER_HOST_PACKAGES = {"plugins/watch-presence/movieclaw-plugin.toml"}


def check_manifest_sources(root: Path) -> list[str]:
    owners = {}
    for directory in (root / "plugins", root / "src/movieclaw_plugins"):
        for path in sorted(directory.glob("*/movieclaw-plugin.toml")):
            document = tomllib.loads(path.read_text())
            # Source packages take precedence over their generated bundled copies.
            owners.setdefault(document["plugin"]["id"], (path, document))
    if not owners:
        return []
    ledger_path = root / "scripts/i18n/plugin-metadata.json"
    if not ledger_path.exists():
        return [f"Missing plugin metadata provenance: {ledger_path}"]
    ledger = json.loads(ledger_path.read_text())
    errors = []
    for path, document in owners.values():
        source_file = str(path.relative_to(root))
        for namespace, fields in (
            ("plugin", ("title", "description")),
            ("theme", ("label", "description")),
        ):
            metadata = document.get(namespace, {})
            for field in fields:
                source = metadata.get(field, "")
                translated = metadata.get(field + "_localized", {}).get("en")
                if isinstance(translated, dict):
                    translated = translated.get("value")
                name = f"{source_file}:{namespace}.{field}"
                if translated is None:
                    if HAN.search(source) and source_file not in OLDER_HOST_PACKAGES:
                        errors.append(f"Missing English plugin metadata: {name}")
                    continue
                if (
                    not isinstance(translated, str)
                    or not translated.strip()
                    or HAN.search(translated)
                ):
                    errors.append(f"Invalid English plugin metadata: {name}")
                expected = (
                    ledger.get(source_file, {}).get(f"{namespace}.{field}", {}).get("sourceHash")
                )
                if expected != hashlib.sha256(source.encode()).hexdigest():
                    errors.append(f"Stale English plugin metadata: {name}")
    return errors


def check_builtin_sources(root: Path, catalog: dict[str, str]) -> list[str]:
    manifest_path = root / "src/movieclaw_api/plugins/manifest.py"
    if not manifest_path.exists():
        return []
    ledger_path = root / "scripts/i18n/builtin-sources.json"
    if not ledger_path.exists():
        return [f"Missing built-in metadata provenance: {ledger_path}"]
    records = json.loads(ledger_path.read_text())
    tree = ast.parse(manifest_path.read_text())
    groups = ast.literal_eval(
        next(
            node.value
            for node in tree.body
            if isinstance(node, ast.AnnAssign)
            and isinstance(node.target, ast.Name)
            and node.target.id == "BUILTIN_GROUPS"
        )
    )
    presentation = ast.parse((root / "src/movieclaw_api/plugins/presentation.py").read_text())
    group_keys = ast.literal_eval(
        next(
            node.value
            for node in presentation.body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "GROUP_MESSAGE_KEYS"
                for target in node.targets
            )
        )
    )
    errors = []
    if len(groups) != len(group_keys):
        errors.append("Built-in group metadata does not match the manifest")
    for (label, _), key in zip(groups, group_keys, strict=False):
        if catalog.get(key) != label:
            errors.append(f"Built-in group metadata source changed: {key}")
    declaration = next(
        node
        for node in tree.body
        if isinstance(node, ast.AnnAssign)
        and isinstance(node.target, ast.Name)
        and node.target.id == "BUILTIN_MANIFEST"
    )
    generator = next(
        node for node in ast.walk(declaration.value) if isinstance(node, ast.GeneratorExp)
    )
    declared = {ast.unparse(node) for node in generator.generators[0].iter.elts}
    if declared != {row["manifest_ref"] for row in records.values() if "manifest_ref" in row}:
        errors.append("Built-in metadata declarations do not match the manifest")
    modules = {}
    for entry_id, record in records.items():
        path = root / record["path"]
        if path not in modules:
            modules[path] = ast.parse(path.read_text())
        function = next(
            node
            for node in modules[path].body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name == record["function"]
        )
        decorator = next(
            node
            for node in function.decorator_list
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "plugin"
        )
        if ast.literal_eval(decorator.args[0]) != entry_id:
            errors.append(f"Built-in metadata source ID changed: {entry_id}")
        title = (
            next(
                (ast.literal_eval(kw.value) for kw in decorator.keywords if kw.arg == "title"),
                entry_id,
            )
            or entry_id
        )
        doc = ast.get_docstring(function) or ""
        description = " ".join(
            line.strip() for line in doc.split("\n\n", 1)[0].splitlines()
        ).strip()
        for field, source in (("title", title), ("description", description)):
            if catalog.get(record[field]) != source:
                errors.append(f"Built-in metadata source changed: {entry_id}.{field}")
    for path, module in modules.items():
        covered = {row["function"] for row in records.values() if root / row["path"] == path}
        for node in ast.walk(module):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "ctx"
                and node.func.attr == "plugin"
                and node.args
                and isinstance(node.args[0], ast.Name)
                and node.args[0].id not in covered
            ):
                errors.append(f"Missing built-in child metadata: {node.args[0].id}")
    return errors


def channel_texts(path: Path):
    """Read owned driver annotations and the WeChat state catalog without imports."""
    tree = ast.parse(path.read_text())

    def literal(node):
        if isinstance(node, ast.IfExp):
            node = node.body
        if isinstance(node, ast.JoinedStr):
            return "".join(
                value.value
                if isinstance(value, ast.Constant)
                else "{" + ast.unparse(value.value) + "}"
                for value in node.values
            )
        if isinstance(node, ast.Dict):
            return {
                literal(key): literal(value)
                for key, value in zip(node.keys, node.values, strict=True)
            }
        try:
            return ast.literal_eval(node)
        except (ValueError, TypeError):
            return None

    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            values = {}
            for child in node.body:
                if isinstance(child, ast.Assign) and isinstance(child.targets[0], ast.Name):
                    values[child.targets[0].id] = literal(child.value)
            for name in ("title", "description"):
                if name in values:
                    yield f"{node.name}.{name}", values[name], values.get(name + "_localized")
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "_BINDING_MESSAGES"
            for target in node.targets
        ):
            for key, (source, english) in literal(node.value).items():
                yield f"messages.{key}", source, {"en": english}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = ast.unparse(node.func)
        if name not in (
            "Binding.form",
            "Binding.flow",
            "FormField",
            "FlowState",
            "ChannelInputError",
        ):
            continue
        values = {keyword.arg: literal(keyword.value) for keyword in node.keywords}
        if name == "ChannelInputError":
            source = literal(node.args[0]) if node.args else None
            if isinstance(source, str):
                yield (
                    "inputError." + hashlib.sha256(source.encode()).hexdigest()[:12],
                    source,
                    values.get("message_localized"),
                )
            continue
        if name == "FormField":
            values.setdefault("label", literal(node.args[1]) if len(node.args) > 1 else None)
            prefix = f"field.{literal(node.args[0])}" if node.args else "field"
        elif name == "FlowState":
            prefix = f"flow.{values.get('status') or 'snapshot'}"
        else:
            prefix = "binding"
        for field in ("label", "help", "placeholder", "hint", "message", "input_label"):
            if isinstance(values.get(field), str):
                yield f"{prefix}.{field}", values[field], values.get(field + "_localized")


def check_channel_sources(root: Path) -> list[str]:
    paths = sorted((root / "src/movieclaw_plugins").glob("*/*_channel/driver.py"))
    if not paths:
        return []
    ledger_path = root / "scripts/i18n/channel-metadata.json"
    if not ledger_path.exists():
        return [f"Missing channel metadata provenance: {ledger_path}"]
    ledger = json.loads(ledger_path.read_text())
    errors = []
    for path in sorted({source for driver in paths for source in driver.parent.glob("*.py")}):
        relative = str(path.relative_to(root))
        for name, source, translations in channel_texts(path):
            if not isinstance(source, str) or (not HAN.search(source) and not translations):
                continue
            english = translations.get("en") if isinstance(translations, dict) else None
            if isinstance(english, dict):
                english = english.get("value")
            if not isinstance(english, str) or not english.strip() or HAN.search(english):
                errors.append(f"Missing or invalid English channel metadata: {relative}:{name}")
            elif name.startswith("inputError.") and set(re.findall(r"\{[^{}]+\}", source)) != set(
                re.findall(r"\{[^{}]+\}", english)
            ):
                errors.append(f"Channel error placeholders differ: {relative}:{name}")
            expected = ledger.get(relative, {}).get(name, {}).get("sourceHash")
            if expected != hashlib.sha256(source.encode()).hexdigest():
                errors.append(f"Stale English channel metadata: {relative}:{name}")
    return errors

"""Detect changes to owned translation sources without importing application modules."""

import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "metadata_source_checks", ROOT / "scripts/i18n/metadata_sources.py"
)
checks = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checks)


def test_manifest_source_changes_and_missing_english_are_reported(tmp_path):
    path = tmp_path / "plugins/example/movieclaw-plugin.toml"
    path.parent.mkdir(parents=True)
    path.write_text('[plugin]\nid="example"\ntitle="示例"\ntitle_localized={en="Example"}\n')
    ledger = tmp_path / "scripts/i18n/plugin-metadata.json"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        json.dumps(
            {
                str(path.relative_to(tmp_path)): {
                    "plugin.title": {"sourceHash": hashlib.sha256("示例".encode()).hexdigest()}
                }
            }
        )
    )
    assert checks.check_manifest_sources(tmp_path) == []
    path.write_text(path.read_text().replace('title="示例"', 'title="新示例"'))
    assert any("Stale English" in error for error in checks.check_manifest_sources(tmp_path))
    path.write_text('[plugin]\nid="example"\ntitle="示例"\n')
    assert any("Missing English" in error for error in checks.check_manifest_sources(tmp_path))


def test_canonical_source_owns_provenance_for_generated_bundled_copy(tmp_path):
    source = tmp_path / "plugins/example/movieclaw-plugin.toml"
    source.parent.mkdir(parents=True)
    source.write_text('[plugin]\nid="example"\ntitle="Example"\n')
    generated = tmp_path / "src/movieclaw_plugins/example/movieclaw-plugin.toml"
    generated.parent.mkdir(parents=True)
    generated.write_text(source.read_text())
    ledger = tmp_path / "scripts/i18n/plugin-metadata.json"
    ledger.parent.mkdir(parents=True)
    ledger.write_text("{}")
    assert checks.check_manifest_sources(tmp_path) == []


def test_builtin_code_and_manifest_changes_require_translation_review(tmp_path):
    folder = tmp_path / "src/movieclaw_api/plugins"
    folder.mkdir(parents=True)
    manifest = folder / "manifest.py"
    manifest.write_text(
        'BUILTIN_GROUPS: tuple = (("基础", ("core.",)),)\n'
        "BUILTIN_MANIFEST: tuple = tuple(Entry(p.name,p) for p in (core.database,))\n"
    )
    source = folder / "core.py"
    source.write_text(
        '@plugin("core.database",title="数据库")\n'
        'async def database(ctx):\n    """原始说明。"""\n    pass\n'
    )
    (folder / "presentation.py").write_text('GROUP_MESSAGE_KEYS=("plugins.groups.core",)\n')
    ledger = tmp_path / "scripts/i18n/builtin-sources.json"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        json.dumps(
            {
                "core.database": {
                    "path": "src/movieclaw_api/plugins/core.py",
                    "function": "database",
                    "manifest_ref": "core.database",
                    "title": "plugins.builtins.databaseTitle",
                    "description": "plugins.builtins.databaseDescription",
                }
            }
        )
    )
    catalog = {
        "plugins.builtins.databaseTitle": "数据库",
        "plugins.builtins.databaseDescription": "原始说明。",
        "plugins.groups.core": "基础",
    }
    assert checks.check_builtin_sources(tmp_path, catalog) == []
    source.write_text(source.read_text().replace("    pass", "    ctx.plugin(startup_check)"))
    assert any(
        "Missing built-in child" in error
        for error in checks.check_builtin_sources(tmp_path, catalog)
    )
    source.write_text(source.read_text().replace("    ctx.plugin(startup_check)", "    pass"))
    source.write_text(source.read_text().replace("原始说明", "已改变的说明"))
    assert any(
        "source changed" in error for error in checks.check_builtin_sources(tmp_path, catalog)
    )
    manifest.write_text(
        manifest.read_text().replace("(core.database,)", "(core.database,core.new,)")
    )
    assert any("declarations" in error for error in checks.check_builtin_sources(tmp_path, catalog))


def test_owned_channel_sources_detect_stale_fields_and_missing_translations(tmp_path):
    source = tmp_path / "src/movieclaw_plugins/example/example_channel/driver.py"
    source.parent.mkdir(parents=True)
    source.write_text(
        'class Driver:\n    title="作者名称"\n    title_localized={"en":"Author title"}\n'
        '    binding=Binding.form((FormField("token","令牌",label_localized={"en":"Token"}),),'
        'hint="作者提示",hint_localized={"en":"Author hint"})\n'
    )
    ledger = tmp_path / "scripts/i18n/channel-metadata.json"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        json.dumps(
            {
                str(source.relative_to(tmp_path)): {
                    key: {"sourceHash": hashlib.sha256(text.encode()).hexdigest()}
                    for key, text, _ in checks.channel_texts(source)
                }
            }
        )
    )
    assert checks.check_channel_sources(tmp_path) == []
    source.write_text(source.read_text().replace("作者提示", "更新提示"))
    assert any("Stale English" in error for error in checks.check_channel_sources(tmp_path))
    source.write_text(source.read_text().replace(',label_localized={"en":"Token"}', ""))
    assert any(
        "Missing or invalid English" in error for error in checks.check_channel_sources(tmp_path)
    )


def test_owned_channel_state_catalog_and_input_errors_have_provenance(tmp_path):
    folder = tmp_path / "src/movieclaw_plugins/example/example_channel"
    folder.mkdir(parents=True)
    (folder / "driver.py").write_text('class Driver:\n    title="Example"\n')
    source = folder / "binding.py"
    source.write_text(
        '_BINDING_MESSAGES={"scan":("扫码","Scan the code")}\n'
        'raise ChannelInputError(f"原原因：{exc}",message_localized={"en":f"Reason: {exc}"})\n'
    )
    ledger = tmp_path / "scripts/i18n/channel-metadata.json"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        json.dumps(
            {
                str(source.relative_to(tmp_path)): {
                    key: {"sourceHash": hashlib.sha256(text.encode()).hexdigest()}
                    for key, text, _ in checks.channel_texts(source)
                }
            }
        )
    )
    assert checks.check_channel_sources(tmp_path) == []
    source.write_text(source.read_text().replace('"扫码"', '"重新扫码"'))
    assert any("Stale English" in error for error in checks.check_channel_sources(tmp_path))
    before = source.read_text()
    source.write_text(before.replace('f"Reason: {exc}"', '"Reason"'))
    assert any("placeholders differ" in error for error in checks.check_channel_sources(tmp_path))
    source.write_text(before.replace('f"Reason: {exc}"', 'f"原原因: {exc}"'))
    assert any(
        "Missing or invalid English" in error for error in checks.check_channel_sources(tmp_path)
    )

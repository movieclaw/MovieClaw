"""Reproduce the Apple P0 checks using a real compiled app bundle on macOS."""

from __future__ import annotations

import copy
import importlib.util
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("xcrun") is None
    or subprocess.run(["xcrun", "--find", "xcstringstool"], capture_output=True).returncode != 0,
    reason="Requires Xcode's xcstringstool",
)


@pytest.mark.parametrize("traditional_alias", [False, True])
def test_generated_symbols_and_bundle_language(tmp_path, traditional_alias):
    fixture = Path(__file__).with_name("apple") / "Localizable.xcstrings"
    script = Path(__file__).resolve().parents[2] / "apps/apple/scripts/prepare-project.py"
    spec = importlib.util.spec_from_file_location("prepare_project", script)
    prepare = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prepare)
    source_catalog = tmp_path / "Shared/Localizable.xcstrings"
    source_catalog.parent.mkdir()
    source = json.loads(fixture.read_text())
    fallback = copy.deepcopy(source["strings"]["common.close"])
    del fallback["localizations"]["de"]
    source["strings"]["common.fallback"] = fallback
    if traditional_alias:
        for entry in source["strings"].values():
            entry["localizations"]["zh-Hant"] = entry["localizations"]["zh-Hans"]
    source_catalog.write_text(json.dumps(source, ensure_ascii=False))
    prepare.stage_catalogs(tmp_path)
    catalog = tmp_path / "build/LocalizedCatalogs/Shared/Localizable.xcstrings"
    generated = tmp_path / "generated"
    generated.mkdir()
    resources = tmp_path / "Probe.app/Contents/Resources"
    resources.mkdir(parents=True)
    binary = tmp_path / "Probe.app/Contents/MacOS/probe"
    binary.parent.mkdir()
    info = {
        "CFBundleIdentifier": "io.movieclaw.i18n-probe",
        "CFBundleExecutable": "probe",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": ["zh-Hans", "en", "de"]
        + (["zh-Hant"] if traditional_alias else []),
    }
    (resources.parent / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(
        [
            "xcrun",
            "xcstringstool",
            "generate-symbols",
            str(catalog),
            "--output-directory",
            str(generated),
            "--language",
            "swift",
        ],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [
            "xcrun",
            "xcstringstool",
            "compile",
            str(catalog),
            "--output-directory",
            str(resources),
        ],
        check=True,
        capture_output=True,
    )
    main = tmp_path / "main.swift"
    main.write_text("""import Foundation
let output = [Bundle.main.preferredLocalizations.first ?? "",
              String(localized: .commonClose),
              String(localized: .libraryScanProgress(3)),
              String(localized: .commonFallback)]
print(String(data: try! JSONEncoder().encode(output), encoding: .utf8)!)
""")
    subprocess.run(
        [
            "xcrun",
            "swiftc",
            str(main),
            str(next(generated.glob("*.swift"))),
            "-o",
            str(binary),
        ],
        check=True,
        capture_output=True,
    )
    for languages, expected in (
        ("en", ["en", "Close", "Loaded 3 items", "Close"]),
        ("ja", ["en", "Close", "Loaded 3 items", "Close"]),
        ("de-DE", ["de", "Schließen", "3 Einträge geladen", "Close"]),
        ("zh-Hans", ["zh-Hans", "关闭", "已加载 3 项", "关闭"]),
    ):
        result = subprocess.check_output([str(binary), "-AppleLanguages", f"({languages})"])
        assert json.loads(result) == expected
    for language in ("zh-Hant", "zh-TW", "zh-HK", "zh-MO"):
        expected = (
            ["zh-Hant", "关闭", "已加载 3 项", "关闭"]
            if traditional_alias
            else ["en", "Close", "Loaded 3 items", "Close"]
        )
        result = subprocess.check_output([str(binary), "-AppleLanguages", f"({language})"])
        assert json.loads(result) == expected

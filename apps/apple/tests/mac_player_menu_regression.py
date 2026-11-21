#!/usr/bin/env python3
"""Process-only SwiftUI regression for #1276 (macOS 26+ / Xcode 26+).

Compiles the production transport/menu, button style, quality/speed choices and
closure bindings with local controller/scrubber/volume doubles. The Swift fixture
uses an unshown host; it never launches MovieClaw or interacts with the desktop.
This tests observation isolation, not native menu tracking or playback E2E.

Run: python3 apps/apple/tests/mac_player_menu_regression.py
"""

import re
import subprocess
import tempfile
from pathlib import Path

APPLE = Path(__file__).resolve().parents[1]


def instrument(source):
    """Tag ViewThatFits slots without adding a view/observation boundary."""
    source = source[source.index("struct MacPlayerTransport:") : source.index("\n/// 音量：")]
    slots = iter(range(3))
    source, count = re.subn(
        r"(?m)^(\s+)trailingButtons$",
        lambda match: match[1] + f"trailingButtons(slot: {next(slots)})",
        source,
    )
    assert count == 3, "Update the probe for the transport's layout alternatives"
    source = source.replace(
        "private var trailingButtons: some View {",
        "private func trailingButtons(slot: Int) -> some View {",
    )
    if "private var moreMenu: some View {" in source:
        # Also accepts the pre-fix source so this same test can demonstrate red.
        source = source.replace("            moreMenu\n", "            moreMenu(slot: slot)\n")
        source = source.replace(
            "private var moreMenu: some View {",
            "private func moreMenu(slot: Int) -> some View {\n"
            "        Probe.menuRenders[slot, default: 0] += 1",
        )
    else:
        source = source.replace(
            "MacPlayerMoreMenu(controller: controller)",
            "MacPlayerMoreMenu(controller: controller, slot: slot)",
        )
        marker = source.index("private struct MacPlayerMoreMenu:")
        source = source[:marker] + source[marker:].replace(
            "    let controller: PlaybackController",
            "    let controller: PlaybackController\n    let slot: Int",
            1,
        ).replace(
            "    var body: some View {",
            "    var body: some View {\n        Probe.menuRenders[slot, default: 0] += 1",
            1,
        )
    source = source.replace(
        "    var body: some View {\n        let duration",
        "    var body: some View {\n"
        "        let _ = Probe.transportRenders += 1\n        let duration",
        1,
    )
    source = source.replace(
        '.accessibilityIdentifier("mac-player-more")',
        '.accessibilityIdentifier("mac-player-more")\n'
        "        .onAppear { Probe.mountedSlots.insert(slot) }\n"
        "        .onDisappear { Probe.mountedSlots.remove(slot) }",
    )
    return source


def main():
    controls = instrument((APPLE / "MovieClawMac/Player/MacPlayerControls.swift").read_text())
    preferences = (APPLE / "Shared/Player/PlayerPreferences.swift").read_text()
    choices = preferences[
        preferences.index("struct QualityOption:") : preferences.index("/// 倍速按片记")
    ]
    bindings = (APPLE / "Shared/Core/ClosureBinding.swift").read_text()
    # Labels are placeholders; the actual choices, bodies and bindings are compiled.
    keys = sorted(set(re.findall(r"String\(localized: \.(\w+)\)", controls + choices)))
    labels = "extension String.LocalizationValue {\n" + "\n".join(
        f'    static var {key}: Self {{ "{key}" }}' for key in keys
    ) + "\n}\n"
    fixture = (Path(__file__).with_name("mac_player_menu_fixture.swift")).read_text()
    source = fixture.replace("// PRODUCTION_VIEWS", labels + choices + bindings + controls)
    with tempfile.TemporaryDirectory(prefix="mc-menu-regression-") as directory:
        swift = Path(directory) / "main.swift"
        binary = Path(directory) / "menu-regression"
        swift.write_text(source)
        subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
             str(swift), "-o", str(binary)],
            check=True,
        )
        subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == "__main__":
    main()

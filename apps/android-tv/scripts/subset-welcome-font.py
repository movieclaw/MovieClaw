#!/usr/bin/env python3
"""生成 Android TV 欢迎页用的宋体子集：app/src/main/res/font/welcome_serif.otf

同 apps/apple/scripts/subset-welcome-font.py：完整的思源宋体（Noto Serif SC，SIL OFL 1.1）一个字重就 11MB，
只抽出欢迎页 / 「谁在看」源码里实际用到的字（台词、片名、标题）再加全部可打印 ASCII。
源码列表同时包含 Apple 端的欢迎页，Android 的子集是 Apple 子集的超集。子集外的字由系统逐字回落到默认字体。

改了台词或这些页面的文案后重新跑一遍（在仓库根目录）：

    python3 -m venv /tmp/fontvenv && /tmp/fontvenv/bin/pip install fonttools
    curl -LO https://github.com/notofonts/noto-cjk/raw/main/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf
    /tmp/fontvenv/bin/python apps/android-tv/scripts/subset-welcome-font.py NotoSerifSC-Regular.otf
"""

import re
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

REPO = Path(__file__).resolve().parents[3]
SOURCES = [
    (REPO / "apps/apple/Shared/Welcome", "*.swift"),
    (REPO / "apps/apple/MovieClaw/Features/Onboarding", "*.swift"),
    (REPO / "apps/apple/MovieClawTV/Welcome", "*.swift"),
    (REPO / "apps/apple/MovieClawTV/Shell", "TVAccountViews.swift"),
    (REPO / "apps/android-tv/app/src/main/kotlin/io/movieclaw/androidtv/ui/welcome", "*.kt"),
    (REPO / "apps/android-tv/app/src/main/kotlin/io/movieclaw/androidtv/ui/accounts", "AccountsScreen.kt"),
    (REPO / "apps/android-tv/core/session/src/main/kotlin/io/movieclaw/androidtv/core/session", "WelcomeScenes.kt"),
]
OUTPUT = REPO / "apps/android-tv/app/src/main/res/font/welcome_serif.otf"
FAMILY = "MovieClaw Welcome Serif"
POSTSCRIPT = "MovieClawWelcomeSerif-Regular"

if len(sys.argv) != 2:
    sys.exit(__doc__)
chars = {chr(c) for c in range(0x20, 0x7F)}
for folder, pattern in SOURCES:
    files = list(folder.glob(pattern))
    assert files, folder
    for path in files:
        for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', path.read_text(encoding="utf-8")):
            chars.update(ch for ch in lit if ord(ch) > 0x7F)
text = "".join(sorted(chars))
opts = subset.Options(); opts.name_IDs = ["*"]
font = TTFont(sys.argv[1])
s = subset.Subsetter(opts); s.populate(text=text); s.subset(font)
for r in font["name"].names:
    if r.nameID in (1, 4, 16):
        r.string = FAMILY if r.nameID != 4 else f"{FAMILY} Regular"
    elif r.nameID == 6:
        r.string = POSTSCRIPT
    elif r.nameID == 3:
        r.string = f"{POSTSCRIPT};subset"
if "CFF " in font:
    cff = font["CFF "].cff
    cff.fontNames = [POSTSCRIPT]
    top = cff.topDictIndex[0]; top.FullName = f"{FAMILY} Regular"; top.FamilyName = FAMILY
font.save(OUTPUT)
cm = TTFont(OUTPUT).getBestCmap()
missing = [c for c in text if ord(c) not in cm]
print(len(text), "chars", OUTPUT.stat().st_size // 1024, "KB; not in Noto Serif SC:", missing)

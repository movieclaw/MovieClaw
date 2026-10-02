#!/usr/bin/env python3
"""生成欢迎页用的宋体子集：Shared/Resources/Fonts/WelcomeSerif.otf（iPhone 与 Apple TV 共用）

为什么要自带字体：iOS 没有内置中文衬线体，欢迎页的电影台词用苹方（黑体）显示缺了字幕的味道。
完整的思源宋体（Noto Serif SC，SIL OFL 1.1）一个字重就 11MB，所以只抽出欢迎页源码里
实际用到的字（台词、片名、标题）再加全部可打印 ASCII，打出来约 100KB。
子集之外的字会自动回落到系统字体，不会显示成方块。

改了台词或欢迎页文案后重新跑一遍：

    python3 -m venv /tmp/fontvenv && /tmp/fontvenv/bin/pip install fonttools
    curl -LO https://github.com/notofonts/noto-cjk/raw/main/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf
    /tmp/fontvenv/bin/python apps/apple/scripts/subset-welcome-font.py NotoSerifSC-Regular.otf
"""

import re
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
# 欢迎页的源码：台词在共享的 Shared/Welcome，两端各自的欢迎页文案在各自目录
WELCOME_SOURCES = [
    ROOT / "Shared/Welcome",
    ROOT / "MovieClaw/Features/Onboarding",
    ROOT / "MovieClawTV/Welcome",
]
OUTPUT = ROOT / "Shared/Resources/Fonts/WelcomeSerif.otf"
# 子集属于 OFL 所说的「修改版」，改个名字与原版区分，也免得和用户自装的同名字体冲突
FAMILY = "MovieClaw Welcome Serif"
POSTSCRIPT = "MovieClawWelcomeSerif-Regular"


def used_characters() -> str:
    chars = {chr(c) for c in range(0x20, 0x7F)}
    for source in (path for folder in WELCOME_SOURCES for path in folder.glob("*.swift")):
        for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', source.read_text(encoding="utf-8")):
            chars.update(ch for ch in literal if ord(ch) > 0x7F)
    return "".join(sorted(chars))


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    text = used_characters()
    options = subset.Options()
    options.name_IDs = ["*"]
    font = TTFont(sys.argv[1])
    subsetter = subset.Subsetter(options)
    subsetter.populate(text=text)
    subsetter.subset(font)

    names = font["name"]
    for record in names.names:
        if record.nameID in (1, 4, 16):
            record.string = FAMILY if record.nameID != 4 else f"{FAMILY} Regular"
        elif record.nameID == 6:
            record.string = POSTSCRIPT
        elif record.nameID == 3:
            record.string = f"{POSTSCRIPT};subset"
    if "CFF " in font:
        cff = font["CFF "].cff
        cff.fontNames = [POSTSCRIPT]
        top = cff.topDictIndex[0]
        top.FullName = f"{FAMILY} Regular"
        top.FamilyName = FAMILY

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    font.save(OUTPUT)
    print(f"{len(text)} 个字符 → {OUTPUT.relative_to(ROOT)}（{OUTPUT.stat().st_size // 1024} KB）")


if __name__ == "__main__":
    main()

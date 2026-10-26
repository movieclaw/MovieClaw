#!/usr/bin/env python3
"""发版前看一眼：每个产品自上次发布以来有没有改动、版本号递增了没有、该不该发。

服务器与各客户端各自发版（tag 前缀见 .claude/skills/release/SKILL.md），哪个要发由人决定；
这个脚本只把事实列出来：上次发布的 tag、代码里的版本号、该产品目录下改了多少文件和最近几条提交。

用法：python3 scripts/release-status.py [--ref origin/main] [--offline]
默认先 `git fetch --tags origin`，比较对象是 --ref（默认 HEAD）。
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
APPLE = "apps/apple"
APPLE_TESTS = [f":(exclude){APPLE}/{d}/" for d in (
    "MovieClawTests", "MovieClawUITests", "MovieClawMacTests", "MovieClawTVUITests"
)]


class Product(NamedTuple):
    name: str
    prefix: str  # tag 前缀：服务器是 "v"，其余是「产品-v」
    version_file: str
    paths: tuple[str, ...]


PRODUCTS = (
    Product("服务器", "v", "pyproject.toml", (
        ".", *(f":(exclude){p}" for p in (
            "apps/android", "apps/android-tv", "apps/android-core", APPLE, "apps/desktop", "macos",
            "docs", "ml", ".claude", ".github",
        )),
    )),
    Product("iPhone / iPad", "ios-v", f"{APPLE}/project.yml", (
        APPLE, *APPLE_TESTS, *(f":(exclude){APPLE}/{d}/" for d in (
            "MovieClawTV", "MovieClawTVTopShelf", "MovieClawMac",
        )),
    )),
    Product("Apple TV", "tvos-v", f"{APPLE}/project.yml", (
        APPLE, *APPLE_TESTS, *(f":(exclude){APPLE}/{d}/" for d in (
            "MovieClaw", "MovieClawNotificationService", "MovieClawMac",
        )),
    )),
    Product("Mac 版", "macos-v", f"{APPLE}/project.yml", (
        APPLE, *APPLE_TESTS, *(f":(exclude){APPLE}/{d}/" for d in (
            "MovieClaw", "MovieClawNotificationService", "MovieClawTV", "MovieClawTVTopShelf",
        )),
    )),
    Product("Mac 转码器", "transcoder-v", "macos/MovieClawTranscoder/Resources/Info.plist", (
        "macos/MovieClawTranscoder",
    )),
    Product(
        "Android", "android-v", "apps/android/version.properties",
        ("apps/android", "apps/android-core"),
    ),
    Product(
        "Android TV", "androidtv-v", "apps/android-tv/version.properties",
        ("apps/android-tv", "apps/android-core"),
    ),
    Product("Windows", "windows-v", "apps/desktop/src-tauri/Cargo.toml", ("apps/desktop",)),
)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout


def version_in(text: str, file: str) -> str | None:
    """从版本文件内容里读出 App 自己的版本号。"""
    if file.endswith(".plist"):
        return plistlib.loads(text.encode()).get("CFBundleShortVersionString")
    patterns = {
        "pyproject.toml": r'(?m)^version = "([^"]+)"',
        "project.yml": r'(?m)^\s*MARKETING_VERSION:\s*"([^"]+)"',
        "version.properties": r"(?m)^versionName=(\S+)",
        "Cargo.toml": r'(?m)^version = "([^"]+)"',
    }
    match = re.search(patterns[Path(file).name], text)
    return match.group(1) if match else None


def key(version: str) -> tuple[int, ...]:
    return tuple(int(p) for p in version.split("."))


def last_tag(prefix: str, tags: list[str]) -> str | None:
    """该产品版本号最高的正式 tag（不含 -beta 之类的预发布）。"""
    found = [t for t in tags if re.fullmatch(rf"{re.escape(prefix)}\d+\.\d+\.\d+", t)]
    return max(found, key=lambda t: key(t[len(prefix):]), default=None)


def verdict(released: str | None, current: str | None, changed: int) -> str:
    if current is None:
        return "读不到版本号"
    if released is None:
        return "从未单独发布"
    if changed == 0:
        return "无改动，不用发"
    if key(current) <= key(released):
        return "有改动，但版本号还没递增"
    return "有改动，版本号已递增，可以发"


# 文档改动不影响安装包，不算「有改动」
IGNORED = (":(exclude)*.md",)


def status(product: Product, ref: str, tags: list[str]) -> dict:
    tag = last_tag(product.prefix, tags)
    current = version_in(git("show", f"{ref}:{product.version_file}"), product.version_file)
    released = tag[len(product.prefix):] if tag else None
    files, commits = [], []
    if tag:
        paths = (*product.paths, *IGNORED)
        files = git("diff", "--name-only", tag, ref, "--", *paths).split()
        commits = git(
            "log", "--oneline", "--no-merges", "-5", f"{tag}..{ref}", "--", *paths
        ).splitlines()
    return {
        "product": product.name,
        "tag": tag,
        "version": current,
        "changed_files": len(files),
        "recent_commits": commits,
        "verdict": verdict(released, current, len(files)),
        "next_tag": f"{product.prefix}{current}" if current else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--ref", default="HEAD", help="与哪个提交比较（默认 HEAD）")
    parser.add_argument("--offline", action="store_true", help="不先 git fetch --tags")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    args = parser.parse_args()
    if not args.offline:
        subprocess.run(["git", "fetch", "--tags", "--quiet", "origin"], cwd=ROOT, check=False)
    tags = git("tag", "--list").split()
    rows = [status(p, args.ref, tags) for p in PRODUCTS]
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    for row in rows:
        print(f"{row['product']}：{row['verdict']}")
        print(f"  上次发布 {row['tag'] or '—'}，代码版本 {row['version'] or '—'}，"
              f"改动 {row['changed_files']} 个文件")
        if row["verdict"].endswith("可以发"):
            print(f"  发布 tag：{row['next_tag']}")
        for line in row["recent_commits"]:
            print(f"    {line}")


if __name__ == "__main__":
    main()

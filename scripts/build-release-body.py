#!/usr/bin/env python3
"""服务器 Release 正文：changelog 原文，再在中英两段末尾各补一节自动生成的「客户端」。

客户端全部独立发版，各自的更新说明只在各自的 Release 里，这里不抄。这一节回答两件事：
上一个服务器版本以来哪些 App 发了新版（带链接），以及发布时每个 App 的最新版本与安装方式。
「需不需要更新 App」要人来判断，写在 changelog 正文里，不在这里生成。
用列表而不用表格：iPhone / Android 的应用内更新界面不渲染 Markdown 表格。

用法：python3 scripts/build-release-body.py --tag v0.38.0 --changelog docs/changelog/v0.38.0.md \
        --releases releases.jsonl [--repo movieclaw/MovieClaw]
releases.jsonl 每行一个 Release：{"tag", "draft", "prerelease", "published_at"}。
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

SEPARATOR = "\n---\n\n## 简体中文\n"
# 从拆分客户端后的第一个服务器版本开始补；更早的 changelog 里已手写客户端版本
SINCE = (0, 38, 0)
# 独立发版的客户端，按这个顺序列出：tag 前缀 → (英文名, 中文名)
CLIENTS = {
    "ios": ("iPhone & iPad", "iPhone 与 iPad"),
    "tvos": ("Apple TV", "Apple TV"),
    "macos": ("Mac", "Mac"),
    "transcoder": ("Mac transcoder", "Mac 转码器"),
    "android": ("Android", "Android"),
    "androidtv": ("Android TV", "Android TV"),
    "windows": ("Windows", "Windows"),
}


def version_of(text: str) -> tuple[int, ...]:
    return tuple(int(n) for n in re.match(r"\d+(?:\.\d+)*", text).group().split("."))


def published(r: dict) -> bool:
    return not r.get("draft") and not r.get("prerelease") and bool(r.get("published_at"))


def latest(prefix: str, releases: list[dict], cutoff: str | None) -> dict | None:
    """本版发布时（草稿取现在）该客户端最新的正式 Release。"""
    candidates = [
        r for r in releases
        if re.fullmatch(rf"{prefix}-v\d+\.\d+\.\d+", r["tag"]) and published(r)
        and (cutoff is None or r["published_at"] <= cutoff)
    ]
    return max(candidates, key=lambda r: version_of(r["tag"].split("-v", 1)[1]), default=None)


def previous_server(tag: str, releases: list[dict]) -> dict | None:
    """版本号比本版小的最近一个正式服务器版本。"""
    current = version_of(tag.removeprefix("v"))
    candidates = [
        r for r in releases
        if re.fullmatch(r"v\d+\.\d+\.\d+", r["tag"]) and published(r)
        and version_of(r["tag"][1:]) < current
    ]
    return max(candidates, key=lambda r: version_of(r["tag"][1:]), default=None)


def sections(tag: str, releases: list[dict], repo: str) -> tuple[str, str] | None:
    current = next((r for r in releases if r["tag"] == tag), {})
    cutoff = current.get("published_at") if published(current) else None
    previous = previous_server(tag, releases)
    lines_en, lines_zh, new_en, new_zh = [], [], [], []
    for prefix, (name_en, name_zh) in CLIENTS.items():
        release = latest(prefix, releases, cutoff)
        if not release:
            continue
        version = release["tag"].split("-v", 1)[1]
        url = f"https://github.com/{repo}/releases/tag/{release['tag']}"
        # 上一个服务器版本之后才发、且这个 App 之前有更早的发布记录才算新；第一条记录（如拆分时
        # 用旧包补建的）不算，免得把早就随旧服务器版本发出去的包当成新版
        earlier = latest(prefix, [r for r in releases if r["tag"] != release["tag"]], cutoff)
        new = (
            bool(previous and earlier)
            and release["published_at"] > previous["published_at"]
            and version_of(earlier["tag"].split("-v", 1)[1]) < version_of(version)
        )
        if new:
            new_en.append(f"[{name_en} {version}]({url})")
            new_zh.append(f"[{name_zh} {version}]({url})")
        if prefix == "ios":
            how_en = f"TestFlight, or the [unsigned IPA]({url}) for sideloading."
            how_zh = f"通过 TestFlight 安装，或下载[未签名 IPA]({url}) 侧载。"
        elif prefix == "tvos":
            how_en = f"TestFlight ([release notes]({url}))."
            how_zh = f"通过 TestFlight 安装（[更新说明]({url})）。"
        else:
            how_en, how_zh = f"[download]({url}).", f"[下载]({url})。"
        lines_en.append(f"- **{name_en} {version}**{' (new)' if new else ''}: {how_en}")
        lines_zh.append(f"- **{name_zh} {version}**{'（新）' if new else ''}：{how_zh}")
    if not lines_en:
        return None
    intro_en, intro_zh = "Each app has its own release notes.", "各 App 的更新说明见各自的发布页。"
    if previous:
        since = previous["tag"]
        if new_en:
            intro_en = f"New since {since}: {', '.join(new_en)}. {intro_en}"
            intro_zh = f"自 {since} 以来新发布：{'、'.join(new_zh)}。{intro_zh}"
        else:
            intro_en = f"No app updates since {since}. {intro_en}"
            intro_zh = f"自 {since} 以来各 App 没有新版本。{intro_zh}"
    return (
        "### Apps\n\n" + intro_en + "\n\n" + "\n".join(lines_en),
        "### 客户端\n\n" + intro_zh + "\n\n" + "\n".join(lines_zh),
    )


def build(tag: str, changelog: str, releases: list[dict], repo: str) -> str:
    if version_of(tag.removeprefix("v")) < SINCE:
        return changelog
    generated = sections(tag, releases, repo)
    if not generated:
        return changelog
    en, zh = generated
    if changelog.count(SEPARATOR) != 1:
        return changelog.rstrip("\n") + "\n\n" + en + "\n"
    before, after = changelog.split(SEPARATOR)
    before = before.rstrip("\n") + "\n\n" + en + "\n"
    return before + SEPARATOR + after.rstrip("\n") + "\n\n" + zh + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--changelog", type=Path, required=True)
    parser.add_argument("--releases", type=Path, required=True)
    parser.add_argument("--repo", default="movieclaw/MovieClaw")
    args = parser.parse_args()
    releases = [json.loads(line) for line in args.releases.read_text().splitlines() if line.strip()]
    body = build(args.tag, args.changelog.read_text(encoding="utf-8"), releases, args.repo)
    print(body, end="")


if __name__ == "__main__":
    main()

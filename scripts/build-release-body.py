#!/usr/bin/env python3
"""服务器 Release 正文：changelog 原文，再在中英两段末尾各补一节自动生成的「客户端」。

客户端版本不再手写进 changelog：iPhone / Apple TV、转码器读本版附件与 release.json，
Mac、Android、Android TV、Windows 各自独立发版，取本版发布时各自最新的正式 Release。
用列表而不用表格：iPhone / Android 的应用内更新界面不渲染 Markdown 表格。

用法：python3 scripts/build-release-body.py --tag v0.38.0 --changelog docs/changelog/v0.38.0.md \
        --releases releases.jsonl --apple-version 0.7.0 [--downloads downloads.json] \
        [--release-info release.json] [--repo movieclaw/MovieClaw]
releases.jsonl 每行一个 Release：
{"tag", "draft", "prerelease", "published_at", "assets": [名字...]}。
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

SEPARATOR = "\n---\n\n## 简体中文\n"
# 从拆分 Android 后的第一个服务器版本开始补；更早的 changelog 里已手写客户端版本
SINCE = (0, 38, 0)
# 独立发版的客户端：tag 前缀 → 显示名
SEPARATE = {"macos": "Mac", "android": "Android", "androidtv": "Android TV", "desktop": "Windows"}


def version_of(text: str) -> tuple[int, ...]:
    return tuple(int(n) for n in re.match(r"\d+(?:\.\d+)*", text).group().split("."))


def latest_separate(prefix: str, releases: list[dict], cutoff: str | None) -> dict | None:
    """本版发布时（草稿取现在）该客户端最新的正式 Release。"""
    candidates = [
        r for r in releases
        if re.fullmatch(rf"{prefix}-v\d+\.\d+\.\d+", r["tag"])
        and not r.get("draft") and not r.get("prerelease") and r.get("published_at")
        and (cutoff is None or r["published_at"] <= cutoff)
    ]
    return max(candidates, key=lambda r: version_of(r["tag"].split("-v", 1)[1]), default=None)


def client_lines(
    tag: str, apple: str, downloads: dict | None, info: dict | None, releases: list[dict],
    repo: str,
) -> tuple[list[str], list[str]]:
    current = next((r for r in releases if r["tag"] == tag), {})
    assets = set(current.get("assets", []))
    updated = set(info["updated"]) if info else None
    packages = {p["product"]: p for p in (downloads or {}).get("packages", [])}
    en, zh = [], []

    def status(product: str) -> tuple[str, str]:
        if updated is None:
            return "", ""
        return (
            (": changed in this release.", "：本版有更新。")
            if product in updated
            else (": no changes in this release.", "：本版无变化。")
        )

    s_en, s_zh = status("iphone")
    line_en = f"- **iPhone, iPad and Apple TV {apple}**{s_en or '.'}"
    line_zh = f"- **iPhone、iPad 与 Apple TV {apple}**{s_zh or '。'}"
    if "MovieClaw-iOS-unsigned.ipa" in assets:
        line_en += " The unsigned IPA below is for sideloading."
        line_zh += "下方未签名 IPA 供侧载。"
    en.append(line_en)
    zh.append(line_zh)
    if "transcoder" in packages:
        p = packages["transcoder"]
        s_en, s_zh = status("transcoder")
        version, asset = p["version"], p["asset"]
        en.append(f"- **Mac transcoder {version}**{s_en or '.'} Download `{asset}` below.")
        zh.append(f"- **Mac 转码器 {version}**{s_zh or '。'}下载下方的 `{asset}`。")
    cutoff = None if current.get("draft") else current.get("published_at")
    for prefix, name in SEPARATE.items():
        release = latest_separate(prefix, releases, cutoff)
        if not release:
            continue
        url = f"https://github.com/{repo}/releases/tag/{release['tag']}"
        version = release["tag"].split("-v", 1)[1]
        en.append(f"- **{name} {version}**: released separately, [download]({url}).")
        zh.append(f"- **{name} {version}**：单独发布，[下载]({url})。")
    return en, zh


def build(
    tag: str, changelog: str, apple: str, downloads: dict | None, info: dict | None,
    releases: list[dict], repo: str,
) -> str:
    if version_of(tag.removeprefix("v")) < SINCE:
        return changelog
    en, zh = client_lines(tag, apple, downloads, info, releases, repo)
    en_section = "### Apps\n\n" + "\n".join(en)
    zh_section = "### 客户端\n\n" + "\n".join(zh)
    if changelog.count(SEPARATOR) != 1:
        return changelog.rstrip("\n") + "\n\n" + en_section + "\n"
    before, after = changelog.split(SEPARATOR)
    return (
        before.rstrip("\n") + "\n\n" + en_section + "\n" + SEPARATOR
        + after.rstrip("\n") + "\n\n" + zh_section + "\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--changelog", type=Path, required=True)
    parser.add_argument("--releases", type=Path, required=True)
    parser.add_argument("--apple-version", required=True)
    parser.add_argument("--downloads", type=Path)
    parser.add_argument("--release-info", type=Path)
    parser.add_argument("--repo", default="movieclaw/MovieClaw")
    args = parser.parse_args()
    releases = [json.loads(line) for line in args.releases.read_text().splitlines() if line.strip()]
    read = lambda path: json.loads(path.read_text()) if path else None  # noqa: E731
    print(
        build(
            args.tag, args.changelog.read_text(encoding="utf-8"), args.apple_version,
            read(args.downloads), read(args.release_info), releases, args.repo,
        ),
        end="",
    )


if __name__ == "__main__":
    main()

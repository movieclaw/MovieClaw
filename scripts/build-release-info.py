#!/usr/bin/env python3
"""生成官网 release.json：这一版更新了哪些部分、要不要更新镜像，以及按语言拆好的版本说明。

客户端 Release（ios-v、android-v 等）只有产品、版本与说明：
python3 scripts/build-release-info.py --tag android-v0.3.2 \
        [--changelog docs/changelog/android-v0.3.2.md]

官网和邮件只读这份清单，不解析 Release 正文。版本说明的格式由本脚本校验，
格式不对时发布阶段就报错，而不是官网静默显示错乱。

用法：python3 scripts/build-release-info.py --tag v0.34.0 --runtime 19 \
        --previous-tag v0.33.0 --previous-runtime 19 --releases releases.jsonl \
        [--changelog docs/changelog/v0.34.0.md]
releases.jsonl 每行一个 Release：{"tag": ..., "assets": [{"name": ..., "digest": ...}]}。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# 客户端附件。沿用旧包时是原样复制，SHA-256 与上一版相同；不同就是这一版重新构建的。
CLIENTS = {
    "MovieClaw-iOS-unsigned.ipa": "iphone",
    "MovieClaw-macos-arm64.zip": "mac",
    "MovieClawTranscoder-macos-arm64.zip": "transcoder",
    "MovieClaw-Android-arm64.apk": "android",
    "MovieClaw-AndroidTV.apk": "androidtv",
}
SEPARATOR = "\n---\n\n## 简体中文\n"
# 客户端 tag 前缀 → 官网的产品标识
CLIENT_PRODUCTS = {
    "ios": "iphone", "tvos": "appletv", "macos": "mac", "transcoder": "transcoder",
    "android": "android", "androidtv": "androidtv", "windows": "windows",
}


def section(text: str, version: str, lang: str) -> dict[str, str]:
    """一种语言的说明：标题行、紧随其后的一段摘要（保留段内换行，同 Release 页），其余是正文。"""
    lines = text.strip().split("\n")
    # 服务器写「## v0.38.0: 标题」，客户端写「## Android 0.3.2: 标题」
    title = re.fullmatch(r"## (?:v|.+? )(\d[\w.-]*?)[:：]\s*(\S.*)", lines[0])
    if not title or title.group(1) != version:
        raise ValueError(
            f"{lang} 第一行必须是「## v{version}: 标题」或「## <产品名> {version}: 标题」，"
            f"实际是：{lines[0]!r}"
        )
    if (
        len(lines) < 3
        or lines[1] != ""
        or not lines[2].strip()
        or lines[2].startswith(("#", ">", "-", "✅", "⚠️"))
    ):
        raise ValueError(f"{lang} 标题后要空一行，接一段摘要")
    end = lines.index("", 2) if "" in lines[2:] else len(lines)
    body = "\n".join(lines[end:]).strip()
    if not body:
        raise ValueError(f"{lang} 摘要之后没有正文")
    return {
        "title": title.group(2).strip(),
        "summary": "\n".join(lines[2:end]).strip(),
        "body": body,
    }


def notes(text: str, version: str) -> dict[str, dict[str, str]]:
    if text.count(SEPARATOR) != 1:
        raise ValueError("英文与中文之间必须是一行 --- 加「## 简体中文」，且只出现一次")
    en, zh = text.split(SEPARATOR)
    return {"en": section(en, version, "英文"), "zh": section(zh, version, "中文")}


def updated(tag: str, previous: str | None, releases: list[dict]) -> list[str]:
    by_tag = {r["tag"]: {a["name"]: a.get("digest") for a in r["assets"]} for r in releases}
    if tag not in by_tag:
        raise ValueError(f"找不到 Release {tag}")
    current, before = by_tag[tag], by_tag.get(previous or "", {})
    # 上一版没有 Release 或缺这个附件时，发版流水线会重新构建，所以算作更新。
    return ["server"] + [
        product
        for asset, product in CLIENTS.items()
        if asset in current and not (current[asset] and before.get(asset) == current[asset])
    ]


def build(
    tag: str,
    runtime: int,
    previous: str | None,
    previous_runtime: int | None,
    releases: list[dict],
    changelog: str | None,
) -> dict:
    version = tag.removeprefix("v")
    return {
        "schema": 1,
        "release": tag,
        "product": "server",
        "requiresRuntime": runtime,
        # 运行时版本比上一版高，旧镜像就装不了这一版，要先更新 Docker 镜像。
        "imageUpdate": previous_runtime is None or runtime > previous_runtime,
        "updated": updated(tag, previous, releases),
        # 发布时 changelog 还没合入，就先不带说明，合入后 release-notes 工作流会重新生成。
        "notes": notes(changelog, version) if changelog is not None else None,
    }


def build_client(tag: str, changelog: str | None) -> dict:
    """客户端 Release 的 release.json：产品、版本与按语言拆好的说明。"""
    match = re.fullmatch(r"([a-z]+)-v(\d+\.\d+\.\d+)", tag)
    if not match or match.group(1) not in CLIENT_PRODUCTS:
        raise ValueError(f"不认识的客户端 tag：{tag}")
    version = match.group(2)
    return {
        "schema": 1,
        "release": tag,
        "product": CLIENT_PRODUCTS[match.group(1)],
        "version": version,
        "notes": notes(changelog, version) if changelog is not None else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--runtime", type=int)
    parser.add_argument("--previous-tag")
    parser.add_argument("--previous-runtime", type=int)
    parser.add_argument("--releases", type=Path)
    parser.add_argument("--changelog", type=Path)
    args = parser.parse_args()
    changelog = args.changelog.read_text(encoding="utf-8") if args.changelog else None
    try:
        if not args.tag.startswith("v"):
            info = build_client(args.tag, changelog)
        elif args.runtime is None or args.releases is None:
            parser.error("服务器版本需要 --runtime 与 --releases")
        else:
            releases = [
                json.loads(line) for line in args.releases.read_text().splitlines() if line.strip()
            ]
            info = build(
                args.tag, args.runtime, args.previous_tag, args.previous_runtime,
                releases, changelog,
            )
    except ValueError as error:
        sys.exit(f"release.json 生成失败：{error}")
    print(json.dumps(info, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

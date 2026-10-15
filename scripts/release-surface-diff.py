#!/usr/bin/env python3
"""写更新说明前的机械盘点：两个版本之间，用户界面上「消失 / 新增」的文字，以及默认值、门槛的变化。

这几类变化在提交标题里最看不出来（删掉的菜单、改掉的默认值、新加的版本或系统门槛），
却是用户最会撞上的。脚本只把线索列出来，写不写、怎么写由人判断（见 changelog-guide.md 第一节）。

用法：python3 scripts/release-surface-diff.py <上一版 tag> <本版 tag 或 HEAD> [路径…]
例：  python3 scripts/release-surface-diff.py ios-v0.7.0 ios-v0.8.0 \
        apps/apple/MovieClaw apps/apple/Shared
"""

from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict

# 带中文的字符串字面量：界面文案都是中文，这是找界面文字最稳的办法
CJK_LITERAL = re.compile(r"""(["'`])((?:(?!\1).)*?[一-鿿](?:(?!\1).)*?)\1""")
# HTML 里直接写在标签之间的文字（Windows 客户端的界面大多是这种）
CJK_HTML = re.compile(r">\s*([^<>]*?[一-鿿][^<>]*?)\s*<")
# 注释行不算界面文字
COMMENT = re.compile(r"^\s*(//|#|\*|/\*|<!--|--)")
# 默认值、门槛、权限、开关一类的信号：只收真正决定默认体验或使用前提的写法，
# 不收 switch 的 default 分支、FileManager.default 之类
GATE = re.compile(
    r"server_default|default=|defaultValue|DEFAULT_|\bMIN_|minimum[A-Z_]|@available|SDK_INT|"
    r"Build\.VERSION|requires_|capabilit|allow_[a-z]|is_admin|role\s*==|"
    r"bool\(forKey|getBoolean\(|\?: (true|false)\b|"
    r"maxConcurrent|RETENTION|_LIMIT\b|feature_flag",
)
SOURCE = (
    ".swift",
    ".kt",
    ".kts",
    ".ts",
    ".tsx",
    ".js",
    ".py",
    ".rs",
    ".html",
    ".xml",
    ".strings",
    ".json",
)
SKIP = re.compile(r"(^|/)(tests?|Tests?|__tests__|generated|Generated)/")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def diff_lines(base: str, head: str, paths: list[str]) -> list[tuple[str, str, str]]:
    """(文件, '+' 或 '-', 行内容)，跳过测试与生成代码。"""
    out, current = [], ""
    for line in git("diff", "-U0", base, head, "--", *paths).splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else ""
        elif line.startswith("--- a/") and not current:
            current = line[6:]
        elif line[:1] in "+-" and not line.startswith(("+++", "---")) and current:
            if not current.endswith(SOURCE) or SKIP.search(current):
                continue
            out.append((current, line[0], line[1:]))
    return out


def strings_in(text: str, path: str) -> list[str]:
    values = [value for _, value in CJK_LITERAL.findall(text)]
    if path.endswith(".html"):
        values += CJK_HTML.findall(text)
    return [v.strip() for v in values if 1 < len(v.strip()) <= 80]


def literals(rows: list[tuple[str, str, str]], sign: str) -> dict[str, set[str]]:
    found: dict[str, set[str]] = defaultdict(set)
    for path, s, text in rows:
        if s == sign and not COMMENT.match(text):
            for value in strings_in(text, path):
                found[value].add(path)
    return found


def file_text(ref: str, path: str, cache: dict) -> str:
    if (ref, path) not in cache:
        result = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
        # 只看代码行：注释里残留的旧文案不能算「还在」
        lines = result.stdout.splitlines() if result.returncode == 0 else []
        cache[(ref, path)] = "\n".join(line for line in lines if not COMMENT.match(line))
    return cache[(ref, path)]


def elsewhere(ref: str, text: str, paths: list[str], skip: set[str]) -> list[str]:
    """同一段文字在 ref 的其他文件里还在不在（入口可能只是挪了地方）。"""
    result = subprocess.run(
        ["git", "grep", "-l", "-F", text, ref, "--", *paths], capture_output=True, text=True
    )
    out = result.stdout if result.returncode == 0 else ""
    files = [line.split(":", 1)[1] for line in out.splitlines() if ":" in line]
    return [f for f in files if f not in skip]


def changed(found: dict[str, set[str]], other: str, cache: dict) -> dict[str, set[str]]:
    """只保留「在这个文件里真的没了 / 真的是新的」：另一版的同一文件里找不到这段文字。"""
    out: dict[str, set[str]] = {}
    for text, files in found.items():
        gone = {f for f in files if text not in file_text(other, f, cache)}
        if gone:
            out[text] = gone
    return out


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    base, head, paths = sys.argv[1], sys.argv[2], sys.argv[3:] or ["."]
    rows = diff_lines(base, head, paths)
    cache: dict = {}
    removed = changed(literals(rows, "-"), head, cache)
    added = changed(literals(rows, "+"), base, cache)

    print(f"# 界面文字与门槛变化：{base} → {head}（{' '.join(paths)}）\n")
    print(f"## 消失的界面文字（{len(removed)}）：删掉的入口、改掉的名字、拿走的功能都在这里\n")
    print(
        "「别处仍有」表示同样的文字还在其他文件里，入口可能只是挪了位置，也可能只剩别的页面有。\n"
    )
    for text, files in sorted(removed.items(), key=lambda kv: sorted(kv[1])[0]):
        rest = elsewhere(head, text, paths, files)
        note = f"（别处仍有：{', '.join(rest[:3])}）" if rest else "（全部消失）"
        print(f"- 「{text}」  ← {', '.join(sorted(files))}{note}")
    print(f"\n## 新增的界面文字（{len(added)}）：新入口、新提示、新限制\n")
    for text, files in sorted(added.items(), key=lambda kv: sorted(kv[1])[0]):
        print(f"- 「{text}」  ← {', '.join(sorted(files))}")
    gates = [(p, s, t.strip()) for p, s, t in rows if GATE.search(t) and not COMMENT.match(t)]
    print(f"\n## 默认值、门槛、权限相关的改动行（{len(gates)}）")
    print("逐条判断：是否改变了用户的默认体验、使用前提或权限。\n")
    for path, s, text in gates[:300]:
        print(f"- {s} {path}: {text[:160]}")


if __name__ == "__main__":
    main()

"""从骨架生成一个插件目录（清单 + 入口模块）。

    python new_plugin.py plugins/me.hello --id me.hello --title "你好" [--description "一句话说明"] [--module hello]

入口模块名缺省取 id 最后一段（连字符换成下划线），如 me.media-stats → media_stats。
目标目录已存在且非空时拒绝（不覆盖已有代码）。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent.parent / "templates" / "starter"

#: 与服务器清单校验同一规则（movieclaw_api/plugins/packages.py）
_ID = re.compile(r"^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9_-]*)+$")
_MODULE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="从骨架生成插件目录")
    parser.add_argument("target", type=Path, help="插件目录，如 plugins/me.hello")
    parser.add_argument("--id", required=True, help="条目 id：小写、带命名空间，如 me.hello")
    parser.add_argument("--title", required=True, help="中文标题（60 字以内）")
    parser.add_argument("--description", default="", help="一句话说明（500 字以内）")
    parser.add_argument("--module", help="入口模块名，缺省由 id 推出")
    args = parser.parse_args(argv)

    if not _ID.match(args.id) or len(args.id) > 64:
        print(f"✗ id 不合规：{args.id}（须小写、带命名空间，如 me.hello、acme.media-stats）")
        return 1
    if not 1 <= len(args.title) <= 60:
        print("✗ title 须是 1～60 个字")
        return 1
    module = args.module or args.id.rsplit(".", 1)[-1].replace("-", "_")
    if not _MODULE.match(module):
        print(f"✗ 模块名不合规：{module}（用 --module 指定一个 Python 标识符）")
        return 1
    target: Path = args.target
    if target.exists() and any(target.iterdir()):
        print(f"✗ {target} 已存在且不为空，不会覆盖；换个目录或先确认里面的代码不要了")
        return 1

    description = args.description or args.title
    replacements = {
        "__PLUGIN_ID__": args.id,
        "__PLUGIN_TITLE__": args.title,
        "__PLUGIN_DESCRIPTION__": description,
        "__MODULE__": module,
    }

    def render(text: str) -> str:
        for key, value in replacements.items():
            text = text.replace(key, value)
        return text

    target.mkdir(parents=True, exist_ok=True)
    manifest = target / "movieclaw-plugin.toml"
    manifest.write_text(render((TEMPLATE / "movieclaw-plugin.toml").read_text("utf-8")), "utf-8")
    entry = target / f"{module}.py"
    entry.write_text(render((TEMPLATE / "plugin_module.py").read_text("utf-8")), "utf-8")
    print(f"✓ 已生成 {manifest}")
    print(f"✓ 已生成 {entry}")
    print("下一步：按需求修改代码与清单，然后运行 check_plugin.py 检查")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

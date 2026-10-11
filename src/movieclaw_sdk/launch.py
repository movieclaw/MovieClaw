"""非 Python 插件的可信启动器（docs/design/plugin-ipc-http.md §9）。

宿主拉起 ``python -s -m movieclaw_sdk.launch [--uid N --gid N] -- <插件可执行文件> [参数…]``：
这里先降权（换到非特权用户、清空附加组）、设资源限制和「父进程退出即退出」，再 ``execve`` 插件。
不可信的二进制不能指望它自己降权，所以这一步必须在它运行之前、由我们的代码做。

stdin（引导行）、stdout / stderr（日志）和宿主递过来的描述符（``pass_fds``）都原样留给插件。
父进程退出信号要在降权之后设——内核在 uid 变化时会把它清掉；它在 ``execve`` 之后仍然有效。
"""

from __future__ import annotations

import argparse
import os
import sys

from movieclaw_sdk.runner import _die_with_parent, _drop_privileges, _limit_resources


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if "--" not in args:
        print(
            "用法：python -m movieclaw_sdk.launch [--uid N --gid N] -- <程序> [参数…]",
            file=sys.stderr,
        )
        return 2
    split = args.index("--")
    parser = argparse.ArgumentParser(prog="movieclaw_sdk.launch")
    parser.add_argument("--uid", type=int, default=None)
    parser.add_argument("--gid", type=int, default=None)
    options = parser.parse_args(args[:split])
    program = args[split + 1 :]
    if not program:
        print("缺少要启动的程序", file=sys.stderr)
        return 2
    _drop_privileges(options.uid, options.gid)
    _die_with_parent()
    _limit_resources()
    os.execv(program[0], program)
    return 0  # 不会到这里：execv 成功就换成了插件进程


if __name__ == "__main__":
    sys.exit(main())

"""MovieClaw 插件 SDK（docs/design/plugin-phase3.md §7）。

插件代码只从这里导入：``plugin``、``Context`` 与开放给第三方的契约。同一份插件代码既能在主进程里
运行（本地受信插件），也能由进程外运行器（``movieclaw_sdk.runner``）在独立进程里运行，写法不变。
"""

from __future__ import annotations

from movieclaw_kernel import Context, plugin

SDK_VERSION = "1.0"

__all__ = ["SDK_VERSION", "Context", "plugin"]

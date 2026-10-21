"""网页主题契约 ``ui.theme``（docs/design/theme-plugins.md §4.1）。

主题包在清单里写 ``[requires] "ui.theme" = "^1.0"``，安装时按这里的版本检查兼容。
一份版本号管五样东西：主题定义的坑位与 props、清单 ``[theme]`` 段、
前端主题 SDK（``@movieclaw/theme-sdk``）的出口、CSS 契约（公开变量与公开部件）、版式取值。

- 加东西（新坑位、新 SDK 出口、新变量）= 次版本；删 / 改签名 = 主版本；
- 前端 React 升主版本也算主版本（主题代码共用主程序的 React）。
"""

from __future__ import annotations

from movieclaw_kernel.contracts import Contract, Stability

THEME_CONTRACT = Contract(
    "ui.theme",
    version="1.0",
    stability=Stability.EXPERIMENTAL,
    doc="网页主题：外框坑位、主题 SDK、CSS 契约与版式（docs/design/theme-plugins.md）",
)

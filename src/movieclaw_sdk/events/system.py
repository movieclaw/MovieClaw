"""系统域事件：待处理事项、更新、使用建议。"""

from __future__ import annotations

from typing import Any

from pydantic import Field

from movieclaw_sdk.events._base import Frozen, define


class AlertRaised(Frozen):
    """一个需要管理员处理的问题新出现或复发（待处理事项，仍在发生的只刷新内容、不再发事件）。"""

    dedupe_key: str
    """同一个问题的键（``downloader:3``、``site:mteam`` …）。"""
    severity: str
    """``error`` / ``warning`` / ``info``。"""
    source: str
    """``downloader`` / ``site`` / ``subscription`` / ``ingest`` / ``plugin`` / ``cloud`` …"""
    title: str
    message: str
    payload: dict[str, Any] = Field(default_factory=dict)


class AlertResolved(Frozen):
    """一个待处理的问题消失了（自动消退）。"""

    dedupe_key: str
    source: str


class UpdateAvailable(Frozen):
    """MovieClaw 发布了新版本（每个版本一次）。"""

    version: str
    compatible: bool
    """能在应用内一键更新；``False`` = 要换 Docker 镜像。"""


class TipSuggested(Frozen):
    """发现有设置能改善体验（每条建议只一次）。"""

    tip: str
    """``reel-clips``（开启片段预切）…"""


SYSTEM_ALERT_RAISED = define(
    "system.alert.raised", AlertRaised, title="出现需要处理的问题", group="系统"
)
SYSTEM_ALERT_RESOLVED = define(
    "system.alert.resolved", AlertResolved, title="问题已消退", group="系统"
)
SYSTEM_UPDATE_AVAILABLE = define(
    "system.update.available", UpdateAvailable, title="有新版本", group="系统"
)
SYSTEM_TIP_SUGGESTED = define(
    "system.tip.suggested", TipSuggested, title="使用建议", group="系统"
)

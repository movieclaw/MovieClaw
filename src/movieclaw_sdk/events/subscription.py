"""订阅域事件。"""

from __future__ import annotations

from movieclaw_sdk.events._base import Frozen, MediaRef, define


class SubscriptionIdentitySkipped(Frozen):
    """订阅遇到无法确认身份的同名资源，已自动跳过（每个订阅只一次）。"""

    subscription_id: int
    media: MediaRef


SUBSCRIPTION_IDENTITY_SKIPPED = define(
    "subscription.identity_skipped",
    SubscriptionIdentitySkipped,
    title="已跳过同名资源",
    group="订阅",
    doc="订阅发现无法确认身份的同名资源，已自动跳过",
)

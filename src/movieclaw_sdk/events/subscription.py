"""订阅域事件。"""

from __future__ import annotations

from movieclaw_sdk.events._base import Frozen, MediaRef, UnitRef, define


class SubscriptionChanged(Frozen):
    """订阅建立、删除或状态变化。"""

    subscription_id: int
    media: MediaRef | None
    member_id: int
    """发起人：成员 id，超管为 0。"""
    status: str | None = None
    """``active`` / ``completed`` / ``paused`` …"""
    previous_status: str | None = None
    reason: str | None = None
    cleanup_job_id: str | None = None
    """删除时一并发起的清理任务。"""


class TorrentRef(Frozen):
    """交给下载器的种子。"""

    site_id: str | None = None
    torrent_id: str | None = None
    title: str
    info_hash: str | None = None
    resolution: str | None = None
    spec: str = ""
    """给人看的规格摘要（分辨率、编码、来源…）。"""


class SubscriptionDownloadStarted(Frozen):
    """订阅找到资源、种子已真实提交下载器（模拟投递不算）。"""

    subscription_id: int
    media: MediaRef
    units: tuple[UnitRef, ...]
    """这个种子补的季集；电影为空。"""
    torrent: TorrentRef
    upgrade: bool = False
    """洗版下载（替换已在库的版本）。"""
    actor_member_id: int | None = None
    """手动选种时点下载的人（超管为 0）；自动投递为 ``None``。"""


class SubscriptionFulfilled(Frozen):
    """订阅的季集经媒体库对账确认入库。"""

    subscription_id: int
    media: MediaRef
    units: tuple[UnitRef, ...]
    """本次确认入库的全部季集；电影为空。"""
    requested_units: tuple[UnitRef, ...]
    """其中仍在订阅范围内的（用户从订阅里去掉的季集顺带入库了，不在这里）。"""


class SubscriptionUpgraded(Frozen):
    """订阅的一集（或电影）换成了更好的版本。"""

    subscription_id: int
    media: MediaRef
    unit: UnitRef | None
    """电影为 ``None``。"""
    old_label: str
    new_label: str


class SubscriptionIdentitySkipped(Frozen):
    """订阅遇到无法确认身份的同名资源，已自动跳过（每个订阅只一次）。"""

    subscription_id: int
    media: MediaRef


SUBSCRIPTION_CREATED = define(
    "subscription.created",
    SubscriptionChanged,
    title="新建了订阅",
    group="订阅",
    version="2.0",
)
SUBSCRIPTION_DELETED = define(
    "subscription.deleted",
    SubscriptionChanged,
    title="删除了订阅",
    group="订阅",
    version="2.0",
)
SUBSCRIPTION_STATUS_CHANGED = define(
    "subscription.status_changed",
    SubscriptionChanged,
    title="订阅状态变化",
    group="订阅",
    doc="订阅状态变化（追踪中 / 已收齐 / 暂停）",
)
SUBSCRIPTION_DOWNLOAD_STARTED = define(
    "subscription.download_started",
    SubscriptionDownloadStarted,
    title="订阅开始下载",
    group="订阅",
    doc="订阅找到资源，种子已提交下载器",
)
SUBSCRIPTION_FULFILLED = define(
    "subscription.fulfilled",
    SubscriptionFulfilled,
    title="订阅内容已入库",
    group="订阅",
    doc="订阅的季集经媒体库对账确认入库",
    version="2.0",
)
SUBSCRIPTION_UPGRADED = define(
    "subscription.upgraded", SubscriptionUpgraded, title="洗版完成", group="订阅"
)
SUBSCRIPTION_IDENTITY_SKIPPED = define(
    "subscription.identity_skipped",
    SubscriptionIdentitySkipped,
    title="已跳过同名资源",
    group="订阅",
    doc="订阅发现无法确认身份的同名资源，已自动跳过",
)

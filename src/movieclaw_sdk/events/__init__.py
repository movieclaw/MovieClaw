"""系统事件目录（docs/design/domain-events.md §3）。

业务里每件「发生了的事」在这里定义一次：名字、载荷、说明。通知、Webhook、插件都从同一条总线取，
看到的是同一个名字、同一份载荷::

    from movieclaw_sdk import plugin
    from movieclaw_sdk.events import SUBSCRIPTION_FULFILLED

    @plugin("my-plugin", title="…")
    async def apply(ctx):
        ctx.on(SUBSCRIPTION_FULFILLED, on_fulfilled, id="fulfilled")                 # 实时
        ctx.on(SUBSCRIPTION_FULFILLED, on_fulfilled, id="fulfilled", durable=True)   # 可靠

命名 ``<域>.<对象>.<动作>``，全小写，段内用下划线，动作用过去时。本包只依赖内核与 pydantic：
进程外插件导入它很轻。
"""

from __future__ import annotations

from movieclaw_sdk.events._base import (
    CORE_DOMAINS,
    ClientRef,
    EventType,
    FileRef,
    MediaRef,
    UnitRef,
    core_events,
    define,
)
from movieclaw_sdk.events.account import ACCOUNT_DEVICE_SIGNED_IN, DeviceSignedIn
from movieclaw_sdk.events.download import (
    DOWNLOAD_COMPLETED,
    DOWNLOAD_IMPORTED,
    DownloadCompleted,
    DownloadImported,
    ImportedItem,
)
from movieclaw_sdk.events.library import (
    LIBRARY_FILE_DELETED,
    LIBRARY_FILE_PURGED,
    LIBRARY_FILE_RESTORED,
    LIBRARY_FILE_TRASHED,
    LIBRARY_FILES_ADDED,
    LIBRARY_INGEST_COMPLETED,
    LIBRARY_ITEM_DELETED,
    LIBRARY_ITEM_FAVORITED,
    LIBRARY_ITEM_MOVED,
    LIBRARY_ITEM_UNFAVORITED,
    LIBRARY_ITEM_VIEWED,
    LIBRARY_ITEMS_ARRIVED,
    AddedFile,
    ArrivedItem,
    FileRecycled,
    FilesAdded,
    IngestCompleted,
    ItemFavorite,
    ItemMoved,
    ItemsArrived,
    ItemViewed,
    LibraryDeleted,
)
from movieclaw_sdk.events.playback import (
    PLAYBACK_COMPLETED,
    PLAYBACK_MARKED_PLAYED,
    PLAYBACK_MARKED_UNPLAYED,
    PLAYBACK_PROGRESS,
    PLAYBACK_STARTED,
    PLAYBACK_STOPPED,
    Playback,
    PlaybackMarked,
    PlaybackStopped,
)
from movieclaw_sdk.events.subscription import (
    SUBSCRIPTION_CREATED,
    SUBSCRIPTION_DELETED,
    SUBSCRIPTION_DOWNLOAD_STARTED,
    SUBSCRIPTION_FULFILLED,
    SUBSCRIPTION_IDENTITY_SKIPPED,
    SUBSCRIPTION_STATUS_CHANGED,
    SUBSCRIPTION_UPGRADED,
    SubscriptionChanged,
    SubscriptionDownloadStarted,
    SubscriptionFulfilled,
    SubscriptionIdentitySkipped,
    SubscriptionUpgraded,
    TorrentRef,
)
from movieclaw_sdk.events.system import (
    SYSTEM_ALERT_RAISED,
    SYSTEM_ALERT_RESOLVED,
    SYSTEM_TIP_SUGGESTED,
    SYSTEM_UPDATE_AVAILABLE,
    AlertRaised,
    AlertResolved,
    TipSuggested,
    UpdateAvailable,
)

__all__ = [
    "ACCOUNT_DEVICE_SIGNED_IN",
    "DOWNLOAD_COMPLETED",
    "DOWNLOAD_IMPORTED",
    "LIBRARY_FILE_DELETED",
    "LIBRARY_FILE_PURGED",
    "LIBRARY_FILE_RESTORED",
    "LIBRARY_FILE_TRASHED",
    "LIBRARY_INGEST_COMPLETED",
    "LIBRARY_ITEM_DELETED",
    "LIBRARY_ITEM_MOVED",
    "LIBRARY_ITEMS_ARRIVED",
    "ArrivedItem",
    "DownloadCompleted",
    "DownloadImported",
    "FileRecycled",
    "ImportedItem",
    "IngestCompleted",
    "ItemsArrived",
    "LibraryDeleted",
    "ItemMoved",
    "LIBRARY_FILES_ADDED",
    "LIBRARY_ITEM_FAVORITED",
    "LIBRARY_ITEM_UNFAVORITED",
    "LIBRARY_ITEM_VIEWED",
    "PLAYBACK_COMPLETED",
    "PLAYBACK_MARKED_PLAYED",
    "PLAYBACK_MARKED_UNPLAYED",
    "PLAYBACK_PROGRESS",
    "PLAYBACK_STARTED",
    "PLAYBACK_STOPPED",
    "AddedFile",
    "FilesAdded",
    "ItemFavorite",
    "ItemViewed",
    "Playback",
    "PlaybackMarked",
    "PlaybackStopped",
    "SUBSCRIPTION_CREATED",
    "SUBSCRIPTION_DELETED",
    "SUBSCRIPTION_DOWNLOAD_STARTED",
    "SUBSCRIPTION_FULFILLED",
    "SUBSCRIPTION_IDENTITY_SKIPPED",
    "SUBSCRIPTION_STATUS_CHANGED",
    "SUBSCRIPTION_UPGRADED",
    "SubscriptionChanged",
    "SubscriptionDownloadStarted",
    "SubscriptionFulfilled",
    "SubscriptionUpgraded",
    "TorrentRef",
    "SYSTEM_ALERT_RAISED",
    "SYSTEM_ALERT_RESOLVED",
    "SYSTEM_TIP_SUGGESTED",
    "SYSTEM_UPDATE_AVAILABLE",
    "AlertRaised",
    "AlertResolved",
    "DeviceSignedIn",
    "SubscriptionIdentitySkipped",
    "TipSuggested",
    "UpdateAvailable",
    "CORE_DOMAINS",
    "ClientRef",
    "EventType",
    "FileRef",
    "MediaRef",
    "UnitRef",
    "core_events",
    "define",
]

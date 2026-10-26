"""Webhook 能勾选的事件（docs/design/domain-events.md §6.2）：就是系统事件目录。

设置页的「订阅事件」多选、保存时的校验都按它；新增系统事件不用改这里。``jellyfin_type``：
有 Jellyfin Webhook 插件对应物的事件，Jellyfin 兼容格式的地址才能勾选。
"""

from __future__ import annotations

from typing import Any

from movieclaw_api.i18n import t

#: 系统事件 → Jellyfin Webhook 插件的 NotificationType；不在表里的事件 Jellyfin 格式不能勾
JELLYFIN_TYPES: dict[str, str] = {
    "playback.started": "PlaybackStart",
    "playback.stopped": "PlaybackStop",
    "playback.progress": "PlaybackProgress",
    "playback.marked_played": "UserDataSaved",
    "playback.marked_unplayed": "UserDataSaved",
    "library.item.favorited": "UserDataSaved",
    "library.item.unfavorited": "UserDataSaved",
}


def event_types() -> dict[str, Any]:
    """能投递的事件：系统事件 + 在运行的插件登记的事件（domain-events.md §7）。"""
    from movieclaw_api.services import plugin_events

    return plugin_events.all_events()


#: 旧版事件名 → 现在的名字（老配置里存的）
LEGACY_NAMES = {
    "item.favorited": "library.item.favorited",
    "item.unfavorited": "library.item.unfavorited",
}


def normalize(names: list[str]) -> list[str]:
    """老配置里的旧事件名换成现在的，认不出的（插件卸载了）去掉，去重保序。"""
    known = event_types()
    out = [LEGACY_NAMES.get(n, n) for n in names]
    return [n for n in dict.fromkeys(out) if n in known]


def is_known_event(name: str) -> bool:
    return name in event_types()


def is_jellyfin_mappable(name: str) -> bool:
    return name in JELLYFIN_TYPES


# Only first-party event identities have translations; plugin titles stay verbatim.
_BUILTIN_TEXT = {
    "account.device.signed_in": (
        "settings.webhook.events.accountDeviceSignedIn",
        "settings.webhook.groups.account",
    ),
    "agent.run.finished": (
        "settings.webhook.events.agentRunFinished",
        "settings.webhook.groups.agent",
    ),
    "download.completed": (
        "settings.webhook.events.downloadCompleted",
        "settings.webhook.groups.download",
    ),
    "download.imported": (
        "settings.webhook.events.downloadImported",
        "settings.webhook.groups.download",
    ),
    "library.files.added": (
        "settings.webhook.events.libraryFilesAdded",
        "settings.webhook.groups.library",
    ),
    "library.file.local-released": (
        "settings.webhook.events.libraryFileLocalReleased",
        "settings.webhook.groups.library",
    ),
    "library.item.favorited": (
        "settings.webhook.events.libraryItemFavorited",
        "settings.webhook.groups.favorites",
    ),
    "library.item.unfavorited": (
        "settings.webhook.events.libraryItemUnfavorited",
        "settings.webhook.groups.favorites",
    ),
    "library.item.viewed": (
        "settings.webhook.events.libraryItemViewed",
        "settings.webhook.groups.library",
    ),
    "library.ingest.completed": (
        "settings.webhook.events.libraryIngestCompleted",
        "settings.webhook.groups.library",
    ),
    "library.items.arrived": (
        "settings.webhook.events.libraryItemsArrived",
        "settings.webhook.groups.library",
    ),
    "library.item.deleted": (
        "settings.webhook.events.libraryItemDeleted",
        "settings.webhook.groups.library",
    ),
    "library.file.deleted": (
        "settings.webhook.events.libraryFileDeleted",
        "settings.webhook.groups.library",
    ),
    "library.file.trashed": (
        "settings.webhook.events.libraryFileTrashed",
        "settings.webhook.groups.trash",
    ),
    "library.file.restored": (
        "settings.webhook.events.libraryFileRestored",
        "settings.webhook.groups.trash",
    ),
    "library.file.purged": (
        "settings.webhook.events.libraryFilePurged",
        "settings.webhook.groups.trash",
    ),
    "library.item.moved": (
        "settings.webhook.events.libraryItemMoved",
        "settings.webhook.groups.library",
    ),
    "playback.started": (
        "settings.webhook.events.playbackStarted",
        "settings.webhook.groups.playback",
    ),
    "playback.stopped": (
        "settings.webhook.events.playbackStopped",
        "settings.webhook.groups.playback",
    ),
    "playback.completed": (
        "settings.webhook.events.playbackCompleted",
        "settings.webhook.groups.playback",
    ),
    "playback.progress": (
        "settings.webhook.events.playbackProgress",
        "settings.webhook.groups.playback",
    ),
    "playback.marked_played": (
        "settings.webhook.events.playbackMarkedPlayed",
        "settings.webhook.groups.playback",
    ),
    "playback.marked_unplayed": (
        "settings.webhook.events.playbackMarkedUnplayed",
        "settings.webhook.groups.playback",
    ),
    "subscription.created": (
        "settings.webhook.events.subscriptionCreated",
        "settings.webhook.groups.subscription",
    ),
    "subscription.deleted": (
        "settings.webhook.events.subscriptionDeleted",
        "settings.webhook.groups.subscription",
    ),
    "subscription.status_changed": (
        "settings.webhook.events.subscriptionStatusChanged",
        "settings.webhook.groups.subscription",
    ),
    "subscription.download_started": (
        "settings.webhook.events.subscriptionDownloadStarted",
        "settings.webhook.groups.subscription",
    ),
    "subscription.fulfilled": (
        "settings.webhook.events.subscriptionFulfilled",
        "settings.webhook.groups.subscription",
    ),
    "subscription.upgraded": (
        "settings.webhook.events.subscriptionUpgraded",
        "settings.webhook.groups.subscription",
    ),
    "subscription.identity_skipped": (
        "settings.webhook.events.subscriptionIdentitySkipped",
        "settings.webhook.groups.subscription",
    ),
    "subscription.awaiting_subtitles": (
        "settings.webhook.events.subscriptionAwaitingSubtitles",
        "settings.webhook.groups.subscription",
    ),
    "subscription.download_stuck": (
        "settings.webhook.events.subscriptionDownloadStuck",
        "settings.webhook.groups.subscription",
    ),
    "subscription.more_episodes": (
        "settings.webhook.events.subscriptionMoreEpisodes",
        "settings.webhook.groups.subscription",
    ),
    "system.alert.raised": (
        "settings.webhook.events.systemAlertRaised",
        "settings.webhook.groups.system",
    ),
    "system.alert.resolved": (
        "settings.webhook.events.systemAlertResolved",
        "settings.webhook.groups.system",
    ),
    "system.update.available": (
        "settings.webhook.events.systemUpdateAvailable",
        "settings.webhook.groups.system",
    ),
    "system.tip.suggested": (
        "settings.webhook.events.systemTipSuggested",
        "settings.webhook.groups.system",
    ),
}


def catalog_view() -> list[dict]:
    """Read-time labels; event identity, order, defaults and third-party titles stay intact."""
    result = []
    for event in event_types().values():
        keys = _BUILTIN_TEXT.get(event.name)
        result.append(
            {
                "event": event.name,
                "group": t(keys[1]) if keys else event.group,
                "label": t(keys[0]) if keys else event.title,
                "jellyfin_supported": event.name in JELLYFIN_TYPES,
                "default_on": not event.high_frequency,
            }
        )
    return result

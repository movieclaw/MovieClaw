"""Webhook 能勾选的事件（docs/design/domain-events.md §6.2）：就是系统事件目录。

设置页的「订阅事件」多选、保存时的校验都按它；新增系统事件不用改这里。``jellyfin_type``：
有 Jellyfin Webhook 插件对应物的事件，Jellyfin 兼容格式的地址才能勾选。
"""

from __future__ import annotations

from typing import Any

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


def catalog_view() -> list[dict]:
    """设置页的事件目录：分组、说明、Jellyfin 可订阅性、新建地址是否默认勾选（高频的不勾）。"""
    return [
        {
            "event": event.name,
            "group": event.group,
            "label": event.title,
            "jellyfin_supported": event.name in JELLYFIN_TYPES,
            "default_on": not event.high_frequency,
        }
        for event in event_types().values()
    ]

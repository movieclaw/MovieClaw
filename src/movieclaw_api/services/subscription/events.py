"""订阅域的 webhook 事件装配（docs/design/webhook.md §1.1 预留域的首个接入）。

订阅域事件描述的是**已发生的外部动作**（种子已提交下载器 / 库存对账确认
已入库），不依赖当前事务落库，因此产生点与通知（``services.push.events``）
相邻调用即可。纯装配、不投递、不查库——所需数据产生点手上都有。

电影订阅的内部 (0,0) 单元不外泄：``units`` 对电影为空列表。
"""

from __future__ import annotations

from movieclaw_db.models import MediaItem
from movieclaw_events import OutboundEvent


def _subscription_media(item: MediaItem) -> dict:
    return {
        "item_id": item.id,
        "type": "movie" if item.kind == "movie" else "series",
        "tmdb_id": item.tmdb_id,
        "imdb_id": item.imdb_id,
        "title": item.title,
        "original_title": item.original_title,
        "year": item.year,
    }


def _units_payload(item: MediaItem, units: list[tuple[int, int]]) -> list[list[int]]:
    if item.kind == "movie":
        return []
    return [[season, episode] for season, episode in units]


def build_download_started_event(
    item: MediaItem,
    units: list[tuple[int, int]],
    *,
    site_id: str,
    torrent_title: str,
    spec: str = "",
) -> OutboundEvent:
    """订阅命中并已提交下载器。``spec`` 是人读的规格摘要（分辨率/编码等）。"""
    return OutboundEvent(
        event="subscription.download_started",
        data={
            "media": _subscription_media(item),
            "units": _units_payload(item, units),
            "torrent": {"site_id": site_id, "title": torrent_title, "spec": spec},
        },
    )


def build_fulfilled_event(
    item: MediaItem, units: list[tuple[int, int]]
) -> OutboundEvent:
    """订阅内容经媒体库对账确认已入库。"""
    return OutboundEvent(
        event="subscription.fulfilled",
        data={
            "media": _subscription_media(item),
            "units": _units_payload(item, units),
        },
    )

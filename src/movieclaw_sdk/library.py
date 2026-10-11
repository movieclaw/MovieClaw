"""媒体库与播放的实时事件（docs/design/plugin-strm-prefetch.md §3）。

发完即忘（``Delivery.LIVE``）：插件进程不在、队列满了就丢，漏了不要紧——这些事件只是「现在
值得做点什么」的提示，该做的事应当能从数据库里的事实补回来（例如按待探列表补探）::

    from movieclaw_sdk import plugin
    from movieclaw_sdk.library import PLAYBACK_STARTED

    @plugin("my-plugin", title="…")
    async def apply(ctx):
        async def on_play(event):
            ...
        ctx.on(PLAYBACK_STARTED, on_play, id="play")

本模块只依赖内核与 pydantic：进程外插件导入它很轻。
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict

from movieclaw_kernel import Delivery, Event, Mode, Stability


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


class AddedFile(_Frozen):
    id: int
    media_item_id: int | None
    """未识别为 ``None``。"""
    season: int
    episode: int
    """电影为 0 / 0。"""
    strm: bool
    """网盘占位文件（.strm）。"""


class FilesAdded(_Frozen):
    """一个库新入账了文件（扫描、实时监控、延迟补扫、下载入库）。"""

    library_id: int
    files: tuple[AddedFile, ...]


class PlaybackStarted(_Frozen):
    """有人开始播放（网页或 Jellyfin 客户端）。"""

    media_item_id: int
    season: int
    episode: int
    """电影为 0 / 0。"""
    file_id: int | None
    """播的是哪个文件；客户端没说为 ``None``。"""
    member_id: int
    """成员；超管为 0。"""
    client: str | None = None


class ItemFavorited(_Frozen):
    """收藏状态变了。"""

    media_item_id: int
    season: int | None = None
    episode: int | None = None
    """收藏的是整部为 ``None``。"""
    member_id: int
    favorite: bool


class ItemViewed(_Frozen):
    """有人打开了条目详情（网页详情页、Jellyfin 客户端取条目）。"""

    media_item_id: int
    season: int | None = None
    episode: int | None = None
    member_id: int
    client: str
    """``web`` / ``jellyfin``。"""


def _event(name: str, payload: type, doc: str) -> Event[object, object]:
    return Event(
        name,
        Mode.EMIT,
        payload=payload,
        delivery=Delivery.LIVE,
        stability=Stability.EXPERIMENTAL,
        doc=doc,
    )


LIBRARY_FILES_ADDED = _event("library.files.added", FilesAdded, "媒体库新入账了文件（实时）")
PLAYBACK_STARTED = _event("playback.started", PlaybackStarted, "有人开始播放（实时）")
LIBRARY_ITEM_FAVORITED = _event("library.item.favorited", ItemFavorited, "条目收藏状态变化（实时）")
LIBRARY_ITEM_VIEWED = _event("library.item.viewed", ItemViewed, "有人打开了条目详情（实时）")

__all__ = [
    "LIBRARY_FILES_ADDED",
    "LIBRARY_ITEM_FAVORITED",
    "LIBRARY_ITEM_VIEWED",
    "PLAYBACK_STARTED",
    "AddedFile",
    "FilesAdded",
    "ItemFavorited",
    "ItemViewed",
    "PlaybackStarted",
]

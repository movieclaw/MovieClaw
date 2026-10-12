"""媒体库域事件。"""

from __future__ import annotations

from movieclaw_sdk.events._base import ClientRef, FileRef, Frozen, MediaRef, UnitRef, define


class ItemFavorite(Frozen):
    """收藏 / 取消收藏（整部、一季或一集）。"""

    member_id: int
    media: MediaRef
    level: str
    """收藏的层级：``movie`` / ``series`` / ``season`` / ``episode``。"""
    season: int | None = None
    """``season`` / ``episode`` 层级时有值。"""
    episode: int | None = None
    client: ClientRef | None = None


class ItemViewed(Frozen):
    """有人打开了条目详情（网页详情页、播放器取条目）。"""

    member_id: int
    media: MediaRef
    season: int | None = None
    episode: int | None = None
    client: ClientRef | None = None


class IngestCompleted(Frozen):
    """一个下载条目整理入库完成。"""

    media: MediaRef
    library_id: int | None
    """入到哪个库；自定义目录（暂存）规则为 ``None``。"""
    files: tuple[FileRef, ...]
    """本次新入账的文件（暂存规则不入账，为空）。"""
    imported_names: tuple[str, ...]
    """条目内被整理的源文件名（相对路径）。"""
    info_hashes: tuple[str, ...]
    rule_id: int | None = None
    staging: bool = False
    intent_owner: str | None = None
    """手动下载意图的归属：``manual`` / ``plugin:<条目 id>``；不是手动下载为 ``None``。"""


class ArrivedItem(Frozen):
    media: MediaRef
    units: tuple[UnitRef, ...]
    """第一次出现在这个库里的季集；电影为空。"""


class ItemsArrived(Frozen):
    """媒体库来了新片或新剧集（不管是谁下载的、怎么入库的）。

    由检测器从台账里新出现的行判定：同库同单元已有更早的行（洗版、多版本、改名）不算；新建
    媒体库的首次全量扫描、老文件、图片库都不算；攒一攒（连续 5 分钟没有新行，最多 30 分钟）再发。
    """

    library_id: int
    items: tuple[ArrivedItem, ...]


class LibraryDeleted(Frozen):
    """从磁盘删除了条目在某个库里的全部文件（``whole_item``）或其中一部分。

    只有媒体库自己的事实（library-boundary.md §3.6）：种子按 ``files[].id`` 调
    ``dl.file-sources.list`` 查（文件删了也能查），订阅按 ``media.id`` 调 ``subscriptions.list``。
    """

    library_id: int
    media: MediaRef | None
    whole_item: bool
    files: tuple[FileRef, ...]
    options: tuple[str, ...] = ()
    """这次删除勾了哪些删除选项（删除参与方的键，如 ``downloads:remove-source``）；
    其他端发起的删除不带选项，为空。"""


class FileRecycled(Frozen):
    """文件进回收站 / 从回收站恢复 / 被彻底清除。"""

    file: FileRef
    media: MediaRef | None
    reason: str | None = None
    """``upgrade_replaced`` / ``upgrade_refuted`` / ``duplicate_cleanup`` /
    ``subscription_cancelled`` / ``expired``（到期清除）/ ``manual``。"""
    trigger_kind: str | None = None
    trigger_id: str | None = None


class ItemMoved(Frozen):
    """条目转移到了另一个媒体库（分错库的补救、库内归并），文件随之搬走。"""

    media: MediaRef
    from_library_id: int
    to_library_id: int
    files_moved: int
    """随迁的台账行数。"""


class AddedFile(Frozen):
    id: int
    media_item_id: int | None
    """未识别为 ``None``。"""
    season: int | None = None
    episode: int | None = None
    """电影为 ``None``。"""
    strm: bool = False
    """网盘占位文件（.strm）。"""


class FilesAdded(Frozen):
    """一个库新入账了文件（扫描、实时监控、延迟补扫、下载入库）。"""

    library_id: int
    files: tuple[AddedFile, ...]


LIBRARY_FILES_ADDED = define(
    "library.files.added",
    FilesAdded,
    title="媒体库新入账了文件",
    group="媒体库",
    version="2.0",
)
LIBRARY_ITEM_FAVORITED = define(
    "library.item.favorited",
    ItemFavorite,
    title="收藏",
    group="收藏",
    sensitive=True,
    version="2.0",
)
LIBRARY_ITEM_UNFAVORITED = define(
    "library.item.unfavorited", ItemFavorite, title="取消收藏", group="收藏", sensitive=True
)
LIBRARY_ITEM_VIEWED = define(
    "library.item.viewed",
    ItemViewed,
    title="打开条目详情",
    group="媒体库",
    doc="有人打开了条目详情（高频）",
    sensitive=True,
    high_frequency=True,
    version="2.0",
)
LIBRARY_INGEST_COMPLETED = define(
    "library.ingest.completed",
    IngestCompleted,
    title="下载条目整理入库",
    group="媒体库",
    doc="一个下载条目整理入库完成",
)
LIBRARY_ITEMS_ARRIVED = define(
    "library.items.arrived",
    ItemsArrived,
    title="媒体库有新片",
    group="媒体库",
    doc="媒体库来了新片或新剧集（不管是谁下载的、怎么入库的）",
)
LIBRARY_ITEM_DELETED = define(
    "library.item.deleted",
    LibraryDeleted,
    title="删除了条目",
    group="媒体库",
    doc="条目在某个库里的文件已从磁盘全部删除",
    version="2.0",
)
LIBRARY_FILE_DELETED = define(
    "library.file.deleted",
    LibraryDeleted,
    title="删除了部分文件",
    group="媒体库",
    doc="条目的部分文件已从磁盘删除",
    version="2.0",
)
LIBRARY_FILE_TRASHED = define(
    "library.file.trashed", FileRecycled, title="文件进了回收站", group="回收站", version="2.0"
)
LIBRARY_FILE_RESTORED = define(
    "library.file.restored", FileRecycled, title="文件从回收站恢复", group="回收站", version="2.0"
)
LIBRARY_FILE_PURGED = define(
    "library.file.purged",
    FileRecycled,
    title="回收站里的文件被彻底清除",
    group="回收站",
    version="2.0",
)
LIBRARY_ITEM_MOVED = define(
    "library.item.moved", ItemMoved, title="条目转移到了另一个库", group="媒体库"
)

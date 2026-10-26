"""下载域事件：订阅投递的种子下载完成、手动下载的内容入库完成。"""

from __future__ import annotations

from movieclaw_sdk.events._base import Frozen, MediaRef, UnitRef, define


class DownloadCompleted(Frozen):
    """订阅投递的种子在下载器里下载完成（入库之前）。"""

    subscription_id: int
    media: MediaRef | None
    units: tuple[UnitRef, ...]
    """这个种子补的季集；电影为空。"""
    info_hash: str
    downloader_id: int | None
    site_id: str | None = None
    torrent_id: str | None = None
    title: str | None = None
    save_path: str | None = None
    download_name: str | None = None
    purpose: str = "download"
    """``download`` / ``upgrade``（洗版）。"""


class ImportedItem(Frozen):
    media: MediaRef
    units: tuple[UnitRef, ...]
    """这次入库的季集；电影为空。"""


class DownloadImported(Frozen):
    """手动下载的内容全部入库了（监听导入入账，或直接下进库目录、扫描入账）。"""

    member_id: int
    """点下载的人：成员 id，超管为 0。"""
    library_id: int
    download_name: str | None = None
    items: tuple[ImportedItem, ...]
    """入库的条目（合集一次下了好几部）。"""


DOWNLOAD_COMPLETED = define(
    "download.completed",
    DownloadCompleted,
    title="订阅的种子下载完成",
    group="下载",
    doc="订阅投递的种子在下载器里下载完成（入库之前）",
    version="2.0",
)
DOWNLOAD_IMPORTED = define(
    "download.imported",
    DownloadImported,
    title="手动下载已入库",
    group="下载",
    doc="手动下载的内容全部整理进媒体库",
)

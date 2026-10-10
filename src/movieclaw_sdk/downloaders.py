"""下载器契约（docs/design/downloader-adapters.md）。

一个下载器插件只实现「怎么跟这款下载软件说话」：继承 ``BaseDownloader``，往注册表
``downloader-adapters`` 贡献一个 ``DownloaderAdapter``。下载器配置、连接测试、路径映射、订阅投递、
做种同步、删种都由主程序负责，插件不用管::

    from movieclaw_sdk import plugin
    from movieclaw_sdk.downloaders import (
        DOWNLOADER_ADAPTERS, BaseDownloader, DownloaderAdapter, DownloaderConfig,
    )

    class Aria2(BaseDownloader):
        ...

    @plugin("aria2-downloader", title="Aria2 下载器")
    async def apply(ctx):
        ctx.contribute(DOWNLOADER_ADAPTERS, "aria2", DownloaderAdapter(
            type="aria2", title="Aria2", factory=Aria2, url_label="RPC 地址"))

同一份适配器既能在主进程里运行，也能在独立进程里运行（宿主经代理调用它的方法）。
qBittorrent、Transmission 是随应用提供的官方插件（``src/movieclaw_plugins/``），可作参考。
"""

from __future__ import annotations

from movieclaw_downloader.base import BaseDownloader
from movieclaw_downloader.exceptions import (
    DownloaderAuthError,
    DownloaderConnectError,
    DownloaderDeleteError,
    DownloaderException,
    DownloaderNotSupportedError,
    DownloaderSubmitError,
    TorrentParseError,
)
from movieclaw_downloader.models import (
    DownloaderConfig,
    DownloaderInfo,
    DownloaderLimits,
    DownloadRequest,
    SubmitResult,
    TorrentBrief,
    TorrentFile,
    TorrentStatus,
)
from movieclaw_downloader.registry import DOWNLOADER_ADAPTERS, DownloaderAdapter
from movieclaw_downloader.torrent import compute_info_hash, parse_magnet_info_hash

__all__ = [
    "DOWNLOADER_ADAPTERS",
    "BaseDownloader",
    "DownloadRequest",
    "DownloaderAdapter",
    "DownloaderAuthError",
    "DownloaderConfig",
    "DownloaderConnectError",
    "DownloaderDeleteError",
    "DownloaderException",
    "DownloaderInfo",
    "DownloaderLimits",
    "DownloaderNotSupportedError",
    "DownloaderSubmitError",
    "SubmitResult",
    "TorrentBrief",
    "TorrentFile",
    "TorrentParseError",
    "TorrentStatus",
    "compute_info_hash",
    "parse_magnet_info_hash",
]


# ---------------------------------------------------------------------- 进程外协议
# 宿主经代理调独立进程里的适配器：方法名 + 参数，结果与异常按下面的口径来回编码（两边共用）。

_EXCEPTIONS = {
    cls.__name__: cls
    for cls in (
        DownloaderException,
        DownloaderConnectError,
        DownloaderAuthError,
        DownloaderSubmitError,
        DownloaderDeleteError,
        TorrentParseError,
    )
}


def request_dict(request: DownloadRequest) -> dict:
    """提交请求编码：种子字节转 base64（JSON 放不下原始字节）。"""
    import base64

    data = request.model_dump(mode="python")
    raw = data.pop("torrent_bytes", None)
    data["torrent_b64"] = base64.b64encode(raw).decode() if raw is not None else None
    return data


def request_from_dict(data: dict) -> DownloadRequest:
    import base64

    data = dict(data)
    raw = data.pop("torrent_b64", None)
    return DownloadRequest(**data, torrent_bytes=base64.b64decode(raw) if raw else None)


def raise_remote(kind: str | None, message: str) -> None:
    """把进程外适配器报的下载器异常还原成同一个类型，上层的错误处理不用分两套。"""
    cls = _EXCEPTIONS.get(kind or "")
    if cls is not None:
        raise cls(message)

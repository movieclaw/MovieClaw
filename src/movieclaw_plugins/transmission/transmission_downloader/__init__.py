"""Transmission 下载器插件（随应用携带的插件包，docs/design/downloader-adapters.md）。

协议客户端在 ``client``，只依赖 SDK 与 transmission_rpc。装一个同 id 的插件包就能替换它；
停用后这种下载器暂时不可用，已有的下载器配置保留。
"""

from __future__ import annotations

from movieclaw_sdk import Context, plugin
from movieclaw_sdk.downloaders import DOWNLOADER_ADAPTERS, DownloaderAdapter

from .client import TransmissionDownloader

ADAPTER = DownloaderAdapter(
    type="transmission",
    title="Transmission",
    factory=TransmissionDownloader,
    url_label="RPC 地址",
    url_placeholder="http://192.168.1.10:9091",
    help="路径缺省时自动补全为 /transmission/rpc",
)


@plugin("transmission-downloader", title="Transmission 下载器", disableable=True, reloadable=True)
async def transmission_downloader(ctx: Context) -> None:
    """接入 Transmission：提交、查询、删除下载任务，同步做种状态。"""
    ctx.contribute(DOWNLOADER_ADAPTERS, "transmission", ADAPTER)

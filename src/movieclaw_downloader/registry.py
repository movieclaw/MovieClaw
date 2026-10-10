"""下载器适配器注册表（docs/design/downloader-adapters.md）。

下载器类型不再写死：每种下载器是一个适配器（实现 ``BaseDownloader``），由插件登记进来。
qBittorrent、Transmission 是随应用提供的官方插件（``src/movieclaw_plugins/``），装一个同 id 的插件包
就能替换；第三方插件可以登记新的类型（Deluge、Aria2……）。

没有插件内核时（命令行工具、单独驱动下载器的测试）回落到内置的两个适配器。
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from movieclaw_downloader.base import BaseDownloader
from movieclaw_downloader.models import DownloaderConfig
from movieclaw_kernel import Registry, RegistryKey, Stability


@dataclass(frozen=True)
class DownloaderAdapter:
    type: str
    """存进下载器配置的类型值，如 ``qbittorrent``；全局唯一。"""
    title: str
    """给人看的名字，如「qBittorrent」。"""
    factory: Callable[[DownloaderConfig], BaseDownloader]
    url_label: str = "地址"
    """配置表单里地址一栏的叫法，如「WebUI 地址」「RPC 地址」。"""
    url_placeholder: str = ""
    needs_username: bool = True
    """是否要用户名（有的下载器只要密码或令牌）。"""
    help: str = ""


DOWNLOADER_ADAPTERS: RegistryKey[DownloaderAdapter] = RegistryKey(
    "downloader-adapters",
    schema=DownloaderAdapter,
    stability=Stability.EXPERIMENTAL,
    doc="下载器类型：每种下载器一个适配器（提交、查询、删除任务……），新增下载器就登记一个",
)

_bound: Registry[DownloaderAdapter] | None = None


def bind_adapters(registry: Registry[DownloaderAdapter]) -> Callable[[], None]:
    global _bound
    _bound = registry

    def unbind() -> None:
        global _bound
        if _bound is registry:
            _bound = None

    return unbind


def builtin_adapters() -> dict[str, DownloaderAdapter]:
    """随应用提供的两个官方下载器插件里的适配器（没有插件内核时直接用）。"""
    from movieclaw_plugins.qbittorrent.qbittorrent_downloader import ADAPTER as QB
    from movieclaw_plugins.transmission.transmission_downloader import ADAPTER as TR

    return {QB.type: QB, TR.type: TR}


def adapters() -> dict[str, DownloaderAdapter]:
    """当前可用的下载器类型：类型值 → 适配器。"""
    if _bound is None:
        return builtin_adapters()
    return {item.type: item for item in _bound}

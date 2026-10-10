from __future__ import annotations

from movieclaw_downloader.base import BaseDownloader
from movieclaw_downloader.exceptions import DownloaderNotSupportedError
from movieclaw_downloader.models import DownloaderConfig
from movieclaw_downloader.registry import adapters


def create_downloader(config: DownloaderConfig) -> BaseDownloader:
    """按配置创建下载器适配器实例。上层只依赖 BaseDownloader 接口。

    适配器来自插件登记（registry.py）：类型没有对应的适配器（插件没装 / 没在运行）时报不支持。
    """
    adapter = adapters().get(str(config.type))
    if adapter is None:
        raise DownloaderNotSupportedError(str(config.type))
    return adapter.factory(config)

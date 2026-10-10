"""下载服务层的模型校验与工厂函数单元测试。"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from movieclaw_downloader import create_downloader
from movieclaw_downloader.exceptions import DownloaderNotSupportedError
from movieclaw_downloader.models import DownloaderConfig, DownloaderType, DownloadRequest
from movieclaw_plugins.qbittorrent.qbittorrent_downloader.client import QBittorrentDownloader
from movieclaw_plugins.transmission.transmission_downloader.client import TransmissionDownloader


class TestDownloadRequestValidation:
    def test_requires_exactly_one_source_none(self):
        with pytest.raises(ValidationError):
            DownloadRequest()

    def test_requires_exactly_one_source_both(self):
        with pytest.raises(ValidationError):
            DownloadRequest(torrent_bytes=b"data", magnet="magnet:?xt=urn:btih:" + "a" * 40)

    def test_torrent_bytes_only_ok(self):
        request = DownloadRequest(torrent_bytes=b"data")
        assert request.magnet is None
        assert request.paused is False
        assert request.tags == []


class TestFactory:
    def test_creates_qbittorrent(self):
        config = DownloaderConfig(type=DownloaderType.QBITTORRENT, url="http://localhost:8080")
        assert isinstance(create_downloader(config), QBittorrentDownloader)

    def test_creates_transmission(self):
        config = DownloaderConfig(type=DownloaderType.TRANSMISSION, url="http://localhost:9091")
        assert isinstance(create_downloader(config), TransmissionDownloader)

    def test_unknown_type_rejected_by_factory(self):
        """类型是开放的字符串（插件可以登记新的下载器）；没有对应适配器时由工厂拒绝。"""
        config = DownloaderConfig(type="aria2", url="http://localhost:6800")
        with pytest.raises(DownloaderNotSupportedError):
            create_downloader(config)

from __future__ import annotations

from typing import Any


class DownloaderException(Exception):
    """所有下载器模块异常的基类。"""

    def __init__(
        self,
        message: str = "downloader operation failed",
        *,
        details: dict[str, Any] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.details = details
        self.message_key = message_key
        self.params = params or {}

    @property
    def message_ref(self) -> dict | None:
        if not self.message_key:
            return None
        return {"message": self.message, "message_key": self.message_key, "params": self.params}


class DownloaderConnectError(DownloaderException):
    """无法连接到下载器（地址错误、服务未启动、网络不通等）。"""

    def __init__(
        self,
        message: str | None = None,
        *,
        details: dict[str, Any] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        if message is None:
            message = "无法连接到下载器，请检查地址和端口"
            message_key = message_key or "errors.downloader.connectDefault"
        super().__init__(message, details=details, message_key=message_key, params=params)


class DownloaderAuthError(DownloaderException):
    """下载器认证失败（用户名或密码错误、IP 被封禁等）。"""

    def __init__(
        self,
        message: str | None = None,
        *,
        details: dict[str, Any] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        if message is None:
            message = "下载器认证失败，请检查用户名和密码"
            message_key = message_key or "errors.downloader.authDefault"
        super().__init__(message, details=details, message_key=message_key, params=params)


class DownloaderSubmitError(DownloaderException):
    """提交下载任务失败（种子文件无效、下载器拒绝等）。"""

    def __init__(
        self,
        message: str | None = None,
        *,
        details: dict[str, Any] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        if message is None:
            message = "提交下载任务失败"
            message_key = message_key or "errors.downloader.submitDefault"
        super().__init__(message, details=details, message_key=message_key, params=params)


class DownloaderDeleteError(DownloaderException):
    """删除下载任务失败（下载器拒绝操作或返回未知错误）。"""

    def __init__(
        self,
        message: str | None = None,
        *,
        details: dict[str, Any] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        if message is None:
            message = "删除下载任务失败"
            message_key = message_key or "errors.downloader.deleteDefault"
        super().__init__(message, details=details, message_key=message_key, params=params)


class TorrentParseError(DownloaderException):
    """种子文件或磁力链接解析失败（内容不是合法的 bencode / magnet 格式）。"""

    def __init__(
        self,
        message: str | None = None,
        *,
        details: dict[str, Any] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        if message is None:
            message = "种子内容解析失败"
            message_key = message_key or "errors.downloader.parseTorrent"
        super().__init__(message, details=details, message_key=message_key, params=params)


class DownloaderNotSupportedError(DownloaderException):
    """请求的下载器类型尚未适配。"""

    def __init__(
        self,
        downloader_type: str,
        *,
        details: dict[str, Any] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            f"下载器类型 '{downloader_type}' 尚未支持",
            details=details,
            message_key=message_key or "errors.downloader.unsupported",
            params=params or {"type": downloader_type},
        )
        self.downloader_type = downloader_type

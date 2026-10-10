"""独立进程里的下载器适配器在宿主这边的代理（docs/design/downloader-adapters.md §4）。

宿主按下载器配置调 ``factory(config)`` 拿到一个 ``RemoteDownloader``；它的每个方法都经协议
转给插件进程，插件进程按连接配置缓存适配器实例（登录态、会话复用），结果与下载器异常原样带回来。
"""

from __future__ import annotations

import contextlib
from typing import Any

from movieclaw_downloader.base import BaseDownloader
from movieclaw_downloader.exceptions import DownloaderConnectError
from movieclaw_downloader.models import (
    DownloaderConfig,
    DownloaderInfo,
    DownloaderLimits,
    DownloadRequest,
    SubmitResult,
    TorrentBrief,
    TorrentStatus,
)
from movieclaw_sdk.downloaders import raise_remote, request_dict

#: 单次调用的上限（秒）：下载器慢的时候（大列表、远程挂载）也给够时间
CALL_TIMEOUT = 60.0


class RemoteDownloader(BaseDownloader):
    def __init__(self, session: Any, cid: str, config: DownloaderConfig) -> None:
        super().__init__(config)
        self._session = session
        self._cid = cid

    async def _call(self, method: str, **args: Any) -> Any:
        from movieclaw_api.services.plugin_runtime import PluginProcessGone, RemoteCallError

        payload = {"config": self.config.model_dump(mode="json"), "method": method, "args": args}
        try:
            return await self._session.call(
                self._cid, payload, timeout=CALL_TIMEOUT, kind="downloader"
            )
        except PluginProcessGone as exc:
            raise DownloaderConnectError(
                f"下载器插件 {self._session.entry_id} 没在运行，稍后会自动重试"
            ) from exc
        except RemoteCallError as exc:
            raise_remote(exc.kind, exc.detail)
            raise

    async def submit(self, request: DownloadRequest) -> SubmitResult:
        return SubmitResult.model_validate(
            await self._call("submit", request=request_dict(request))
        )

    async def get_torrent(
        self, info_hash: str, *, include_files: bool = True
    ) -> TorrentStatus | None:
        data = await self._call("get_torrent", info_hash=info_hash, include_files=include_files)
        return None if data is None else TorrentStatus.model_validate(data)

    async def list_torrents(self) -> list[TorrentBrief]:
        return [TorrentBrief.model_validate(x) for x in await self._call("list_torrents")]

    async def delete_torrent(self, info_hash: str, *, delete_files: bool = False) -> None:
        await self._call("delete_torrent", info_hash=info_hash, delete_files=delete_files)

    async def set_location(self, info_hash: str, save_path: str) -> None:
        await self._call("set_location", info_hash=info_hash, save_path=save_path)

    async def set_file_selection(self, info_hash: str, selected_indices: list[int]) -> None:
        await self._call(
            "set_file_selection", info_hash=info_hash, selected_indices=selected_indices
        )

    async def resume(self, info_hash: str) -> None:
        await self._call("resume", info_hash=info_hash)

    async def get_limits(self) -> DownloaderLimits:
        return DownloaderLimits.model_validate(await self._call("get_limits"))

    async def set_limits(self, limits: DownloaderLimits) -> None:
        await self._call("set_limits", limits=limits.model_dump(mode="json"))

    async def transfer_speeds(self) -> tuple[int, int]:
        down, up = await self._call("transfer_speeds")
        return int(down), int(up)

    async def set_download_limits(self, info_hashes: list[str], limit_bytes: int | None) -> None:
        await self._call("set_download_limits", info_hashes=info_hashes, limit_bytes=limit_bytes)

    async def set_upload_limits(self, info_hashes: list[str], limit_bytes: int | None) -> None:
        await self._call("set_upload_limits", info_hashes=info_hashes, limit_bytes=limit_bytes)

    async def test_connection(self) -> DownloaderInfo:
        return DownloaderInfo.model_validate(await self._call("test_connection"))

    async def close(self) -> None:
        # 插件进程已经不在：没有要关的连接
        with contextlib.suppress(DownloaderConnectError):
            await self._call("close")

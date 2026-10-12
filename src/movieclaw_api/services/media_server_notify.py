"""媒体库内容变了就通知媒体服务器刷新（媒体库 L4，可选）。

配置 MEDIA_SERVER_URL / MEDIA_SERVER_TYPE / MEDIA_SERVER_TOKEN 后，库里新入账了文件、
删了文件、回收站进出、条目转移，都触发库刷新，新内容即刻出现在 Emby/Jellyfin 里（两者同源，
刷新接口一致：POST /Library/Refresh，X-Emby-Token 鉴权）。

谁来触发：内置插件 ``library.media-server-refresh`` 订阅这些系统事件（domain-events.md §6.4），
一阵子的变化合成一次刷新——扫描、批量转移、整季删除都不会对下游发一串全库扫描。没配置时不订阅。

失败语义：通知是锦上添花，任何失败只记中文告警，绝不影响业务结果。
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable, Coroutine
from typing import Any

import httpx

from movieclaw_api.core.config import get_settings
from movieclaw_net import EgressScope, egress_transport

logger = logging.getLogger("movieclaw_api.media_server_notify")

_SUPPORTED = {"emby", "jellyfin"}

#: 内容一阵子没有新变化才刷新；一直在变（大扫描、批量转移）最多等这么久也刷一次
QUIET_S = 10.0
MAX_WAIT_S = 120.0


def configured() -> bool:
    return bool(get_settings().media_server_url.strip())


def triggers() -> list[Any]:
    """会让下游库内容变化的系统事件。"""
    from movieclaw_sdk.events import (
        LIBRARY_FILE_DELETED,
        LIBRARY_FILE_PURGED,
        LIBRARY_FILE_RESTORED,
        LIBRARY_FILE_TRASHED,
        LIBRARY_FILES_ADDED,
        LIBRARY_ITEM_DELETED,
        LIBRARY_ITEM_MOVED,
    )

    return [
        LIBRARY_FILES_ADDED,
        LIBRARY_ITEM_DELETED,
        LIBRARY_FILE_DELETED,
        LIBRARY_FILE_TRASHED,
        LIBRARY_FILE_RESTORED,
        LIBRARY_FILE_PURGED,
        LIBRARY_ITEM_MOVED,
    ]


Spawn = Callable[[Coroutine[Any, Any, Any]], Any]


class Refresher:
    """把一阵子的库变化合成一次刷新：安静 ``QUIET_S`` 秒，或从第一次变化起满 ``MAX_WAIT_S`` 秒。"""

    def __init__(self, spawn: Spawn) -> None:
        self._spawn = spawn
        self._timer: asyncio.TimerHandle | None = None
        self._first: float | None = None

    def poke(self, _payload: object = None) -> None:
        loop = asyncio.get_running_loop()
        now = loop.time()
        if self._first is None:
            self._first = now
        if self._timer is not None:
            self._timer.cancel()
        due = min(now + QUIET_S, self._first + MAX_WAIT_S)
        self._timer = loop.call_later(max(0.0, due - now), self._fire)

    def _fire(self) -> None:
        self._timer = None
        self._first = None
        self._spawn(notify_media_server_refresh())

    def close(self) -> None:
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None


async def notify_media_server_refresh() -> bool:
    """触发媒体服务器库刷新；未配置返回 False，通知成功返回 True。"""
    settings = get_settings()
    url = settings.media_server_url.strip().rstrip("/")
    if not url:
        return False
    server_type = settings.media_server_type.strip().lower()
    if server_type not in _SUPPORTED:
        logger.warning(
            "不支持的媒体服务器类型：%s（支持 emby / jellyfin），已跳过通知",
            settings.media_server_type,
        )
        return False
    try:
        # LAN 范围：媒体服务器在内网，任何代理配置下都必须直连
        transport = egress_transport("media_server", scope=EgressScope.LAN)
        async with httpx.AsyncClient(timeout=10.0, transport=transport) as client:
            response = await client.post(
                f"{url}/Library/Refresh",
                headers={"X-Emby-Token": settings.media_server_token},
            )
        response.raise_for_status()
    except Exception as exc:  # noqa: BLE001 -- 通知失败绝不影响入库
        logger.warning("通知媒体服务器刷新失败（不影响入库）：%s（%s）", url, exc)
        return False
    logger.info("已通知 %s 刷新媒体库：%s", server_type, url)
    return True

"""网盘挂载直链（docs/design/strm-playback.md §10）。

strm 指向服务器挂载目录里的文件（CloudDrive2 / rclone 挂载）时，默认由服务器读挂载、再出字节给
播放器——视频流量经过服务器两遍。插件经钩子 ``playback.strm.direct-link`` 认领这类文件、给出网盘
直链，播放器就被 302 过去，服务器零流量。

只改「播放器去哪取」：服务器自己读字节（首播探测、换封装转码、字幕、缩略图）照旧读挂载。
插件没认领、出错、超时，或给的地址播放器连不上，一律照旧出字节，播放不受插件影响。
"""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path
from urllib.parse import urlsplit

from movieclaw_api import hooks
from movieclaw_playback.streaming import StrmLink, strm_redirect_target

logger = logging.getLogger(__name__)

#: 没认领 / 给不出可用地址的结论记多久：播放器拖一次进度就是几条 Range 请求，不该每条都再问一遍
_MISS_TTL_S = 60.0
#: 插件给的复用时长上限
_MAX_TTL_S = 3600.0
_CACHE_MAX = 256
_cache: dict[tuple[str, str | None], tuple[float, str | None]] = {}
_inflight: dict[tuple[str, str | None], asyncio.Task[tuple[str | None, float]]] = {}


async def mounted_redirect(file_id: int, target: Path, user_agent: str | None) -> str | None:
    """把播放器 302 到哪；None 表示照旧由服务器出挂载里的字节。没有插件监听时不做任何事。"""
    if not hooks.active(hooks.STRM_DIRECT_LINK):
        return None
    key = (str(target), user_agent)
    cached = _cache.get(key)
    if cached is not None and cached[0] > time.monotonic():
        return cached[1]
    # 播放器起播常同时开几路连接：同一文件同一 UA 只问一次插件（网盘取直链接口多有风控）
    task = _inflight.get(key)
    if task is None:
        task = asyncio.create_task(_ask(file_id, target, user_agent))
        _inflight[key] = task
        task.add_done_callback(lambda _t: _inflight.pop(key, None))
    url, ttl = await asyncio.shield(task)
    if len(_cache) >= _CACHE_MAX:
        _cache.clear()
    _cache[key] = (time.monotonic() + ttl, url)
    return url


async def _ask(file_id: int, target: Path, user_agent: str | None) -> tuple[str | None, float]:
    link = await hooks.bail(
        hooks.STRM_DIRECT_LINK,
        hooks.MountedFile(file_id=file_id, path=str(target), user_agent=user_agent),
    )
    if link is None:
        return None, _MISS_TTL_S
    if urlsplit(link.url).scheme.lower() not in {"http", "https"}:
        logger.warning("插件给的直链不是 http(s) 地址，照旧由服务器出字节：%s", target)
        return None, _MISS_TTL_S
    # 内网 302 服务（alist /d/…）由服务器带着播放器的 UA 替它跟跳转，与 strm 里写内网地址同一套
    url = await strm_redirect_target(StrmLink(url=link.url), user_agent)
    if url is None:
        logger.warning(
            "插件给的直链播放器连不上（跟跳转也落不到外网），照旧由服务器出字节：%s", link.url
        )
        return None, _MISS_TTL_S
    logger.info("网盘挂载文件改由插件给的直链播放：%s", target)
    return url, min(max(float(link.ttl_s), 0.0), _MAX_TTL_S)

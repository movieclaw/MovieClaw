"""家里的上行在不在被外网播放用着（docs/design/cloud-storage.md §5.3）。

外网设备取流（直出、转码分片、网盘转发）时记一下时间；后台上传每传一片前看一眼，外网有人在看就先停，
最后一次外网取流过去 30 秒再接着传。只记一个时间戳：不采样、不碰盘。
"""

from __future__ import annotations

import time

#: 外网取流停了多久才算让完路
QUIET_S = 30.0

_last_outside = 0.0


def note(client_host: str | None) -> None:
    """一次取流请求：来自外网就记下时间。没有网盘后端时什么都不做（cloud-storage.md §11.8）。"""
    from movieclaw_api.services.drives.registry import active
    from movieclaw_api.services.drives.sources import is_home_client

    global _last_outside
    if active() and not is_home_client(client_host):
        _last_outside = time.monotonic()


def busy() -> bool:
    """外网有人正在看（上传该让路）。"""
    return _last_outside > 0 and time.monotonic() - _last_outside < QUIET_S


def reset_state() -> None:
    global _last_outside
    _last_outside = 0.0

"""上报客户端信息（协议无关的值对象）。

协议层（Jellyfin 的 ``RequestIdentity``、网页的 User-Agent）各自翻译成 ``ClientInfo``，播放活动、
观看事件（``movieclaw_api.services.playback.events``）都用它。
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ClientInfo:
    """上报客户端信息（协议无关的值对象）。"""

    name: str = ""
    device_name: str = ""
    device_id: str = ""
    version: str = ""

    def payload(self) -> dict:
        return {
            "name": self.name or None,
            "device_name": self.device_name or None,
            "device_id": self.device_id or None,
            "version": self.version or None,
        }

"""账号域事件。"""

from __future__ import annotations

from movieclaw_sdk.events._base import Frozen, define


class DeviceSignedIn(Frozen):
    """一台设备登录了某个账号（App、电视、命令行、转码器、网页、第三方播放器）。"""

    member_id: int
    """账号：成员 id，超管为 0。"""
    device_id: int | None
    """登录设备记录；第三方播放器（Jellyfin 协议）为 ``None``。"""
    device_name: str
    kind: str
    """``app`` / ``tv`` / ``cli`` / ``transcoder`` / ``web`` / ``player`` …"""
    kind_label: str
    ip: str | None = None
    approver_device_id: int | None = None
    """在哪台已登录的设备上批准了这次配对（扫码登录）。"""
    new_device: bool
    """第一次在这台设备登录；同一台换凭证、之前自己退出又登回来、网页登录都不算。"""


ACCOUNT_DEVICE_SIGNED_IN = define(
    "account.device.signed_in",
    DeviceSignedIn,
    title="设备登录",
    group="账号",
    doc="一台设备登录了账号",
    sensitive=True,
)

"""服务器主机密钥（docs/design/server-addresses.md §3.3）。

App 在家试内网地址时，先用匿名的 ``/health?nonce=`` 问一句「你是谁」，验过签名才带登录凭据：
酒店 Wi-Fi 里恰好也有一台 ``192.168.1.10``、还冒充了我们的实例号（实例号不保密）时，令牌不会
发过去。Ed25519 一对密钥，首次用到时生成，私钥加密落库，永不轮换——重装即换，相当于换了一台
服务器。
"""

from __future__ import annotations

import asyncio
import base64
import re

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from pydantic import Field

from movieclaw_api.settings import get_setting_store
from movieclaw_api.settings.base import SettingSchema, register_setting

#: 客户端随机串：base64url，16~128 个字符
NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{16,128}$")


@register_setting(
    namespace="app.server.host_key", title="服务器主机密钥", secret_fields=["private_key"]
)
class HostKeySetting(SettingSchema):
    private_key: str = Field(
        default="", description="Ed25519 私钥（base64 原始 32 字节）；空表示尚未生成"
    )


_cached: Ed25519PrivateKey | None = None
_lock = asyncio.Lock()


async def _private_key() -> Ed25519PrivateKey:
    global _cached
    if _cached is not None:
        return _cached
    async with _lock:  # 首次并发：只生成一把
        if _cached is not None:
            return _cached
        store = get_setting_store()
        setting = await store.get(HostKeySetting)
        if setting.private_key:
            key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(setting.private_key))
        else:
            key = Ed25519PrivateKey.generate()
            raw = key.private_bytes(
                serialization.Encoding.Raw,
                serialization.PrivateFormat.Raw,
                serialization.NoEncryption(),
            )
            await store.set(HostKeySetting(private_key=base64.b64encode(raw).decode()))
        _cached = key
        return key


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


async def public_key() -> str:
    """公钥：base64url（无填充）的 32 字节原始公钥。"""
    raw = (
        (await _private_key())
        .public_key()
        .public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    )
    return _b64url(raw)


def proof_message(instance_id: str, nonce: str) -> bytes:
    return f"movieclaw-health\n{instance_id}\n{nonce}".encode()


async def prove(instance_id: str, nonce: str) -> str:
    """对 ``proof_message`` 的签名：base64url（无填充）。"""
    return _b64url((await _private_key()).sign(proof_message(instance_id, nonce)))


def reset_state() -> None:
    global _cached, _lock
    _cached = None
    _lock = asyncio.Lock()


__all__ = ["NONCE_PATTERN", "HostKeySetting", "proof_message", "prove", "public_key", "reset_state"]

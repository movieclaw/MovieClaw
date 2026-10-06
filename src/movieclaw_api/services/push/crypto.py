"""推送密文与 collapse_id（docs/design/push-payload.md）。

推送内容端到端加密：实例用每台设备自己的密钥加密，中继和苹果只看得到密文。

格式 ``v1.<key_id>.<nonce>.<密文>``：

- AES-256-GCM，nonce 12 字节随机数，密文带 16 字节认证标签；
- 附加认证数据是 ``v1.<key_id>``，防止把一段密文挪到别的 key_id 下；
- 各段都是不带填充的 base64url，整串只有 base64url 字符和点，满足中继对 payload 的检查。

App（CryptoKit）和这里用同一组测试向量（push-payload.md §7）做单元测试，两边逐字节一致。
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import re

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

FORMAT_VERSION = "v1"
KEY_BYTES = 32
NONCE_BYTES = 12

#: key_id 是 8 字节随机数的 base64url，正好 11 个字符
KEY_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{11}$")

#: alert 明文的字节上限（push-payload.md §4）：最终交给苹果的 JSON 不能超过 4096 字节，
#: 通用文案、aps 字段、格式头约 200 字节，密文按 base64 膨胀 4/3 再加认证标签，
#: 按 2200 字节控制留足余量
MAX_ALERT_PLAINTEXT_BYTES = 2200


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text: str) -> bytes:
    """解码不带填充的 base64url；格式不对抛 ValueError。"""
    if not re.fullmatch(r"[A-Za-z0-9_-]*", text):
        raise ValueError("不是 base64url")
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except binascii.Error as exc:
        raise ValueError("不是 base64url") from exc


def decode_key(text: str) -> bytes:
    """App 交上来的密钥：32 字节的 base64url。"""
    key = b64url_decode(text)
    if len(key) != KEY_BYTES:
        raise ValueError("密钥必须是 32 字节")
    return key


def _aad(key_id: str) -> bytes:
    return f"{FORMAT_VERSION}.{key_id}".encode("ascii")


def seal(plaintext: bytes, *, key: bytes, key_id: str, nonce: bytes | None = None) -> str:
    """加密一条推送明文，返回 ``v1.<key_id>.<nonce>.<密文>``。

    ``nonce`` 只给测试向量用；正常调用每条推送都取新的随机数，同一把密钥下绝不重复。
    """
    if not KEY_ID_PATTERN.fullmatch(key_id):
        raise ValueError("key_id 格式不对")
    nonce = nonce if nonce is not None else os.urandom(NONCE_BYTES)
    if len(nonce) != NONCE_BYTES:
        raise ValueError("nonce 必须是 12 字节")
    sealed = AESGCM(key).encrypt(nonce, plaintext, _aad(key_id))
    return f"{FORMAT_VERSION}.{key_id}.{b64url(nonce)}.{b64url(sealed)}"


def open_sealed(payload: str, *, key: bytes) -> bytes:
    """解密（实例自己用不到，测试和排查用）。认证失败抛 ``cryptography`` 的异常。"""
    version, key_id, nonce, sealed = payload.split(".")
    if version != FORMAT_VERSION:
        raise ValueError(f"不认识的格式版本：{version}")
    return AESGCM(key).decrypt(b64url_decode(nonce), b64url_decode(sealed), _aad(key_id))


def encode_plaintext(message: dict) -> bytes:
    """明文是紧凑的 UTF-8 JSON（不转义中文，省字节）。"""
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def fit_alert(message: dict) -> bytes:
    """编码 alert 明文；超过上限时先去掉集数格子，再截短 ``body``，还超就再截 ``title``。"""
    data = encode_plaintext(message)
    if len(data) <= MAX_ALERT_PLAINTEXT_BYTES:
        return data
    trimmed = dict(message)
    # 集数格子只是长按时的点缀，不能为它截掉正文
    if trimmed.pop("grid", None) is not None:
        data = encode_plaintext(trimmed)
        if len(data) <= MAX_ALERT_PLAINTEXT_BYTES:
            return data
    for field in ("body", "subtitle", "title"):
        text = str(trimmed.get(field) or "")
        while text and len(data) > MAX_ALERT_PLAINTEXT_BYTES:
            # 按超出的字节数估算要砍掉的字数（中文一个字 3 字节），至少砍一个
            overflow = len(data) - MAX_ALERT_PLAINTEXT_BYTES
            text = text[: max(0, len(text) - max(1, overflow // 3 + 1))]
            trimmed[field] = text.rstrip() + "…"
            data = encode_plaintext(trimmed)
        if len(data) <= MAX_ALERT_PLAINTEXT_BYTES:
            return data
    # 标题正文都砍光还超（图片路径或服务器名异常长）：去掉配图
    trimmed.pop("image", None)
    return encode_plaintext(trimmed)


def new_collapse_key() -> str:
    """实例本地的 collapse_key：32 字节随机数，第一次用时生成并加密存储。"""
    return b64url(os.urandom(KEY_BYTES))


def collapse_id(collapse_key: bytes, object_type: str, object_id: str) -> str:
    """同一个「事件对象」的推送用同一个 collapse_id，手机上只留最新一条。

    collapse_id 对中继和苹果可见，所以是本地密钥对对象做 HMAC 后截短的不透明值，
    不能直接写订阅 ID、片名之类的值（push-payload.md §5）。
    """
    digest = hmac.new(collapse_key, f"{object_type}:{object_id}".encode(), hashlib.sha256).digest()
    return b64url(digest)[:16]

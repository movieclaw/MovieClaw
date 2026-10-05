"""推送密文的测试向量（docs/design/push-payload.md §7）。

App 端（CryptoKit）用同一组向量：两边加密结果逐字节一致，解密能还原明文。
"""

from __future__ import annotations

import json

import pytest
from cryptography.exceptions import InvalidTag

from movieclaw_api.services.push import crypto

_KEY = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
_KEY_ID = "k7Qm2xP9Hn4"
_NONCE = bytes.fromhex("000102030405060708090a0b")
_PLAINTEXT = (
    '{"v":1,"type":"alert","title":"流浪地球 2 已入库","body":"4K · HDR · 已添加到「电影」",'
    '"image":"/api/push/images/abc123","open":"movieclaw://library/items/123",'
    '"thread":"library","category":"library.added","sound":"default",'
    '"server":{"id":"s1","name":"客厅 NAS"},"account":{"id":"u7","name":"爸爸"},'
    '"sent_at":1767225600}'
).encode()
_PAYLOAD = (
    "v1.k7Qm2xP9Hn4.AAECAwQFBgcICQoL.PCCgOf_U7jn5OOfuk9NaDO-z9UDSV30IUROJ4D9TIlS0kUhJBSSOKJM0"
    "_M26p82PXLzlKL9sMPgTtUh2fJrX1NIIjVoRZgYpWAaKrFiv61-KbH7Zk-nzjXVNfUz0Fy04LkXoBSTM6ja8dVPTL"
    "xADRZhIA9uK6lXvPpd4pO-HCWvIfWGk1-b5YCrNas5NvyLgDNaOWkN49ingPp9N1f2Fh_Hl_2eQ0KUKwg6u1e6ytZ"
    "mx7L5K-c4S2Efl4qsYp8WSYTWo1i--t71SMbyUw2Pjpo0XmgRccsPfEPX-oiVqo9gwTKHBggI5BzYi3mnAfQhzhLHK"
    "EO9G7Nc1URxR4vhguzaiw7Kx-CZfGrpQPZXIlKg_Ok_tzsrSjQwDTzBpl9U-b3f8csHnp3OwBhgvPbeM8farNjtrr"
    "u3wEIn6ni8fOMXr5hpE_z8ZnYHaShdr5C9QpizntOFhYLyzgC4ieMqlItk-6ARo"
)


def test_seal_matches_vector() -> None:
    assert len(_PLAINTEXT) == 341
    assert crypto.seal(_PLAINTEXT, key=_KEY, key_id=_KEY_ID, nonce=_NONCE) == _PAYLOAD


def test_open_vector() -> None:
    assert crypto.open_sealed(_PAYLOAD, key=_KEY) == _PLAINTEXT


def test_aad_binds_key_id() -> None:
    """把密文挪到别的 key_id 下解不开。"""
    moved = _PAYLOAD.replace(_KEY_ID, "AAAAAAAAAAA", 1)
    with pytest.raises(InvalidTag):
        crypto.open_sealed(moved, key=_KEY)


def test_random_nonce_and_charset() -> None:
    first = crypto.seal(b"{}", key=_KEY, key_id=_KEY_ID)
    second = crypto.seal(b"{}", key=_KEY, key_id=_KEY_ID)
    assert first != second
    # 中继只接受 base64url 字符和点
    assert set(first) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")


def test_collapse_id_vector() -> None:
    key = bytes.fromhex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
    assert crypto.collapse_id(key, "subscription", "42") == "QuH-0hNhmLQa5h0c"


def test_decode_key_rejects_wrong_length() -> None:
    assert crypto.decode_key(crypto.b64url(_KEY)) == _KEY
    with pytest.raises(ValueError):
        crypto.decode_key(crypto.b64url(_KEY[:16]))
    with pytest.raises(ValueError):
        crypto.decode_key("不是base64")


def test_fit_alert_truncates_body_first() -> None:
    message = {"v": 1, "type": "alert", "title": "标题", "body": "长" * 2000, "sent_at": 1}
    data = crypto.fit_alert(message)
    assert len(data) <= crypto.MAX_ALERT_PLAINTEXT_BYTES
    decoded = json.loads(data)
    assert decoded["title"] == "标题"
    assert decoded["body"].endswith("…")


def test_fit_alert_keeps_short_message_intact() -> None:
    message = {"v": 1, "type": "alert", "title": "标题", "body": "正文"}
    assert crypto.fit_alert(message) == crypto.encode_plaintext(message)

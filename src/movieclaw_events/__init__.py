"""事件 id：ULID（时间有序 + 全局唯一，消费方按它去重）。

叶子包，不依赖任何协议包与服务层。自实现约 20 行，免得引入 ``python-ulid`` 依赖触发
runtime-version bump。事件的定义与产生见 ``movieclaw_sdk.events``、``movieclaw_api.events``。
"""

from __future__ import annotations

import os
import time

# Crockford Base32 字母表（ULID 规范：去掉易混淆的 I/L/O/U）
_B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def new_ulid() -> str:
    """生成一个 26 字符 ULID：48 位毫秒时间戳 + 80 位随机数。

    同毫秒内不保证单调递增（本场景事件量级用不到），跨毫秒天然按时间排序。
    """
    value = (int(time.time() * 1000) & (2**48 - 1)) << 80
    value |= int.from_bytes(os.urandom(10), "big")
    chars = []
    for shift in range(125, -1, -5):
        chars.append(_B32[(value >> shift) & 0x1F])
    return "".join(chars)


__all__ = ["new_ulid"]

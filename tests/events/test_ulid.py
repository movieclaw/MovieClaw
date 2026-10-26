"""事件 id（ULID）单测。"""

from __future__ import annotations

import time

from movieclaw_events import new_ulid

_B32 = set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")


def test_ulid_format():
    ulid = new_ulid()
    assert len(ulid) == 26
    assert set(ulid) <= _B32


def test_ulid_unique_and_time_ordered():
    first = new_ulid()
    time.sleep(0.002)  # 跨毫秒后按字典序递增（时间戳在高位）
    second = new_ulid()
    assert first != second
    assert first < second


def test_ulid_bulk_unique():
    ids = {new_ulid() for _ in range(1000)}
    assert len(ids) == 1000


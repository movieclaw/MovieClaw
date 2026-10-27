"""行值批量匹配 ``(a, b, c) IN ((…), (…))`` 的可走索引写法。

镜像里的 SQLite 是 Debian bookworm 的 3.40.1：它对行值 IN 不用复合索引，整表扫描
（NAS 实测 media_episode 7 个三元组 10 ms、library_file 16 ms；本机 3.54 走索引
只要 0.06 ms，开发时看不出来）。补一条首列 ``a IN (…)``，老版本即可按首列索引
查找、再逐行核对行值；新版本照样走复合索引，结果完全相同。
"""

from __future__ import annotations

from collections.abc import Collection, Sequence
from typing import Any

from sqlalchemy import and_, tuple_
from sqlalchemy.sql.elements import ColumnElement


def tuple_in(columns: Sequence[Any], values: Collection[Sequence[Any]]) -> ColumnElement[bool]:
    """``columns`` 组成的行值落在 ``values`` 里。首列须有索引（或为复合索引的首列）。"""
    rows = list(values)
    return and_(columns[0].in_({row[0] for row in rows}), tuple_(*columns).in_(rows))


__all__ = ["tuple_in"]

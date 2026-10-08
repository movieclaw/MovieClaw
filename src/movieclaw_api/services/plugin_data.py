"""插件数据服务 ``PLUGIN_DATA``（docs/design/plugin-phase2b.md §4）。

::

    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    await store.set("keywords", ["国语"], scope="subscription:35")       # 实体扩展字段
    await store.set("token", "…", secret=True)                           # 加密存放
    rules = await store.get("keywords", scope="subscription:35", default=[])

插件只能读写自己条目 id 下的数据；作用域是 ``global`` 或「实体:id」。值须能 JSON 序列化，
单个值不超过 64 KB（大东西放文件，这里存引用）。
"""

from __future__ import annotations

import json
import re
from typing import Any

from sqlalchemy import delete, func, select

from movieclaw_db.engine import Database
from movieclaw_db.models import PluginData, utcnow

GLOBAL = "global"
MAX_VALUE_BYTES = 64 * 1024
_SCOPE = re.compile(r"^(global|[a-z_]+:[A-Za-z0-9_.\-]{1,100})$")


def _check(scope: str, key: str) -> None:
    if not _SCOPE.match(scope):
        raise ValueError(f"作用域须是 global 或「实体:id」（如 subscription:35）：{scope!r}")
    if not key or len(key) > 200:
        raise ValueError("键不能为空，且不超过 200 个字符")


def entity_scope(entity: str, entity_id: int | str) -> str:
    """``entity_scope("subscription", 35)`` → ``subscription:35``。"""
    return f"{entity}:{entity_id}"


class PluginStore:
    """一个插件条目自己的数据。"""

    def __init__(self, db: Database, entry_id: str) -> None:
        self._db = db
        self.entry_id = entry_id

    async def get(self, key: str, *, scope: str = GLOBAL, default: Any = None) -> Any:
        _check(scope, key)
        async with self._db.session() as session:
            row = await session.scalar(self._query(scope, key))
        if row is None:
            return default
        return _decode(row)

    async def set(self, key: str, value: Any, *, scope: str = GLOBAL, secret: bool = False) -> None:
        _check(scope, key)
        text = json.dumps(value, ensure_ascii=False)
        if len(text.encode("utf-8")) > MAX_VALUE_BYTES:
            raise ValueError(f"值超过 {MAX_VALUE_BYTES // 1024} KB，请存文件、这里存引用")
        stored: Any = value
        if secret:
            from movieclaw_db.crypto import get_secret_box

            stored = {"enc": get_secret_box().encrypt(text)}
        async with self._db.session() as session:
            row = await session.scalar(self._query(scope, key))
            if row is None:
                session.add(
                    PluginData(
                        entry_id=self.entry_id, scope=scope, key=key, value=stored, secret=secret
                    )
                )
            else:
                row.value = stored
                row.secret = secret
                row.updated_at = utcnow()
            await session.commit()

    async def delete(self, key: str, *, scope: str = GLOBAL) -> bool:
        _check(scope, key)
        async with self._db.session() as session:
            result = await session.execute(
                delete(PluginData).where(
                    PluginData.entry_id == self.entry_id,
                    PluginData.scope == scope,
                    PluginData.key == key,
                )
            )
            await session.commit()
        return bool(result.rowcount)

    async def items(self, *, scope: str = GLOBAL) -> dict[str, Any]:
        """某个作用域下的全部键值。"""
        _check(scope, "*")
        async with self._db.session() as session:
            rows = (
                await session.execute(
                    select(PluginData).where(
                        PluginData.entry_id == self.entry_id, PluginData.scope == scope
                    )
                )
            ).scalars()
            return {row.key: _decode(row) for row in rows}

    async def scopes(self, key: str, *, entity: str | None = None) -> dict[str, Any]:
        """某个键在各作用域下的值，例如「哪些订阅设置了关键字规则」。"""
        async with self._db.session() as session:
            query = select(PluginData).where(
                PluginData.entry_id == self.entry_id, PluginData.key == key
            )
            if entity is not None:
                query = query.where(PluginData.scope.startswith(f"{entity}:"))  # type: ignore[union-attr]
            rows = (await session.execute(query)).scalars()
            return {row.scope: _decode(row) for row in rows}

    def _query(self, scope: str, key: str):
        return select(PluginData).where(
            PluginData.entry_id == self.entry_id,
            PluginData.scope == scope,
            PluginData.key == key,
        )


def _decode(row: PluginData) -> Any:
    if not row.secret:
        return row.value
    from movieclaw_db.crypto import get_secret_box

    return json.loads(get_secret_box().decrypt(row.value["enc"]))


class PluginDataService:
    """``PLUGIN_DATA`` 的实现：按条目发作用域受限的存储。"""

    def __init__(self, db: Database) -> None:
        self._db = db

    def scoped(self, ctx: Any) -> PluginStore:
        return PluginStore(self._db, ctx.entry_id)

    async def counts(self) -> dict[str, int]:
        """每个插件条目存了多少行（诊断用）。"""
        async with self._db.session() as session:
            rows = await session.execute(
                select(PluginData.entry_id, func.count()).group_by(PluginData.entry_id)
            )
            return {entry: count for entry, count in rows.all()}

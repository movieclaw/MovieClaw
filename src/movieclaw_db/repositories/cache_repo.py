from __future__ import annotations

from datetime import datetime

from sqlalchemy import delete
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models.base import utcnow
from movieclaw_db.models.cache_entry import CacheEntry


class CacheRepository:
    """通用持久缓存表（``cache_entry``）的数据访问层。

    职责边界：只做「(namespace, key) 存取一段 JSON 文本」的原始读写，
    不理解 payload 内容、不做 TTL 判断——过期语义在 ``movieclaw_cache.SwrCache``。
    """

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, namespace: str, key: str) -> CacheEntry | None:
        """读取一条缓存记录；不存在返回 None。"""
        result = await self._session.execute(
            select(CacheEntry).where(CacheEntry.namespace == namespace, CacheEntry.cache_key == key)
        )
        return result.scalar_one_or_none()

    async def upsert(self, namespace: str, key: str, payload: str) -> None:
        """新增或整体覆盖一条缓存记录，并把 fetched_at 刷新为当前时间。"""
        row = await self.get(namespace, key)
        if row is None:
            row = CacheEntry(namespace=namespace, cache_key=key, payload=payload)
            self._session.add(row)
        else:
            row.payload = payload
            row.fetched_at = utcnow()
        await self._session.commit()

    async def get_many(self, namespace: str, keys: list[str]) -> dict[str, str]:
        """批量读取：key → payload，不存在的 key 不出现在结果里。"""
        found: dict[str, str] = {}
        # 分块：SQLite 单条语句的参数上限是 999（老版本）
        for start in range(0, len(keys), 900):
            result = await self._session.execute(
                select(CacheEntry.cache_key, CacheEntry.payload).where(
                    CacheEntry.namespace == namespace,
                    CacheEntry.cache_key.in_(keys[start : start + 900]),  # type: ignore[attr-defined]
                )
            )
            found.update(result.tuples().all())
        return found

    async def put_many(self, namespace: str, items: dict[str, str]) -> None:
        """批量新增或覆盖，一次提交。"""
        if not items:
            return
        now = utcnow()
        statement = sqlite_insert(CacheEntry)
        rows = [
            {"namespace": namespace, "cache_key": key, "payload": payload, "fetched_at": now}
            for key, payload in items.items()
        ]
        for start in range(0, len(rows), 200):
            await self._session.execute(
                statement.on_conflict_do_update(
                    index_elements=["namespace", "cache_key"],
                    set_={"payload": statement.excluded.payload, "fetched_at": now},
                ),
                rows[start : start + 200],
            )
        await self._session.commit()

    async def purge_older_than(self, cutoff: datetime) -> int:
        """删除抓取时间早于 cutoff 的全部缓存行，返回删除条数（清理任务用）。"""
        result = await self._session.execute(
            delete(CacheEntry).where(CacheEntry.fetched_at < cutoff)
        )
        await self._session.commit()
        return result.rowcount or 0

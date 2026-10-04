"""可重建的名称索引：事务内记录变更，现有持久化 Job 分批消费。

数据库只保存派生数据。读取期间不写库；待更新实体用最新业务名称参与匹配，
因此首次构建、改名和后台失败都不会漏搜新名称，也不会返回已经失效的旧名。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
from collections import defaultdict

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services import jobs
from movieclaw_api.services.library.search_matching import name_forms, name_tokens
from movieclaw_db.engine import get_database
from movieclaw_db.models import MediaItem
from movieclaw_db.models.person import Person

logger = logging.getLogger("movieclaw_api.library_search")
INDEX_VERSION = 2
_pump: asyncio.Task | None = None


async def source_names(
    session: AsyncSession, kind: str, ids: list[int]
) -> dict[int, list[tuple[str, str]]]:
    """只取名称列，避免加载完整 ORM 或媒体文件；人物与影片独立索引。"""
    if isinstance(ids, list) and not ids:
        return {}
    if kind == "media":
        rows = (
            await session.execute(
                select(
                    MediaItem.id,
                    MediaItem.title,
                    MediaItem.original_title,
                    MediaItem.english_title,
                    MediaItem.aliases,
                ).where(MediaItem.id.in_(ids))
            )
        ).all()
        return {
            row[0]: [
                (field, value)
                for field, value in (
                    ("title", row[1]),
                    ("original_title", row[2]),
                    ("english_title", row[3]),
                    *(("alias", alias) for alias in (row[4] or []) if isinstance(alias, str)),
                )
                if value and value.strip()
            ]
            for row in rows
        }
    rows = (
        await session.execute(
            select(
                Person.id,
                Person.name,
                Person.original_name,
            ).where(Person.id.in_(ids))
        )
    ).all()
    result = {}
    for person_id, name, original_name in rows:
        names = []
        for field, value in (("person_name", name), ("person_original_name", original_name)):
            if not value or not value.strip():
                continue
            names.append((field, value))
            # 外文姓名按明确的空格/间隔号拆分，支持「诺兰 / nl / Nolan」。
            # 不拆普通中文姓名，不枚举任意子串，避免单字姓氏造成大量误命中。
            parts = re.split(r"[\s·・•]+", value.strip())
            if len(parts) > 1:
                names.extend((field + "_part", part) for part in parts if len(part) >= 2)
        result[person_id] = names
    return result


def _prepare(names: list[tuple[str, str]]) -> tuple[list[dict], str]:
    values = []
    for field, raw in names:
        forms = name_forms(raw)
        if forms.text:
            values.append(
                {
                    "field": field,
                    "raw": raw,
                    "normalized": forms.text,
                    "pinyin": forms.pinyin,
                    "initials": forms.initials,
                }
            )
    return values, name_tokens([raw for _, raw in names])


async def refresh_index_batch(batch_size: int = 200) -> int:
    """一次短读事务、在线程中转换、一次短写事务；revision 防止吞掉并发更新。"""
    db = get_database()
    async with db.session() as session:
        pending = (
            await session.execute(
                text("""SELECT entity_kind, entity_id, revision
            FROM library_search_dirty ORDER BY entity_kind, entity_id LIMIT :limit"""),
                {"limit": batch_size},
            )
        ).all()
        grouped: dict[str, list[int]] = defaultdict(list)
        for kind, entity_id, _ in pending:
            grouped[kind].append(entity_id)
        sources = {kind: await source_names(session, kind, ids) for kind, ids in grouped.items()}
    prepared = await asyncio.to_thread(
        lambda: [_prepare(sources[kind].get(entity_id, [])) for kind, entity_id, _ in pending]
    )
    processed = 0
    async with db.session() as session:
        for (kind, entity_id, revision), (names, tokens) in zip(pending, prepared, strict=True):
            params = {"kind": kind, "id": entity_id, "revision": revision}
            claimed = await session.execute(
                text("""DELETE FROM library_search_dirty
                WHERE entity_kind=:kind AND entity_id=:id AND revision=:revision"""),
                params,
            )
            if not claimed.rowcount:
                continue
            document_id = (
                await session.execute(
                    text("""
                INSERT INTO library_search_document(entity_kind, entity_id, index_version)
                VALUES (:kind, :id, :version)
                ON CONFLICT(entity_kind, entity_id) DO UPDATE SET index_version=:version
                RETURNING id"""),
                    {**params, "version": INDEX_VERSION},
                )
            ).scalar_one()
            await session.execute(
                text("DELETE FROM library_search_fts WHERE rowid=:id"), {"id": document_id}
            )
            await session.execute(
                text("DELETE FROM library_search_name WHERE document_id=:id"), {"id": document_id}
            )
            if names:
                await session.execute(
                    text("""INSERT INTO library_search_name
                    (document_id, source_field, raw_name, normalized, pinyin, initials)
                    VALUES (:doc, :field, :raw, :normalized, :pinyin, :initials)"""),
                    [{**value, "doc": document_id} for value in names],
                )
                await session.execute(
                    text("""INSERT INTO library_search_fts(rowid, name_tokens)
                    VALUES (:id, :tokens)"""),
                    {"id": document_id, "tokens": tokens},
                )
            else:
                await session.execute(
                    text("DELETE FROM library_search_document WHERE id=:id"), {"id": document_id}
                )
            processed += 1
        await session.commit()
    return processed


@jobs.register_job_handler("library.search-index.refresh")
async def _refresh_job(context: jobs.JobContext, input_data: dict[str, object]) -> dict:
    total = 0
    while True:
        await context.raise_if_cancelled()
        count = await refresh_index_batch()
        if not count:
            return {"indexed": total}
        total += count
        if context.progress_due():
            await context.update_progress(
                mode="indeterminate",
                phase="indexing",
                message=f"已更新 {total} 个搜索文档",
                current=total,
            )


async def _enqueue_refresh() -> None:
    async with get_database().session() as session:
        pending = (
            await session.execute(text("SELECT 1 FROM library_search_dirty LIMIT 1"))
        ).first()
        if pending:
            await jobs.create_job(
                session,
                job_type="library.search-index.refresh",
                input_data={},
                subject="更新媒体库搜索索引",
                dedupe_key="library.search-index.refresh",
                resources=[jobs.ResourceRef("library_search", "index", "lock")],
                priority=-10,
            )


async def _watch_dirty() -> None:
    # 这里只负责唤醒现有 JobDispatcher，租约、恢复、重试仍由统一任务系统承担。
    initialized = False
    while True:
        try:
            if not initialized:
                async with get_database().session() as session:
                    await session.execute(
                        text("""INSERT INTO library_search_dirty(entity_kind, entity_id)
                        SELECT entity_kind, entity_id FROM library_search_document
                        WHERE index_version != :v
                        ON CONFLICT(entity_kind, entity_id) DO NOTHING"""),
                        {"v": INDEX_VERSION},
                    )
                    await session.commit()
                initialized = True
            await _enqueue_refresh()
        except Exception:
            logger.warning("搜索索引更新暂时失败，稍后自动重试", exc_info=True)
        await asyncio.sleep(2)


def start_search_index() -> None:
    global _pump
    _pump = asyncio.create_task(_watch_dirty(), name="library-search-index")


async def close_search_index() -> None:
    global _pump
    if _pump is not None:
        _pump.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await _pump
        _pump = None

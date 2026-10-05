"""SQLite 海报墙/搜索的标量批量读取，减少并发时逐行转换的线程切换。"""

import json

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession


async def scalar_rows(session: AsyncSession, statement, *, pack: bool = True) -> list[tuple]:
    """数据库封装成单个 JSON 值，Python 一次解码，再恢复列的标准类型。

    只接收标量 SELECT，不接收 ORM 实体或二进制列。保留子查询原排序、过滤和
    参数绑定，不拼接输入。日期、布尔、枚举等使用各列原有的 SQLAlchemy
    result_processor，与常规读取一致；空结果仍返回空列表。
    少量名称/图片使用常规读取，避免 JSON 聚合与表达式装配的固定开销。
    """
    if not pack:
        return [tuple(row) for row in (await session.execute(statement)).all()]
    values = statement.subquery()
    packed = await session.scalar(
        select(func.json_group_array(func.json_array(*values.c))).select_from(values)
    )
    dialect = session.bind.dialect
    processors = [c.type.dialect_impl(dialect).result_processor(dialect, None) for c in values.c]
    return [
        tuple(
            process(value) if process is not None else value
            for process, value in zip(processors, row, strict=True)
        )
        for row in json.loads(packed)
    ]

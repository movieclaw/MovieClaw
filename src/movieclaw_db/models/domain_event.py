"""可靠事件（docs/design/plugin-phase2a.md §2）：事件本体、消费者进度、死信。

事件行由业务代码在**记录该事实的同一次提交**里写入（outbox）：提交即成立，回滚即不存在。
投递器按 ``seq`` 顺序把事件交给各个消费者，每个消费者各自记进度，互不影响。

``seq`` 的单调与提交顺序一致依赖 SQLite 的单写者：写事务从第一次写入起独占写锁直到提交，
自增值的分配顺序就是提交顺序，消费者按 ``seq > cursor`` 读不会漏掉「晚提交的小序号」。
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import JSON, Column, Index, Integer, Text
from sqlmodel import Field, SQLModel

from movieclaw_db.models.base import utcnow


class DomainEvent(SQLModel, table=True):
    __tablename__ = "domain_event"
    __table_args__ = (
        Index("ix_domain_event_name_seq", "name", "seq"),
        {"sqlite_autoincrement": True},
    )

    seq: int | None = Field(
        default=None,
        sa_column=Column(Integer, primary_key=True, autoincrement=True),
        description="投递顺序",
    )
    id: str = Field(
        sa_column=Column(Text, nullable=False, unique=True),
        description="事件 id（ULID），消费方以它去重",
    )
    name: str = Field(sa_column=Column(Text, nullable=False), description="事件名")
    version: str = Field(default="1.0", description="载荷契约版本")
    payload: dict[str, Any] = Field(default_factory=dict, sa_column=Column(JSON, nullable=False))
    origin_kind: str = Field(
        default="system", description="发起方类型：system / user / member / plugin"
    )
    origin_id: str | None = Field(default=None, description="发起方 id")
    chain: list[str] = Field(
        default_factory=list,
        sa_column=Column(JSON, nullable=False),
        description="因果链：引起本事件的事件名序列",
    )
    occurred_at: datetime = Field(default_factory=utcnow, index=True)


class EventConsumer(SQLModel, table=True):
    """一个可靠监听器（条目 id + 监听器 id）的进度。"""

    __tablename__ = "event_consumer"

    consumer_id: str = Field(primary_key=True, description="<条目 id>:<监听器 id>")
    event_name: str = Field(index=True, description="订阅的事件名")
    cursor: int = Field(default=0, description="已处理到的 seq")
    attempts: int = Field(default=0, description="当前事件已失败的次数")
    next_attempt_at: datetime | None = Field(default=None, description="下次重试时间")
    last_error: str | None = Field(default=None, sa_column=Column(Text, nullable=True))
    last_seen_at: datetime = Field(
        default_factory=utcnow, description="最近一次被订阅；长期未出现说明插件已移除"
    )


class EventDeadLetter(SQLModel, table=True):
    """超过重试次数的事件：诊断里可见，可手动重放或忽略。"""

    __tablename__ = "event_dead_letter"

    id: int | None = Field(default=None, primary_key=True)
    consumer_id: str = Field(index=True)
    event_seq: int = Field(index=True)
    event_id: str
    event_name: str
    error: str = Field(sa_column=Column(Text, nullable=False))
    attempts: int = 0
    created_at: datetime = Field(default_factory=utcnow)
    resolved_at: datetime | None = Field(default=None, index=True)
    resolution: str | None = Field(default=None, description="replayed / dismissed")

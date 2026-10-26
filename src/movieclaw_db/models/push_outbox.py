"""自托管实时通知的发件箱（docs/design/cloud-push.md §4.1）。

开了「实时通知（保持连接）」的 Android 设备不走苹果 / 厂商推送，而是一直连着服务器的
``GET /push/me/stream``。推送分发时给这类设备每台写一行，在线就立刻从流里送出，
断线期间的留在这里，重连后按游标补发；App 显示后 ``ack``，标记已送达。

- 跟着设备走：``login_device_id`` 外键级联删除，注销设备、删除成员时随行删掉；
- ``id`` 用 AUTOINCREMENT：清理后也不会回退，App 存的游标永远单调；
- 每台设备最多留 200 条未送达的，超过 7 天的、已送达的写入时顺手清掉。
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, Column, ForeignKey, Integer
from sqlmodel import Field, SQLModel

from movieclaw_db.models.base import utcnow


class PushOutbox(SQLModel, table=True):
    """一行 = 发给一台实时连接设备的一条通知。"""

    __tablename__ = "push_outbox"
    __table_args__ = ({"sqlite_autoincrement": True},)

    id: int | None = Field(default=None, primary_key=True)
    login_device_id: int = Field(
        sa_column=Column(
            Integer,
            ForeignKey("login_device.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        description="收件设备",
    )
    created_at: datetime = Field(default_factory=utcnow, nullable=False)
    payload: dict = Field(
        sa_column=Column(JSON, nullable=False),
        description="通知内容：title / body / event / category / deeplink / collapse / priority …",
    )
    delivered_at: datetime | None = Field(default=None, description="App 确认收到的时间")

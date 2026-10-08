"""插件数据（docs/design/plugin-phase2b.md §4）：插件自己的状态与挂在实体上的扩展字段。

一个条目只能读写自己 ``entry_id`` 下的行。``scope`` 是 ``global`` 或「实体:id」
（``subscription:35``、``media_item:7192``），实体扩展字段就是挂在实体作用域下的键。
秘密值用 SecretBox 加密后存 ``{"enc": "enc::…"}``，读取时解密。
实体删除不级联：数据量小，插件可按可靠事件自行清理。
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import JSON, Column, Text, UniqueConstraint
from sqlmodel import Field, SQLModel

from movieclaw_db.models.base import utcnow


class PluginData(SQLModel, table=True):
    __tablename__ = "plugin_data"
    __table_args__ = (UniqueConstraint("entry_id", "scope", "key", name="uq_plugin_data_key"),)

    id: int | None = Field(default=None, primary_key=True)
    entry_id: str = Field(index=True, description="插件条目 id")
    scope: str = Field(index=True, description="global 或 实体:id")
    key: str = Field(sa_column=Column(Text, nullable=False))
    value: Any = Field(default=None, sa_column=Column(JSON, nullable=True))
    secret: bool = Field(default=False, description="value 是加密后的 {enc: …}")
    updated_at: datetime = Field(default_factory=utcnow)

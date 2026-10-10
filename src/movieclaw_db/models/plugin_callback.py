"""插件回调端点的密钥（docs/design/plugin-callbacks.md §4）。

一行 = 一把密钥：外部平台按 ``/api/v1/hooks/<条目 id>/<端点名>/<密钥>`` 调进来，
宿主按它找到插件与归属。
只存密钥的哈希；``key_tail`` 是末四位，列表里给人认地址用。调用次数、失败次数只在内存里记，不落盘。
"""

from __future__ import annotations

from datetime import datetime

from sqlmodel import Field, SQLModel

from movieclaw_db.models.base import utcnow


class PluginCallback(SQLModel, table=True):
    __tablename__ = "plugin_callback"

    id: int | None = Field(default=None, primary_key=True)
    entry_id: str = Field(index=True, description="插件条目 id")
    name: str = Field(description="端点名（插件在代码里定义）")
    key_hash: str = Field(unique=True, description="密钥的 SHA-256（十六进制）")
    key_tail: str = Field(description="密钥末四位，列表里认地址用")
    scope: str = Field(
        default="plugin", description="归属：plugin / account:<通道>:<账号> / entity:<类型>:<id>"
    )
    created_at: datetime = Field(default_factory=utcnow)
    revoked_at: datetime | None = Field(default=None, description="作废时间；非空即失效")

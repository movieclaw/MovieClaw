from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, ForeignKey, Integer
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin


class StrmProbeState(TimestampMixin, table=True):
    """网盘（strm）条目的探测记录（docs/design/plugin-strm-prefetch.md §4）。

    规格本身记在台账行上（与本地文件同一批列）；这里只记「探得怎么样」：

    - **失败退避**：连续失败按 1 小时、6 小时、1 天、封顶 3 天退避。后台预探遵守它，
      不对一条坏链反复白等超时；用户点播放不受限制（链接可能已经修好）；
    - **直链指纹**：探测时直链的主机 + 路径。扫描发现 .strm 被改写时据此区分「换了文件」
      （清空规格重探）与「只换了签名参数」（规格照旧）。

    一个 strm 文件一行，探过（成功或失败）才有；文件行删除时级联删除。
    """

    __tablename__ = "strm_probe_state"

    file_id: int = Field(
        sa_column=Column(
            Integer, ForeignKey("library_file.id", ondelete="CASCADE"), primary_key=True
        ),
        description="台账文件行",
    )
    target: str | None = Field(
        default=None, description="最近一次探测时直链的主机 + 路径（不含查询参数）"
    )
    failures: int = Field(default=0, description="连续失败次数；成功清零")
    last_error: str | None = Field(default=None, description="最近一次失败的原因（给人看）")
    last_attempt_at: datetime | None = Field(default=None, description="最近一次探测时间")
    next_retry_at: datetime | None = Field(
        default=None, index=True, description="失败退避：这之前后台预探不再探它；成功为空"
    )

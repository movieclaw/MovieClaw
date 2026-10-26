from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from sqlalchemy import JSON, Column, Text
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin


class NoticeSeverity(StrEnum):
    """告警严重度。"""

    WARNING = "warning"  # 能转但降级/需要留意
    ERROR = "error"  # 自动化到此为止，不修就永远卡着


class NoticeStatus(StrEnum):
    """告警生命周期。"""

    ACTIVE = "active"  # 问题存在，前端红灯
    RESOLVED = "resolved"  # 问题消失，系统自动熄灯
    DISMISSED = "dismissed"  # 用户手动关闭（问题仍在也不再打扰）


class SystemNotice(TimestampMixin, table=True):
    """全局待处理事项：需要用户行动才能推进的运行时故障。

    与日志、订阅时间线的本质区别是**状态化而非事件流**：每条告警是一个有
    生命周期的问题——同一问题靠 ``dedupe_key`` 收敛为一行（幂等 upsert），
    问题消失时由对应的恢复路径自动 resolve（入库对账关闭工单、ingest 成功、
    下载器/站点验证恢复），用户不需要手动"标记已读"。正常运行时活跃告警
    应该是零条，所以它一旦亮起就有意义。

    dedupe_key 约定（source 为前缀，便于按域批量消退）：
    - ``subscription.landing:{subscription_id}:{info_hash}`` 落点核验失败
    - ``ingest:{entry_path}``                                监听导入处理失败
    - ``downloader:{downloader_id}``                         下载器验证失败
    - ``site:{site_id}``                                     站点凭据失效
    """

    __tablename__ = "system_notice"

    id: int | None = Field(default=None, primary_key=True)

    dedupe_key: str = Field(
        sa_column=Column(Text, nullable=False, unique=True, index=True),
        description="同一问题的唯一标识：重复发生只刷新这一行",
    )
    severity: str = Field(description="严重度（NoticeSeverity）")
    source: str = Field(
        index=True, description="来源域：subscription / ingest / downloader / site"
    )
    title: str = Field(description="一句话标题（面板列表行）")
    title_key: str | None = Field(default=None)
    message_key: str | None = Field(default=None)
    message_params: dict = Field(default_factory=dict, sa_column=Column(JSON, nullable=False))
    message: str = Field(
        sa_column=Column(Text, nullable=False),
        description="完整中文陈述（含修复引导），与日志/时间线同文案",
    )
    payload: dict = Field(
        default_factory=dict,
        sa_column=Column(JSON, nullable=False),
        description="deep-link 参数（subscription_id / entry_path 等）",
    )
    status: str = Field(
        default=NoticeStatus.ACTIVE.value, index=True, description="生命周期（NoticeStatus）"
    )
    resolved_at: datetime | None = Field(
        default=None, description="消退时间（自动 resolve 或用户 dismiss）"
    )

from __future__ import annotations

from sqlalchemy import JSON, Column, ForeignKey, Integer, UniqueConstraint
from sqlmodel import Field

from movieclaw_db.models.base import TimestampMixin


class SmartProfile(TimestampMixin, table=True):
    __tablename__ = "smart_profile"

    kind: str = Field(primary_key=True)
    revision: int = Field(default=1)
    preferences: dict = Field(sa_column=Column(JSON, nullable=False))


class SmartSeason(TimestampMixin, table=True):
    __tablename__ = "smart_season"
    __table_args__ = (UniqueConstraint("subscription_id", "season_number", name="uq_smart_season"),)

    id: int | None = Field(default=None, primary_key=True)
    subscription_id: int = Field(
        sa_column=Column(
            Integer, ForeignKey("subscription.id", ondelete="CASCADE"), nullable=False, index=True
        )
    )
    season_number: int
    series_key: str
    confirmed: bool = Field(default=False)
    evidence: dict = Field(default_factory=dict, sa_column=Column(JSON, nullable=False))


class SmartCandidate(TimestampMixin, table=True):
    """每订阅的已观测候选。索引清理不能丢失等待中的兜底资源。"""

    __tablename__ = "smart_candidate"
    __table_args__ = (
        UniqueConstraint("subscription_id", "site_id", "torrent_id", name="uq_smart_candidate"),
    )

    id: int | None = Field(default=None, primary_key=True)
    subscription_id: int = Field(
        sa_column=Column(
            Integer, ForeignKey("subscription.id", ondelete="CASCADE"), nullable=False, index=True
        )
    )
    site_id: str
    torrent_id: str
    snapshot: dict = Field(sa_column=Column(JSON, nullable=False))
    observations: list[dict] = Field(default_factory=list, sa_column=Column(JSON, nullable=False))


class SmartDecisionRecord(TimestampMixin, table=True):
    __tablename__ = "smart_decision_record"
    id: int | None = Field(default=None, primary_key=True)
    wanted_id: int = Field(
        sa_column=Column(
            Integer, ForeignKey("wanted_item.id", ondelete="CASCADE"), nullable=False, index=True
        )
    )
    mode: str
    inputs: dict = Field(sa_column=Column(JSON, nullable=False))
    outcome: dict = Field(sa_column=Column(JSON, nullable=False))

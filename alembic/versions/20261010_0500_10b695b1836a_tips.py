"""add tip_event / tip_record: per-person state of usage tips (docs/design/tips.md)

使用提示（对标 Apple TipKit）：客户端声明提示与出现条件，服务端只存每个人的
事件计数和每条提示的展示/作废记录，换设备不重复提示。

向前兼容：只加两张新表、无数据改写。回退到旧版本时旧代码不读这两张表，
提示状态随旧版本一起「消失」，其他功能不受影响。

Revision ID: 10b695b1836a
Revises: a7d2c9e4f1b3
Create Date: 2026-10-10 05:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "10b695b1836a"
down_revision: str | None = "a7d2c9e4f1b3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "tip_event",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("member_id", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("event_id", sa.String(), nullable=False),
        sa.Column("count", sa.Integer(), nullable=False),
        sa.Column("first_at", sa.DateTime(), nullable=False),
        sa.Column("last_at", sa.DateTime(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("member_id", "event_id", name="uq_tip_event_member_event"),
    )
    with op.batch_alter_table("tip_event", schema=None) as batch_op:
        batch_op.create_index(batch_op.f("ix_tip_event_member_id"), ["member_id"], unique=False)

    op.create_table(
        "tip_record",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("member_id", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("tip_id", sa.String(), nullable=False),
        sa.Column("display_count", sa.Integer(), nullable=False),
        sa.Column("first_displayed_at", sa.DateTime(), nullable=True),
        sa.Column("last_displayed_at", sa.DateTime(), nullable=True),
        sa.Column("invalidated_at", sa.DateTime(), nullable=True),
        sa.Column("invalidated_reason", sa.String(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("member_id", "tip_id", name="uq_tip_record_member_tip"),
    )
    with op.batch_alter_table("tip_record", schema=None) as batch_op:
        batch_op.create_index(batch_op.f("ix_tip_record_member_id"), ["member_id"], unique=False)


def downgrade() -> None:
    with op.batch_alter_table("tip_record", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_tip_record_member_id"))
    op.drop_table("tip_record")
    with op.batch_alter_table("tip_event", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_tip_event_member_id"))
    op.drop_table("tip_event")

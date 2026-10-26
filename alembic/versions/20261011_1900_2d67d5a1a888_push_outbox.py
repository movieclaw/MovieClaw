"""add push_outbox + login_device.push_stream: self-hosted realtime push (cloud-push.md §4.1)

Android App 开了「实时通知（保持连接）」后不走中继：推送写进这台设备的发件箱，
由它一直连着的 ``GET /push/me/stream`` 送出，断线期间的重连后补发。

向前兼容：只加一张新表和一个有默认值的列、无数据改写。回退到旧版本时旧代码不读它们，
实时通知随旧版本一起「消失」，App 回退到本机轮询。

Revision ID: 2d67d5a1a888
Revises: c5f1e8a3d907
Create Date: 2026-10-11 01:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "2d67d5a1a888"
down_revision: str | None = "c5f1e8a3d907"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("login_device", schema=None) as batch_op:
        batch_op.add_column(
            sa.Column("push_stream", sa.Boolean(), nullable=False, server_default="0")
        )
    op.create_table(
        "push_outbox",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("login_device_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("delivered_at", sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(["login_device_id"], ["login_device.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sqlite_autoincrement=True,
    )
    with op.batch_alter_table("push_outbox", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_push_outbox_login_device_id"), ["login_device_id"], unique=False
        )


def downgrade() -> None:
    with op.batch_alter_table("push_outbox", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_push_outbox_login_device_id"))
    op.drop_table("push_outbox")
    with op.batch_alter_table("login_device", schema=None) as batch_op:
        batch_op.drop_column("push_stream")

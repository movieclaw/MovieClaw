"""add event_consumer.event_names: one durable consumer can follow several events

统一事件（docs/design/domain-events.md §5、§6.2）：Webhook 地址是一个可靠消费者，订阅一组事件、
按产生顺序投递。``event_names`` 记这组事件名；旧列 ``event_name`` 保留并照写第一个事件名，
回退到旧版本时旧代码还能读。

Revision ID: e41a7c2f9b63
Revises: 7c3e9a51d2f4
Create Date: 2026-10-12 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e41a7c2f9b63"
down_revision: str | None = "7c3e9a51d2f4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("event_consumer", schema=None) as batch_op:
        batch_op.add_column(
            sa.Column("event_names", sa.JSON(), nullable=False, server_default="[]")
        )
    op.execute("UPDATE event_consumer SET event_names = json_array(event_name)")


def downgrade() -> None:
    with op.batch_alter_table("event_consumer", schema=None) as batch_op:
        batch_op.drop_column("event_names")

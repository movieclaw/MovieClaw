"""add push_preference.muted_item_ids

「这部剧不再提醒」（docs/design/cloud-push.md §5.1）：长按通知静音一部剧，只关这一部的
推送，订阅照常下载。存每个人静音的条目 id 列表。

向前兼容：只加可空列、无数据改写。NULL = 没静音过；回退到旧版本时旧代码忽略该列即可。

Revision ID: a5c3f19d7e42
Revises: 4f8a2c6e1d37
Create Date: 2026-10-06 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a5c3f19d7e42"
down_revision: str | None = "4f8a2c6e1d37"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("push_preference", schema=None) as batch_op:
        batch_op.add_column(sa.Column("muted_item_ids", sa.JSON(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("push_preference", schema=None) as batch_op:
        batch_op.drop_column("muted_item_ids")

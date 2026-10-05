"""add push_preference.library_ids

「媒体库有新片」推送（docs/design/cloud-push.md §5）：每个人选自己关心的媒体库。
NULL = 自己能看到的全部库（含以后新建的）。

向前兼容：只加可空列、无数据改写。回退到旧版本时旧代码不读这一列。

Revision ID: 5b1d7e3c9a42
Revises: a90cbe890eb2
Create Date: 2026-10-03 19:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "5b1d7e3c9a42"
down_revision: str | None = "a90cbe890eb2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("push_preference") as batch:
        batch.add_column(sa.Column("library_ids", sa.JSON(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("push_preference") as batch:
        batch.drop_column("library_ids")

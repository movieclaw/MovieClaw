"""add library_file.release_name

命名模板 {release_name} 占位符（issue #577）：入库时源文件的原始文件名。
整理改名后当前文件名就不再是原名，所以要在入库现场落列。

向前兼容：只加可空列、无数据改写。存量行为 NULL（{release_name} 渲染为空并被
收缩）；回退到旧版本时旧代码忽略该列即可。

Revision ID: 4f8a2c6e1d37
Revises: 62d9a8c4f130
Create Date: 2026-10-05 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "4f8a2c6e1d37"
down_revision: str | None = "62d9a8c4f130"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("library_file", schema=None) as batch_op:
        batch_op.add_column(sa.Column("release_name", sa.String(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("library_file", schema=None) as batch_op:
        batch_op.drop_column("release_name")

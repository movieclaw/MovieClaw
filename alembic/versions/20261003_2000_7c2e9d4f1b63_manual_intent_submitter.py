"""add manual_download_intent.submitted_by_member_id

手动下载入库时把「入库完成」推给点下载的人（docs/design/cloud-push.md §5）：
手动下载锚记下是谁提交的。与订阅的 created_by_member_id 同一约定：NULL = 超管，
成员删除时 SET NULL。

向前兼容：只加可空列和外键、无数据改写。存量锚为 NULL，入库时按超管处理。

Revision ID: 7c2e9d4f1b63
Revises: 5b1d7e3c9a42
Create Date: 2026-10-03 20:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7c2e9d4f1b63"
down_revision: str | None = "5b1d7e3c9a42"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("manual_download_intent", schema=None) as batch_op:
        batch_op.add_column(sa.Column("submitted_by_member_id", sa.Integer(), nullable=True))
        batch_op.create_index(
            "ix_manual_download_intent_submitted_by_member_id",
            ["submitted_by_member_id"],
            unique=False,
        )
        batch_op.create_foreign_key(
            "fk_manual_download_intent_submitted_by_member",
            "member",
            ["submitted_by_member_id"],
            ["id"],
            ondelete="SET NULL",
        )


def downgrade() -> None:
    with op.batch_alter_table("manual_download_intent", schema=None) as batch_op:
        batch_op.drop_constraint(
            "fk_manual_download_intent_submitted_by_member", type_="foreignkey"
        )
        batch_op.drop_index("ix_manual_download_intent_submitted_by_member_id")
        batch_op.drop_column("submitted_by_member_id")

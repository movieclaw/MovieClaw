"""add push_download_watch; drop manual_download_intent.submitted_by_member_id

手动下载的「入库完成」推给点下载的人（docs/design/cloud-push.md §5）：每次手动提交
下载都记一行（谁点的、哪个种子、下到哪），入库时按种子或路径对上。上一个迁移把
「谁点的」放在手动下载锚上，只覆盖得到管理员的智能入库；改成单独一张表，原来那一列
不再使用，一并删掉（这几个推送迁移都还没有进正式版本）。

向前兼容：新建表 + 删一个只有开发版用过的可空列。

Revision ID: 9d4b6a2e8f17
Revises: 7c2e9d4f1b63
Create Date: 2026-10-03 22:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "9d4b6a2e8f17"
down_revision: str | None = "7c2e9d4f1b63"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "push_download_watch",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("member_id", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("info_hash", sa.Text(), nullable=False),
        sa.Column("save_path", sa.Text(), nullable=True),
        sa.Column("download_name", sa.Text(), nullable=True),
        sa.Column("batch_ids", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("member_id", "info_hash", name="uq_push_download_watch_member_hash"),
    )
    with op.batch_alter_table("push_download_watch", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_push_download_watch_member_id"), ["member_id"], unique=False
        )
        batch_op.create_index(
            batch_op.f("ix_push_download_watch_info_hash"), ["info_hash"], unique=False
        )

    with op.batch_alter_table("manual_download_intent", schema=None) as batch_op:
        batch_op.drop_constraint(
            "fk_manual_download_intent_submitted_by_member", type_="foreignkey"
        )
        batch_op.drop_index("ix_manual_download_intent_submitted_by_member_id")
        batch_op.drop_column("submitted_by_member_id")


def downgrade() -> None:
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

    with op.batch_alter_table("push_download_watch", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_push_download_watch_info_hash"))
        batch_op.drop_index(batch_op.f("ix_push_download_watch_member_id"))
    op.drop_table("push_download_watch")

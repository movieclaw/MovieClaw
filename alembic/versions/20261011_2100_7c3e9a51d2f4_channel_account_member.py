"""add channel_account.member_id: IM accounts belong to a member (cloud-push.md §5)

IM 推送并入「账号 → 通知」：IM 只是一个人的一个通知渠道，推什么按归属成员的通知偏好来。
绑定目前只有管理员能做，已有的账号都归超管（0）。

向前兼容：只加一个有默认值的列、无数据改写。回退到旧版本时旧代码不读它。

Revision ID: 7c3e9a51d2f4
Revises: 2d67d5a1a888
Create Date: 2026-10-11 21:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7c3e9a51d2f4"
down_revision: str | None = "2d67d5a1a888"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("channel_account", schema=None) as batch_op:
        batch_op.add_column(
            sa.Column("member_id", sa.Integer(), nullable=False, server_default="0")
        )
        batch_op.create_index(
            batch_op.f("ix_channel_account_member_id"), ["member_id"], unique=False
        )


def downgrade() -> None:
    with op.batch_alter_table("channel_account", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_channel_account_member_id"))
        batch_op.drop_column("member_id")

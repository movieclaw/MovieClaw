"""add App push registration and preferences

App 推送（docs/design/cloud-push.md §4、§5）：

- ``login_device`` 加推送登记的几列：App 用这台设备自己的凭证把 APNs 令牌和解密
  密钥交给实例，存在设备行上，退出登录、注销设备时随行删除；
- 新表 ``push_preference``：每人一行，记改过的事件开关。

向前兼容：只加可空列和新表、无数据改写。回退到旧版本时旧代码不读这些列和这张表，
App 推送随旧版本一起消失，其他功能不受影响。

Revision ID: a90cbe890eb2
Revises: 3c8e1f5a7b20
Create Date: 2026-10-03 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a90cbe890eb2"
down_revision: str | None = "3c8e1f5a7b20"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_PUSH_COLUMNS = (
    ("push_token", sa.String()),
    ("push_topic", sa.String()),
    ("push_environment", sa.String()),
    ("push_types", sa.JSON()),
    ("push_key_id", sa.String()),
    ("push_key", sa.String()),
    ("push_permission", sa.String()),
    ("push_problem", sa.String()),
    ("push_registered_at", sa.DateTime()),
)


def upgrade() -> None:
    with op.batch_alter_table("login_device") as batch:
        for name, type_ in _PUSH_COLUMNS:
            batch.add_column(sa.Column(name, type_, nullable=True))

    op.create_table(
        "push_preference",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("member_id", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("events", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("member_id", name="uq_push_preference_member"),
    )
    with op.batch_alter_table("push_preference", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_push_preference_member_id"), ["member_id"], unique=False
        )


def downgrade() -> None:
    with op.batch_alter_table("push_preference", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_push_preference_member_id"))
    op.drop_table("push_preference")
    with op.batch_alter_table("login_device") as batch:
        for name, _ in reversed(_PUSH_COLUMNS):
            batch.drop_column(name)

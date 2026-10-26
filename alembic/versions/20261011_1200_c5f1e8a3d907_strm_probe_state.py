"""add strm_probe_state: probe failures, backoff and target fingerprint of strm files

网盘规格预探（docs/design/plugin-strm-prefetch.md §4）：每个探过的 strm 文件一行，
记连续失败次数、下次可重试时间与探测时直链的主机 + 路径。

向前兼容：只加一张新表、无数据改写。回退到旧版本时旧代码不读这张表，
退避与改写检测随之失效，探测照旧在首播时进行。

Revision ID: c5f1e8a3d907
Revises: b4e8d2a61c7f
Create Date: 2026-10-11 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c5f1e8a3d907"
down_revision: str | None = "b4e8d2a61c7f"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "strm_probe_state",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("file_id", sa.Integer(), nullable=False),
        sa.Column("target", sa.String(), nullable=True),
        sa.Column("failures", sa.Integer(), nullable=False),
        sa.Column("last_error", sa.String(), nullable=True),
        sa.Column("last_attempt_at", sa.DateTime(), nullable=True),
        sa.Column("next_retry_at", sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(["file_id"], ["library_file.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("file_id"),
    )
    with op.batch_alter_table("strm_probe_state", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_strm_probe_state_next_retry_at"), ["next_retry_at"], unique=False
        )


def downgrade() -> None:
    with op.batch_alter_table("strm_probe_state", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_strm_probe_state_next_retry_at"))
    op.drop_table("strm_probe_state")

"""playback_preference: per-member player preferences (auto skip).

One row per member: the auto-skip master switch (on by default) and the shows
whose intro the member chose to skip automatically (docs/design/skip-intro.md
§5). Purely additive; older code ignores the table.

Revision ID: c5f1a8e3d9b2
Revises: b8d4f1a6c372
Create Date: 2026-10-19 22:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c5f1a8e3d9b2"
down_revision: str | None = "b8d4f1a6c372"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "playback_preference",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("member_id", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("auto_skip", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("auto_skip_intro_item_ids", sa.JSON(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("member_id", name="uq_playback_preference_member"),
    )
    with op.batch_alter_table("playback_preference", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_playback_preference_member_id"), ["member_id"], unique=False
        )


def downgrade() -> None:
    with op.batch_alter_table("playback_preference", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_playback_preference_member_id"))
    op.drop_table("playback_preference")

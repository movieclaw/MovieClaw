"""Imported watch records with per-source idempotency.

Revision ID: f9b42d6a8e10
Revises: d7a2e4f9c615
"""

import sqlalchemy as sa
from alembic import op

revision = "f9b42d6a8e10"
down_revision = "d7a2e4f9c615"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "watch_record",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("member_id", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "media_item_id",
            sa.Integer(),
            sa.ForeignKey("media_item.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("season_number", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("episode_number", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("watched_at", sa.DateTime(), nullable=False),
        sa.Column("state_version", sa.DateTime(), nullable=False),
        sa.Column("source", sa.String(100), nullable=False),
        sa.Column("source_id", sa.String(128), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("member_id", "source", "source_id", name="uq_watch_record_source"),
    )
    for field in ("member_id", "media_item_id", "watched_at"):
        op.create_index(f"ix_watch_record_{field}", "watch_record", [field])


def downgrade():
    op.drop_table("watch_record")

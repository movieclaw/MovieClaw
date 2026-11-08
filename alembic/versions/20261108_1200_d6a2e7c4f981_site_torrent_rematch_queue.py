"""Persist rematch work for refreshed torrents.

Revision ID: d6a2e7c4f981
Revises: c5f1a8e3b724
Create Date: 2026-11-08 12:00:00.000000
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d6a2e7c4f981"
down_revision: str | None = "c5f1a8e3b724"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "site_torrent",
        sa.Column("rematch_revision", sa.Integer(), server_default="0", nullable=False),
    )
    op.add_column(
        "site_torrent",
        sa.Column("rematch_enqueued_at", sa.DateTime(), nullable=True),
    )
    op.create_index(
        "ix_site_torrent_rematch_queue",
        "site_torrent",
        ["rematch_enqueued_at", "id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_site_torrent_rematch_queue", table_name="site_torrent")
    op.drop_column("site_torrent", "rematch_enqueued_at")
    op.drop_column("site_torrent", "rematch_revision")

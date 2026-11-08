"""Index refreshed torrents for incremental passive matching.

Revision ID: d6a2e7c4f981
Revises: c5f1a8e3b724
Create Date: 2026-11-08 12:00:00.000000
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "d6a2e7c4f981"
down_revision: str | None = "c5f1a8e3b724"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index(
        "ix_site_torrent_updated_id",
        "site_torrent",
        ["updated_at", "id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_site_torrent_updated_id", table_name="site_torrent")

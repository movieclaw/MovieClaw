"""library.keep_local: keep the local copy of drive-primary libraries.

Libraries whose primary root is a cloud drive folder release local
bytes once a file is uploaded and verified; keep_local keeps both
(docs/design/cloud-storage.md section 3.2/6).

Revision ID: f7d2b4e8a139
Revises: e6c3a9d1f527
Create Date: 2026-10-19 09:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f7d2b4e8a139"
down_revision: str | None = "e6c3a9d1f527"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("library") as batch:
        batch.add_column(
            sa.Column("keep_local", sa.Boolean(), nullable=False, server_default=sa.false())
        )


def downgrade() -> None:
    with op.batch_alter_table("library") as batch:
        batch.drop_column("keep_local")

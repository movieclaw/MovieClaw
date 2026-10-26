"""library_file_replica: drop upload attempts made for .strm placeholders.

The upload candidate query recognised a .strm by ``container = 'strm'``, but
probing a strm replaces that with the real container of the link it points
at, and a rewritten strm clears it. Those placeholders were then queued for
upload over and over (#921). The query now goes by the path; the replica
rows those attempts left behind (still uploading or failed) are removed so
the files no longer show as failing to upload.

Revision ID: b8d4f1a6c372
Revises: a3e9c5d2b814
Create Date: 2026-10-19 20:00:00.000000

"""

from collections.abc import Sequence

from alembic import op

revision: str = "b8d4f1a6c372"
down_revision: str | None = "a3e9c5d2b814"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        "DELETE FROM library_file_replica"
        " WHERE origin = 'uploaded' AND state IN ('uploading', 'failed')"
        " AND library_file_id IN ("
        " SELECT id FROM library_file WHERE lower(file_path) LIKE '%.strm')"
    )


def downgrade() -> None:
    pass

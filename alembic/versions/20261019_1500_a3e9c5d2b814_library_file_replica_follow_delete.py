"""library_file_replica: drop a replica row together with its ledger row.

library_file.id is a plain INTEGER PRIMARY KEY, so SQLite hands a deleted
id to the next insert. A replica row left behind by a deleted ledger row
(deleting a library cascades its files but not their replicas) then got
attached to an unrelated new file: imports hit the unique index and
playback fetched the old file's cloud copy (#909).

The trigger also fires for rows removed by ON DELETE CASCADE. Existing
leftovers are removed: replicas without a ledger row, and replicas created
before the ledger row they point at (only possible through id reuse). A
library scan re-imports the cloud files whose replica was removed.

Revision ID: a3e9c5d2b814
Revises: f7d2b4e8a139
Create Date: 2026-10-19 15:00:00.000000

"""

from collections.abc import Sequence

from alembic import op

revision: str = "a3e9c5d2b814"
down_revision: str | None = "f7d2b4e8a139"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        "DELETE FROM library_file_replica WHERE NOT EXISTS ("
        " SELECT 1 FROM library_file WHERE library_file.id = library_file_replica.library_file_id)"
    )
    op.execute(
        "DELETE FROM library_file_replica WHERE created_at < ("
        " SELECT created_at FROM library_file"
        " WHERE library_file.id = library_file_replica.library_file_id)"
    )
    op.execute(
        "CREATE TRIGGER library_file_drop_replica AFTER DELETE ON library_file BEGIN"
        " DELETE FROM library_file_replica WHERE library_file_id = OLD.id; END"
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS library_file_drop_replica")

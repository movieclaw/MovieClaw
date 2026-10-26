"""search_history.also_keywords_json: the extra keywords searched alongside the main one.

Detail pages search a title by its Chinese, English and original names together
(issue #680). The extra names are part of what was searched, so they join the
dedup key and come back when a history entry is replayed. Existing rows searched
the keyword alone and stay NULL.
"""

import sqlalchemy as sa
from alembic import op

revision = "f3a9c1e7b2d4"
down_revision = "e12bc13203b5"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("search_history", schema=None) as batch_op:
        batch_op.add_column(sa.Column("also_keywords_json", sa.String(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("search_history", schema=None) as batch_op:
        batch_op.drop_column("also_keywords_json")

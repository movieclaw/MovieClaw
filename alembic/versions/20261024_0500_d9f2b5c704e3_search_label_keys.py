"""Distinguish translated built-in search labels from user-named scopes."""

import sqlalchemy as sa
from alembic import op

revision = "d9f2b5c704e3"
down_revision = "c8e1a4b693d2"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("search_history", sa.Column("label_key", sa.String(), nullable=True))


def downgrade():
    with op.batch_alter_table("search_history") as batch:
        batch.drop_column("label_key")

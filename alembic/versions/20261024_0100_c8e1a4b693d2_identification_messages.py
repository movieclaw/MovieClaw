"""Keep a message reference beside the original identification failure text."""

import sqlalchemy as sa
from alembic import op

revision = "c8e1a4b693d2"
down_revision = "b7d0f3a582c1"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("library_file", sa.Column("unidentified_message", sa.JSON(), nullable=True))


def downgrade():
    with op.batch_alter_table("library_file") as batch:
        batch.drop_column("unidentified_message")

"""Remove retired smart subscription preview reports and feedback."""

import sqlalchemy as sa
from alembic import op

revision = "c9a72e4d6b10"
down_revision = "f8316ab24d90"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_table("smart_lab_run")


def downgrade() -> None:
    # The retired reports are deleted; downgrade restores only the table schema.
    op.create_table(
        "smart_lab_run",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("report", sa.JSON(), nullable=False),
        sa.Column("feedback", sa.JSON(), nullable=True),
    )

"""Persist isolated smart subscription preview reports and feedback."""
import sqlalchemy as sa
from alembic import op

revision = "f8316ab24d90"
down_revision = "e7f4a1c9b203"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "smart_lab_run",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("report", sa.JSON(), nullable=False),
        sa.Column("feedback", sa.JSON(), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("smart_lab_run")

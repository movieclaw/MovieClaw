"""Keep reader-local LLM errors beside the original rollback-compatible text."""

import sqlalchemy as sa
from alembic import op

revision = "a3c6f9b217d4"
down_revision = "f2b5d8a014c3"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("llm_provider", sa.Column("last_error_ref", sa.JSON(), nullable=True))


def downgrade():
    with op.batch_alter_table("llm_provider") as batch:
        batch.drop_column("last_error_ref")

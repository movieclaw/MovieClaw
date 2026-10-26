"""Keep automatic session labels beside their original Chinese previews."""

import sqlalchemy as sa
from alembic import op

revision = "b7d29a60c3e1"
down_revision = "a3c6f9b217d4"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("agent_session", sa.Column("title_ref", sa.JSON(), nullable=True))
    op.add_column("agent_session", sa.Column("last_prompt_ref", sa.JSON(), nullable=True))


def downgrade():
    with op.batch_alter_table("agent_session") as batch:
        batch.drop_column("title_ref")
        batch.drop_column("last_prompt_ref")

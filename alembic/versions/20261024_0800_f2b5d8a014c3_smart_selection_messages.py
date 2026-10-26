"""Keep localized explanations outside the strict, rollback-compatible selection state."""

import sqlalchemy as sa
from alembic import op

revision = "f2b5d8a014c3"
down_revision = "e1a4c7f903b2"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("wanted_item", sa.Column("selection_messages", sa.JSON(), nullable=True))


def downgrade():
    with op.batch_alter_table("wanted_item") as batch:
        batch.drop_column("selection_messages")

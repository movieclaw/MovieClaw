"""Track translation provenance of newly seeded rule set names."""

import sqlalchemy as sa
from alembic import op

revision = "e1a4c7f903b2"
down_revision = "d9f2b5c704e3"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("rule_set", sa.Column("name_key", sa.String(), nullable=True))


def downgrade():
    with op.batch_alter_table("rule_set") as batch:
        batch.drop_column("name_key")

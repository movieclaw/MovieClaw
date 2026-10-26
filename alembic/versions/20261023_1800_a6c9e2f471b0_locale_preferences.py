"""Remember device language/timezone and the member's last interactive language."""

import sqlalchemy as sa
from alembic import op

revision = "a6c9e2f471b0"
down_revision = "c5f1a8d3e7b2"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("login_device", sa.Column("locale", sa.String(), nullable=True))
    op.add_column("login_device", sa.Column("timezone", sa.String(), nullable=True))
    op.add_column("member", sa.Column("last_locale", sa.String(), nullable=True))


def downgrade():
    with op.batch_alter_table("login_device") as batch:
        batch.drop_column("timezone")
        batch.drop_column("locale")
    with op.batch_alter_table("member") as batch:
        batch.drop_column("last_locale")

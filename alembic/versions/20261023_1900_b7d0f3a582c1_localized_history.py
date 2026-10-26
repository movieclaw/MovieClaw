"""Keep message references alongside rollback-compatible Chinese history."""

import sqlalchemy as sa
from alembic import op

revision = "b7d0f3a582c1"
down_revision = "a6c9e2f471b0"
branch_labels = None
depends_on = None


def upgrade():
    for table, key, params in (
        ("system_notice", "message_key", "message_params"),
        ("subscription_activity", "message_key", "message_params"),
        ("task_run", "error_key", "error_params"),
    ):
        op.add_column(table, sa.Column(key, sa.String(), nullable=True))
        op.add_column(table, sa.Column(params, sa.JSON(), nullable=False, server_default="{}"))
    op.add_column("system_notice", sa.Column("title_key", sa.String(), nullable=True))


def downgrade():
    for table, columns in (
        ("system_notice", ("title_key", "message_key", "message_params")),
        ("subscription_activity", ("message_key", "message_params")),
        ("task_run", ("error_key", "error_params")),
    ):
        with op.batch_alter_table(table) as batch:
            for column in columns:
                batch.drop_column(column)

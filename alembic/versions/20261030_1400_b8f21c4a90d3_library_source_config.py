"""External library source columns: provider-owned config and sync timestamp."""

import sqlalchemy as sa
from alembic import op

revision = "b8f21c4a90d3"
down_revision = "161724435305"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("library", sa.Column("source_config", sa.JSON(), nullable=True))
    op.add_column(
        "library", sa.Column("last_source_sync_at", sa.DateTime(), nullable=True)
    )


def downgrade():
    # 原生 DROP COLUMN：batch 会重建整表，撞上引用它的触发器
    op.drop_column("library", "last_source_sync_at")
    op.drop_column("library", "source_config")

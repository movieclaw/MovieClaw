"""Keep cloud upload failure references beside their original Chinese text."""

import sqlalchemy as sa
from alembic import op

revision = "c6f14d3a9b72"
down_revision = "b5e03c29f8a1"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("library_file_replica", sa.Column("error_ref", sa.JSON(), nullable=True))


def downgrade():
    # 原生 DROP COLUMN：batch 会重建整表，撞上引用它的触发器
    op.drop_column("library_file_replica", "error_ref")

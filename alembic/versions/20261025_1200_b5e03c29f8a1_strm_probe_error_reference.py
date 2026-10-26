"""Keep strm probe failure references beside their original Chinese text."""

import sqlalchemy as sa
from alembic import op

revision = "b5e03c29f8a1"
down_revision = "a4d92b18e6f7"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("strm_probe_state", sa.Column("last_error_ref", sa.JSON(), nullable=True))


def downgrade():
    # 原生 DROP COLUMN：batch 会重建整表，撞上引用它的触发器
    op.drop_column("strm_probe_state", "last_error_ref")

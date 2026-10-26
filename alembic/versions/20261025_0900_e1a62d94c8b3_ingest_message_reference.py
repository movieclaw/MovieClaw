"""Keep watch-import conclusion references beside their original Chinese text."""

import sqlalchemy as sa
from alembic import op

revision = "e1a62d94c8b3"
down_revision = "d9f51c83b70a"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("ingest_entry", sa.Column("message_ref", sa.JSON(), nullable=True))


def downgrade():
    # 原生 DROP COLUMN：batch 会重建整表，撞上引用它的触发器
    op.drop_column("ingest_entry", "message_ref")

"""Keep job subject references beside their original Chinese text."""

import sqlalchemy as sa
from alembic import op

revision = "a4d92b18e6f7"
down_revision = "f3c81a07d2e5"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("job", sa.Column("subject_ref", sa.JSON(), nullable=True))


def downgrade():
    # 原生 DROP COLUMN：batch 会重建整表，撞上引用它的触发器
    op.drop_column("job", "subject_ref")

"""Keep download attempt cleanup-note references beside their original Chinese text."""

import sqlalchemy as sa
from alembic import op

revision = "f3c81a07d2e5"
down_revision = "e1a62d94c8b3"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "subscription_download_attempt", sa.Column("cleanup_note_ref", sa.JSON(), nullable=True)
    )


def downgrade():
    # 原生 DROP COLUMN：batch 会重建整表，撞上引用它的触发器
    op.drop_column("subscription_download_attempt", "cleanup_note_ref")

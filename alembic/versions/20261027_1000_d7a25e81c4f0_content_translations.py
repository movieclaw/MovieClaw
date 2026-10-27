"""Store interface-language titles and overviews beside the primary-language columns."""

import sqlalchemy as sa
from alembic import op

revision = "d7a25e81c4f0"
down_revision = "c6f14d3a9b72"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("media_item", sa.Column("title_translations", sa.JSON(), nullable=True))
    op.add_column("media_metadata", sa.Column("overview_translations", sa.JSON(), nullable=True))


def downgrade():
    # 原生 DROP COLUMN：batch 会重建整表，撞上引用它的触发器
    op.drop_column("media_metadata", "overview_translations")
    op.drop_column("media_item", "title_translations")

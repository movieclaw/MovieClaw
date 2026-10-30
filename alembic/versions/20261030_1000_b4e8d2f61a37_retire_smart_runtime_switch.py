"""Retire the hidden smart-subscription runtime switch (subscription.smart).

The switch never had a UI or API writer, so a stored ``enabled=false`` silently
blocked every smart subscription with no way back (#1093). The code no longer
reads it; drop the row so a rollback to an older build cannot revive it.
"""

from alembic import op

revision = "b4e8d2f61a37"
down_revision = "d7a25e81c4f0"
branch_labels = None
depends_on = None


def upgrade():
    op.execute("DELETE FROM app_setting WHERE namespace = 'subscription.smart'")


def downgrade():
    # 旧版本读不到该行时按默认值（全部开启）运行，无需恢复
    pass

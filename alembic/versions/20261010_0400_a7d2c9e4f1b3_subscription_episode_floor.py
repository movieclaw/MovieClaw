"""subscription.episode_floors / episode_evidence: episodes beyond what TMDB lists (issue #640).

TMDB often lists fewer episodes than a Chinese drama actually has (one show had 6
of 27). The expected set only knew TMDB's episodes, so the subscription stopped
after episode 6. ``episode_floors`` is the user-confirmed episode count per
season; ``episode_evidence`` keeps what the system saw (site torrents declaring
later episodes, the Douban episode count) so the subscription can suggest it.
Existing subscriptions have neither and stay NULL.
"""

import sqlalchemy as sa
from alembic import op

revision = "a7d2c9e4f1b3"
down_revision = "f3a9c1e7b2d4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("subscription", schema=None) as batch_op:
        batch_op.add_column(sa.Column("episode_floors", sa.JSON(), nullable=True))
        batch_op.add_column(sa.Column("episode_evidence", sa.JSON(), nullable=True))


# SQLite 删列要重建 subscription 表，活动表上引用它的触发器会让改名失败，
# 先摘后挂（同 smart_subscription 迁移）
_TRIGGER = """CREATE TRIGGER trg_subscription_activity_last_activity
    AFTER INSERT ON subscription_activity FOR EACH ROW BEGIN
    UPDATE subscription SET last_activity_at = MAX(last_activity_at, NEW.created_at)
    WHERE id = NEW.subscription_id; END"""


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_subscription_activity_last_activity")
    with op.batch_alter_table("subscription", schema=None) as batch_op:
        batch_op.drop_column("episode_evidence")
        batch_op.drop_column("episode_floors")
    op.execute(_TRIGGER)

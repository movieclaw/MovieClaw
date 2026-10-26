"""subscription.episode_caps: subscribe to part of a very long season at a time.

A single TMDB season can hold a thousand episodes (Chinese comic dramas, daily
shows). ``episode_caps`` is the per-season window the user chose, stored as
{"start": x, "end": y}: finished long seasons subscribe from episode 1
({"start": 1, "end": 20}); airing ones subscribe the latest batch with no upper
bound ({"start": aired-19, "end": null}) so future episodes keep flowing in.
The expected set simply stays inside the window and the subscription stays open
until the user widens or clears it. Existing subscriptions have no window and
stay NULL, i.e. whole seasons as before.

Revision ID: c5f1a8d3e7b2
Revises: f9b42d6a8e10
Create Date: 2026-10-18 10:30:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c5f1a8d3e7b2"
down_revision: str | None = "f9b42d6a8e10"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("subscription", schema=None) as batch_op:
        batch_op.add_column(sa.Column("episode_caps", sa.JSON(), nullable=True))


# SQLite 删列要重建 subscription 表，活动表上引用它的触发器会让改名失败，
# 先摘后挂（同 episode_floor 迁移）
_TRIGGER = """CREATE TRIGGER trg_subscription_activity_last_activity
    AFTER INSERT ON subscription_activity FOR EACH ROW BEGIN
    UPDATE subscription SET last_activity_at = MAX(last_activity_at, NEW.created_at)
    WHERE id = NEW.subscription_id; END"""


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_subscription_activity_last_activity")
    with op.batch_alter_table("subscription", schema=None) as batch_op:
        batch_op.drop_column("episode_caps")
    op.execute(_TRIGGER)

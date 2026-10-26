"""smart_memory: what smart subscriptions remember, plus per-subscription overrides.

Adds the single-row ``smart_memory`` table (languages the household understands and
quality habits scoped by kind / region / network) and ``subscription.smart_overrides``
(quality set for one title, or carried over from the previous title in a series).
See docs/design/smart-subscription-memory.md.

Smart settings become one set shared by movies and TV. When the two saved profiles
disagree on resolution or source, the TV values move into a "所有剧集" habit and the TV
profile takes the movie values, so every existing subscription resolves exactly as
before.

Revision ID: d7a2e4f9c615
Revises: c5f1a8e3d9b2
Create Date: 2026-10-21 12:00:00.000000

"""

import json
from collections.abc import Sequence
from datetime import UTC, datetime

import sqlalchemy as sa
from alembic import op

revision: str = "d7a2e4f9c615"
down_revision: str | None = "c5f1a8e3d9b2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "smart_memory",
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("languages", sa.JSON(), nullable=False),
        sa.Column("habits", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("subscription", schema=None) as batch_op:
        batch_op.add_column(sa.Column("smart_overrides", sa.JSON(), nullable=True))

    bind = op.get_bind()
    rows = {
        kind: json.loads(prefs) if isinstance(prefs, str) else prefs
        for kind, prefs in bind.execute(sa.text("SELECT kind, preferences FROM smart_profile"))
    }
    habits = []
    movie, tv = rows.get("movie"), rows.get("tv")
    if movie and tv:
        habit = {
            field: tv[field]
            for field in ("resolution", "source")
            if tv.get(field) and tv.get(field) != movie.get(field)
        }
        if habit:
            habits.append(
                {
                    "scope": "kind",
                    "value": "tv",
                    "kind": "tv",
                    **habit,
                    "source_title": None,
                    "at": None,
                }
            )
            merged = {**tv, **{f: movie[f] for f in habit}}
            bind.execute(
                sa.text("UPDATE smart_profile SET preferences = :p WHERE kind = 'tv'"),
                {"p": json.dumps(merged)},
            )
    now = datetime.now(UTC).replace(tzinfo=None)
    bind.execute(
        sa.text(
            "INSERT INTO smart_memory (id, created_at, updated_at, revision, languages, habits) "
            "VALUES (1, :now, :now, 0, '[]', :habits)"
        ),
        {"now": now, "habits": json.dumps(habits)},
    )


# SQLite 删列要重建 subscription 表，活动表上引用它的触发器会让改名失败，
# 先摘后挂（同 subscription_episode_floor 迁移）
_TRIGGER = """CREATE TRIGGER trg_subscription_activity_last_activity
    AFTER INSERT ON subscription_activity FOR EACH ROW BEGIN
    UPDATE subscription SET last_activity_at = MAX(last_activity_at, NEW.created_at)
    WHERE id = NEW.subscription_id; END"""


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_subscription_activity_last_activity")
    with op.batch_alter_table("subscription", schema=None) as batch_op:
        batch_op.drop_column("smart_overrides")
    op.execute(_TRIGGER)
    op.drop_table("smart_memory")

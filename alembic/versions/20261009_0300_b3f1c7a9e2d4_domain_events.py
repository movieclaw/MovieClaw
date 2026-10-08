"""domain_event / event_consumer / event_dead_letter: durable events for plugins.

Business code writes an event row in the same commit that records the fact
(transactional outbox); a dispatcher delivers it to each durable consumer in
order, at least once, with retries and a dead-letter table. Nothing is written
unless some plugin subscribes to the event, so existing deployments only gain
three empty tables. See docs/design/plugin-phase2a.md §2.
"""

import sqlalchemy as sa
from alembic import op

revision = "b3f1c7a9e2d4"
down_revision = "d5e8a2b7c914"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "domain_event",
        sa.Column("seq", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("id", sa.Text(), nullable=False, unique=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("version", sa.String(), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("origin_kind", sa.String(), nullable=False),
        sa.Column("origin_id", sa.String(), nullable=True),
        sa.Column("chain", sa.JSON(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(), nullable=False),
        sqlite_autoincrement=True,
    )
    op.create_index("ix_domain_event_name_seq", "domain_event", ["name", "seq"])
    op.create_index("ix_domain_event_occurred_at", "domain_event", ["occurred_at"])

    op.create_table(
        "event_consumer",
        sa.Column("consumer_id", sa.String(), primary_key=True),
        sa.Column("event_name", sa.String(), nullable=False),
        sa.Column("cursor", sa.Integer(), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(), nullable=True),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("last_seen_at", sa.DateTime(), nullable=False),
    )
    op.create_index("ix_event_consumer_event_name", "event_consumer", ["event_name"])

    op.create_table(
        "event_dead_letter",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("consumer_id", sa.String(), nullable=False),
        sa.Column("event_seq", sa.Integer(), nullable=False),
        sa.Column("event_id", sa.String(), nullable=False),
        sa.Column("event_name", sa.String(), nullable=False),
        sa.Column("error", sa.Text(), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("resolved_at", sa.DateTime(), nullable=True),
        sa.Column("resolution", sa.String(), nullable=True),
    )
    op.create_index("ix_event_dead_letter_consumer_id", "event_dead_letter", ["consumer_id"])
    op.create_index("ix_event_dead_letter_event_seq", "event_dead_letter", ["event_seq"])
    op.create_index("ix_event_dead_letter_resolved_at", "event_dead_letter", ["resolved_at"])


def downgrade() -> None:
    op.drop_table("event_dead_letter")
    op.drop_table("event_consumer")
    op.drop_table("domain_event")

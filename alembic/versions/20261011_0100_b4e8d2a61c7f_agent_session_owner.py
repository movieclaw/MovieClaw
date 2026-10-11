"""agent_session.owner: which plugin started a session (docs/design/plugin-agent.md §8).

Plugins can now drive the agent. Sessions they start record the owner
``plugin:<entry id>`` so a plugin only sees its own sessions and the web list can
mark them. The JSONL header carries the same value and the index rebuild
backfills it; sessions from before this column have no owner (web / admin).
"""

import sqlalchemy as sa
from alembic import op

revision = "b4e8d2a61c7f"
down_revision = "10b695b1836a"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("agent_session", schema=None) as batch_op:
        batch_op.add_column(sa.Column("owner", sa.String(), nullable=True))
        batch_op.create_index("ix_agent_session_owner", ["owner"], unique=False)


def downgrade() -> None:
    with op.batch_alter_table("agent_session", schema=None) as batch_op:
        batch_op.drop_index("ix_agent_session_owner")
        batch_op.drop_column("owner")

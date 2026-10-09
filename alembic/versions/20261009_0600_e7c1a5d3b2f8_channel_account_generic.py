"""channel_account: generic accounts for channel plugins.

Channels become plugins (docs/design/plugin-channels.md §6): account ids are
unique per channel instead of globally, and each account gets a display name
and a plugin-private state blob. Credentials and state of existing rows are
read in their old shape and rewritten on the next save, so nothing needs to be
decrypted here.
"""

import sqlalchemy as sa
from alembic import op

revision = "e7c1a5d3b2f8"
down_revision = "d6b9e3f2a1c5"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("channel_account", sa.Column("display_name", sa.String(), nullable=True))
    op.add_column("channel_account", sa.Column("state", sa.Text(), nullable=True))
    op.drop_index("ix_channel_account_account_id", table_name="channel_account")
    op.create_index("ix_channel_account_account_id", "channel_account", ["account_id"])
    op.create_index(
        "uq_channel_account_channel_account",
        "channel_account",
        ["channel_id", "account_id"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("uq_channel_account_channel_account", table_name="channel_account")
    op.drop_index("ix_channel_account_account_id", table_name="channel_account")
    op.create_index("ix_channel_account_account_id", "channel_account", ["account_id"], unique=True)
    op.drop_column("channel_account", "state")
    op.drop_column("channel_account", "display_name")

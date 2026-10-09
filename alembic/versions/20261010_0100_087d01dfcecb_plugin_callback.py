"""plugin_callback: keys of plugin callback endpoints.

Plugins can open addresses that outside platforms call into
(docs/design/plugin-callbacks.md section 4). Each row is one key under
/api/v1/hooks/<entry>/<name>/<key>; only its hash is stored.
"""

import sqlalchemy as sa
from alembic import op

revision = "087d01dfcecb"
down_revision = "e7c1a5d3b2f8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "plugin_callback",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("entry_id", sa.String(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("key_hash", sa.String(), nullable=False),
        sa.Column("key_tail", sa.String(), nullable=False),
        sa.Column("scope", sa.String(), nullable=False, server_default="plugin"),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("revoked_at", sa.DateTime(), nullable=True),
    )
    op.create_index("ix_plugin_callback_entry_id", "plugin_callback", ["entry_id"])
    op.create_index("ix_plugin_callback_key_hash", "plugin_callback", ["key_hash"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_plugin_callback_key_hash", table_name="plugin_callback")
    op.drop_index("ix_plugin_callback_entry_id", table_name="plugin_callback")
    op.drop_table("plugin_callback")

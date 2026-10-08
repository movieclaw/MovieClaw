"""plugin_data: per-plugin state and entity extension fields.

Plugins store their own state and data attached to entities (a keyword rule
on a subscription) in one table keyed by entry id, scope and key; a plugin can
only reach its own rows. Nothing is written until a plugin uses it. See
docs/design/plugin-phase2b.md §4.
"""

import sqlalchemy as sa
from alembic import op

revision = "d6b9e3f2a1c5"
down_revision = "c4a8d2e6f1b7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "plugin_data",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("entry_id", sa.String(), nullable=False),
        sa.Column("scope", sa.String(), nullable=False),
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column("value", sa.JSON(), nullable=True),
        sa.Column("secret", sa.Boolean(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("entry_id", "scope", "key", name="uq_plugin_data_key"),
    )
    op.create_index("ix_plugin_data_entry_id", "plugin_data", ["entry_id"])
    op.create_index("ix_plugin_data_scope", "plugin_data", ["scope"])


def downgrade() -> None:
    op.drop_table("plugin_data")

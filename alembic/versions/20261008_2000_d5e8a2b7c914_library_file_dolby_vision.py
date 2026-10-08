"""library_file: record the Dolby Vision profile and base-layer compatibility.

Playback decisions split Dolby Vision by profile: a TV that decodes the profile
plays the original file, P8 / P7 with a compatible base layer can play just the
HDR10 base layer, and only the rest needs server-side tone mapping. Existing
rows are filled by the startup backfill (library/dolby_vision_backfill.py).
"""

import sqlalchemy as sa
from alembic import op

revision = "d5e8a2b7c914"
down_revision = "c9a72e4d6b10"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("library_file") as batch:
        batch.add_column(sa.Column("dv_profile", sa.Integer(), nullable=True))
        batch.add_column(sa.Column("dv_bl_compatible", sa.Boolean(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("library_file") as batch:
        batch.drop_column("dv_bl_compatible")
        batch.drop_column("dv_profile")

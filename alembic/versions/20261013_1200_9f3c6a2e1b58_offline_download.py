"""offline download: member.allow_video_download + playback_log.viewing_id

iPhone 离线下载（docs/design/offline-download.md）：

- ``member.allow_video_download``：下载影片到设备的开关（member-permissions-v2.md §3.2），
  默认开 = 现状（Jellyfin 客户端一直对所有成员开放下载）；
- ``playback_log.viewing_id``：本机播放的观看记录编号（客户端生成的 UUID），离线补传按它幂等合并。

Revision ID: 9f3c6a2e1b58
Revises: 5b8d2e6f1a47
Create Date: 2026-10-13 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "9f3c6a2e1b58"
down_revision: str | None = "5b8d2e6f1a47"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("member") as batch:
        batch.add_column(
            sa.Column(
                "allow_video_download", sa.Boolean(), nullable=False, server_default=sa.true()
            )
        )
    with op.batch_alter_table("playback_log") as batch:
        batch.add_column(sa.Column("viewing_id", sa.String(), nullable=True))
        batch.create_index("ix_playback_log_viewing_id", ["viewing_id"], unique=True)


def downgrade() -> None:
    with op.batch_alter_table("playback_log") as batch:
        batch.drop_index("ix_playback_log_viewing_id")
        batch.drop_column("viewing_id")
    with op.batch_alter_table("member") as batch:
        batch.drop_column("allow_video_download")

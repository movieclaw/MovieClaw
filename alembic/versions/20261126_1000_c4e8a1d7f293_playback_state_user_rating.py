"""add playback_state.user_rating / rated_at

个人评分（docs/design/user-rating.md，issue #1292）：

- ``user_rating``（``SMALLINT NULL``）：1–10 整数（1 = 半星，10 = 5 星），``NULL`` = 未评分，
  与 Plex / Jellyfin / Trakt 零换算。
- ``rated_at``（``DATETIME NULL``）：最近一次评分的服务器时间，清除时置 ``NULL``；理由同
  ``favorited_at``——``updated_at`` 会被进度上报、轨记忆等其它写入改写。

落点单元复用收藏的哨兵约定（电影 ``(0,0)``、整剧 ``(-1,-1)``，季/集留好结构 ``(s,-1)`` /
``(s,e)`` 但第一期不开放）。

向前兼容：纯新增两列、可空、无默认值，存量行一律 ``NULL``；SQLite 与 PostgreSQL 均可直接运行，
旧版本回退后不认识它们，读写都不碰。

注：issue #1292 撰写时 head 为 ``a7d2e9c41b58``，上游随后合并了 ``be3b7498a20c``
（``downloader_verification_lease``），本迁移接在当前线性 head ``be3b7498a20c`` 之后。

Revision ID: c4e8a1d7f293
Revises: be3b7498a20c
Create Date: 2026-11-26 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c4e8a1d7f293"
down_revision: str | None = "be3b7498a20c"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("playback_state") as batch:
        batch.add_column(sa.Column("user_rating", sa.SmallInteger(), nullable=True))
        batch.add_column(sa.Column("rated_at", sa.DateTime(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("playback_state") as batch:
        batch.drop_column("rated_at")
        batch.drop_column("user_rating")

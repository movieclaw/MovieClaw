"""add playback_state.continue_dismissed

「接下来继续」的锚点是这部作品最近播放（``last_played_at``）的那一行，展示单元
是从锚点起第一个没看完的。清理插件只把 ``position_ms`` 清成 0 时，没看完
（``played=false``）的单元照样算"能接着看"，卡片不走；而把 played 改真是伪装
已看、清 last_played_at 会破坏流水，都不对。

新增一列显式记"用户不想在这一行再看到它"。只影响首页「接下来继续」，真正再
播放时清回 false。

向前兼容（CLAUDE.md 硬约束 3）：纯新增、NOT NULL 带 server_default 0，存量
行一律 false（= 今天的行为）；旧版本回退后不认识它，读写都不碰。

Revision ID: a7d2e9c41b58
Revises: d6a2e7c4f981
Create Date: 2026-11-09 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a7d2e9c41b58"
down_revision: str | None = "d6a2e7c4f981"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("playback_state") as batch:
        batch.add_column(
            sa.Column(
                "continue_dismissed",
                sa.Boolean(),
                nullable=False,
                server_default=sa.false(),
            )
        )


def downgrade() -> None:
    with op.batch_alter_table("playback_state") as batch:
        batch.drop_column("continue_dismissed")

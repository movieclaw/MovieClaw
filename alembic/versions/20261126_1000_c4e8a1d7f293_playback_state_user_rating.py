"""retain revision c4e8a1d7f293 as a no-op compatibility migration

PR #1332（个人评分）已从 main 撤回，本迁移原用于向 ``playback_state`` 新增
``user_rating`` / ``rated_at`` 两列。

保留本 revision 作为空操作兼容占位，确保：
- 曾运行过评分主干、库内 ``alembic_version`` 已推进至 ``c4e8a1d7f293`` 的隔离库，
  升级/切回当前主干时仍可正常启动，不会触发 ``UnknownRevisionError``；
- 这些库中已有的 ``user_rating`` / ``rated_at`` 列与用户评分数据原样保留为休眠数据，
  ``upgrade()`` 与 ``downgrade()`` 均不删列、不删数据；
- 全新安装及从 v0.52.1（``be3b7498a20c``）升级的库平稳推进到 ``c4e8a1d7f293``，
  不额外建未使用列，也不触发 SQLite 表重建。

若未来重新引入个人评分功能，新迁移在向 ``playback_state`` 添加 ``user_rating`` /
``rated_at`` 前须先检查列是否已存在，以兼容上述已含休眠列的数据库。

Revision ID: c4e8a1d7f293
Revises: be3b7498a20c
Create Date: 2026-11-26 10:00:00.000000
"""

from collections.abc import Sequence

revision: str = "c4e8a1d7f293"
down_revision: str | None = "be3b7498a20c"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass

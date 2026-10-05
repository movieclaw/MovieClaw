"""add site_credential.boost_downloader_id

刷流按站点选择下载器（docs/design/site-protection-ratio-boost.md「刷流下载器」）：
开启刷流时为该站选定投递的下载器，刷流做种与订阅/手动下载可以分到不同客户端。
删除下载器时 SET NULL，回到跟随默认下载器。

向前兼容：只加可空列和外键、无数据改写。存量站点为 NULL = 跟随默认下载器，
与引入本列之前的行为完全一致；回退到旧版本时旧代码忽略该列即可。

Revision ID: b3e7c1d9a5f2
Revises: 9d4b6a2e8f17
Create Date: 2026-10-04 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b3e7c1d9a5f2"
down_revision: str | None = "9d4b6a2e8f17"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("site_credential", schema=None) as batch_op:
        batch_op.add_column(sa.Column("boost_downloader_id", sa.Integer(), nullable=True))
        batch_op.create_foreign_key(
            "fk_site_credential_boost_downloader",
            "downloader_client",
            ["boost_downloader_id"],
            ["id"],
            ondelete="SET NULL",
        )


def downgrade() -> None:
    with op.batch_alter_table("site_credential", schema=None) as batch_op:
        batch_op.drop_constraint("fk_site_credential_boost_downloader", type_="foreignkey")
        batch_op.drop_column("boost_downloader_id")

"""add llm_provider 模型目录三列（docs/design/llm-model-catalog.md）

- ``model_listing``：服务商 /models 列表的缓存（拉取时间、来源、错误、条目）；
- ``model_visibility``：用户在「管理模型」里改过的显示/隐藏选择；
- ``catalog_id``：兼容端点对应的公共目录服务商（NULL = 按地址自动识别）。

全部可空：旧版本回退时忽略这些列，行为与迁移前一致。

Revision ID: 161724435305
Revises: b4e8d2f61a37
Create Date: 2026-10-30 12:00:00.000000

"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "161724435305"
down_revision: str | None = "b4e8d2f61a37"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("llm_provider", schema=None) as batch_op:
        batch_op.add_column(sa.Column("model_listing", sa.JSON(), nullable=True))
        batch_op.add_column(sa.Column("model_visibility", sa.JSON(), nullable=True))
        batch_op.add_column(sa.Column("catalog_id", sa.String(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("llm_provider", schema=None) as batch_op:
        batch_op.drop_column("catalog_id")
        batch_op.drop_column("model_visibility")
        batch_op.drop_column("model_listing")

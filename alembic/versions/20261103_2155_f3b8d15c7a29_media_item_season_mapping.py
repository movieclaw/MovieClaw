"""media_item.season_mapping: 站点季号 → TMDB 集号区间的映射（issue #1155）。

TMDB 偶尔把**实际分两季播出**的剧登记成一条连着编号的长季：《我独自升级》
``tv/127532`` 只有第 1 季、25 集，而第 13–25 集其实是隔了 280 天播出的第二季。
站点不认这套合并编号，照常拆成 S01（12 集）/ S02（13 集）发布，于是标着
``S02`` 的种子在匹配内核里永远覆盖不到订阅在等的 ``(1, 13..25)``。

本列存由 ``media_episode.air_date`` 的播出断档推出来的映射，形如
``[{"number": 2, "season": 1, "start": 13, "end": 25}]``（站点第 2 季 =
TMDB 第 1 季第 13–25 集）。推导规则见 ``movieclaw_matcher/seasons.py``。

三态与同表的 ``identity_twins`` 一致：NULL = 没算过、[] = 算过且无需映射
（普通剧恒为此值）、非空 = 有映射。**条目级属性**，多个订阅与库扫描共用。

向前兼容：纯加可空列，旧代码回退后忽略它；存量条目取 NULL（"没算过"），
下一次元数据刷新自动补齐，不需要数据迁移脚本。

Revision ID: f3b8d15c7a29
Revises: e2a7c4d91f63
Create Date: 2026-11-03 21:55:00.000000

"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f3b8d15c7a29"
down_revision: str | None = "e2a7c4d91f63"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("media_item", schema=None) as batch_op:
        batch_op.add_column(sa.Column("season_mapping", sa.JSON(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("media_item", schema=None) as batch_op:
        batch_op.drop_column("season_mapping")

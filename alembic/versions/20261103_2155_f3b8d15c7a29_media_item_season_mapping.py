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

# SQLite 的 ALTER TABLE 不支持改列，batch_alter_table 会重建整张 media_item：
# RENAME 旧表 → 建新表 → 拷数据 → DROP 旧表。**DROP TABLE 会连带删掉挂在该表上的
# 触发器**，而 ``library_search_media_item_{insert,update,delete}`` 正是挂在它上面的
# （20261004_1200_62d9a8c4f130 创建）。所以走 batch 之前先把它们摘下来、重建之后再挂回去，
# 否则降级后这些触发器永久消失，下一次 ``downgrade`` 到旧版本时
# ``DROP TRIGGER library_search_media_item_insert`` 会以 "no such trigger" 失败。
# 定义与 20261004_1200_62d9a8c4f130 逐字一致（那边也是同样的写法）。
_SEARCH_TRIGGERS = {
    event: (
        f"""CREATE TRIGGER IF NOT EXISTS library_search_media_item_{event.lower()}
            AFTER {event} ON media_item {condition}
            BEGIN
              INSERT INTO library_search_dirty(entity_kind, entity_id, revision)
              VALUES ('media', {"OLD" if event == "DELETE" else "NEW"}.id, 1)
              ON CONFLICT(entity_kind, entity_id) DO UPDATE SET revision = revision + 1;
            END"""
    )
    for event, condition in (
        ("INSERT", ""),
        (
            "UPDATE",
            "WHEN " + " OR ".join(
                f"OLD.{field} IS NOT NEW.{field}"
                for field in ("title", "original_title", "english_title", "aliases")
            ),
        ),
        ("DELETE", ""),
    )
}


def _drop_search_triggers(connection) -> None:
    """摘掉挂在 media_item 上的搜索索引触发器（batch 重建会连带删除它们）。"""
    for event in _SEARCH_TRIGGERS:
        connection.exec_driver_sql(f"DROP TRIGGER IF EXISTS library_search_media_item_{event.lower()}")


def _restore_search_triggers(connection) -> None:
    """把搜索索引触发器挂回去。

    ``library_search_dirty`` 表未必存在（更早的起点、或已降级到该迁移之前），
    这种情况下触发器本来就不该有，静默跳过——不能因此让迁移失败。
    """
    exists = connection.exec_driver_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'library_search_dirty'"
    ).first()
    if not exists:
        return
    for statement in _SEARCH_TRIGGERS.values():
        connection.exec_driver_sql(statement)


def upgrade() -> None:
    with op.batch_alter_table("media_item", schema=None) as batch_op:
        batch_op.add_column(sa.Column("season_mapping", sa.JSON(), nullable=True))
    _restore_search_triggers(op.get_bind())


def downgrade() -> None:
    connection = op.get_bind()
    _drop_search_triggers(connection)
    with op.batch_alter_table("media_item", schema=None) as batch_op:
        batch_op.drop_column("season_mapping")
    _restore_search_triggers(connection)

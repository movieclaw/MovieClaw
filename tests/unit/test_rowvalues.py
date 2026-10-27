"""tuple_in：结果与行值 IN 一致，且查询计划走索引查找（镜像 SQLite 3.40 的行值 IN 会整表扫描）。"""

from __future__ import annotations

from sqlalchemy import (
    Column,
    Index,
    Integer,
    MetaData,
    String,
    Table,
    create_engine,
    select,
    tuple_,
)

from movieclaw_db.rowvalues import tuple_in

_meta = MetaData()
_unit = Table(
    "unit",
    _meta,
    Column("id", Integer, primary_key=True),
    Column("item", Integer),
    Column("season", Integer),
    Column("episode", Integer),
    Column("name", String),
    Index("ix_unit_item_season_episode", "item", "season", "episode"),
)


def _engine():
    engine = create_engine("sqlite://")
    _meta.create_all(engine)
    with engine.begin() as conn:
        conn.execute(
            _unit.insert(),
            [
                {"item": i, "season": s, "episode": e, "name": f"{i}-{s}-{e}"}
                for i in range(1, 60)
                for s in range(0, 3)
                for e in range(0, 12)
            ],
        )
    return engine


def test_same_rows_as_plain_tuple_in() -> None:
    engine = _engine()
    wanted = [(7, 1, 4), (7, 2, 11), (31, 0, 0), (59, 2, 3), (99, 1, 1)]
    cols = (_unit.c.item, _unit.c.season, _unit.c.episode)
    with engine.connect() as conn:
        plain = conn.execute(select(_unit.c.name).where(tuple_(*cols).in_(wanted))).scalars()
        fast = conn.execute(select(_unit.c.name).where(tuple_in(cols, wanted))).scalars()
        assert sorted(fast) == sorted(plain) == ["31-0-0", "59-2-3", "7-1-4", "7-2-11"]


def test_query_plan_searches_index() -> None:
    engine = _engine()
    stmt = select(_unit.c.name).where(
        tuple_in((_unit.c.item, _unit.c.season, _unit.c.episode), [(7, 1, 4), (31, 0, 0)])
    )
    compiled = stmt.compile(engine, compile_kwargs={"literal_binds": True})
    with engine.connect() as conn:
        plan = [row[3] for row in conn.exec_driver_sql(f"EXPLAIN QUERY PLAN {compiled}")]
    assert any(step.startswith("SEARCH unit USING") for step in plan), plan
    assert not any(step.startswith("SCAN unit") for step in plan), plan

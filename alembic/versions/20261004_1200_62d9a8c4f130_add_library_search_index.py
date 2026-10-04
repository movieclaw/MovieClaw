"""媒体库名称搜索索引及持久化增量队列。

只新增派生表和轻量触发器，旧程序仍可读写业务表。拼音转换由应用后台执行，
触发器仅在名称字段变化时标记实体；同一事务记录变化，进程退出也不会丢更新。

Revision ID: 62d9a8c4f130
Revises: b3e7c1d9a5f2
"""

from collections.abc import Sequence

from alembic import op

revision: str = "62d9a8c4f130"
down_revision: str | None = "b3e7c1d9a5f2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("""CREATE TABLE library_search_document (
        id INTEGER PRIMARY KEY,
        entity_kind TEXT NOT NULL,
        entity_id INTEGER NOT NULL,
        index_version INTEGER NOT NULL,
        UNIQUE(entity_kind, entity_id)
    )""")
    op.execute("""CREATE TABLE library_search_name (
        id INTEGER PRIMARY KEY,
        document_id INTEGER NOT NULL REFERENCES library_search_document(id) ON DELETE CASCADE,
        source_field TEXT NOT NULL,
        raw_name TEXT NOT NULL,
        normalized TEXT NOT NULL,
        pinyin TEXT NOT NULL,
        initials TEXT NOT NULL
    )""")
    for field in ("normalized", "pinyin", "initials"):
        op.execute(f"CREATE INDEX ix_library_search_name_{field} ON library_search_name({field})")
    op.execute("CREATE INDEX ix_library_search_name_document ON library_search_name(document_id)")
    op.execute("CREATE VIRTUAL TABLE library_search_fts USING fts5(name_tokens)")
    op.execute("""CREATE TABLE library_search_dirty (
        entity_kind TEXT NOT NULL,
        entity_id INTEGER NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(entity_kind, entity_id)
    )""")
    for table, kind, fields in (
        ("media_item", "media", ("title", "original_title", "english_title", "aliases")),
        ("person", "person", ("name", "original_name")),
    ):
        for event in ("INSERT", "UPDATE", "DELETE"):
            ref = "OLD" if event == "DELETE" else "NEW"
            condition = ""
            if event == "UPDATE":
                condition = "WHEN " + " OR ".join(f"OLD.{f} IS NOT NEW.{f}" for f in fields)
            op.execute(f"""CREATE TRIGGER library_search_{table}_{event.lower()}
                AFTER {event} ON {table} {condition}
                BEGIN
                  INSERT INTO library_search_dirty(entity_kind, entity_id, revision)
                  VALUES ('{kind}', {ref}.id, 1)
                  ON CONFLICT(entity_kind, entity_id) DO UPDATE SET revision = revision + 1;
                END""")
        op.execute(f"""INSERT INTO library_search_dirty(entity_kind, entity_id)
            SELECT '{kind}', id FROM {table}""")


def downgrade() -> None:
    for table in ("media_item", "person"):
        for event in ("insert", "update", "delete"):
            op.execute(f"DROP TRIGGER library_search_{table}_{event}")
    for table in (
        "library_search_fts",
        "library_search_name",
        "library_search_document",
        "library_search_dirty",
    ):
        op.execute(f"DROP TABLE {table}")

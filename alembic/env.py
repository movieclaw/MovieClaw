"""Alembic 迁移环境。

关键设计：
1. 目标元数据取自 ``SQLModel.metadata``。为此必须先导入所有表模型（通过
   ``movieclaw_db.models`` 的集中导入），否则 autogenerate 会认为没有任何表。
2. 数据库 URL 从应用的 Settings 读取，并把异步驱动 ``sqlite+aiosqlite`` 转换为
   同步的 ``sqlite``（pysqlite，标准库自带）。迁移是一次性、短暂的 DDL 操作，
   用同步驱动最简单可靠，无需在 Alembic 里处理 async。
"""

from __future__ import annotations

import os
import time
from logging.config import fileConfig
from pathlib import Path

from alembic import context
from sqlalchemy import Engine, engine_from_config, event, pool
from sqlmodel import SQLModel

# 导入所有 ORM 模型 —— 触发它们注册到 SQLModel.metadata（autogenerate 必需）
import movieclaw_db.models  # noqa: F401
from movieclaw_api.core.config import get_settings

# Alembic Config 对象，读取 alembic.ini
config = context.config

# 配置日志（供独立运行 alembic CLI 时按 alembic.ini 输出迁移日志）。
# 关键：必须传 disable_existing_loggers=False。fileConfig 默认会禁用所有"配置文件
# 未显式声明"的既有 logger——而本 env 也会在应用启动时被 run_migrations() 调用，
# 若采用默认值，会连带把应用自己的 logger（如 movieclaw_api.access 访问日志、
# 错误日志）一并禁用，导致启动迁移后日志静默失效。
if config.config_file_name is not None:
    fileConfig(config.config_file_name, disable_existing_loggers=False)

# autogenerate 的对比基准
target_metadata = SQLModel.metadata


def _sync_database_url() -> str:
    """从应用 Settings 取 URL，并转为同步 sqlite 驱动供迁移使用。"""
    url = get_settings().database_url
    # sqlite+aiosqlite:///xxx -> sqlite:///xxx
    return url.replace("+aiosqlite", "")


def run_migrations_offline() -> None:
    """离线模式：不建立真实连接，仅生成 SQL 脚本。"""
    context.configure(
        url=_sync_database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        # SQLite 的 ALTER 能力有限，开启批处理模式以支持列变更等操作
        render_as_batch=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def _make_sqlite_ddl_transactional(engine: Engine) -> None:
    """让每个迁移成为真正的原子事务：中途被杀就整体回滚，下次启动从头重跑它。

    pysqlite 默认只在 INSERT/UPDATE/DELETE 前隐式 BEGIN，CREATE/ALTER/DROP 一律
    自动提交——alembic 名义上「每个迁移一个事务」，实际 DDL 执行一条落盘一条。
    慢盘首装迁移跑到一半被入口脚本的启动超时杀掉时，就会留下「表已建好、版本号
    没前进」的半截状态，此后每次启动都在同一句 CREATE TABLE 上报 already exists，
    容器永久起不来。这里按 SQLAlchemy 文档的做法关掉驱动自己的事务管理，由
    SQLAlchemy 在 begin 时显式发 BEGIN，DDL 才真正进事务。

    同时与应用连接保持一致用 WAL + synchronous=NORMAL：提交不再逐条 fsync，
    慢盘上首装上百个迁移的耗时从分钟级降下来；中断时未提交的事务同样整体作废。
    """

    @event.listens_for(engine, "connect")
    def _on_connect(dbapi_conn, _connection_record) -> None:  # type: ignore[no-untyped-def]
        dbapi_conn.isolation_level = None
        cursor = dbapi_conn.cursor()
        cursor.execute("PRAGMA journal_mode=WAL;")
        cursor.execute("PRAGMA synchronous=NORMAL;")
        cursor.close()

    @event.listens_for(engine, "begin")
    def _on_begin(conn) -> None:  # type: ignore[no-untyped-def]
        conn.exec_driver_sql("BEGIN")


def _report_progress(**_kwargs) -> None:  # type: ignore[no-untyped-def]
    """每完成一个迁移写一次心跳（当前时间戳），供入口脚本区分「迁移还在推进」
    与「真卡死」：慢盘首装要跑上百个迁移，总耗时可能远超启动超时，但只要心跳
    还在刷新就不该杀进程。只有入口脚本给了路径才写；写失败不影响迁移本身。"""
    path = os.environ.get("MOVIECLAW_MIGRATION_PROGRESS_FILE")
    if not path:
        return
    try:
        target = Path(path)
        tmp = target.with_name(target.name + ".tmp")
        tmp.write_text(str(int(time.time())), encoding="utf-8")
        tmp.replace(target)
    except OSError:
        pass


def run_migrations_online() -> None:
    """在线模式：建立连接并执行迁移。"""
    configuration = config.get_section(config.config_ini_section) or {}
    configuration["sqlalchemy.url"] = _sync_database_url()

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    _make_sqlite_ddl_transactional(connectable)

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            # SQLite 不支持大多数 ALTER TABLE，批处理模式会以"建新表+拷贝"方式实现
            render_as_batch=True,
            # 每个迁移连同版本号推进一起提交：中断只丢当前这一个，已完成的保留，
            # 慢机反复重启也能逐步推进到 head
            transactional_ddl=True,
            transaction_per_migration=True,
            on_version_apply=_report_progress,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()

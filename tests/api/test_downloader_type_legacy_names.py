"""下载器类型列的旧存法（成员名）兼容。

早期 ``client_type`` 按枚举声明，库里存的是 "QBITTORRENT" 这样的成员名。列放开成字符串后
必须读成 "qbittorrent"，否则按类型查适配器全部落空——升级后 NAS 上所有下载器报「尚未支持」。
内置两种写回仍存成员名，回退旧版本照样能读；插件登记的类型原样存取。
"""

from __future__ import annotations

import pytest_asyncio
from sqlalchemy import text
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import DownloaderClient
from movieclaw_downloader import DownloaderConfig
from movieclaw_downloader.registry import builtin_adapters


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'dl.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def test_legacy_member_names_read_as_type_values(db) -> None:
    async with db.session() as session:
        for name, legacy in (("qb", "QBITTORRENT"), ("tr", "TRANSMISSION")):
            await session.execute(
                text(
                    "INSERT INTO downloader_client (created_at, updated_at, name, client_type, url,"
                    " enabled, status) VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, :name, :type,"
                    " 'http://x', 1, 'ACTIVE')"
                ),
                {"name": name, "type": legacy},
            )
        await session.commit()
    async with db.session() as session:
        rows = {r.name: r for r in (await session.execute(select(DownloaderClient))).scalars()}
    assert rows["qb"].client_type == "qbittorrent"
    assert rows["tr"].client_type == "transmission"
    adapters = builtin_adapters()
    for row in rows.values():
        # 读出来的值能直接查到适配器（线上故障就是这里查不到）
        assert DownloaderConfig(type=row.client_type, url=row.url).type in adapters


async def test_writes_stay_readable_by_older_versions(db) -> None:
    async with db.session() as session:
        session.add(DownloaderClient(name="qb", client_type="qbittorrent", url="http://x"))
        session.add(DownloaderClient(name="mem", client_type="memory", url="http://y"))
        await session.commit()
        raw = dict(
            (await session.execute(text("SELECT name, client_type FROM downloader_client"))).all()
        )
        # 内置类型仍存成员名（旧版本按枚举名读），插件类型原样
        assert raw == {"qb": "QBITTORRENT", "mem": "memory"}
        found = (
            await session.execute(
                select(DownloaderClient).where(DownloaderClient.client_type == "qbittorrent")
            )
        ).scalar_one()
        assert found.name == "qb"

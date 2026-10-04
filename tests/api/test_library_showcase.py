"""海报行「选中展开」的批量展示信息（GET /libraries/showcase）。

电视首页焦点停在一张海报上时，它展开成横版剧照卡、下面写类型 / 片长 / 分级与
两行简介；客户端拿一行的条目 id 整批取一次。这里守三件事：字段拼得对（本地
资产优先、回落 TMDB）、按传入顺序返回、看不见的库里的条目不给。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    FileSource,
    FileState,
    Library,
    LibraryFile,
    MediaItem,
    MediaMetadata,
    utcnow,
)


@pytest.fixture
def stack(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'showcase.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()

    async def _seed() -> None:
        init_db(get_settings().database_url, echo=False)
        await run_migrations()
        async with get_database().session() as session:
            public = Library(name="电影", kind="movie", root_paths=[str(tmp_path / "a")])
            # 只对白名单开放、且没把成员加进去：成员看不见这个库
            private = Library(
                name="私藏",
                kind="movie",
                root_paths=[str(tmp_path / "b")],
                access_mode="selected",
            )
            session.add_all([public, private])
            await session.flush()
            specs = [
                # (片名, 所在库, 本地 Logo, TMDB 剧照路径, 简介)
                ("有 Logo 的", public, "items/1/clearlogo.png", "/bd1.jpg", "  一段简介。 "),
                ("只有 TMDB 的", public, None, "/bd2.jpg", None),
                ("私藏片", private, None, "/bd3.jpg", "不该被看到"),
            ]
            for index, (title, library, logo_file, backdrop_path, overview) in enumerate(specs):
                item = MediaItem(
                    kind="movie",
                    tmdb_id=70_000 + index,
                    title=title,
                    original_title=title,
                    year=2006,
                    backdrop_path=backdrop_path,
                    logo_path="" if logo_file is None else "/logo.png",
                )
                session.add(item)
                await session.flush()
                session.add_all(
                    [
                        MediaMetadata(
                            media_item_id=item.id,
                            overview=overview,
                            genres=["剧情", "喜剧", "爱情"],
                            runtime_minutes=109,
                            content_rating="PG-13",
                            logo_file=logo_file,
                            scraped_at=utcnow(),
                        ),
                        LibraryFile(
                            library_id=library.id,
                            media_item_id=item.id,
                            season_number=0,
                            episode_number=0,
                            file_path=str(tmp_path / f"{index}.mkv"),
                            size_bytes=4096,
                            source=FileSource.SCANNED,
                            state=FileState.IN_PLACE,
                        ),
                    ]
                )
            await session.commit()
        await dispose_db()

    asyncio.run(_seed())

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal
    from movieclaw_db.models import Member

    app = create_app()
    state: dict[str, object] = {"member": None}

    def _principal() -> Principal:
        member = state["member"]
        if member is None:
            return Principal(kind="admin", name="admin")
        return Principal(kind="member", name=member.username, member=member)

    app.dependency_overrides[require_login] = _principal
    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/members",
            json={"username": "viewer", "password": "viewer-pass-1", "nickname": "家人"},
        )
        assert resp.status_code == 200, resp.text
        member_id = resp.json()["data"]["id"]

        def become_member() -> None:
            async def _load():
                async with get_database().session() as session:
                    return await session.get(Member, member_id)

            state["member"] = asyncio.run(_load())

        yield client, become_member
    get_settings.cache_clear()


def _showcase(client: TestClient, *ids: int) -> list[dict]:
    query = "&".join(f"ids={i}" for i in ids)
    resp = client.get(f"/api/v1/libraries/showcase?{query}")
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def test_fields_and_order(stack) -> None:
    client, _ = stack
    rows = _showcase(client, 2, 1)
    # 按传入顺序，不按 id
    assert [row["media_item_id"] for row in rows] == [2, 1]
    tmdb_only, with_logo = rows

    # 本地 Logo 资产优先（带版本号）；剧照回落 TMDB 的 w1280（展开卡 4K 下要 1600px）
    assert with_logo["logo_url"].startswith("/images/assets/items/1/clearlogo.png?v=")
    assert with_logo["backdrop_url"].endswith("/w1280/bd1.jpg")
    # logo_path 为空串 = TMDB 确认没有 Logo：按没有处理，前端写文字片名
    assert tmdb_only["logo_url"] is None
    assert with_logo["overview"] == "一段简介。"
    assert tmdb_only["overview"] is None
    assert with_logo["genres"] == ["剧情", "喜剧", "爱情"]
    assert with_logo["runtime_minutes"] == 109
    assert with_logo["content_rating"] == "PG-13"


def test_unknown_and_duplicate_ids_are_skipped(stack) -> None:
    client, _ = stack
    assert [row["media_item_id"] for row in _showcase(client, 1, 999, 1)] == [1]


def test_invisible_library_is_skipped(stack) -> None:
    """白名单库里的条目，没被授权的成员拿到 id 也取不到它的剧照与简介。"""
    client, become_member = stack
    assert {row["media_item_id"] for row in _showcase(client, 1, 2, 3)} == {1, 2, 3}

    become_member()
    assert {row["media_item_id"] for row in _showcase(client, 1, 2, 3)} == {1, 2}

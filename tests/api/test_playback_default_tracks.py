"""默认轨策略的端到端（``movieclaw_playback.track_policy`` 接到各入口）。

音轨跟片子走（TMDB 原始语言）、字幕跟人走（媒体库的元数据主语言）。这里测上下文真的从库里取到了、
各入口用的是同一个结论：起播决策、进度上报的「是不是默认挑选」、详情页标的「默认」，
以及取上下文只多一条 SQL。
"""

from __future__ import annotations

import itertools
from functools import partial
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event, select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.playback.track_context import track_contexts
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileSource,
    FileState,
    Library,
    LibraryFile,
    MediaItem,
    MediaMetadata,
)
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_playback.track_policy import TrackContext

_PB = "/api/v1/playback"
_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}
#: App 的自研引擎：全解码、直读原文件（决策直接给档 0，不起 ffmpeg）
_APP = {"universal": True}

#: 英文片：国语配音标了默认，英语原声排第二；字幕英文标了默认，中文排第二
_AUDIO = [
    {"codec": "aac", "channels": 2, "language": "chi", "default": True},
    {"codec": "aac", "channels": 2, "language": "eng", "default": False},
]
_SUBS = [
    {"codec": "subrip", "language": "eng", "default": True, "forced": False},
    {"codec": "subrip", "language": "chi", "default": False, "forced": False},
]


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'tracks.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    monkeypatch.setattr("movieclaw_api.api.routes.playback.available_backends", lambda: ())

    from movieclaw_api.app import create_app

    with TestClient(create_app(), headers={"Accept-Language": "zh-Hans"}) as c:
        c.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


_seed_counter = itertools.count(1)


async def _seed(tmp_path: Path, original_language: str | None) -> tuple[int, int]:
    """建库 + 条目（带原始语言）+ 一个在位文件，返回 (library_id, media_item_id)。"""
    n = next(_seed_counter)
    root = tmp_path / f"movies{n}"
    root.mkdir(exist_ok=True)
    path = root / f"Movie{n}.2010.1080p.mp4"
    path.write_bytes(b"FAKE-MEDIA-BYTES" * 64)
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name=f"电影库{n}", kind="movie", root_paths=[str(root)]
        )
        item = MediaItem(kind="movie", tmdb_id=n, title=f"示例{n}", original_title=f"Movie{n}")
        session.add(item)
        await session.flush()
        session.add(MediaMetadata(media_item_id=item.id, original_language=original_language))
        session.add(
            LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(path),
                size_bytes=path.stat().st_size,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                container="mp4",
                video_codec="h264",
                resolution="1080p",
                duration_seconds=600,
                audio_streams=_AUDIO,
                subtitle_streams=_SUBS,
                external_subtitles=[],
            )
        )
        await session.commit()
        assert library.id is not None and item.id is not None
        return library.id, item.id


def seed(
    client: TestClient, tmp_path: Path, original_language: str | None = "en"
) -> tuple[int, int]:
    return client.portal.call(partial(_seed, tmp_path, original_language))  # type: ignore[attr-defined]


async def _set_library_language(library_id: int, language: str) -> None:
    async with get_database().session() as session:
        library = await session.get(Library, library_id)
        assert library is not None
        library.scrape_overrides = {"language_priority": [language]}
        await session.commit()


def decide(client: TestClient, item_id: int, **extra) -> dict:
    resp = client.post(
        f"{_PB}/decide", json={"media_item_id": item_id, "capability": _APP, **extra}
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def default_subtitle(decision: dict) -> str | None:
    return next((s["track_ref"] for s in decision["subtitles"] if s["is_default"]), None)


def report(client: TestClient, item_id: int, **body) -> None:
    resp = client.post(f"{_PB}/progress", json={"media_item_id": item_id, **body})
    assert resp.status_code == 200, resp.text


def remembered(client: TestClient, item_id: int) -> tuple[str | None, str | None]:
    resp = client.get(f"{_PB}/resume", params={"media_item_id": item_id})
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    return data["audio_track"], data["subtitle_track"]


def detail_defaults(client: TestClient, library_id: int, item_id: int) -> dict:
    resp = client.get(f"/api/v1/libraries/{library_id}/items/{item_id}")
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]["files"][0]["playback_defaults"]


# ---------------------------------------------------------------------------
# 起播决策
# ---------------------------------------------------------------------------


def test_decide_plays_the_original_language_with_library_language_subtitles(client, tmp_path):
    """中文库（默认 zh-CN）里的英文片：放英语原声、开中文字幕——都不是容器标的默认轨。
    轨列表里的 is_default 仍是容器旗标（网页端据此判断直出放的是哪条）。"""
    _, item_id = seed(client, tmp_path)
    decision = decide(client, item_id)
    assert decision["audio"]["track_ref"] == "embedded:1"
    assert [t["is_default"] for t in decision["audio_tracks"]] == [True, False]
    assert default_subtitle(decision) == "embedded:1"


def test_the_library_language_decides_the_subtitles(client, tmp_path):
    """同一部英文片放进英文库：原声就是库语言，不开字幕（没有强制字幕）。"""
    library_id, item_id = seed(client, tmp_path)
    client.portal.call(partial(_set_library_language, library_id, "en-US"))  # type: ignore[attr-defined]
    decision = decide(client, item_id)
    assert decision["audio"]["track_ref"] == "embedded:1"
    assert default_subtitle(decision) is None


def test_picking_the_dub_turns_the_library_language_subtitles_on_in_any_library(
    client, tmp_path
):
    """英文库里用户换成国语配音：放的不再是库语言，开英文字幕——字幕看的是将要放的那条音轨。"""
    library_id, item_id = seed(client, tmp_path)
    client.portal.call(partial(_set_library_language, library_id, "en-US"))  # type: ignore[attr-defined]
    assert default_subtitle(decide(client, item_id, audio_track="embedded:0")) == "embedded:0"


def test_without_an_original_language_the_container_default_audio_plays(client, tmp_path):
    """没刮削到原始语言：音轨照旧按容器默认旗标。"""
    _, item_id = seed(client, tmp_path, original_language=None)
    assert decide(client, item_id)["audio"]["track_ref"] == "embedded:0"


# ---------------------------------------------------------------------------
# 进度上报：「是不是默认挑选」按同一个策略判断
# ---------------------------------------------------------------------------


def test_reports_are_judged_against_the_track_policy(client, tmp_path):
    """报上来的是英语原声（策略挑的）不记；换成国语配音（恰好是容器默认轨）才是用户的选择。"""
    _, item_id = seed(client, tmp_path)
    report(client, item_id, event="start", audio_track="embedded:1", subtitle_track="embedded:1")
    assert remembered(client, item_id) == (None, None)
    report(client, item_id, event="progress", position_ms=60_000, audio_track="embedded:0")
    assert remembered(client, item_id) == ("embedded:0", None)


# ---------------------------------------------------------------------------
# 详情页标的「默认」
# ---------------------------------------------------------------------------


def test_item_detail_marks_what_will_play_and_why(client, tmp_path):
    library_id, item_id = seed(client, tmp_path)
    defaults = detail_defaults(client, library_id, item_id)
    assert defaults == {
        "audio_track": "embedded:1",
        "audio_reason": "original_language",
        "audio_note": "影片原声",
        "subtitle_track": "embedded:1",
        "subtitle_reason": "library_language",
        "subtitle_note": "媒体库语言的字幕",
    }
    # 用户换过的记住了：详情页跟着变，理由也说清楚
    report(client, item_id, event="start", audio_track="embedded:0", subtitle_track="off")
    defaults = detail_defaults(client, library_id, item_id)
    assert (defaults["audio_track"], defaults["audio_reason"]) == ("embedded:0", "remembered")
    assert (defaults["subtitle_track"], defaults["subtitle_note"]) == (
        None,
        "你上次看时关掉了字幕",
    )


# ---------------------------------------------------------------------------
# 开销：上下文一条 SQL 取完
# ---------------------------------------------------------------------------


async def _contexts_with_statements(item_id: int) -> tuple[dict[int, TrackContext], list[str]]:
    engine = get_database().engine.sync_engine
    captured: list[str] = []

    def capture(_conn, _cursor, statement, _parameters, _context, _executemany) -> None:
        captured.append(statement)

    async with get_database().session() as session:
        files = list(
            (
                await session.execute(
                    select(LibraryFile).where(LibraryFile.media_item_id == item_id)
                )
            ).scalars()
        )
        event.listen(engine, "before_cursor_execute", capture)
        try:
            contexts = await track_contexts(session, files)
        finally:
            event.remove(engine, "before_cursor_execute", capture)
    return contexts, captured


def test_track_contexts_take_one_statement(client, tmp_path):
    library_id, item_id = seed(client, tmp_path)
    client.portal.call(partial(_set_library_language, library_id, "zh-TW"))  # type: ignore[attr-defined]
    contexts, statements = client.portal.call(  # type: ignore[attr-defined]
        partial(_contexts_with_statements, item_id)
    )
    assert len(statements) == 1, statements
    assert list(contexts.values()) == [TrackContext("chi", "hant", "eng")]

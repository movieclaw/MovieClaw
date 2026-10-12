"""媒体库内容变了就通知媒体服务器刷新（domain-events.md §6.4）：订阅系统事件、一阵子合成一次。"""

from __future__ import annotations

import asyncio
import time

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import media_server_notify as notify
from movieclaw_sdk.events import (
    LIBRARY_FILE_TRASHED,
    LIBRARY_FILES_ADDED,
    AddedFile,
    FileRecycled,
    FileRef,
    FilesAdded,
)


async def test_refresher_merges_a_burst_and_caps_the_wait(monkeypatch) -> None:
    monkeypatch.setattr(notify, "QUIET_S", 0.1)
    monkeypatch.setattr(notify, "MAX_WAIT_S", 0.35)
    fired: list[float] = []

    async def refresh() -> bool:
        fired.append(time.monotonic())
        return True

    monkeypatch.setattr(notify, "notify_media_server_refresh", refresh)
    refresher = notify.Refresher(lambda coro: asyncio.ensure_future(coro))
    # 一串变化：合成一次
    for _ in range(3):
        refresher.poke()
        await asyncio.sleep(0.02)
    await asyncio.sleep(0.2)
    assert len(fired) == 1
    # 一直在变：最多等 MAX_WAIT_S 也刷一次
    start = time.monotonic()
    for _ in range(12):
        refresher.poke()
        await asyncio.sleep(0.05)
    assert len(fired) == 2 and fired[1] - start < 0.5
    refresher.close()


@pytest.fixture
def app_with_media_server(tmp_path, monkeypatch):  # type: ignore[no-untyped-def]
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ms.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_SERVER_URL", "http://emby:8096")
    monkeypatch.setenv("MEDIA_SERVER_TYPE", "emby")
    monkeypatch.setattr(notify, "QUIET_S", 0.1)
    get_settings.cache_clear()
    calls: list[int] = []

    async def refresh() -> bool:
        calls.append(1)
        return True

    monkeypatch.setattr(notify, "notify_media_server_refresh", refresh)
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as client:
        yield client, calls
    get_settings.cache_clear()


def _publish(client: TestClient, event, payload) -> None:  # type: ignore[no-untyped-def]
    from movieclaw_api import events

    async def run() -> None:
        await events.publish_now(event, lambda: payload)

    client.portal.call(run)


def test_library_changes_refresh_the_media_server_once(app_with_media_server) -> None:  # type: ignore[no-untyped-def]
    client, calls = app_with_media_server
    added = FilesAdded(library_id=1, files=(AddedFile(id=1, media_item_id=None),))
    trashed = FileRecycled(file=FileRef(id=1, library_id=1, path="/m/a.mkv"), media=None)
    _publish(client, LIBRARY_FILES_ADDED, added)
    _publish(client, LIBRARY_FILE_TRASHED, trashed)
    deadline = time.monotonic() + 5
    while not calls and time.monotonic() < deadline:
        time.sleep(0.05)
    time.sleep(0.3)
    assert calls == [1]


def test_unconfigured_media_server_subscribes_to_nothing(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ms0.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_SERVER_URL", "")
    get_settings.cache_clear()
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as client:
        bus = client.app.state.kernel.bus
        # 没配媒体服务器：库变化事件上没有它的监听器（零开销）
        owners = {listener.entry_id for listener in bus.listeners(LIBRARY_FILES_ADDED)}
        assert "library.media-server-refresh" not in owners
    get_settings.cache_clear()

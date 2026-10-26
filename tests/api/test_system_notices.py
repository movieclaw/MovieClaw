"""待处理事项（状态化告警中心）的端到端测试。

以下载器验证这条真实写入点驱动全生命周期，覆盖状态机的四条关键语义：
- 失败点亮 / 恢复自动熄灭（upsert → resolve）；
- 同一问题幂等收敛为一行（dedupe_key 唯一）；
- 用户 dismiss 后同一问题持续沉默，但问题消失仍会被自动清场；
- 清场（resolved）后问题复发重新点亮。

假下载器与 test_downloaders 同构：url 含 "unreachable" 即模拟连不上，
BackgroundTasks 在 TestClient 响应后同步执行完毕，状态断言无需等待。
"""
from __future__ import annotations

import sqlite3

import pytest
from fastapi.testclient import TestClient

import movieclaw_api.services.downloader_config as downloader_service
from movieclaw_api.core.config import get_settings
from movieclaw_downloader import DownloaderConnectError, DownloaderInfo
from movieclaw_downloader.models import DownloaderConfig

_UNREACHABLE_MARK = "unreachable"


class _FakeDownloader:
    """假适配器：跳过真实网络，按 url 决定测试结果。"""

    def __init__(self, config: DownloaderConfig) -> None:
        self.config = config

    async def test_connection(self) -> DownloaderInfo:
        if _UNREACHABLE_MARK in self.config.url:
            raise DownloaderConnectError("无法连接到 qBittorrent，请检查 WebUI 地址和端口")
        return DownloaderInfo(type=self.config.type, version="v5.0.2")

    async def close(self) -> None:
        pass


@pytest.fixture
def client(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    monkeypatch.setattr(downloader_service, "create_downloader", _FakeDownloader)

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app, headers={"Accept-Language": "zh-Hans"}) as c:
        yield c, db_file
    get_settings.cache_clear()


_PAYLOAD = {
    "name": "qb",
    "client_type": "qbittorrent",
    "url": "http://unreachable:8080",
    "username": "admin",
    "password": "s3cret",
    "save_path": "/downloads",
}


def _create_failing(c: TestClient) -> int:
    r = c.post("/api/v1/downloaders", json=_PAYLOAD)
    assert r.status_code == 200
    return r.json()["data"]["id"]


def _notices(c: TestClient) -> list[dict]:
    r = c.get("/api/v1/system/notices")
    assert r.status_code == 200
    return r.json()["data"]


def _rows(db_file) -> list[tuple[str, str]]:
    return (
        sqlite3.connect(db_file).execute("SELECT dedupe_key, status FROM system_notice").fetchall()
    )


def test_failure_lights_notice_and_recovery_resolves(client) -> None:
    c, db_file = client
    downloader_id = _create_failing(c)

    active = _notices(c)
    assert len(active) == 1
    assert active[0]["source"] == "downloader"
    assert active[0]["severity"] == "error"
    assert "连接失败" in active[0]["title"]
    assert active[0]["payload"] == {"downloader_id": downloader_id}

    # 修好地址（更新会触发重测）→ 红灯自动熄灭，行保留为 resolved
    r = c.put(
        f"/api/v1/downloaders/{downloader_id}",
        json={**_PAYLOAD, "url": "http://192.168.1.10:8080"},
    )
    assert r.status_code == 200
    assert _notices(c) == []
    assert _rows(db_file) == [(f"downloader:{downloader_id}", "resolved")]


def test_repeated_failures_dedupe_to_single_row(client) -> None:
    c, db_file = client
    downloader_id = _create_failing(c)
    # 连续三次重测失败：仍只有一行（幂等 upsert 刷新，不刷屏）
    for _ in range(3):
        assert c.post(f"/api/v1/downloaders/{downloader_id}/verify").status_code == 200
    assert len(_notices(c)) == 1
    assert _rows(db_file) == [(f"downloader:{downloader_id}", "active")]


def test_dismiss_keeps_silent_while_problem_persists(client) -> None:
    c, db_file = client
    downloader_id = _create_failing(c)
    notice_id = _notices(c)[0]["id"]

    assert c.post(f"/api/v1/system/notices/{notice_id}/dismiss").status_code == 200
    assert _notices(c) == []

    # 问题仍在（重测继续失败）：dismissed 持续沉默，不重新点亮
    assert c.post(f"/api/v1/downloaders/{downloader_id}/verify").status_code == 200
    assert _notices(c) == []
    assert _rows(db_file) == [(f"downloader:{downloader_id}", "dismissed")]


def test_resolved_then_refail_reactivates(client) -> None:
    c, _ = client
    downloader_id = _create_failing(c)
    notice_id = _notices(c)[0]["id"]
    # dismiss → 问题消失（修好）→ 自动清场（dismissed 也被 resolve）
    c.post(f"/api/v1/system/notices/{notice_id}/dismiss")
    c.put(f"/api/v1/downloaders/{downloader_id}", json={**_PAYLOAD, "url": "http://ok:8080"})
    assert _notices(c) == []

    # 问题复发：resolved 行重新点亮（复发是新事件，dismiss 不跨事件生效）
    c.put(f"/api/v1/downloaders/{downloader_id}", json=_PAYLOAD)
    active = _notices(c)
    assert len(active) == 1
    assert active[0]["id"] == notice_id  # 同一行复用，不产生新行


def test_delete_downloader_resolves_notice(client) -> None:
    c, _ = client
    downloader_id = _create_failing(c)
    assert len(_notices(c)) == 1
    assert c.delete(f"/api/v1/downloaders/{downloader_id}").status_code == 200
    assert _notices(c) == []


def test_dismiss_unknown_notice_404(client) -> None:
    c, _ = client
    assert c.post("/api/v1/system/notices/999/dismiss").status_code == 404

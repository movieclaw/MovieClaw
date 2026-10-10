"""使用提示接口（docs/design/tips.md）：事件计数、展示记录、作废、重置、按人隔离。

删除成员时的清理由 ``register_member_scoped`` 注册表 + test_download_target_pref
的守卫统一覆盖；鉴权由 test_auth 的守护测试覆盖（/tips 挂在成员区）。
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    # 当前请求的身份：测试里改 who["principal"] 就能切换成员
    who = {"principal": Principal(kind="admin", name="tester")}
    app.dependency_overrides[require_login] = lambda: who["principal"]
    with TestClient(app) as c:
        c.who = who  # type: ignore[attr-defined]
        yield c

    reset_setting_store()
    reset_secret_box()
    get_settings.cache_clear()


def _as_member(client: TestClient, member_id: int) -> None:
    from movieclaw_api.services.auth import Principal

    client.who["principal"] = Principal(  # type: ignore[attr-defined]
        kind="member", name=f"m{member_id}", member_id=member_id, is_admin=False
    )


def _state(client: TestClient) -> dict:
    resp = client.get("/api/v1/tips/state")
    assert resp.status_code == 200
    return resp.json()["data"]


def test_empty_state(client: TestClient) -> None:
    assert _state(client) == {"events": [], "tips": []}


def test_donate_counts_and_keeps_first_time(client: TestClient) -> None:
    first = client.post("/api/v1/tips/events/player.opened").json()["data"]
    assert first["count"] == 1
    assert first["first_at"].endswith("+00:00")

    second = client.post("/api/v1/tips/events/player.opened").json()["data"]
    assert second["count"] == 2
    assert second["first_at"] == first["first_at"]
    assert second["last_at"] >= first["last_at"]

    events = _state(client)["events"]
    assert [(e["event_id"], e["count"]) for e in events] == [("player.opened", 2)]


def test_concurrent_donations_do_not_lose_counts(client: TestClient) -> None:
    """多台设备同时上报：原子 upsert，一次都不能丢（也不能撞唯一约束 500）。"""
    with ThreadPoolExecutor(max_workers=8) as pool:
        codes = list(
            pool.map(lambda _: client.post("/api/v1/tips/events/burst").status_code, range(40))
        )
    assert codes == [200] * 40
    assert _state(client)["events"][0]["count"] == 40


def test_display_then_invalidate(client: TestClient) -> None:
    shown = client.post("/api/v1/tips/library.filter/displays").json()["data"]
    assert shown["display_count"] == 1
    assert shown["invalidated_at"] is None
    again = client.post("/api/v1/tips/library.filter/displays").json()["data"]
    assert again["display_count"] == 2
    assert again["first_displayed_at"] == shown["first_displayed_at"]

    gone = client.post("/api/v1/tips/library.filter/invalidate", json={"reason": "closed"}).json()[
        "data"
    ]
    assert gone["invalidated_reason"] == "closed"
    assert gone["display_count"] == 2

    # 重复作废不改第一次的原因与时间
    repeat = client.post(
        "/api/v1/tips/library.filter/invalidate", json={"reason": "action_performed"}
    ).json()["data"]
    assert repeat["invalidated_reason"] == "closed"
    assert repeat["invalidated_at"] == gone["invalidated_at"]


def test_invalidate_before_ever_shown(client: TestClient) -> None:
    """用户自己摸到了功能：提示还没出现过就作废，以后也不该再出现。"""
    data = client.post("/api/v1/tips/search.history/invalidate").json()["data"]
    assert data["display_count"] == 0
    assert data["first_displayed_at"] is None
    assert data["invalidated_reason"] == "action_performed"


def test_unknown_reason_accepted(client: TestClient) -> None:
    """原因不是枚举：新端的新原因旧服务端照收。"""
    resp = client.post("/api/v1/tips/a/invalidate", json={"reason": "max_displays"})
    assert resp.status_code == 200
    assert resp.json()["data"]["invalidated_reason"] == "max_displays"


@pytest.mark.parametrize("bad", ["Player", "-x", "a" * 65, "中文"])
def test_bad_identifiers_rejected(client: TestClient, bad: str) -> None:
    assert client.post(f"/api/v1/tips/events/{bad}").status_code == 422
    assert client.post(f"/api/v1/tips/{bad}/displays").status_code == 422


def test_state_is_per_person(client: TestClient) -> None:
    client.post("/api/v1/tips/events/x")
    client.post("/api/v1/tips/t/invalidate")

    _as_member(client, 7)
    assert _state(client) == {"events": [], "tips": []}
    client.post("/api/v1/tips/events/x")
    client.post("/api/v1/tips/events/x")
    assert _state(client)["events"][0]["count"] == 2

    _as_member(client, 8)
    assert _state(client) == {"events": [], "tips": []}


def test_reset_only_clears_own_state(client: TestClient) -> None:
    client.post("/api/v1/tips/events/x")
    _as_member(client, 7)
    client.post("/api/v1/tips/events/x")
    client.post("/api/v1/tips/t/displays")

    assert client.delete("/api/v1/tips/state").status_code == 200
    assert _state(client) == {"events": [], "tips": []}

    from movieclaw_api.services.auth import Principal

    client.who["principal"] = Principal(kind="admin", name="tester")  # type: ignore[attr-defined]
    assert _state(client)["events"][0]["count"] == 1

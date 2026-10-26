"""Android 客户端自身更新：服务器替 App 查最新版、代取 APK（services/client_update.py）。"""

from __future__ import annotations

import hashlib

import httpx
import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import app_update, client_update
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_AUTH = "/api/v1/auth"
_ADMIN = {"username": "admin", "password": "admin-password-1"}
_MEMBER = {"username": "kid", "password": "member-password-1"}
_REPO = "/repos/movieclaw/movieclaw"
_APK = b"PK\x03\x04 fake apk bytes " * 1000


def _release(tag: str, asset: str, info: str) -> dict:
    return {
        "tag_name": tag,
        "body": f"## {tag}",
        "html_url": f"https://github.test/releases/{tag}",
        "published_at": "2026-10-16T00:57:29Z",
        "assets": [
            {
                "name": f"{asset}.apk",
                "browser_download_url": f"https://github.test/dl/{tag}/{asset}.apk",
            },
            {"name": info, "browser_download_url": f"https://github.test/dl/{tag}/{info}"},
        ],
    }


def _info(version: str, build: int, asset: str) -> dict:
    return {
        "product": "android",
        "version": version,
        "build": str(build),
        "minimumSdk": 26,
        "asset": asset,
        "size": len(_APK),
        "sha256": hashlib.sha256(_APK).hexdigest().upper(),
        "certificateSha256": "18042f",
    }


@pytest.fixture
def github(monkeypatch):  # type: ignore[no-untyped-def]
    """假 GitHub：按路径应答，记录调用。"""
    calls: list[str] = []
    routes: dict[str, object] = {
        f"{_REPO}/git/matching-refs/tags/android-v": [
            {"ref": f"refs/tags/{t}"}
            for t in ("android-v0.3.1", "android-v0.4.0", "android-v0.10.0")
        ],
        # 0.10.0 还是草稿：匿名 404，应退回 0.4.0
        f"{_REPO}/releases/tags/android-v0.4.0": _release(
            "android-v0.4.0", "MovieClaw-Android-arm64", "MovieClaw-Android-arm64.json"
        ),
        "/dl/android-v0.4.0/MovieClaw-Android-arm64.json": _info(
            "0.4.0", 30000007, "MovieClaw-Android-arm64.apk"
        ),
        "/dl/android-v0.4.0/MovieClaw-Android-arm64.apk": _APK,
        # 按 tag 找不到时的兜底整页列表（这里没有电视版的发布）
        f"{_REPO}/releases?per_page=100": [],
    }

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path + (f"?{request.url.query.decode()}" if request.url.query else "")
        calls.append(path)
        body = routes.get(path)
        if isinstance(body, bytes):
            return httpx.Response(200, content=body)
        return httpx.Response(404) if body is None else httpx.Response(200, json=body)

    real_client = httpx.AsyncClient

    def patched_client(**kwargs):  # type: ignore[no-untyped-def]
        kwargs.pop("proxy", None)
        kwargs["transport"] = httpx.MockTransport(handler)
        return real_client(**kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", patched_client)
    app_update.reset_release_cache_for_tests()
    client_update.reset_cache_for_tests()
    yield routes, calls
    client_update.reset_cache_for_tests()


@pytest.fixture
def client(tmp_path, monkeypatch):  # type: ignore[no-untyped-def]
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'clients.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    from movieclaw_api.app import create_app

    with TestClient(create_app(), headers={"Accept-Language": "zh-Hans"}) as c:
        c.post(f"{_AUTH}/bootstrap", json=_ADMIN)
        c.post(f"{_AUTH}/login", json=_ADMIN)
        yield c
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _login_member(client: TestClient) -> None:
    resp = client.post("/api/v1/members", json={**_MEMBER, "role": "member"})
    assert resp.status_code in (200, 201), resp.text
    client.cookies.clear()
    assert client.post(f"{_AUTH}/login", json=_MEMBER).status_code == 200


def test_member_sees_latest_stable_release(client, github) -> None:  # type: ignore[no-untyped-def]
    _, calls = github
    _login_member(client)
    resp = client.get("/api/v1/app/clients/android/latest")
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["version"] == "0.4.0"
    assert data["build"] == 30000007
    assert data["sha256"] == hashlib.sha256(_APK).hexdigest()  # 统一成小写
    assert data["certificate_sha256"] == "18042f"
    assert data["changelog"] == "## android-v0.4.0"
    # 第二次走缓存，不再打 GitHub（未认证配额 60 次/小时，App 每次启动都会问）
    before = len(calls)
    assert client.get("/api/v1/app/clients/android/latest").status_code == 200
    assert len(calls) == before


def test_apk_is_streamed_through_the_server(client, github) -> None:  # type: ignore[no-untyped-def]
    resp = client.get("/api/v1/app/clients/android/apk")
    assert resp.status_code == 200, resp.text
    assert resp.content == _APK
    assert resp.headers["content-length"] == str(len(_APK))
    assert resp.headers["x-apk-sha256"] == hashlib.sha256(_APK).hexdigest()


def test_unknown_product_and_anonymous_are_rejected(client, github) -> None:  # type: ignore[no-untyped-def]
    assert client.get("/api/v1/app/clients/ios/latest").status_code == 422
    client.cookies.clear()
    assert client.get("/api/v1/app/clients/android/latest").status_code == 401


def test_no_release_yet_is_a_clear_error(client, github) -> None:  # type: ignore[no-untyped-def]
    resp = client.get("/api/v1/app/clients/androidtv/latest")
    assert resp.status_code == 400
    assert "还没有这个客户端的正式发布" in resp.text

"""Site errors retain provenance across verification, synchronization and reader locales."""

import copy
import json
import sqlite3
from dataclasses import replace

import httpx
import pytest
from alembic import command
from sqlalchemy.engine import make_url
from tests.api import test_sites as sites

from movieclaw_api.core.config import get_settings
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.schemas.site import ConfiguredSite, SiteSyncStatsView
from movieclaw_api.services import torrent_sync, verification
from movieclaw_db.migrations import _build_config
from movieclaw_db.models import SystemNotice
from movieclaw_db.repositories.credential_repo import CredentialRepository
from movieclaw_db.repositories.torrent_repo import TorrentRepository
from movieclaw_tracker.exceptions import TrackerAuthError, TrackerNetworkError, TrackerParseError

client = sites.client
db = sites.db


def test_verification_http_localizes_same_error_and_clears_reference_after_recovery(
    client, monkeypatch
):
    import movieclaw_api.api.routes.sites as routes
    import movieclaw_tracker as tracker
    from movieclaw_tracker.http import HttpClient
    from movieclaw_tracker.registry import _registry

    requests = []

    def upstream(request):
        requests.append(request)
        if request.headers.get("x-api-key") != "fixture-good-key":
            return httpx.Response(200, json={"message": "invalid api key", "code": 401})
        data = (
            {"id": "42", "username": "原始用户名", "memberCount": {"uploaded": "1024"}}
            if request.url.path == "/api/member/profile"
            else {"seeder": 2, "leecher": 0}
        )
        return httpx.Response(200, json={"message": "SUCCESS", "data": data})

    def http_client(**kwargs):
        kwargs.update(
            transport=httpx.MockTransport(upstream), min_request_interval=0, max_retries=1
        )
        return HttpClient(**kwargs)

    monkeypatch.setattr(tracker, "HttpClient", http_client)
    monkeypatch.setitem(_registry, "mteam", replace(_registry["mteam"], min_request_interval=0))
    monkeypatch.setattr(routes, "verify_site", verification.verify_site)
    response = client.post(
        "/api/v1/sites",
        headers={"Accept-Language": "en"},
        json={
            "site_id": "mteam",
            "auth_type": "apikey",
            "api_key": "fixture-bad-key",
        },
    )
    assert response.is_success
    database = make_url(get_settings().database_url).database

    def saved():
        with sqlite3.connect(database) as connection:
            return connection.execute(
                "SELECT last_error,last_error_ref,api_key FROM site_credential "
                "WHERE site_id='mteam'"
            ).fetchone()

    original = saved()
    assert "认证失败" in original[0] and "M-Team 接口返回错误" in original[0]
    assert original[2].startswith("enc::") and "fixture-bad-key" not in original[2]
    for locale in ["en", "zh-Hans", "en"]:
        row = client.get("/api/v1/sites/mteam", headers={"Accept-Language": locale}).json()["data"]
        assert row["status"] == "failed" and not row["usable"]
        assert row["last_error"] == (
            "Authentication failed: M-Team returned an error: invalid api key"
            if locale == "en"
            else original[0]
        )
        assert not {"api_key", "cookie", "password"} & set(row)
        assert saved() == original
    updated = client.put(
        "/api/v1/sites/mteam",
        json={
            "auth_type": "apikey",
            "api_key": "fixture-good-key",
        },
    )
    assert updated.is_success
    row = client.get("/api/v1/sites/mteam").json()["data"]
    assert row["status"] == "active" and row["last_error"] is None
    assert row["profile"]["username"] == "原始用户名"
    assert saved()[0] is None and json.loads(saved()[1]) is None
    assert requests[-1].headers["x-api-key"] == "fixture-good-key"


@pytest.mark.parametrize(
    "kind,failures,stopped",
    [
        (TrackerNetworkError, 20, False),
        (TrackerAuthError, 1, True),
        (TrackerParseError, 9, True),
    ],
)
async def test_actual_sync_keeps_backoff_and_breaker_facts_with_reader_local_errors(
    db,
    monkeypatch,
    kind,
    failures,
    stopped,
):
    from sqlmodel import select

    credential = await sites._make_active_with_failures(db, "mteam", failures)
    error = kind("原始第三方原因")
    monkeypatch.setattr(torrent_sync, "get_site_access", lambda: sites._FailingAccess(error))
    monkeypatch.setattr(torrent_sync, "invalidate_site_access", sites._noop_invalidate)
    await torrent_sync._sync_one_site(credential)
    async with db.session() as session:
        row = await CredentialRepository(session).get_by_site("mteam")
        cursor = await TorrentRepository(session).get_cursor("mteam")
        notices = list((await session.execute(select(SystemNotice))).scalars())
        original = copy.deepcopy(cursor.last_error_ref)
        raw = cursor.last_error
        assert "同步已暂停" in raw if stopped else "自动重试" in raw
        assert cursor.consecutive_failures == failures + 1
        interval = cursor.sync_interval_seconds
        for locale in ["en", "zh-Hans", "en"]:
            with use_locale(locale):
                view = SiteSyncStatsView.from_parts(0, cursor)
                config = ConfiguredSite.from_model(row)
                assert view.last_error == raw if locale == "zh-Hans" else view.last_error != raw
                if stopped:
                    assert config.last_error == view.last_error
                    assert render_value(notices[0].message_params["reason"]) == view.last_error
                else:
                    assert config.status.value == "active"
                assert view.sync_interval_seconds == interval
            assert cursor.last_error_ref == original and cursor.last_error == raw
        await TorrentRepository(session).reset_failure_state("mteam")
        assert cursor.last_error is None and cursor.last_error_ref is None


def test_unknown_tracker_auth_text_stays_raw_inside_localized_owned_prefix():
    explicit = TrackerAuthError("第三方原始认证错误")
    assert explicit.message_ref is None
    ref = verification.friendly_error_message(explicit)
    with use_locale("en"):
        assert render_value(ref) == "Authentication failed: 第三方原始认证错误"
    unknown = TrackerAuthError("第三方原始认证错误", message_key="plugin.unknown.auth")
    with use_locale("en"):
        assert render_value(verification.friendly_error_message(unknown)) == (
            "Authentication failed: 第三方原始认证错误"
        )


def test_site_error_migration_keeps_old_rows_and_rolls_back(tmp_path, monkeypatch):
    path = tmp_path / "legacy-sites.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    with sqlite3.connect(path) as connection:
        connection.executescript(
            "CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY);"
            "INSERT INTO alembic_version VALUES ('c8e40b72a6f9');"
            "CREATE TABLE site_credential (id INTEGER PRIMARY KEY,last_error TEXT);"
            "INSERT INTO site_credential VALUES (1,'旧站点错误');"
            "CREATE TABLE site_sync_cursor (id INTEGER PRIMARY KEY,last_error TEXT);"
            "INSERT INTO site_sync_cursor VALUES (1,'旧同步错误');"
        )
    try:
        config = _build_config()
        command.upgrade(config, "d9f51c83b70a")
        for table, value in [("site_credential", "旧站点错误"), ("site_sync_cursor", "旧同步错误")]:
            with sqlite3.connect(path) as connection:
                assert connection.execute(
                    f"SELECT last_error,last_error_ref FROM {table}"
                ).fetchone() == (value, None)
        command.downgrade(config, "c8e40b72a6f9")
        for table, value in [("site_credential", "旧站点错误"), ("site_sync_cursor", "旧同步错误")]:
            with sqlite3.connect(path) as connection:
                assert connection.execute(f"SELECT last_error FROM {table}").fetchone() == (value,)
    finally:
        get_settings.cache_clear()


@pytest.mark.parametrize("provenance", ["old", "unknown", "owned"])
def test_failed_auth_result_retains_raw_fallback_for_old_and_unknown_metadata(
    client,
    monkeypatch,
    provenance,
):
    from types import SimpleNamespace
    from unittest.mock import AsyncMock

    import movieclaw_api.api.routes.sites as routes
    from movieclaw_tracker.models import AuthResult, AuthState

    source = "登录页存在验证码，但未配置验证码识别器" if provenance == "owned" else "第三方原始拒绝"
    if provenance == "old":
        result = SimpleNamespace(success=False, message=source)
    else:
        result = AuthResult(
            success=False,
            state=AuthState.FAILED,
            message=source,
            message_ref={
                "message_key": (
                    "errors.siteDiagnostic.captchaSolverMissing"
                    if provenance == "owned"
                    else "plugin.unknown.auth"
                )
            },
        )
    site = SimpleNamespace(
        authenticate=AsyncMock(return_value=result), client=SimpleNamespace(close=AsyncMock())
    )
    monkeypatch.setattr(verification, "create_site", AsyncMock(return_value=site))
    monkeypatch.setattr(routes, "verify_site", verification.verify_site)
    assert client.post(
        "/api/v1/sites",
        json={
            "site_id": "mteam",
            "auth_type": "apikey",
            "api_key": "fixture-key",
        },
    ).is_success
    for locale in ["en", "zh-Hans", "en"]:
        row = client.get("/api/v1/sites/mteam", headers={"Accept-Language": locale}).json()["data"]
        expected = (
            "The sign-in page requires a CAPTCHA, but no CAPTCHA solver is configured"
            if provenance == "owned" and locale == "en"
            else source
        )
        assert row["last_error"] == expected


@pytest.mark.parametrize("with_reference", [True, False])
async def test_shared_site_access_preserves_auth_result_provenance_and_closes_failure(
    db,
    monkeypatch,
    with_reference,
):
    from types import SimpleNamespace
    from unittest.mock import AsyncMock

    from movieclaw_api.services import site_access
    from movieclaw_tracker.models import AuthResult, AuthState

    source = "登录页存在验证码，但未配置验证码识别器"
    result = AuthResult(
        success=False,
        state=AuthState.NEEDS_CAPTCHA,
        message=source,
        message_ref={"message_key": "errors.siteDiagnostic.captchaSolverMissing"}
        if with_reference
        else None,
    )
    site = SimpleNamespace(
        authenticate=AsyncMock(return_value=result), client=SimpleNamespace(close=AsyncMock())
    )
    monkeypatch.setattr(site_access, "create_site", AsyncMock(return_value=site))
    credential = await sites._make_active_with_failures(db, "mteam", 0)
    with pytest.raises(TrackerAuthError) as failure:
        await site_access.SiteAccessManager()._build(credential)
    site.client.close.assert_awaited_once()
    with use_locale("en"):
        displayed = render_value(verification.friendly_error_message(failure.value))
    expected = (
        "The sign-in page requires a CAPTCHA, but no CAPTCHA solver is configured"
        if with_reference
        else source
    )
    assert displayed == "Authentication failed: " + expected

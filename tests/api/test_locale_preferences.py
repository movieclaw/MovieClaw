from __future__ import annotations

import asyncio
import json
import sqlite3

from alembic import command
from sqlalchemy import event

from . import test_auth as auth_tests
from . import test_login_devices as devices
from . import test_member_auth as member_tests

client = auth_tests.client


def test_parallel_first_requests_create_one_admin_language_history(client, monkeypatch):
    from movieclaw_api.i18n import use_locale
    from movieclaw_api.services import locale_preferences
    from movieclaw_api.services.auth import Principal
    from movieclaw_api.services.locale_preferences import member_locale, record_request_language

    # 模块级锁一旦在别的用例里被争用，就绑在那个用例的事件循环上；同进程里排在
    # 后面跑本用例会报「bound to a different event loop」（取决于分片顺序）
    monkeypatch.setattr(locale_preferences, "_admin_locale_lock", asyncio.Lock())
    auth_tests._bootstrap(client)

    async def parallel():
        with use_locale("en"):
            await asyncio.gather(
                *(
                    record_request_language(Principal(kind="admin", name="admin"), None)
                    for _ in range(8)
                )
            )

    client.portal.call(parallel)
    assert client.portal.call(member_locale, 0) == "en"


def test_devices_keep_independent_languages_and_cli_does_not_change_history(client):
    from movieclaw_api.services.locale_preferences import member_locale
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.login_device import LoginDevice

    auth_tests._bootstrap(client)
    account = auth_tests._ADMIN
    first = devices._app_login(client, account, installation="phone-one")
    second = devices._app_login(client, account, installation="phone-two")
    english = devices._as(client, first["token"])
    chinese = devices._as(client, second["token"])
    english.get("/api/v1/auth/me", headers={"Accept-Language": "en"})
    chinese.get("/api/v1/auth/me", headers={"Accept-Language": "zh-Hans"})
    cli = devices._as(client, devices._pair_cli(client))
    # Approving the pairing is itself an interactive Web request.
    chinese.get("/api/v1/auth/me", headers={"Accept-Language": "zh-Hans"})
    assert cli.get("/api/v1/auth/me", headers={"Accept-Language": "en"}).status_code == 200
    assert client.portal.call(member_locale, 0) == "zh-Hans"

    async def saved(device_id):
        async with get_database().session() as session:
            return (await session.get(LoginDevice, int(device_id.removeprefix("ld-")))).locale

    assert client.portal.call(saved, first["device"]["id"]) == "en"
    assert client.portal.call(saved, second["device"]["id"]) == "zh-Hans"


def test_device_and_admin_language_are_updated_only_when_changed(client):
    from movieclaw_api.settings.schemas import AdminLocaleSetting
    from movieclaw_api.settings.store import get_setting_store
    from movieclaw_db.engine import get_database

    auth_tests._bootstrap(client)
    headers = {"Accept-Language": "en-US", "X-MovieClaw-Timezone": "America/New_York"}
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 200
    db = get_database()
    writes = []

    def before_execute(_conn, _cursor, statement, _parameters, _context, _executemany):
        if statement.lstrip().upper().startswith(("UPDATE", "INSERT", "DELETE")):
            writes.append(statement)

    event.listen(db.engine.sync_engine, "before_cursor_execute", before_execute)
    try:
        assert client.get("/api/v1/auth/me", headers=headers).status_code == 200
        assert client.get("/api/v1/auth/me", headers=headers).status_code == 200
        assert writes == []
    finally:
        event.remove(db.engine.sync_engine, "before_cursor_execute", before_execute)

    async def saved():
        from sqlalchemy import select

        from movieclaw_db.models.login_device import LoginDevice

        async with db.session() as session:
            device = (await session.execute(select(LoginDevice))).scalars().first()
            return (
                device.locale,
                device.timezone,
                (await get_setting_store().get(AdminLocaleSetting)).last_locale,
            )

    assert client.portal.call(saved) == ("en", "America/New_York", "en")
    assert (
        client.get(
            "/api/v1/auth/me",
            headers={"Accept-Language": "zh-TW", "X-MovieClaw-Timezone": "invalid"},
        ).status_code
        == 200
    )
    assert client.portal.call(saved) == ("zh-Hans", "America/New_York", "zh-Hans")


def test_locale_bookkeeping_does_not_overwrite_a_fresh_offline_account_update(client):
    from sqlmodel import select

    from movieclaw_api.settings.schemas import AdminAccountSetting
    from movieclaw_api.settings.store import get_setting_store
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.app_setting import AppSetting

    auth_tests._bootstrap(client)
    # Keep the original account cached, then simulate a separate maintenance process.
    original = client.portal.call(get_setting_store().get, AdminAccountSetting)

    async def update_account():
        async with get_database().session() as session:
            row = (
                await session.execute(
                    select(AppSetting).where(AppSetting.namespace == "auth.admin")
                )
            ).scalar_one()
            value = json.loads(row.value_json)
            value["nickname"] = "Changed by maintenance"
            value["password_hash"] = auth_tests.auth_service.hash_password("new-password")
            row.value_json = json.dumps(value)
            await session.commit()
            return value

    updated = client.portal.call(update_account)
    assert original.nickname != updated["nickname"]
    assert client.get("/api/v1/auth/me", headers={"Accept-Language": "en"}).status_code == 200
    fresh = client.portal.call(auth_tests.auth_service._load_admin_fresh)
    assert fresh.nickname == updated["nickname"]
    assert fresh.password_hash == updated["password_hash"]


def test_member_locale_is_personal_and_explicit_preference_wins(client):
    from movieclaw_api.services.locale_preferences import member_locale

    admin_cookie, member_cookie, member_id = member_tests._setup_admin_and_member(client)
    member_tests._use(client, member_cookie)
    assert client.get("/api/v1/auth/me", headers={"Accept-Language": "en"}).status_code == 200
    assert client.portal.call(member_locale, member_id) == "en"
    client.put("/api/v1/ui/preferences", json={"language": "zh-Hans"})
    assert client.portal.call(member_locale, member_id) == "zh-Hans"
    member_tests._use(client, admin_cookie)
    client.get("/api/v1/auth/me", headers={"Accept-Language": "en"})
    assert client.portal.call(member_locale, 0) == "en"
    assert client.portal.call(member_locale, member_id) == "zh-Hans"


def test_locale_schema_migration_preserves_existing_devices(tmp_path, monkeypatch):
    from movieclaw_api.core.config import get_settings
    from movieclaw_db.migrations import _build_config

    path = tmp_path / "migration.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, "c5f1a8d3e7b2")
    with sqlite3.connect(path) as connection:
        connection.execute(
            "INSERT INTO login_device (member_id,kind,name,token_hash,scope,created_at,updated_at) "
            "VALUES (0,'ios','Phone','hash','full',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)"
        )
    command.upgrade(config, "head")
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT name,locale,timezone FROM login_device").fetchone() == (
            "Phone",
            None,
            None,
        )
        assert "last_locale" in {r[1] for r in connection.execute("PRAGMA table_info(member)")}
    get_settings.cache_clear()

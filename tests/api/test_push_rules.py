"""通知规则表与收件人解析（docs/design/domain-events.md §6.1）。"""

from __future__ import annotations

import pytest_asyncio

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.push import engine, preferences, rules
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import Member
from movieclaw_sdk.events import (
    ACCOUNT_DEVICE_SIGNED_IN,
    DeviceSignedIn,
    MediaRef,
    SubscriptionIdentitySkipped,
    core_events,
)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'rules.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


def test_preference_switches_follow_the_rule_table() -> None:
    keys = [e.key for e in preferences.push_events()]
    assert keys == [
        "subscription.fulfilled",
        "subscription.download_started",
        "subscription.identity_skipped",
        "subscription.upgraded",
        "subscription.completed",
        "subscription.download_stuck",
        "subscription.more_episodes",
        "library.items.arrived",
        "account.device.signed_in",
        "system.alert.raised",
        "system.alert.resolved",
        "system.update.available",
        "system.tip.suggested",
    ]
    # 偏好键就是触发它的事件名：每条都对得上一个系统事件（剧卡的事件在 P2/P4 定义；
    # 「订阅收齐了」是状态变化事件里的一种情形，单独一个开关）
    defined = {e.name for e in core_events()}
    for entry in rules.entries():
        assert entry.pref_key in defined | {
            "subscription.fulfilled",
            "subscription.download_started",
            "subscription.upgraded",
            "library.items.arrived",
            "subscription.completed",
        }
    member_keys = {e.key for e in preferences.events_for(is_admin=False)}
    assert "system.alert.raised" not in member_keys and "subscription.fulfilled" in member_keys
    # 老 App 发来的旧键都有去处
    assert set(preferences.LEGACY_KEYS.values()) <= set(keys)


def test_media_of_finds_the_item_in_a_payload() -> None:
    media = MediaRef(id=7, kind="movie", title="奥德赛")
    assert engine.media_of(SubscriptionIdentitySkipped(subscription_id=1, media=media)) == media
    signed_in = DeviceSignedIn(
        member_id=0, device_id=1, device_name="x", kind="app", kind_label="App", new_device=True
    )
    assert engine.media_of(signed_in) is None


async def test_member_audience_only_reaches_active_members(db) -> None:
    async with db.session() as session:
        session.add(Member(id=5, username="alice", password_hash="x", status="active"))
        session.add(Member(id=6, username="bob", password_hash="x", status="disabled"))
        await session.commit()
        audience = rules.Audience.member("member_id")
        for member_id, expected in ((0, {0}), (5, {5}), (6, set()), (99, set())):
            payload = DeviceSignedIn(
                member_id=member_id,
                device_id=None,
                device_name="x",
                kind="app",
                kind_label="App",
                new_device=True,
            )
            assert await audience.resolve(session, payload) == expected
        assert await rules.Audience.admins().resolve(session, None) == {0}


def test_new_device_rule_only_fires_for_new_devices(monkeypatch) -> None:
    sent: list[tuple] = []
    monkeypatch.setattr(
        engine, "notify", lambda key, recipients, build, **kw: sent.append((key, kw))
    )
    base = {
        "member_id": 0,
        "device_id": 3,
        "device_name": "iPhone",
        "kind": "app",
        "kind_label": "App",
        "approver_device_id": 1,
    }
    engine.dispatch(ACCOUNT_DEVICE_SIGNED_IN.name, DeviceSignedIn(**base, new_device=False))
    assert sent == []
    engine.dispatch(ACCOUNT_DEVICE_SIGNED_IN.name, DeviceSignedIn(**base, new_device=True))
    [(key, kw)] = sent
    assert key == "account.device.signed_in"
    # 刚登录的那台、批准配对的那台都不推
    assert kw["exclude_device_ids"] == frozenset({1, 3})

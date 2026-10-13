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
    AGENT_RUN_FINISHED,
    DeviceSignedIn,
    MediaRef,
    RunFinished,
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
        "agent.run.finished",
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


async def test_agent_run_finished_only_notifies_runs_started_from_the_app(monkeypatch) -> None:
    sent: list[tuple] = []
    monkeypatch.setattr(
        engine, "notify", lambda key, recipients, build, **kw: sent.append((key, build, kw))
    )
    base = {"member_id": 0, "session_id": "s1", "title": "最近入库了哪些电影？", "elapsed_ms": 1200}
    # IM 通道里的回复本来就在聊天里、插件代发的由插件自己处理：都不推
    for source in ("channel", "plugin"):
        engine.dispatch(
            AGENT_RUN_FINISHED.name,
            RunFinished(**base, status="done", answer="查到了", source=source),
        )
    assert sent == []

    engine.dispatch(
        AGENT_RUN_FINISHED.name,
        RunFinished(**base, status="done", answer="查到了 2 个库", source="app"),
    )
    [(key, build, kw)] = sent
    assert key == "agent.run.finished"
    # 人在 App 里盯着的事，不再转进 IM；同一会话的新一条替换旧的
    assert kw["to_im"] is False
    assert kw["collapse"] == ("agent-run", "s1")
    alert = await build(None, 0)
    # 标题是哪个会话、正文是回答开头，不另写「AI 助手已回复」
    assert (alert.title, alert.subtitle, alert.body) == (
        "最近入库了哪些电影？",
        "",
        "查到了 2 个库",
    )
    # 点开直达这个会话
    assert alert.open == "/sessions/s1"

    sent.clear()
    engine.dispatch(
        AGENT_RUN_FINISHED.name,
        RunFinished(**base, status="error", answer="", error="模型接口超时", source="app"),
    )
    alert = await sent[0][1](None, 0)
    assert (alert.title, alert.body) == ("最近入库了哪些电影？", "没能完成：模型接口超时")

    # 只有卡片没有文字的回答、还没有标题的会话：正文 / 标题兜底
    sent.clear()
    engine.dispatch(
        AGENT_RUN_FINISHED.name,
        RunFinished(**{**base, "title": None}, status="done", answer="", source="app"),
    )
    alert = await sent[0][1](None, 0)
    assert (alert.title, alert.body) == ("AI 助手", "已回复，点开查看")


def test_agent_run_finished_switch_is_admin_only_and_on_by_default() -> None:
    [admin_view] = [
        e for e in preferences.events_for(is_admin=True) if e.key == "agent.run.finished"
    ]
    assert admin_view.default is True
    # 会话只有管理员有：成员的通知设置里没有这个开关
    assert "agent.run.finished" not in [e.key for e in preferences.events_for(is_admin=False)]

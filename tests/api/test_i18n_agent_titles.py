"""Automatic labels retain their source and never guess from user-supplied titles."""

import copy
import hashlib
import json
import sqlite3

import pytest
from alembic import command
from tests.api import test_agent_sessions as sessions

from movieclaw_api.core.config import get_settings
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.schemas.agent import SessionSummary
from movieclaw_api.services.agent_session_recorder import (
    AgentSessionRecorder,
    rebuild_agent_session_index,
)
from movieclaw_api.services.agent_sessions import (
    AgentSessionStore,
    continuation_title,
    get_agent_session_store,
    message_preview,
    message_preview_reference,
)
from movieclaw_api.services.push.core_rules import _agent_finished
from movieclaw_db.engine import get_database
from movieclaw_db.migrations import _build_config
from movieclaw_db.repositories.agent_session_repo import AgentSessionRepository
from movieclaw_llm import ChatMessage, ImagePart
from movieclaw_sdk.events.agent import RunFinished

client = sessions.client
db = sessions.db


@pytest.mark.parametrize(
    "content,zh,en",
    [
        (
            '<skill name="demo" location="/test/SKILL.md">\n'
            "Private skill body\n</skill>\n\nMy text",
            "[技能] My text",
            "[Skill] My text",
        ),
        (
            '<skill name="demo" location="/test/SKILL.md">\nPrivate skill body\n</skill>',
            "[技能]",
            "[Skill]",
        ),
        ([ImagePart(attachment_id="one")], "[图片]", "[Image]"),
        (
            [ImagePart(attachment_id="one"), ImagePart(attachment_id="two")],
            "[图片 ×2]",
            "[Images ×2]",
        ),
    ],
)
def test_previews_use_content_facts_and_keep_original_chinese(content, zh, en):
    message = ChatMessage(role="user", content=content)
    ref = message_preview_reference(message)
    before = copy.deepcopy(ref)
    assert message_preview(message) == zh
    for locale, expected in [("en", en), ("zh-Hans", zh), ("en", en)]:
        with use_locale(locale):
            assert render_value(ref).strip() == expected
    assert ref == before
    assert "Private skill body" not in json.dumps(ref)
    # A user can type any of these literal strings without receiving provenance.
    assert message_preview_reference(ChatMessage(role="user", content=zh)) is None


def test_continuations_do_not_guess_legacy_prefix_or_double_generated_prefix():
    title, ref = continuation_title("My title")
    assert title == "续：My title"
    assert continuation_title(title, ref) == (title, ref)
    assert continuation_title("续：User custom") == ("续：User custom", None)
    with use_locale("en"):
        assert render_value(ref) == "Continued: My title"
    assert continuation_title(None) == (None, None)


async def test_recorder_rebuild_rename_discard_and_notification_share_facts(db):
    store = get_agent_session_store()
    sid = store.create().session_id
    async with db.session() as session:
        await AgentSessionRepository(session).create(sid, title=None)
    recorder = AgentSessionRecorder(store, sid, entry_count=0)
    await recorder.record_user_message([ImagePart(attachment_id="fixture-image")])
    snapshot = hashlib.sha256(store.path(sid).read_bytes()).digest()
    async with db.session() as session:
        repo = AgentSessionRepository(session)
        row = await repo.get(sid)
        assert row.title == row.last_prompt == "[图片]"
        ref = copy.deepcopy(row.title_ref)
        for locale, label in [("en", "[Image]"), ("zh-Hans", "[图片]"), ("en", "[Image]")]:
            with use_locale(locale):
                summary = SessionSummary.from_model(row)
                assert summary.title == summary.last_prompt == label
                alert = await _agent_finished(
                    session,
                    0,
                    RunFinished(
                        member_id=0,
                        session_id=sid,
                        title=row.title,
                        title_ref=ref,
                        status="done",
                        answer="Raw answer",
                        source="app",
                    ),
                )
                assert alert.title == label
        assert row.title_ref == ref
        await repo.delete(sid)
    await rebuild_agent_session_index()
    async with db.session() as session:
        repo = AgentSessionRepository(session)
        row = await repo.get(sid)
        assert row.title_ref == ref == row.last_prompt_ref
        await repo.rename(sid, "续：User custom")
        assert row.title_ref is None
        with use_locale("en"):
            assert SessionSummary.from_model(row).title == "续：User custom"
        await repo.resync_after_discard(sid, leaf_uuid=None, entry_count=0, last_prompt=None)
        assert row.title is row.title_ref is row.last_prompt_ref is None
    assert hashlib.sha256(store.path(sid).read_bytes()).digest() == snapshot


def test_http_fork_reads_language_without_rewriting_source_and_keeps_custom_names(client):
    sessions.configure_provider(client)
    sid, _ = sessions._send_message_and_wait(client, {"content": "Raw title"})
    sessions._wait_not_running(client, sid)
    store = get_agent_session_store()
    original = store.path(sid).read_bytes()
    forked = client.post(f"/api/v1/sessions/{sid}/fork", headers={"Accept-Language": "en"})
    assert forked.status_code == 201
    target = forked.json()["data"]["session"]["id"]
    target_bytes = store.path(target).read_bytes()
    for locale, label in [
        ("en", "Continued: Raw title"),
        ("zh-Hans", "续：Raw title"),
        ("en", "Continued: Raw title"),
    ]:
        detail = client.get(
            f"/api/v1/sessions/{target}", headers={"Accept-Language": locale}
        ).json()["data"]
        assert detail["session"]["title"] == label
        assert detail["entries"][0]["source_title"] == "Raw title"
        listing = client.get("/api/v1/sessions", headers={"Accept-Language": locale}).json()["data"]
        assert next(item for item in listing if item["id"] == target)["title"] == label
    # Chained forks keep one automatic prefix, with no source-file writes.
    chained = client.post(
        f"/api/v1/sessions/{target}/fork", headers={"Accept-Language": "en"}
    ).json()["data"]
    assert chained["session"]["title"] == "Continued: Raw title"
    assert chained["entries"][0]["source_title"] == "Continued: Raw title"
    assert store.path(target).read_bytes() == target_bytes
    assert store.path(sid).read_bytes() == original
    assert client.patch(f"/api/v1/sessions/{target}", json={"title": "续：User custom"}).is_success
    for locale in ["en", "zh-Hans"]:
        detail = client.get(
            f"/api/v1/sessions/{target}", headers={"Accept-Language": locale}
        ).json()["data"]
        assert detail["session"]["title"] == "续：User custom"
        assert detail["session"]["title_ref"] is None
    with sqlite3.connect(get_database().engine.url.database) as connection:
        raw = connection.execute(
            "SELECT title, title_ref FROM agent_session WHERE id=?", (chained["session"]["id"],)
        ).fetchone()
        assert raw[0] == "续：Raw title"
        assert json.loads(raw[1])["message_key"] == "agent.session.continued"


def test_legacy_title_upgrade_and_rollback_preserve_raw_values(tmp_path, monkeypatch):
    path = tmp_path / "legacy-title.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    with sqlite3.connect(path) as connection:
        connection.executescript(
            "CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY);"
            "INSERT INTO alembic_version VALUES ('a3c6f9b217d4');"
            "CREATE TABLE agent_session (id TEXT PRIMARY KEY, title TEXT, last_prompt TEXT);"
            "INSERT INTO agent_session VALUES ('old', '续：用户标题', '[图片]');"
        )
    try:
        config = _build_config()
        command.upgrade(config, "b7d29a60c3e1")
        with sqlite3.connect(path) as connection:
            assert connection.execute(
                "SELECT title,last_prompt,title_ref,last_prompt_ref FROM agent_session"
            ).fetchone() == ("续：用户标题", "[图片]", None, None)
        command.downgrade(config, "a3c6f9b217d4")
        with sqlite3.connect(path) as connection:
            assert connection.execute("SELECT title,last_prompt FROM agent_session").fetchone() == (
                "续：用户标题",
                "[图片]",
            )
    finally:
        get_settings.cache_clear()


def test_generated_skill_instruction_is_persisted_as_fact_and_only_chat_view_is_localized(tmp_path):
    from movieclaw_agent.skills import Skill, expand_skill_invocations, prepare_skill_invocations
    from movieclaw_api.api.routes.agent import _chat_view, _entry_view

    path = tmp_path / "SKILL.md"
    path.write_text("---\nname: fixture\ndescription: Test\n---\nRaw skill body")
    skill = Skill(name="fixture", description="Test", file_path=path, scope="user")
    original = prepare_skill_invocations("/skill:fixture", [skill])
    assert original.generated_instruction
    assert expand_skill_invocations("/skill:fixture", [skill]) == original.text
    message = ChatMessage(role="user", content=original.text)
    ref = message_preview_reference(message, generated_skill_instruction=True)
    store = AgentSessionStore(tmp_path / "sessions")
    sid = store.create().session_id
    entry = store.append(sid, message, generated_skill_instruction=True)
    assert _entry_view(entry).generated_skill_instruction is True
    snapshot = store.path(sid).read_bytes()
    assert store.summarize(sid).title_ref == ref
    for locale in ["en", "zh-Hans", "en"]:
        with use_locale(locale):
            view = _chat_view(entry)
            expected = (
                "No extra instructions; follow the selected skill."
                if locale == "en"
                else "用户未附加说明，按上述技能指令执行。"
            )
            assert view.message.text().endswith(expected)
            assert render_value(ref).endswith(expected)
        assert entry.message.text() == original.text
        assert store.path(sid).read_bytes() == snapshot
        assert store.build_history(sid)[0].text() == original.text
    # Identical user-entered words carry no generated fact and stay raw.
    typed = prepare_skill_invocations(
        "/skill:fixture 用户未附加说明，按上述技能指令执行。", [skill]
    )
    assert not typed.generated_instruction
    raw_entry = store.append(sid, ChatMessage(role="user", content=typed.text))
    with use_locale("en"):
        assert _chat_view(raw_entry).message.text().endswith("用户未附加说明，按上述技能指令执行。")

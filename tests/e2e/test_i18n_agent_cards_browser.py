"""Revisit real Agent transcripts and reader-local cards without changing source identities."""

import hashlib
import re
import sqlite3

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO

browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack
pytestmark = pytest.mark.integration


async def _seed(stack, folder, identity):
    from tests.api import test_upgrade_run as upgrades

    from movieclaw_api.services.agent_sessions import AgentSessionStore
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Library, MediaItem, PlaybackState, Subscription
    from movieclaw_db.repositories.agent_session_repo import AgentSessionRepository
    from movieclaw_llm import ChatMessage, ToolCall

    database = Database(stack["database_url"])
    store = AgentSessionStore(stack["data"] / "agent-sessions")
    try:
        library_id, item_id, sub_id, _rules = await upgrades._seed(database, tmdb_id=identity)
        path = folder / "作者 S01E01.mkv"
        path.write_bytes(b"Keep author bytes; this test checks card navigation, not decoding")
        async with database.session() as session:
            library = await session.get(Library, library_id)
            library.name, library.root_paths = f"作者媒体库 {identity}", [str(folder)]
            item = await session.get(MediaItem, item_id)
            item.title = "作者剧集"
            sub = await session.get(Subscription, sub_id)
            sub.follow_future = True
            file = upgrades._file(library_id, item_id, 1, 1, resolution="2160p", hdr="HDR10")
            file.file_path, file.size_bytes = str(path), path.stat().st_size
            session.add(file)
            session.add(
                PlaybackState(
                    media_item_id=item_id,
                    season_number=1,
                    episode_number=1,
                    position_ms=2000,
                    played=True,
                )
            )
            await session.commit()
            await upgrades._add_wanted(session, sub_id, item_id, 1, 1)
        groups = [
            {
                "component": "library",
                "title": "作者收藏",
                "items": [{"library_id": library_id}, {"library_id": 990001}],
            },
            {
                "component": "title",
                "title": "作者推荐",
                "items": [{"title_ref": "tmdb:movie:100"}, {"title_ref": "tmdb:movie:990002"}],
            },
            {
                "component": "library_item",
                "title": "作者播放",
                "items": [
                    {"media_item_id": item_id, "season_number": 1, "episode_number": 1},
                    {"media_item_id": 990003},
                ],
            },
            {
                "component": "subscription",
                "title": "作者订阅",
                "items": [{"subscription_id": sub_id}, {"subscription_id": 990004}],
            },
            {
                "component": "library",
                "title": "失败调用不能显示",
                "items": [{"library_id": 990005}],
            },
        ]
        sid = store.create().session_id
        store.append(sid, ChatMessage(role="user", content="请展示作者的媒体卡片"))
        store.append(
            sid,
            ChatMessage(
                role="assistant",
                content="作者说明",
                tool_calls=[
                    ToolCall(id=f"cards-{index}", name="show_media_cards_v1", arguments=group)
                    for index, group in enumerate(groups)
                ],
            ),
        )
        for index in range(len(groups)):
            store.append(
                sid,
                ChatMessage(
                    role="tool",
                    name="show_media_cards_v1",
                    tool_call_id=f"cards-{index}",
                    content="工具执行失败：旧历史原文" if index == 4 else "已展示媒体卡片",
                ),
            )
        store.append(sid, ChatMessage(role="assistant", content="作者回复"))
        async with database.session() as session:
            await AgentSessionRepository(session).create(sid, title="作者会话")
        return sid, library_id, item_id, sub_id, path, store.path(sid)
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_history_cards_keep_ids_and_source_text_across_languages(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": width, "height": 1100},
        is_mobile=width == 320,
        has_touch=width == 320,
    )
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    preferences = context.request.get(base + "/api/v1/ui/preferences").json()["data"]
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    assert context.request.put(base + "/api/v1/ui/preferences", data=preferences).ok
    context.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
    folder = stack["data"] / f"agent-cards-{theme_id}-{width}"
    folder.mkdir()
    sid, library_id, item_id, sub_id, source, transcript = _run(
        _seed(stack, folder, 940000 + width + (10000 if theme_id == "netflix" else 0))
    )

    def facts():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return [
                db.execute(sql, (identity,)).fetchall()
                for sql, identity in [
                    ("SELECT title, original_title, tmdb_id FROM media_item WHERE id=?", item_id),
                    ("SELECT name, root_paths FROM library WHERE id=?", library_id),
                    ("SELECT selected_seasons, follow_future FROM subscription WHERE id=?", sub_id),
                    (
                        "SELECT position_ms, played FROM playback_state WHERE media_item_id=?",
                        item_id,
                    ),
                ]
            ]

    before = facts(), source.read_bytes(), transcript.read_bytes()
    page = context.new_page()
    errors, reads = [], []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on(
        "response",
        lambda response: (
            reads.append(response.url) if "/discover/titles/" in response.url else None
        ),
    )
    path = base + "/sessions/" + sid
    shots = REPO / ".tmp-uidev/i18n/agent-cards"
    shots.mkdir(parents=True, exist_ok=True)
    for language in ("en", "zh-Hans", "en"):
        if page.url.startswith(base):
            page.goto(base + "/settings/appearance")
            control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
            control.check()
            expect(control).to_be_enabled()
            expect(page.locator("html")).to_have_attribute("lang", language)
        page.goto(path)
        if page.get_by_role("button", name="Get started", exact=True).count():
            page.get_by_role("button", name="Get started", exact=True).click()
        expect(page.locator("html")).to_have_attribute("lang", language)
        expect(page.get_by_role("heading", name="作者收藏", exact=True)).to_be_visible()
        expect(page.get_by_role("heading", name="失败调用不能显示", exact=True)).to_have_count(0)
        library = page.get_by_role(
            "link", name=re.compile(r"^(Open library “作者媒体库|打开媒体库「作者媒体库)")
        )
        expect(library).to_have_attribute("href", f"/library/{library_id}")
        play = page.get_by_role(
            "link", name=re.compile(r"^(Resume “作者剧集”|继续播放《作者剧集》)")
        )
        expect(play).to_have_attribute("href", f"/play/{item_id}/s01e01")
        expect(play).to_have_attribute("aria-label", re.compile("S01E01$"))
        expect(page.locator(f'a[href="/subscriptions/{sub_id}"]')).to_have_count(1)
        expect(page.locator('a[href="/media/movie/100"]')).to_have_count(1)
        for text in (
            [
                "Library #990001 not found",
                "Not found",
                "Item #990003 not found",
                "Subscription #990004 not found",
            ]
            if language == "en"
            else ["未找到媒体库 #990001", "未找到", "未找到条目 #990003", "未找到订阅 #990004"]
        ):
            expect(page.get_by_text(text, exact=True)).to_have_count(1)
        expect(
            page.get_by_text("1 file" if language == "en" else "1 个文件", exact=False).last
        ).to_be_visible()
        assert facts() == before[0]
        assert source.read_bytes() == before[1]
        assert transcript.read_bytes() == before[2]
        if language == "en":
            library.evaluate("node => node.scrollIntoView({block:'center'})")
            page.screenshot(
                path=str(shots / f"{theme_id}-{width}-libraries.png"), animations="disabled"
            )
            play.evaluate("node => node.scrollIntoView({block:'center'})")
            page.screenshot(path=str(shots / f"{theme_id}-{width}-play.png"), animations="disabled")
    assert (
        len([url for url in reads if "tmdb%3Amovie%3A100" in url or "tmdb:movie:100" in url]) >= 3
    )
    # A normal card click uses the existing product route; it does not start playback.
    target = page.locator(f'a[href="/library/{library_id}/item/{item_id}?season=1&episode=1"]')
    target.click()
    page.wait_for_url(re.compile(rf"/library/{library_id}/item/{item_id}\?season=1&episode=1$"))
    expect(page.get_by_role("heading", name="作者剧集", exact=True)).to_be_visible()
    assert hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256(before[1]).digest()
    assert not errors, errors
    context.close()

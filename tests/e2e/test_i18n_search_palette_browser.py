"""Search palette history operations, language and layout against real API/SQLite."""

from __future__ import annotations

import asyncio
import re
from concurrent.futures import ThreadPoolExecutor

import pytest

from . import test_library_filtering_browser as inventory
from . import test_search_history_browser as history
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot as _content_snapshot
from .test_library_manage_browser import _wait_for

browser = theme.browser
stack = inventory.stack
pytestmark = pytest.mark.integration


def _snapshot(page, path):
    page.wait_for_function("""() => [...document.querySelectorAll(
        '.search-palette-panel, .search-palette-overlay')]
        .every(element => element.getAnimations().every(animation =>
            animation.playState === 'finished' || animation.playState === 'idle'))""")
    page.evaluate("""async () => {
        await document.fonts.ready;
        await new Promise(requestAnimationFrame);
        await new Promise(requestAnimationFrame);
    }""")
    _content_snapshot(page, path)


async def _seed(database_url):
    await history._seed_history(database_url)
    from movieclaw_db.engine import Database
    from movieclaw_db.repositories.search_history_repo import SearchHistoryRepository

    database = Database(database_url)
    try:
        async with database.session() as session:
            await SearchHistoryRepository(session).record(
                "我的音乐范围", categories=["movie"], label="音乐"
            )
            await SearchHistoryRepository(session).record(
                "共同关键词",
                categories=["movie"],
                label="电影",
                label_key="search.categories.movie",
            )
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_name,width", [("silver", 1440), ("silver", 320), ("netflix", 1440), ("netflix", 320)]
)
def test_english_palette_history_and_scopes(stack, browser, theme_name, width):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 900})
    prefix = f"{base}/api/v1"
    response = context.request.post(prefix + "/auth/bootstrap", data=inventory.ADMIN)
    if response.status == 409:
        response = context.request.post(prefix + "/auth/login", data=inventory.ADMIN)
    assert response.ok, response.text()
    assert context.request.delete(prefix + "/search/history").ok
    with ThreadPoolExecutor(max_workers=1) as pool:
        pool.submit(lambda: asyncio.run(_seed(stack["database_url"]))).result()
    prefs = context.request.get(prefix + "/ui/preferences").json()["data"]
    prefs.update(theme=theme_name, theme_desktop=theme_name, theme_mobile=theme_name)
    assert context.request.put(prefix + "/ui/preferences", data=prefs).ok
    page = context.new_page()
    page.set_default_timeout(30_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base)
    if theme_name == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix", timeout=30_000)
        if width >= 768:
            expect(page.get_by_role("link", name="My subscriptions", exact=True)).to_be_visible(
                timeout=30_000
            )
    page.get_by_role("button", name=re.compile(r"^Search \(")).click()
    dialog = page.get_by_role("dialog", name="Search", exact=True)
    dialog.get_by_role("radio", name="Titles", exact=True).click()
    recent = dialog.get_by_role("list", name="Recent searches", exact=True)
    expect(recent).to_contain_text("影视独有记录")
    expect(recent).not_to_contain_text("资源独有记录")
    expect(dialog.get_by_role("textbox", name="Search titles", exact=True)).to_be_visible()
    shots = theme.REPO / ".tmp-uidev/i18n/search-palette"
    shots.mkdir(parents=True, exist_ok=True)
    _snapshot(page, shots / f"{theme_name}-{width}-titles-en.png")
    dialog.get_by_role("radio", name="Resources", exact=True).click()
    expect(recent).to_contain_text("资源独有记录")
    expect(recent).not_to_contain_text("影视独有记录")
    if theme_name == "netflix":
        dialog.get_by_role(
            "button", name="Collapse search scopes for 共同关键词", exact=True
        ).click()
        dialog.get_by_role("button", name="Expand search scopes for 共同关键词", exact=True).click()
        expect(recent).to_contain_text("2 scopes")
    expect(recent.get_by_text(re.compile("^Resources · Movies"))).to_be_visible()
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    assert dialog.evaluate("element => element.scrollWidth <= element.clientWidth")
    expect(recent).to_contain_text("音乐")
    expect(recent).not_to_contain_text("Music")
    text = dialog.inner_text()
    for keyword in ("影视独有记录", "资源独有记录", "共同关键词", "我的音乐范围", "音乐"):
        text = text.replace(keyword, "")
    assert not re.search(r"[\u3400-\u9fff]", text), text
    _snapshot(page, shots / f"{theme_name}-{width}-resources-en.png")
    dialog.get_by_role("button", name="Delete search history group: 共同关键词", exact=True).click()
    confirmation = page.get_by_role(
        "dialog", name="Delete 2 search records for “共同关键词”?", exact=True
    )
    confirmation.get_by_role("button", name="Delete", exact=True).click()
    expect(recent).not_to_contain_text("共同关键词")
    _wait_for(
        lambda: len(context.request.get(prefix + "/search/history").json()["data"]) == 4,
        timeout=20,
        what="history group deletion",
    )
    dialog.get_by_role("button", name="Clear resource search history", exact=True).click()
    expect(recent).to_have_count(0)
    _wait_for(
        lambda: len(context.request.get(prefix + "/search/history").json()["data"]) == 2,
        timeout=20,
        what="resource history clear",
    )
    if theme_name == "silver" and width == 320:
        expect(dialog.get_by_text("Browse latest resources", exact=True)).to_be_visible()
    else:
        expect(dialog.get_by_text(re.compile("^No search history yet"))).to_be_visible()
    dialog.get_by_role("radio", name="Library", exact=True).click()
    expect(dialog.get_by_role("textbox", name="Search library", exact=True)).to_be_visible()
    expect(dialog.get_by_role("list", name="Recent searches", exact=True)).to_have_count(0)
    dialog.get_by_role("textbox", name="Search library", exact=True).focus()
    page.keyboard.press("Escape")
    expect(dialog).to_have_count(0)
    assert (
        page.evaluate("JSON.parse(localStorage.getItem('movieclaw.search-palette-state')).mode")
        == "library"
    )
    page.keyboard.press("Control+k")
    expect(page.get_by_role("dialog", name="Search", exact=True)).to_be_visible()
    assert not errors
    context.close()

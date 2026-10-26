"""Content browsing through Next, the real API/SQLite and a local TMDB HTTP fixture."""

from __future__ import annotations

import re

import pytest

from . import test_theme_device_class_browser as theme

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_I18N_DISCOVERY", "1")
        yield from theme.stack.__wrapped__(tmp_path_factory)


def _snapshot(page, path, *, full_page=False):
    page.wait_for_function(
        """() => [...document.querySelectorAll('div[aria-hidden="true"][class*="z-[100]"]')]
        .every(element => getComputedStyle(element).opacity === "0")"""
    )
    page.screenshot(path=str(path), full_page=full_page)


def _change_language(page, language):
    from playwright.sync_api import expect

    english = page.locator("html").get_attribute("lang") == "en"
    page.get_by_role("button", name=re.compile("^(AD admin|Account menu$|账号菜单$)")).click()
    page.get_by_role("button", name="Settings" if english else "设置", exact=True).click()
    page.get_by_role(
        "button", name="Appearance and language" if english else "外观与语言", exact=True
    ).click()
    group = page.get_by_test_id("language-settings")
    group.locator(f'input[value="{language}"]').check()
    expect(group.locator(f'input[value="{language}"]')).to_be_enabled()
    expect(page.locator("html")).to_have_attribute("lang", language)
    page.get_by_role(
        "button",
        name="返回工作台" if language == "zh-Hans" else "Back to dashboard",
        exact=True,
    ).click()


def test_content_browsing_uses_the_reader_language(stack, browser):
    from playwright.sync_api import expect

    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 900})
    assert context.request.post(f"{stack}/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    artifacts = theme.REPO / ".tmp-uidev/i18n/content"
    artifacts.mkdir(parents=True, exist_ok=True)
    page.goto(f"{stack}/library")
    expect(page.get_by_role("heading", name="A home for your collection")).to_be_visible()
    expect(page.get_by_role("link", name="Create your first library")).to_be_visible()
    expect(page).to_have_title("Library · MovieClaw")
    _snapshot(page, artifacts / "library-empty-en.png")

    page.goto(f"{stack}/discover/movie")
    expect(page.get_by_role("heading", name="Popular movies", exact=True)).to_be_visible()
    expect(page.get_by_text("Theatrical region:", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Mainland China", exact=True)).to_be_visible()
    page.get_by_role("button", name="Mainland China", exact=True).click()
    expect(page.get_by_role("menuitem", name="Japan", exact=True)).to_be_visible()
    page.get_by_role("menuitem", name="Japan", exact=True).click()
    expect(page.get_by_role("button", name="Japan", exact=True)).to_be_visible()
    expect(page).to_have_title("Discover · MovieClaw")
    _snapshot(page, artifacts / "discover-en.png")

    page.goto(f"{stack}/discover/movie?country=JP&year=2024&rating=8&runtime=90&sort=rating")
    expect(page.get_by_role("heading", name="Filtered results", exact=True)).to_be_visible()
    expect(page.get_by_text("4 titles found · 4 loaded", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name=re.compile("Country.*Japan"))).to_be_visible()
    expect(
        page.get_by_role("button", name=re.compile("Maximum runtime.*Up to 90 min"))
    ).to_be_visible()
    assert not re.search(r"[\u3400-\u9fff]", page.locator("main").first.inner_text())
    _snapshot(page, artifacts / "filters-en.png")

    page.goto(f"{stack}/media/movie/300")
    expect(page.get_by_role("heading", name="某电影", exact=True)).to_be_visible()
    expect(page.get_by_text(re.compile("^Release date ·"))).to_be_visible()
    expect(page.get_by_role("link", name="Search releases", exact=True)).to_be_visible()
    expect(page.get_by_text("95 minutes", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Track this title", exact=True)).to_be_visible()
    expect(page.get_by_text("Related links", exact=True)).to_be_visible()
    _snapshot(page, artifacts / "details-en.png")

    _change_language(page, "zh-Hans")
    expect(page.get_by_text(re.compile("^上映日期 ·"))).to_be_visible()
    expect(page.get_by_role("link", name="搜索资源", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="订阅追踪", exact=True)).to_be_visible()
    _change_language(page, "en")
    page.set_viewport_size({"width": 390, "height": 844})
    page.goto(f"{stack}/discover/movie?country=JP&rating=8")
    expect(page.get_by_role("heading", name="Filtered results", exact=True)).to_be_visible()
    expect(page.get_by_text("4 titles found · 4 loaded", exact=True)).to_be_visible()
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    _snapshot(page, artifacts / "filters-mobile-en.png", full_page=True)
    # Keep the same document while revisiting both locale caches through actual navigation.
    page.set_viewport_size({"width": 1280, "height": 900})
    page.get_by_role("button", name="Discover", exact=True).click()
    expect(page.get_by_role("heading", name="Popular movies", exact=True)).to_be_visible()
    page.evaluate("window.contentLanguageMarker = 123")
    for language, discovery, popular in (
        ("zh-Hans", "发现", "热门电影"),
        ("en", "Discover", "Popular movies"),
    ):
        _change_language(page, language)
        page.get_by_role("button", name=discovery, exact=True).click()
        expect(page.get_by_role("heading", name=popular, exact=True)).to_be_visible()
        assert page.evaluate("window.contentLanguageMarker") == 123
    assert not errors
    context.close()

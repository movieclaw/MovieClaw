"""Search results, filters, snapshots and three sources through real Next/API/SQLite."""

from __future__ import annotations

import re
from urllib.parse import urlencode

import httpx
import pytest

from . import test_search_background_browser as background
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import _wait_for

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_SEARCH_I18N", "1")
        for value in background.bg_stack.__wrapped__(tmp_path_factory):
            assert httpx.post(value["lab"] + "/library").is_success
            yield value


def _api(context, base, method, path, **kwargs):
    response = getattr(context.request, method)(f"{base}/api/v1{path}", **kwargs)
    assert response.ok, response.text()
    return response.json().get("data")


@pytest.mark.parametrize(
    "theme_name,width", [("silver", 1440), ("silver", 320), ("netflix", 1440), ("netflix", 320)]
)
def test_results_filters_retry_and_sources(stack, browser, theme_name, width):
    from playwright.sync_api import expect

    base, lab = stack["base"], stack["lab"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    response = context.request.post(f"{base}/api/v1/auth/bootstrap", data=background.ADMIN)
    if response.status == 409:
        response = context.request.post(f"{base}/api/v1/auth/login", data=background.ADMIN)
    assert response.ok, response.text()
    prefs = _api(context, base, "get", "/ui/preferences")
    prefs.update(theme=theme_name, theme_desktop=theme_name, theme_mobile=theme_name, language="en")
    _api(context, base, "put", "/ui/preferences", data=prefs)
    assert context.request.post(lab + "/reset").ok
    assert context.request.post(lab + "/slow/hold").ok
    page = context.new_page()
    page.set_default_timeout(30_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    keyword = f"Example.{theme_name}.{width}"
    path = "/search?" + urlencode(
        {"q": keyword, "label": "电影", "label_key": "search.categories.movie", "cats": "movie"}
    )
    page.goto(base + path)
    if theme_name == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_title("View search details by site")).to_be_visible()
    expect(page.get_by_text("3 results found", exact=True)).to_be_visible()
    before = context.request.get(lab + "/search-log").json()
    assert all(words == [keyword] for words in before.values())
    page.get_by_title("View search details by site").click()
    expect(page.get_by_text("Searching…", exact=True)).to_be_visible()
    expect(page.get_by_text(re.compile("^The site redirected"))).to_be_visible()
    shots = theme.REPO / ".tmp-uidev/i18n/search-results"
    shots.mkdir(parents=True, exist_ok=True)
    _snapshot(page, shots / f"{theme_name}-{width}-status-en.png")
    # Retry only the failed adapter; this remains a real dispatcher/SSE interaction.
    page.get_by_role("button", name="Retry site", exact=True).click()
    _wait_for(
        lambda: len(context.request.get(lab + "/search-log").json()["flaky"]) == 2,
        timeout=10,
        what="single-site retry",
    )
    expect(page.get_by_text(re.compile("^The site redirected"))).to_have_count(0)
    if theme_name == "silver" and width < 768:
        page.get_by_role("button", name="Close", exact=True).last.click()
    else:
        page.locator("div.fixed.inset-0.z-20").click(position={"x": width / 2, "y": 800})
    assert context.request.post(lab + "/slow/release").ok
    expect(page.get_by_text("9 results", exact=True)).to_be_visible()
    # The season filter updates the displayed set, without calling any adapter again.
    if theme_name == "silver" and width < 768:
        page.get_by_role("button", name="Season", exact=True).click()
        page.get_by_role("menuitemcheckbox", name=re.compile("Season 2")).click()
    else:
        page.get_by_role("button", name=re.compile("^Filter")).click()
        sheet = page.locator(".solid-popover").filter(
            has=page.get_by_text("Filter results", exact=True)
        )
        sheet.get_by_role("button", name=re.compile("^Season 2")).click()
        close = sheet.get_by_role("button", name="Close filters", exact=True).bounding_box()
        assert close and close["width"] >= 27
        _snapshot(page, shots / f"{theme_name}-{width}-filters-en.png")
        sheet.get_by_role("button", name="Show 6 results", exact=True).click()
    expect(page.get_by_text("6 of 9 results", exact=True)).to_be_visible()
    calls = context.request.get(lab + "/search-log").json()
    assert calls["fast"] == calls["slow"] == [keyword]
    assert calls["flaky"] == [keyword, keyword]
    page.get_by_role("button", name=re.compile("^Sort: Seeds, descending$")).click()
    sort_item = page.get_by_role("menuitem", name="Published", exact=True)
    if not sort_item.count():
        sort_item = page.get_by_role("button", name="Published", exact=True)
    sort_item.click()
    expect(
        page.get_by_role("button", name="Sort: Published, descending", exact=True)
    ).to_be_visible()
    assert context.request.get(lab + "/search-log").json() == calls
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    assert not re.search(r"[\u3400-\u9fff]", page.locator("main").first.inner_text())
    free = page.get_by_text("3 free", exact=True).bounding_box()
    assert free and free["x"] + free["width"] <= width
    if theme_name == "silver" and width < 768:
        search = page.locator(".mobile-topbar").get_by_title("Search (⌘K or Ctrl+K)").bounding_box()
        assert search and search["x"] + search["width"] <= width
    _snapshot(page, shots / f"{theme_name}-{width}-results-en.png")

    # Opening Settings replaces the results subtree under the existing shell.
    # Returning replays the original cached run (six hits; the retry is a separate run).
    if theme_name == "silver" and width == 1440:
        page.evaluate("window.searchLocaleMarker = 345")
        for language, expected in [("zh-Hans", "共 6 条结果"), ("en", "6 results")]:
            english = page.locator("html").get_attribute("lang") == "en"
            page.get_by_role("button", name=re.compile("^BG bg-search-admin")).click()
            page.get_by_role("button", name="Settings" if english else "设置", exact=True).click()
            page.get_by_role(
                "button", name="Appearance and language" if english else "外观与语言", exact=True
            ).click()
            page.get_by_test_id("language-settings").locator(f'input[value="{language}"]').check()
            expect(page.locator("html")).to_have_attribute("lang", language)
            page.get_by_role(
                "button",
                name="返回工作台" if language == "zh-Hans" else "Back to dashboard",
                exact=True,
            ).click()
            expect(page.get_by_text(expected, exact=True)).to_be_visible()
            assert page.evaluate("window.searchLocaleMarker") == 345
            assert context.request.get(lab + "/search-log").json() == calls

    # An actual saved snapshot replays in English and Chinese without new site calls.
    def row():
        return next(
            (
                item
                for item in _api(context, base, "get", "/search/history")
                if item["keyword"] == keyword and not item["site_ids"]
            ),
            None,
        )

    _wait_for(lambda: row() and row()["has_snapshot"], timeout=15, what="saved snapshot")
    history_id = row()["id"]
    page.goto(base + path + f"&snapshot={history_id}")
    expect(page.get_by_role("button", name="Search again", exact=True)).to_be_visible()
    expect(page.get_by_text(re.compile("^Snapshot from"))).to_be_visible()
    assert context.request.get(lab + "/search-log").json() == calls
    # Title sources and library use the real search routes; names stay in their source language.
    page.goto(base + "/search?q=interstellar&tab=media")
    expect(page.get_by_text("Douban", exact=True)).to_be_visible()
    expect(page.get_by_text("TMDB", exact=True)).to_be_visible()
    expect(page.get_by_text("1 result", exact=True)).to_have_count(2)
    assert not re.search(
        r"[\u3400-\u9fff]", page.locator("main").first.inner_text().replace("原始影片名", "")
    )
    _snapshot(page, shots / f"{theme_name}-{width}-titles-en.png")
    page.goto(base + "/search?q=nolan&tab=library")
    expect(page.get_by_text("Director: 克里斯托弗·诺兰", exact=True).first).to_be_visible()
    expect(page.get_by_text("星际穿越", exact=True)).to_be_visible()
    expect(page.get_by_text("1 title in library", exact=True)).to_be_visible()
    _snapshot(page, shots / f"{theme_name}-{width}-library-en.png")
    page.goto(base + "/search?q=no-matches&tab=media")
    expect(page.get_by_text("No matching titles", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Search site resources", exact=True)).to_be_visible()
    page.goto(base + "/search?q=no-matches&tab=library")
    expect(page.get_by_text("No matching titles in your library", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Search titles", exact=True)).to_be_visible()
    assert not errors, errors
    context.close()

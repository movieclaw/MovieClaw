"""Localized inventory browsing and filters with real SQL counts and saved URL state."""

from __future__ import annotations

import re
from urllib.parse import parse_qs, urlparse

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot

stack = inventory.stack
browser = theme.browser
pytestmark = pytest.mark.integration


def _english_interface(page):
    text = page.locator("main").first.inner_text()
    data = [row[0] for row in inventory.CATALOG] + [
        "电影库",
        "剧集库",
        inventory.UNSCRAPED_TITLE,
        "某部日本动画剧",
        *[value[1] for value in inventory.SERIES.values()],
    ]
    for value in sorted(data, key=len, reverse=True):
        text = text.replace(value, "")
    assert not re.search(r"[\u3400-\u9fff]", text), text


def test_library_inventory_and_filters_use_english(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1100})
    assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=inventory.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    library_id, item_ids = inventory._ensure_libraries(page, stack)
    assert context.request.post(
        f"{base}/api/v1/playback/marks",
        data={"media_item_id": item_ids["千与千寻"], "favorite": True},
    ).ok
    page.goto(f"{base}/library/{library_id}")
    expect(page.get_by_role("heading", name="电影库", exact=True)).to_be_visible()
    sort = page.get_by_role("button", name="Sort", exact=True)
    expect(sort).to_contain_text("By title")
    expect(page.get_by_role("button", name="Filter", exact=True)).to_be_visible()
    _english_interface(page)
    artifacts = theme.REPO / ".tmp-uidev/i18n/library-browse"
    artifacts.mkdir(parents=True, exist_ok=True)
    page.wait_for_function(
        """() => [...document.querySelectorAll('main img')]
        .filter(i => i.getBoundingClientRect().width > 0)
        .every(i => i.complete && i.naturalWidth > 0)"""
    )
    _snapshot(page, artifacts / "inventory-en.png")

    sort.click()
    page.get_by_role("menuitemradio", name="By rating", exact=True).click()
    expect(sort).to_contain_text("By rating")
    sort.click()
    page.get_by_role("menuitemradio", name=re.compile("^By rating,")).click()
    page.keyboard.press("Escape")
    expect(sort).to_have_attribute("title", re.compile("Low → high"))
    page.get_by_role("button", name="Filter", exact=True).click()
    page.get_by_role("button", name="Genres", exact=True).click()
    page.get_by_role("menuitem", name=re.compile("^Animation")).click()
    page.keyboard.press("Escape")
    page.get_by_role("button", name="Region", exact=True).click()
    page.get_by_role("menuitem", name=re.compile("^Japan")).click()
    page.keyboard.press("Escape")
    count = context.request.get(f"{base}/api/v1/libraries/{library_id}/facets?g=16&c=JP").json()[
        "data"
    ]["total"]
    expect(page.get_by_text(f"{count} titles found", exact=True)).to_be_visible()
    page.get_by_role("button", name="More filters", exact=True).click()
    expect(page.get_by_text(re.compile("^Find titles"))).to_be_visible()
    expect(page.get_by_text(re.compile("^Inspect library"))).to_be_visible()
    _english_interface(page)
    _snapshot(page, artifacts / "filters-en.png")

    page.goto(f"{base}/library/{library_id}?g=16&c=US")
    expect(
        page.get_by_role("heading", name="No titles match all 2 conditions", exact=True)
    ).to_be_visible()
    relax = page.get_by_role("button", name=re.compile("^Remove “Genres = Animation”"))
    expect(relax).to_be_visible()
    _english_interface(page)
    _snapshot(page, artifacts / "relax-en.png")
    relax.click()
    page.wait_for_function("!new URLSearchParams(location.search).has('g')")
    assert parse_qs(urlparse(page.url).query)["c"] == ["US"]
    page.evaluate("window.libraryBrowseLanguageMarker = 456")
    for locale, filter_label, remove in (
        ("zh-Hans", "筛选", "取消 地区 美国"),
        ("en", "Filter", "Remove Region: United States"),
    ):
        _change_language(page, locale)
        expect(page.get_by_role("button", name=re.compile("^" + filter_label))).to_be_visible()
        assert parse_qs(urlparse(page.url).query).get("c") == ["US"], page.url
        expect(page.get_by_role("button", name=remove, exact=True)).to_be_visible()
        assert page.evaluate("window.libraryBrowseLanguageMarker") == 456
        assert parse_qs(urlparse(page.url).query)["c"] == ["US"]

    page.set_viewport_size({"width": 390, "height": 844})
    _snapshot(page, artifacts / "inventory-mobile-en.png")
    page.get_by_role("button", name=re.compile("^Filter")).click()
    expect(page.get_by_role("button", name="Collapse filters", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name=re.compile("^View .* titles$"))).to_be_visible()
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    _snapshot(page, artifacts / "filters-mobile-en.png")
    page.get_by_role("button", name="Collapse filters", exact=True).click()
    assert not errors
    context.close()

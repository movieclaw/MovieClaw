"""Browser URL → shared search run → history → a reader in another language."""

from __future__ import annotations

import sqlite3
from urllib.parse import urlencode

import pytest

from . import test_search_background_browser as background
from . import test_theme_device_class_browser as theme
from .test_library_manage_browser import _wait_for

browser = theme.browser
stack = background.bg_stack
pytestmark = pytest.mark.integration


def test_scope_identity_survives_reload_and_a_second_browser_language(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    english = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
    assert english.request.post(f"{base}/api/v1/auth/bootstrap", data=background.ADMIN).ok
    params = {
        "q": "Original title",
        "cats": "movie",
        "label": "Movies",
        "label_key": "search.categories.movie",
    }
    page = english.new_page()
    page.set_default_timeout(30_000)
    page.goto(f"{base}/search?{urlencode(params)}")
    expect(
        page.get_by_role("listitem").filter(has=page.get_by_text("FAST", exact=False)).first
    ).to_be_visible()

    def history(context, locale):
        response = context.request.get(
            f"{base}/api/v1/search/history", headers={"Accept-Language": locale}
        )
        assert response.ok, response.text()
        return response.json()["data"]

    _wait_for(
        lambda: (rows := history(english, "en")) and rows[0]["has_snapshot"],
        timeout=30,
        what="real search snapshot",
    )
    assert history(english, "en")[0]["label"] == "Movies"
    assert history(english, "en")[0]["label_key"] == "search.categories.movie"
    first_calls = english.request.get(f"{stack['lab']}/search-log").json()
    assert first_calls == {site: ["Original title"] for site in ("fast", "slow", "flaky")}
    page.reload()
    expect(
        page.get_by_role("listitem").filter(has=page.get_by_text("FAST", exact=False)).first
    ).to_be_visible()
    chinese = browser.new_context(locale="zh-CN", storage_state=english.storage_state())
    chinese.add_cookies([{"name": "mc_locale", "value": "zh-Hans", "url": base}])
    chinese_page = chinese.new_page()
    chinese_page.goto(f"{base}/search?{urlencode({**params, 'label': '电影'})}")
    expect(
        chinese_page.get_by_role("listitem")
        .filter(has=chinese_page.get_by_text("FAST", exact=False))
        .first
    ).to_be_visible()
    assert history(chinese, "zh-Hans")[0]["label"] == "电影"
    assert history(chinese, "zh-Hans")[0]["search_count"] == 1
    assert english.request.get(f"{stack['lab']}/search-log").json() == first_calls
    with sqlite3.connect(stack["root"] / "data.db") as connection:
        assert connection.execute(
            "SELECT label, label_key FROM search_history WHERE keyword = ?", ("Original title",)
        ).fetchone() == ("电影", "search.categories.movie")
    chinese.close()
    english.close()

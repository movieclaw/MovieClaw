"""Smart settings and memory through real UI/API/SQLite; subtitle policy stays independent."""

from __future__ import annotations

import re

import pytest

from . import test_smart_memory_browser as lab
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot

stack = lab.stack
browser = lab.browser
pytestmark = pytest.mark.integration


def _api(context, base, method, path, **kwargs):
    response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
    assert response.ok, response.text()
    return response.json()["data"]


def _english(locator, *metadata):
    text = locator.inner_text()
    for value in metadata:
        text = text.replace(value, "")
    assert not re.search(r"[\u3400-\u9fff]", text), text


def test_smart_setup_choices_memory_and_layout(stack, browser):
    from playwright.sync_api import expect

    base, _ = stack
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/smart-settings"
    shots.mkdir(parents=True, exist_ok=True)

    def open_card(kind, tmdb_id):
        page.goto(f"{base}/media/{kind}/{tmdb_id}")
        page.get_by_role("button", name="Track this title", exact=True).click()
        return page.get_by_role("region", name="Smart selection", exact=True)

    def confirm():
        # The subscription shell is migrated in the next slice; this test targets its smart card.
        page.get_by_role(
            "button", name=re.compile("^(确认订阅|Confirm subscription)$")
        ).last.click()
        expect(page.get_by_role("region", name="Smart selection", exact=True)).to_have_count(0)

    card = open_card("movie", 701)
    expect(
        card.get_by_text("Set this up once for both movies and series.", exact=True)
    ).to_be_visible()
    _english(card)
    card.get_by_label("Preferred resolution", exact=True).select_option("1080p")
    card.get_by_label("Preferred source", exact=True).select_option("blu-ray")
    card.get_by_label("Movie wait limit", exact=True).select_option("custom")
    days = card.get_by_role("spinbutton", name="Movie wait limit in days", exact=True)
    days.fill("3")
    card.get_by_role("button", name="Increase Movie wait limit by 1 day", exact=True).click()
    expect(days).to_have_value("4")
    card.get_by_role("button", name="Decrease Movie wait limit by 1 day", exact=True).click()
    card.get_by_label("Wait limit per episode", exact=True).select_option("0")
    _snapshot(page, shots / "first-setup-en.png")
    card.get_by_role("button", name="Save settings", exact=True).click()
    expect(card.get_by_text("Prefer 1080p Blu-ray", exact=True)).to_be_visible()
    expect(
        card.get_by_role(
            "group", name="This title is in English. Require Chinese subtitles?", exact=True
        )
    ).to_be_visible()
    expect(
        card.get_by_label("Yes, only releases with Chinese subtitles", exact=True)
    ).to_be_checked()
    card.get_by_role("button", name="Change quality", exact=True).click()
    card.get_by_role("group", name="Resolution", exact=True).get_by_role(
        "button", name="4K", exact=True
    ).click()
    card.get_by_role("group", name="Source", exact=True).get_by_role(
        "button", name="Remux", exact=True
    ).click()
    scope = card.get_by_role("group", name="Use this preference in future?", exact=True)
    expect(scope.get_by_label("Only this title", exact=True)).to_be_checked()
    scope.get_by_label("All movies", exact=True).check()
    _english(card)
    _snapshot(page, shots / "quality-and-language-en.png")
    confirm()
    rows = _api(context, base, "get", "/subscriptions")
    movie = next(row for row in rows if row["media"]["tmdb_id"] == 701)
    movie_id = movie["id"]
    detail = _api(context, base, "get", f"/subscriptions/{movie_id}")
    assert detail["smart_policy"]["resolution"] == "2160p"
    assert detail["smart_policy"]["source"] == "remux"
    assert detail["smart_policy"]["watchable_languages"] == ["zh"]
    defaults = _api(context, base, "get", "/subscriptions/smart-defaults")
    assert defaults["resolution"] == "1080p" and defaults["source"] == "blu-ray"
    assert defaults["movie_wait_seconds"] == 3 * 86400 and defaults["tv_wait_seconds"] == 0

    page.goto(base + "/settings/subscription")
    languages = page.get_by_role("list", name="Languages you understand", exact=True)
    expect(languages.get_by_text("Chinese", exact=True)).to_be_visible()
    page.get_by_label("Add a language you understand", exact=True).select_option("ja")
    page.get_by_role("button", name="Add", exact=True).click()
    expect(languages.get_by_text("Japanese", exact=True)).to_be_visible()
    page.get_by_role("button", name="Remove Japanese", exact=True).click()
    expect(languages.get_by_text("Japanese", exact=True)).to_have_count(0)

    card = open_card("tv", 804)
    expect(
        card.get_by_text("English · Only releases with Chinese subtitles", exact=True)
    ).to_be_visible()
    card.get_by_role("button", name="Change subtitle requirements", exact=True).click()
    expect(card.get_by_role("group", name="Do you understand English?", exact=True)).to_be_visible()
    card.get_by_label("No, I understand English", exact=True).check()
    confirm()
    detail = _api(context, base, "get", f"/subscriptions/{movie_id}")
    assert detail["smart_policy"]["watchable_languages"] == []
    events = _api(context, base, "get", f"/subscriptions/{movie_id}/activities")
    assert any(
        event["message"].startswith("Following current smart settings and memory:")
        for event in events
    )

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = _api(context, base, "get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        _api(context, base, "put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/subscription")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")
        panel = page.get_by_role("tabpanel", name="Smart selection", exact=True)
        expect(panel.get_by_text("All movies · 4K Remux", exact=True)).to_be_visible()
        expect(
            panel.get_by_role("list", name="Languages you understand").get_by_text(
                "English", exact=True
            )
        ).to_be_visible()
        _english(panel, "奥本海默", "绝命毒师")
        assert panel.evaluate("el => el.scrollWidth <= el.clientWidth + 1")
        _snapshot(page, shots / f"{theme_id}-{width}-memory-en.png")
        settings = panel.get_by_role("region", name="Smart settings", exact=True)
        settings.get_by_role("button", name="Edit settings", exact=True).click()
        settings.get_by_text("Selection and minimum requirements", exact=True).click()
        _english(settings)
        assert settings.evaluate("el => el.scrollWidth <= el.clientWidth + 1")
        _snapshot(page, shots / f"{theme_id}-{width}-edit-en.png")
        settings.get_by_role("button", name="Cancel changes", exact=True).click()
    assert _api(context, base, "get", "/subscriptions/smart-defaults") == defaults

    page.set_viewport_size({"width": 1280, "height": 1000})
    page.evaluate("window.smartLanguageMarker = 919")
    for locale, section, title, language_name in (
        ("zh-Hans", "订阅规则", "智能选择", "英语"),
        ("en", "Subscription rules", "Smart selection", "English"),
    ):
        english = page.locator("html").get_attribute("lang") == "en"
        page.get_by_role(
            "button", name="Back to dashboard" if english else "返回工作台", exact=True
        ).click()
        _change_language(page, locale)
        page.get_by_role("button", name=re.compile("^(AD admin|Account menu$|账号菜单$)")).click()
        page.get_by_role(
            "button", name="设置" if locale == "zh-Hans" else "Settings", exact=True
        ).click()
        page.get_by_role("button", name=section, exact=True).click()
        panel = page.get_by_role("tabpanel", name=title, exact=True)
        expect(panel.get_by_text(language_name, exact=True)).to_be_visible()
        assert page.evaluate("window.smartLanguageMarker") == 919
    assert not errors
    context.close()

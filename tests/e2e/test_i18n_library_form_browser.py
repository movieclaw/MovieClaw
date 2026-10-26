"""English library creation, real directory navigation, editing and localized settings."""

from __future__ import annotations

import re

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot

stack = theme.stack
browser = theme.browser
pytestmark = pytest.mark.integration


def _english_copy(locator, *, user_text=""):
    text = locator.inner_text().replace(user_text, "") if user_text else locator.inner_text()
    assert not re.search(r"[\u3400-\u9fff]", text), text


def test_library_forms_and_metadata_settings_in_english(stack, browser, tmp_path):
    from playwright.sync_api import expect

    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 900})
    assert context.request.post(f"{stack}/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    root = tmp_path / "Anime"
    root.mkdir()
    name = "我的动画"
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    artifacts = theme.REPO / ".tmp-uidev/i18n/library-form"
    artifacts.mkdir(parents=True, exist_ok=True)
    page.goto(f"{stack}/library/manage?create=1")
    dialog = page.get_by_role("dialog")
    expect(dialog.get_by_role("heading", name="Add library", exact=True)).to_be_visible()
    _english_copy(dialog)
    _snapshot(page, artifacts / "types-en.png")
    dialog.get_by_role("button", name=re.compile("^Movie")).click()
    dialog.get_by_placeholder("e.g. Movies / Animation").fill(name)
    dialog.get_by_role("button", name="Browse and add a server folder", exact=True).click()
    picker = page.get_by_role("dialog", name="Choose a server folder", exact=True)
    picker.get_by_title("Enter path manually", exact=True).click()
    path = picker.get_by_placeholder("Enter an absolute path and press Enter")
    path.fill(str(root))
    path.press("Enter")
    picker.get_by_role("button", name="Choose this folder", exact=True).click()
    expect(picker).to_have_count(0)
    dialog.get_by_role("button", name="Next: collection scope", exact=True).click()
    dialog.get_by_role("button", name="Japan", exact=True).click()
    dialog.get_by_role("button", name="Animation", exact=True).click()
    expect(dialog.get_by_text(re.compile("^Current: collect Animation from Japan"))).to_be_visible()
    _english_copy(dialog, user_text=name)
    _snapshot(page, artifacts / "scope-en.png")
    dialog.get_by_role("button", name="Create and start scan", exact=True).click()
    expect(dialog).to_have_count(0)
    saved = context.request.get(f"{stack}/api/v1/libraries").json()["data"]
    library = next(item for item in saved if item["name"] == name)
    library_id = library["id"]
    assert library["root_paths"] == [str(root)]
    assert library["source"] == "tmdb"
    assert {r["field"]: r["values"] for r in library["match_rules"]} == {
        "genres": [16],
        "origin_countries": ["JP"],
    }

    def edit(label="Edit library"):
        english = page.locator("html").get_attribute("lang") == "en"
        page.get_by_role(
            "button", name=f'Actions for "{name}"' if english else f"「{name}」的操作", exact=True
        ).click()
        page.get_by_role("menuitem", name=label, exact=True).click()
        return page.get_by_role("dialog")

    dialog = edit()
    expect(dialog.get_by_role("heading", name=f'Edit "{name}"', exact=True)).to_be_visible()
    dialog.locator('[data-section="scan"] > button').click()
    _english_copy(dialog, user_text=name)
    dialog.locator('[data-section="scrape"] > button').click()
    _english_copy(dialog, user_text=name)
    metadata = dialog.get_by_role("button", name=re.compile("^Metadata language"))
    metadata.click()
    card = metadata.locator("..")
    card.get_by_role("button", name="Custom", exact=True).click()
    _snapshot(page, artifacts / "language-card-en.png")
    japanese = card.locator("button[aria-pressed]").filter(has_text="Japanese")
    japanese.click()
    expect(japanese).to_have_attribute("aria-pressed", "true")
    _snapshot(page, artifacts / "overrides-en.png")
    dialog.get_by_role("button", name="Save", exact=True).click()
    expect(dialog).to_have_count(0)
    saved = context.request.get(f"{stack}/api/v1/libraries/{library_id}").json()["data"]
    assert "ja-JP" in saved["scrape_overrides"]["language_priority"]
    assert saved["match_rules"] == library["match_rules"]

    page.evaluate("window.libraryFormLanguageMarker = 321")
    for locale, edit_label, scope_label, country, genre in (
        ("zh-Hans", "编辑库", "收藏范围", "日本", "动画"),
        ("en", "Edit library", "Collection scope", "Japan", "Animation"),
    ):
        _change_language(page, locale)
        dialog = edit(edit_label)
        dialog.get_by_role("button", name=re.compile("^" + scope_label)).click()
        expect(dialog.get_by_role("button", name=country, exact=True)).to_have_attribute(
            "data-active", "true"
        )
        expect(dialog.get_by_role("button", name=genre, exact=True)).to_have_attribute(
            "data-active", "true"
        )
        dialog.get_by_role(
            "button", name="Cancel" if locale == "en" else "取消", exact=True
        ).click()
        assert page.evaluate("window.libraryFormLanguageMarker") == 321

    # The same shared controls in global settings, including real auto-save and template errors.
    page.get_by_role("button", name=re.compile("^AD admin")).click()
    page.get_by_role("button", name="Settings", exact=True).click()
    page.get_by_role("button", name="Metadata and organization", exact=True).click()
    expect(page.get_by_role("button", name=re.compile("^Metadata language"))).to_be_visible()
    _english_copy(page.locator("main").first, user_text=name)
    page.get_by_role("button", name=re.compile("^Content rating")).click()
    page.get_by_role("button", name=re.compile("More regions$")).click()
    page.get_by_placeholder("Search regions by name or code…").fill("Germany")
    germany = page.get_by_role("button", name=re.compile("^Germany"))
    expect(germany).to_be_visible()
    with page.expect_response(
        lambda r: r.url.endswith("/scrape/config") and r.request.method == "PUT"
    ) as result:
        germany.click()
    assert result.value.ok
    config = context.request.get(f"{stack}/api/v1/scrape/config").json()["data"]["setting"]
    assert "DE" in config["cert_country_priority"]
    page.get_by_role("button", name=re.compile("^Image sources")).click()
    page.get_by_label("Enable Fanart.tv", exact=True).click()
    page.get_by_role("button", name="Verify and enable", exact=True).click()
    expect(page.get_by_text("Paste an API key first", exact=True)).to_be_visible()
    _english_copy(page.locator("main").first, user_text=name)
    _snapshot(page, artifacts / "fanart-form-en.png")
    page.get_by_role("button", name="Cancel", exact=True).click()
    page.get_by_role("button", name=re.compile("^Naming templates")).click()
    template = page.get_by_label("Episode filename", exact=True)
    template.fill("{unknown}")
    expect(page.get_by_text("Unsupported tokens: {unknown}", exact=True)).to_be_visible()
    template.fill("{title} - E{episode:02d}")
    with page.expect_response(
        lambda r: r.url.endswith("/scrape/config") and r.request.method == "PUT"
    ) as result:
        page.get_by_role("button", name="Save", exact=True).click()
    assert result.value.ok
    config = context.request.get(f"{stack}/api/v1/scrape/config").json()["data"]["setting"]
    assert config["naming_episode_file"] == "{title} - E{episode:02d}"
    _english_copy(page.locator("main").first, user_text=name)
    _snapshot(page, artifacts / "naming-en.png")
    page.set_viewport_size({"width": 390, "height": 844})
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    naming_header = page.get_by_role("button", name=re.compile("^Naming templates"))
    naming_header.click()
    naming_header.evaluate(
        "e => Promise.all(e.parentElement.getAnimations({subtree: true}).filter(a => a instanceof CSSTransition).map(a => a.finished.catch(() => {})))"  # noqa: E501
    )
    naming_header.scroll_into_view_if_needed()
    _snapshot(page, artifacts / "naming-mobile-en.png")
    page.set_viewport_size({"width": 1280, "height": 900})
    page.get_by_role("button", name="Back to dashboard", exact=True).click()
    page.set_viewport_size({"width": 390, "height": 844})
    page.get_by_role("button", name="Create library", exact=True).click()
    dialog = page.get_by_role("dialog")
    dialog.get_by_role("button", name=re.compile("^Movie")).click()
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    assert dialog.evaluate("e => e.scrollWidth <= e.clientWidth + 1")
    _snapshot(page, artifacts / "create-mobile-en.png")
    assert not errors
    context.close()

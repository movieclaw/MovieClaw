"""Localized feature catalog, same-document language changes and actual re-enable mutation."""

import re

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_feature_notice_reader_language_and_reenable(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    reply = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not reply.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    disabled = api("put", "/app/features/ingest-watch", data={"enabled": False})
    assert disabled["enabled"] is False and disabled["entries"] == ["library.ingest-watch"]
    state_file = stack["data"] / "plugins-features.json"
    saved = state_file.read_bytes()
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/import-watch")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    title = page.get_by_text("“Automatic import” is disabled", exact=True)
    expect(title).to_be_visible()
    expect(page.get_by_role("button", name="Re-enable", exact=True)).to_be_visible()
    page.evaluate("window.__i18nDocument = 'kept'")
    shots = REPO / ".tmp-uidev/i18n/plugin-features"
    shots.mkdir(parents=True, exist_ok=True)

    def screenshot(name):
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        button = page.get_by_role("button", name="Re-enable", exact=True)
        box = button.bounding_box()
        assert box and box["width"] > 50 and box["x"] + box["width"] <= width
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    screenshot("disabled")
    if width == 1280:
        for language in ("zh-Hans", "en"):
            english = page.locator("html").get_attribute("lang") == "en"
            page.get_by_role(
                "button", name="Appearance and language" if english else "外观与语言", exact=True
            ).click()
            control = page.get_by_test_id("language-settings")
            control.locator(f'input[value="{language}"]').check()
            expect(page.locator("html")).to_have_attribute("lang", language)
            expect(control).to_be_enabled()
            page.get_by_role(
                "button", name="Automatic import" if language == "en" else "自动入库", exact=True
            ).click()
            expect(
                page.get_by_role(
                    "button", name="Re-enable" if language == "en" else "重新开启", exact=True
                )
            ).to_be_visible()
            if language == "en":
                expect(title).to_be_visible()
            else:
                expect(page.get_by_text("「自动入库」已停用", exact=True)).to_be_visible()
            assert page.evaluate("window.__i18nDocument") == "kept"
            assert state_file.read_bytes() == saved
        screenshot("roundtrip")
    with page.expect_response(
        lambda response: response.request.method == "PUT"
        and response.url.endswith("/api/v1/app/features/ingest-watch")
    ) as mutation:
        page.get_by_role("button", name="Re-enable", exact=True).click()
    assert mutation.value.ok
    expect(title).not_to_be_visible()
    restored = next(item for item in api("get", "/app/features") if item["key"] == "ingest-watch")
    assert restored["enabled"] is True
    assert state_file.read_bytes() != saved
    assert not errors
    context.close()

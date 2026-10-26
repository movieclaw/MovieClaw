"""Owned plugin metadata, stable group IDs and restoration through the real Next/API stack."""

import re

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_i18n_plugin_market_browser as market
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
market_http = market.market_http
stack = market.stack


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_owned_plugin_names_group_headings_and_restore(stack, browser, theme_id, width):  # noqa: F811
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
    overview = api("get", "/app/plugins")
    original_groups = overview["groups"]
    if any(row["id"] == "telegram-channel" for row in overview["plugins"]):
        api("delete", "/app/plugins/telegram-channel/bundled")
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/plugins")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_text("WeChat channel", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Restore", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/builtin-plugins"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    shot("removed")
    with page.expect_response(
        lambda response: (
            response.request.method == "POST"
            and response.url.endswith("/telegram-channel/bundled/restore")
        )
    ) as restored:
        page.get_by_role("button", name="Restore", exact=True).click()
    assert restored.value.ok
    expect(page.get_by_role("button", name="Restore", exact=True)).not_to_be_visible()
    assert api("get", "/app/plugins")["removed"] == []
    page.get_by_role("button", name=re.compile("additional system modules?")).click()
    expect(page.get_by_role("heading", name="Core", exact=True)).to_be_visible()
    expect(page.get_by_role("link", name=re.compile(r"^Database core\.database"))).to_be_visible()
    page.get_by_role("heading", name="Core", exact=True).scroll_into_view_if_needed()
    shot("core")
    if width == 1280:
        page.evaluate("window.__i18nDocument = 'kept'")
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
                "button", name="Plugins" if language == "en" else "插件", exact=True
            ).click()
            toggle = (
                re.compile("additional system modules?")
                if language == "en"
                else re.compile("另有.*系统模块")
            )
            page.get_by_role("button", name=toggle).click()
            expect(
                page.get_by_role("heading", name="Core" if language == "en" else "基础", exact=True)
            ).to_be_visible()
            assert api("get", "/app/plugins")["groups"] == original_groups
            assert page.evaluate("window.__i18nDocument") == "kept"
        shot("roundtrip")
    assert not errors
    context.close()

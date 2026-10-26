"""Real saved-account switching/removal plus controlled HTTP startup failures."""

import json
import re

import pytest

from . import test_smart_subscription_browser as smart
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import _wait_for

stack = smart.smart_stack
browser = theme.browser
pytestmark = pytest.mark.integration
FAMILY = {"username": "family", "password": "family-pass-1"}


def test_saved_accounts_profile_names_and_sign_out(stack, browser):
    from playwright.sync_api import expect

    base = stack[0]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    assert context.request.post(base + "/api/v1/members", data=FAMILY).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/account"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english(scope):
        text = scope.inner_text().replace("原始昵称", "").replace("原始", "").replace("原", "")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    def open_accounts(theme_id="silver", width=1280):
        if theme_id == "netflix" and width == 1280:
            page.goto(base + "/library")
            page.get_by_role("button", name="Account menu", exact=True).click()
        else:
            page.goto(base + "/my")
        if theme_id == "netflix" and width == 320:
            expect(page.get_by_role("navigation", name="My shortcuts", exact=True)).to_be_visible()
        english(page.locator("main"))
        page.get_by_role("button", name="Switch account", exact=True).click()
        dialog = page.get_by_role("dialog", name="Switch account", exact=True)
        expect(dialog.get_by_text("Super administrator", exact=False)).to_be_visible()
        expect(dialog.get_by_text("Member", exact=False).last).to_be_visible()
        return dialog

    page.goto(base + "/settings/profile")
    nickname = page.get_by_role("textbox", name="Nickname", exact=True)
    nickname.fill("原始昵称")
    with page.expect_response(
        lambda response: response.url.endswith("/auth/profile") and response.request.method == "PUT"
    ) as changed:
        nickname.press("Enter")
    assert changed.value.ok
    assert api("get", "/auth/me")["nickname"] == "原始昵称"
    english(page.locator("main"))
    api("post", "/auth/login", data=FAMILY)

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        api("post", "/auth/login", data=theme.ADMIN)
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        dialog = open_accounts(theme_id, width)
        english(dialog)
        _snapshot(page, shots / f"{theme_id}-{width}-accounts-en.png")
        dialog.get_by_role("button", name="Remove family from this browser", exact=True).click()
        confirmation = page.get_by_role("dialog", name="Sign out “family”?", exact=True)
        english(confirmation)
        _snapshot(page, shots / f"{theme_id}-{width}-remove-en.png")
        confirmation.get_by_role("button", name="Cancel", exact=True).click()
        assert {row["username"] for row in api("get", "/auth/accounts")} == {"admin", "family"}
        page.evaluate("window.accountSwitchMarker = 440")
        dialog.get_by_title("Switch to family", exact=True).click()
        _wait_for(
            lambda: api("get", "/auth/me")["username"] == "family",
            timeout=20,
            what="actual account switch",
        )
        page.wait_for_function("window.accountSwitchMarker === undefined")
        assert api("get", "/auth/me")["role"] == "member"
        assert api("get", "/auth/me")["nickname"] != "原始昵称"
        assert {row["username"] for row in api("get", "/auth/accounts")} == {"admin", "family"}
        page.goto(base + "/my")
        expect(page.get_by_text("family", exact=True).first).to_be_visible()
        expect(page.get_by_text("原始昵称", exact=True)).to_have_count(0)

    api("post", "/auth/login", data=theme.ADMIN)
    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    dialog = open_accounts()
    dialog.get_by_role("button", name="Remove family from this browser", exact=True).click()
    confirmation = page.get_by_role("dialog", name="Sign out “family”?", exact=True)
    with page.expect_response(
        lambda response: (
            response.url.endswith("/auth/accounts/family") and response.request.method == "DELETE"
        )
    ) as removed:
        confirmation.get_by_role("button", name="Sign out", exact=True).click()
    assert removed.value.ok
    expect(confirmation).to_be_hidden()
    _wait_for(
        lambda: len(api("get", "/auth/accounts")) == 1, timeout=20, what="saved session removal"
    )
    assert [row["username"] for row in api("get", "/auth/accounts")] == ["admin"]
    # Removing a saved session leaves the member account usable.
    api("post", "/auth/login", data=FAMILY)
    api("post", "/auth/login", data=theme.ADMIN)
    dialog = open_accounts()
    dialog.get_by_role("button", name="Sign out of all accounts", exact=True).click()
    confirmation = page.get_by_role("dialog", name="Sign out of all accounts?", exact=True)
    english(confirmation)
    expect(confirmation.get_by_text("All 2 accounts", exact=False)).to_be_visible()
    _snapshot(page, shots / "sign-out-all-en.png")
    confirmation.get_by_role("button", name="Cancel", exact=True).click()
    assert len(api("get", "/auth/accounts")) == 2
    dialog.get_by_role("button", name="Sign out of all accounts", exact=True).click()
    page.get_by_role("dialog", name="Sign out of all accounts?", exact=True).get_by_role(
        "button", name="Sign out of all", exact=True
    ).click()
    page.wait_for_url(re.compile(r"/login(?:\?|$)"))
    assert context.request.get(base + "/api/v1/auth/me").status == 401
    assert not errors
    context.close()


def test_startup_http_failures_translate_and_retry_without_reloading(stack, browser):
    from playwright.sync_api import expect

    base = stack[0]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 900})
    context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    page = context.new_page()
    shots = theme.REPO / ".tmp-uidev/i18n/account"
    shots.mkdir(parents=True, exist_ok=True)
    pattern = "**/api/v1/auth/bootstrap"
    for locale, title, reconnect in (
        ("en", "Could not load workspace", "Reconnect"),
        ("zh-Hans", "工作台加载失败", "重新连接"),
    ):
        preferences = context.request.get(base + "/api/v1/ui/preferences").json()["data"]
        preferences["language"] = locale
        assert context.request.put(base + "/api/v1/ui/preferences", data=preferences).ok
        context.add_cookies([{"name": "mc_locale", "value": locale, "url": base}])
        page.route(
            pattern,
            lambda route: route.fulfill(
                status=503, content_type="text/plain", body="isolated proxy outage"
            ),
        )
        page.goto(base + "/library")
        expect(page.get_by_role("heading", name=title, exact=True)).to_be_visible()
        expect(page.get_by_text("HTTP 503", exact=False)).to_be_visible()
        if locale == "en":
            assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
            expect(
                page.get_by_role("link", name="View system status", exact=True)
            ).to_have_attribute("href", "/health")
        _snapshot(page, shots / f"startup-503-{locale}.png")
        page.evaluate("window.startupRetryMarker = 441")
        page.unroute(pattern)
        page.get_by_role("button", name=reconnect, exact=True).click()
        expect(page.get_by_role("heading", name=title, exact=True)).to_have_count(0)
        expect(
            page.get_by_role(
                "link",
                name="Create your first library" if locale == "en" else "创建第一个媒体库",
                exact=True,
            )
        ).to_be_visible()
        assert page.evaluate("window.startupRetryMarker") == 441
    # A supplied server message remains exact rather than being guessed from its Chinese text.
    context.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
    page.route(
        pattern,
        lambda route: route.fulfill(
            status=500,
            content_type="application/json",
            body=json.dumps({"success": False, "message": "原始运维错误", "code": "LAB_FAILURE"}),
        ),
    )
    page.goto(base + "/library")
    expect(page.get_by_text("原始运维错误", exact=True)).to_be_visible()
    page.unroute(pattern)
    context.close()

"""Real Next + API + database language flow. Run with pytest -m integration."""

from __future__ import annotations

import re

import pytest

from . import test_theme_device_class_browser as theme

ADMIN = theme.ADMIN
stack = theme.stack
browser = theme.browser

pytestmark = pytest.mark.integration


def test_language_end_to_end(stack, browser):
    from playwright.sync_api import expect

    artifacts = theme.REPO / ".tmp-uidev/i18n"
    artifacts.mkdir(parents=True, exist_ok=True)
    base = stack
    english = browser.new_context(
        locale="en-US", timezone_id="America/New_York", viewport={"width": 1280, "height": 900}
    )
    english.set_default_navigation_timeout(120_000)
    page = english.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(f"{base}/setup", wait_until="domcontentloaded")
    expect(page.locator("html")).to_have_attribute("lang", "en")
    expect(page.locator("main")).to_have_attribute("data-revealed", "true", timeout=30000)
    expect(page.get_by_role("button", name="Get started", exact=True)).to_be_visible()
    page.get_by_role("button", name="Get started", exact=True).click()
    page.get_by_placeholder("Administrator username").fill(ADMIN["username"])
    page.get_by_placeholder("Password (at least 8 characters)", exact=True).fill(ADMIN["password"])
    page.get_by_placeholder("Confirm password", exact=True).fill("mismatched")
    page.get_by_role("button", name="Create account and continue").click()
    expect(page.get_by_text("Passwords do not match", exact=True)).to_be_visible()
    page.get_by_placeholder("Confirm password", exact=True).fill(ADMIN["password"])
    page.get_by_role("button", name="Create account and continue").click()
    page.wait_for_url(f"{base}/", wait_until="domcontentloaded")
    expect(page.get_by_role("button", name="New session", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="My subscriptions", exact=True)).to_be_visible()
    expect(page.get_by_text("Super administrator", exact=True)).to_be_visible()
    page.wait_for_function(
        """() => [...document.querySelectorAll('div[aria-hidden="true"][class*="z-[100]"]')]
        .every(element => getComputedStyle(element).opacity === "0")"""
    )
    page.screenshot(path=str(artifacts / "home-en.png"), full_page=True)
    page.get_by_role("button", name=re.compile("Super administrator")).click()
    page.get_by_role("button", name="Sign out", exact=True).click()
    page.wait_for_url(
        re.compile(re.escape(base) + r"/login(?:\?.*)?$"), wait_until="domcontentloaded"
    )

    page.goto(f"{base}/login?next=/settings/appearance", wait_until="domcontentloaded")
    expect(page.get_by_placeholder("Username", exact=True)).to_be_visible()
    page.get_by_placeholder("Username", exact=True).fill(ADMIN["username"])
    page.get_by_placeholder("Password", exact=True).fill("wrong-password")
    with page.expect_response(
        lambda r: r.url.endswith("/auth/login") and r.request.method == "POST"
    ) as response:
        page.get_by_role("button", name="Sign in", exact=True).last.click()
    body = response.value.json()
    assert body["message_key"] == "errors.auth.wrongPassword"
    assert body["message"] == "Incorrect username or password"
    assert response.value.request.headers["accept-language"] == "en"
    assert response.value.request.headers["x-movieclaw-timezone"] == "America/New_York"
    expect(page.get_by_text("Incorrect username or password", exact=True)).to_be_visible()
    page.screenshot(path=str(artifacts / "login-en.png"), full_page=True)

    # No document reload: form state and a window marker survive switching.
    page.evaluate("window.__languageMarker = 42")
    page.get_by_role("combobox", name="Language", exact=True).select_option("zh-Hans")
    expect(page.locator("html")).to_have_attribute("lang", "zh-Hans")
    expect(page.get_by_placeholder("用户名", exact=True)).to_have_value(ADMIN["username"])
    expect(page.get_by_text("用户名或密码错误", exact=True)).to_be_visible()
    assert page.evaluate("window.__languageMarker") == 42
    page.get_by_placeholder("密码", exact=True).fill("wrong-password")
    with page.expect_response(
        lambda r: r.url.endswith("/auth/login") and r.request.method == "POST"
    ) as response:
        page.get_by_role("button", name="登录", exact=True).last.click()
    assert response.value.json()["message"] == "用户名或密码错误"
    expect(page.get_by_text("用户名或密码错误", exact=True)).to_be_visible()
    page.screenshot(path=str(artifacts / "login-zh.png"), full_page=True)
    page.get_by_placeholder("密码", exact=True).fill(ADMIN["password"])
    page.get_by_role("button", name="登录", exact=True).last.click()
    page.wait_for_url(f"{base}/settings/appearance", wait_until="domcontentloaded")
    group = page.get_by_test_id("language-settings")
    expect(group).to_be_visible(timeout=30000)
    page.evaluate("window.__languageMarker = 84")
    group.locator('input[value="en"]').check()
    expect(group.locator('input[value="en"]')).to_be_enabled()
    expect(page.locator("html")).to_have_attribute("lang", "en")
    expect(page.get_by_role("heading", name="Appearance and language", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Devices", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Updates and maintenance", exact=True)).to_be_visible()
    expect(page).to_have_title("Appearance and language · Settings · MovieClaw")
    assert page.evaluate("window.__languageMarker") == 84
    saved = english.request.get(f"{base}/api/v1/ui/preferences").json()["data"]
    assert saved["language"] == "en"
    page.reload(wait_until="domcontentloaded")
    expect(group.locator('input[value="en"]')).to_be_checked()
    expect(page.locator("html")).to_have_attribute("lang", "en")
    page.wait_for_function(
        """() => [...document.querySelectorAll('div[aria-hidden="true"][class*="z-[100]"]')]
          .every(element => getComputedStyle(element).opacity === "0")"""
    )
    expect(
        page.get_by_text("Solid colors, brand red, top navigation and cinematic rows", exact=True)
    ).to_be_visible()
    page.screenshot(path=str(artifacts / "appearance-en.png"), full_page=True)
    # The bundled theme uses the same live locale context through its public SDK.
    page.get_by_role("button", name=re.compile("^Netflix")).first.click()
    expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_role("link", name="My subscriptions", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="New task", exact=True)).to_be_visible()
    page.screenshot(path=str(artifacts / "netflix-appearance-en.png"), full_page=True)
    page.get_by_role("link", name="My subscriptions", exact=True).click()
    expect(page.get_by_role("heading", name="My subscriptions", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="All", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Series", exact=True)).to_be_visible()
    expect(
        page.get_by_role("heading", name="Start with something you want to watch", exact=True)
    ).to_be_visible()
    expect(page.get_by_role("link", name="Discover series", exact=True)).to_be_visible()
    page.screenshot(path=str(artifacts / "netflix-subscriptions-en.png"), full_page=True)
    page.goto(f"{base}/settings/appearance", wait_until="domcontentloaded")
    page.get_by_role("button", name=re.compile("^Silver Glass")).first.click()
    expect(page.locator("html")).not_to_have_attribute("data-theme", "netflix")

    # New browser starts in Chinese, but this account's explicit language wins at login.
    chinese = browser.new_context(
        locale="zh-CN", timezone_id="Asia/Shanghai", viewport={"width": 390, "height": 844}
    )
    chinese.set_default_navigation_timeout(120_000)
    other = chinese.new_page()
    other.goto(f"{base}/login?next=/settings/appearance", wait_until="domcontentloaded")
    expect(other.locator("html")).to_have_attribute("lang", "zh-Hans")
    other.get_by_placeholder("用户名", exact=True).fill(ADMIN["username"])
    other.get_by_placeholder("密码", exact=True).fill(ADMIN["password"])
    other.get_by_role("button", name="登录", exact=True).last.click()
    other.wait_for_url(f"{base}/settings/appearance", wait_until="domcontentloaded")
    expect(other.locator("html")).to_have_attribute("lang", "en")
    other.get_by_test_id("language-settings").locator('input[value="auto"]').check()
    expect(other.locator("html")).to_have_attribute("lang", "zh-Hans")
    expect(other.get_by_test_id("language-settings").locator('input[value="auto"]')).to_be_enabled()
    expect(other.get_by_role("heading", name="外观与语言", exact=True).first).to_be_visible()
    assert not any(cookie["name"] == "mc_locale" for cookie in chinese.cookies())
    other.reload(wait_until="domcontentloaded")
    expect(other.locator("html")).to_have_attribute("lang", "zh-Hans")
    assert other.evaluate("document.documentElement.scrollWidth <= innerWidth")
    assert not errors
    chinese.close()
    english.close()


def test_development_pseudo_and_localized_manifest(stack, browser):
    from playwright.sync_api import expect

    context = browser.new_context(locale="en-US")
    context.request.post(f"{stack}/api/v1/auth/bootstrap", data=ADMIN)
    context.clear_cookies()
    context.set_default_navigation_timeout(120_000)
    page = context.new_page()
    page.goto(f"{stack}/login?add=1&locale=pseudo", wait_until="domcontentloaded")
    expect(page.locator("html")).to_have_attribute("lang", "en")
    expect(page.locator("body")).to_contain_text("Šîğñ", timeout=30000)
    assert not any(cookie["value"] == "pseudo" for cookie in context.cookies())
    # APIRequestContext 不会从浏览器 locale 推导 Accept-Language；经页面取 manifest，
    # 才覆盖真实浏览器的语言头与 cookie 协商。
    response = page.evaluate("""async () => {
        const response = await fetch('/manifest.webmanifest');
        return {vary: response.headers.get('vary'), body: await response.json()};
    }""")
    assert {"accept-language", "cookie"} <= {
        value.strip().lower() for value in response["vary"].split(",")
    }
    manifest = response["body"]
    assert manifest["lang"] == "en"
    assert manifest["description"] == "Your media tracking workspace"
    page.goto(f"{stack}/login?add=1", wait_until="domcontentloaded")
    expect(page.get_by_placeholder("Username", exact=True)).to_be_visible()
    page.get_by_role("combobox", name="Language", exact=True).select_option("zh-Hans")
    expect(page.locator("html")).to_have_attribute("lang", "zh-Hans")
    translated = page.evaluate(
        "async () => (await fetch('/manifest.webmanifest')).json()"
    )
    assert translated["lang"] == "zh-Hans"
    assert translated["description"] == "液态玻璃风格的影视追踪工作台"
    context.close()

"""Reader-local route metadata and accessible labels with real auth and avatar storage."""

import hashlib
import html
import re
import sqlite3

import pytest
from tests.api.test_avatar import _PNG_1X1

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_library_manage_browser import REPO

browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack
pytestmark = pytest.mark.integration


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_metadata_and_accessibility_preserve_author_content(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    # A fresh visitor can change the displayed quote before signing in.
    visitor = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    welcome = visitor.new_page()
    welcome.goto(base + "/login")
    quote = welcome.get_by_role("button", name=re.compile(r"Tap for another quote\.$"))
    expect(quote).to_be_visible()
    previous = quote.get_attribute("aria-label")
    assert previous and "轻点换一句台词" not in previous
    # English readers get the original line (or the English translation) and the English title
    assert not re.search(r"[㐀-鿿]", previous), previous
    quote.click()
    expect(quote).not_to_have_attribute("aria-label", previous)
    visitor.close()
    chinese_visitor = browser.new_context(locale="zh-CN", viewport={"width": width, "height": 1000})
    chinese_welcome = chinese_visitor.new_page()
    chinese_welcome.goto(base + "/login")
    chinese_quote = chinese_welcome.get_by_role("button", name=re.compile(r"轻点换一句台词$"))
    expect(chinese_quote).to_be_visible()
    assert re.search(r"——《.+》。", chinese_quote.get_attribute("aria-label") or "")
    chinese_visitor.close()

    context = browser.new_context(
        locale="en-US",
        viewport={"width": width, "height": 1000},
        is_mobile=width == 320,
        has_touch=width == 320,
    )
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    assert context.request.put(base + "/api/v1/auth/profile", data={"nickname": "原始昵称"}).ok
    uploaded = context.request.post(
        base + "/api/v1/auth/avatar",
        multipart={
            "file": {
                "name": "作者头像.png",
                "mimeType": "image/png",
                "buffer": _PNG_1X1,
            }
        },
    )
    assert uploaded.ok, uploaded.text()
    source_avatar = uploaded.json()["data"]["avatar_url"]
    preferences = context.request.get(base + "/api/v1/ui/preferences").json()["data"]
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    assert context.request.put(base + "/api/v1/ui/preferences", data=preferences).ok

    def facts():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            raw = db.execute(
                "SELECT value_json FROM app_setting WHERE namespace='auth.admin'"
            ).fetchone()[0]
            return hashlib.sha256(raw.encode()).hexdigest()

    original = facts()
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/metadata-accessibility"
    shots.mkdir(parents=True, exist_ok=True)
    routes = [
        ("/apps/fixture-missing", "Plugin pages", "插件页面"),
        ("/my", "Me", "我的"),
        ("/new", "New task", "新任务"),
        ("/people/990001", "Person", "影人"),
        ("/subscriptions/990002", "Subscription details", "订阅详情"),
        ("/subscriptions", "My subscriptions", "我的订阅"),
        ("/play/990003", "Play", "播放"),
        (
            "/settings/plugins/author-fixture",
            "author-fixture · Plugin · Settings",
            "author-fixture · 插件 · 设置",
        ),
    ]
    for language in ("en", "zh-Hans", "en"):
        preferences["language"] = language
        assert context.request.put(base + "/api/v1/ui/preferences", data=preferences).ok
        context.add_cookies([{"name": "mc_locale", "value": language, "url": base}])
        for route, english, chinese in routes:
            response = context.request.get(base + route)
            assert response.ok, (route, response.status)
            titles = re.findall(r"<title>(.*?)</title>", response.text(), re.DOTALL)
            assert titles, route
            assert (
                html.unescape(titles[-1])
                == (english if language == "en" else chinese) + " · MovieClaw"
            )
        page.goto(base + "/settings/profile")
        expect(page.locator("html")).to_have_attribute("lang", language)
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", theme_id)
        avatar = (
            page.locator("main")
            .get_by_alt_text(
                "原始昵称’s avatar" if language == "en" else "原始昵称 的头像", exact=True
            )
            .first
        )
        expect(avatar).to_be_visible()
        assert "/auth/avatar" in avatar.get_attribute("src")
        expect(
            page.get_by_role("textbox", name="Nickname" if language == "en" else "昵称", exact=True)
        ).to_have_value("原始昵称")
        if width == 320 and language == "en":
            label_box = page.get_by_text("Nickname", exact=True).bounding_box()
            field_box = page.get_by_role("textbox", name="Nickname", exact=True).bounding_box()
            assert label_box and field_box
            assert field_box["y"] >= label_box["y"] + label_box["height"]
            assert field_box["x"] >= 0 and field_box["x"] + field_box["width"] <= width
        page.screenshot(
            path=str(shots / f"{theme_id}-{width}-{language}-profile.png"), animations="disabled"
        )
        page.goto(base + "/health")
        expect(page).to_have_title(
            "Service status · MovieClaw" if language == "en" else "服务状态 · MovieClaw"
        )
        expect(page.get_by_text("Healthy", exact=True)).to_be_visible()
        assert context.request.get(base + source_avatar).body() == _PNG_1X1
        assert (
            context.request.get(base + "/api/v1/auth/me").json()["data"]["avatar_url"]
            == source_avatar
        )
        assert facts() == original
    assert not errors, errors
    context.close()

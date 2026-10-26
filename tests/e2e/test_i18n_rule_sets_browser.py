"""Real rule-set CRUD and preference order through Next, API and SQLite."""

from __future__ import annotations

import re

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot

stack = theme.stack
browser = theme.browser
pytestmark = pytest.mark.integration


def _english(locator, user_name=""):
    text = locator.inner_text().replace(user_name, "") if user_name else locator.inner_text()
    assert not re.search(r"[\u3400-\u9fff]", text), text


@pytest.mark.parametrize("theme_id", ["silver", "netflix"])
@pytest.mark.parametrize("width", [1280, 320])
def test_rule_sets_keep_scope_order_custom_names_and_protection(stack, browser, theme_id, width):
    from playwright.sync_api import expect

    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 900})
    assert context.request.post(f"{stack}/api/v1/auth/bootstrap", data=theme.ADMIN).status in (
        200,
        409,
    )
    assert context.request.post(f"{stack}/api/v1/auth/login", data=theme.ADMIN).ok
    assert context.request.put(
        f"{stack}/api/v1/ui/preferences",
        data={
            "language": "en",
            "theme": theme_id,
            "theme_desktop": theme_id,
            "theme_mobile": theme_id,
        },
    ).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    artifacts = theme.REPO / ".tmp-uidev/i18n/rule-sets"
    artifacts.mkdir(parents=True, exist_ok=True)
    page.goto(f"{stack}/settings/subscription")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
        page.locator('[class*="nf:"]').first.wait_for(state="attached")
    page.get_by_role("tab", name="Custom rules", exact=True).click()
    listing = page.get_by_role("list", name="Rule sets", exact=True)
    expect(listing.get_by_role("button", name="Default rule set", exact=True)).to_be_visible()
    seeded = context.request.get(f"{stack}/api/v1/rule-sets").json()["data"]
    default = next(row for row in seeded if row["name_key"])
    assert default["name"] == "默认规则组"

    # A spec-only save of the translated built-in name must not rename it to English.
    listing.get_by_role("button", name="Default rule set", exact=True).click()
    dialog = page.get_by_role("dialog")
    expect(dialog.get_by_placeholder("e.g. 4K freeleech, smaller series releases")).to_have_value(
        "Default rule set"
    )
    _english(dialog)
    dialog.get_by_role("button", name="Save", exact=True).click()
    expect(dialog).to_have_count(0)
    saved = context.request.get(f"{stack}/api/v1/rule-sets").json()["data"]
    assert (
        next(row for row in saved if row["id"] == default["id"])["name_key"] == default["name_key"]
    )

    name = f"我的追剧规则 {theme_id} {width}"
    page.get_by_role("button", name="New rule set", exact=True).click()
    dialog = page.get_by_role("dialog")
    dialog.get_by_placeholder("e.g. 4K freeleech, smaller series releases").fill(name)
    dialog.get_by_role("button", name=re.compile("^Scope")).click()
    dialog.get_by_role("button", name="Series", exact=True).click()
    dialog.get_by_role("button", name="Japan", exact=True).click()
    dialog.get_by_role("button", name="Animation", exact=True).click()
    dialog.get_by_role("button", name="2160p", exact=True).click()
    dialog.get_by_role("button", name="1080p", exact=True).click()
    dialog.get_by_role("button", name="Upgrade to Blu-ray", exact=True).click()
    # The target can differ from the highest preferred resolution.
    dialog.get_by_role("button", name="1080p", exact=True).last.click()
    dialog.get_by_role("button", name=re.compile("^Upgrade priority")).click()
    dialog.get_by_role("button", name="HDR", exact=True).click()
    expect(dialog.get_by_text("· Not configured", exact=True)).to_be_visible()
    dialog.get_by_role("button", name=re.compile("^Quality and origin")).click()
    dialog.get_by_role("button", name="H.265", exact=True).click()
    dialog.get_by_role("button", name="DV", exact=True).click()
    dialog.get_by_role("button", name=re.compile("^Download requirements")).click()
    dialog.get_by_role("button", name="Chinese (Simplified or Traditional)", exact=True).click()
    dialog.get_by_role("button", name="Mandarin", exact=True).click()
    dialog.get_by_text("Freeleech releases only", exact=True).locator("../..").locator(
        "input"
    ).check()
    minimum = (
        dialog.get_by_text("Minimum size per episode (MB)", exact=True)
        .locator("..")
        .locator("input")
    )
    maximum = (
        dialog.get_by_text("Maximum size per episode (MB)", exact=True)
        .locator("..")
        .locator("input")
    )
    minimum.fill("1000")
    maximum.fill("100")
    dialog.get_by_role("button", name="Save", exact=True).click()
    expect(
        dialog.get_by_text("Minimum size cannot exceed maximum size", exact=True)
    ).to_be_visible()
    maximum.fill("2000")
    ladder = dialog.get_by_role("button", name=re.compile("^Then upgrade step by step"))
    ladder.click()
    expect(dialog.get_by_text("1080p · Blu-ray · DV", exact=True).first).to_be_visible()
    expect(dialog.get_by_text(re.compile("Higher tiers.*2160p · Remux · DV"))).to_be_visible()
    _english(dialog, name)
    assert dialog.evaluate("el => el.scrollWidth <= el.clientWidth + 1")
    _snapshot(page, artifacts / f"{theme_id}-{width}-editor-en.png")
    dialog.locator(".scroll-thin").last.evaluate("el => el.scrollTop = 0")
    _snapshot(page, artifacts / f"{theme_id}-{width}-top-en.png")
    dialog.get_by_role("button", name="Save", exact=True).click()
    expect(dialog).to_have_count(0)
    rows = context.request.get(f"{stack}/api/v1/rule-sets").json()["data"]
    saved = next(row for row in rows if row["name"] == name)
    assert saved["name_key"] is None
    assert saved["spec"]["resolutions"] == ["2160p", "1080p"]
    assert saved["spec"]["upgrade_source"] == "blu-ray"
    assert saved["spec"]["cutoff_resolution"] == "1080p"
    assert saved["spec"]["upgrade_ladder"] == ["resolution", "source", "hdr"]
    assert saved["spec"]["subtitle_languages_require"] == ["zh"]
    assert saved["spec"]["audio_languages_require"] == ["cmn"]
    assert saved["spec"]["free_only"]
    assert {rule["field"]: rule["values"] for rule in saved["match_rules"]} == {
        "kind": ["tv"],
        "genres": [16],
        "origin_countries": ["JP"],
    }
    row = listing.get_by_role("listitem").filter(
        has=page.get_by_role("button", name=name, exact=True)
    )
    expect(row.get_by_text(re.compile("Applies to.*Series.*Japan.*Animation"))).to_be_visible()
    _english(row, name)
    _snapshot(page, artifacts / f"{theme_id}-{width}-list-en.png")
    page.set_viewport_size({"width": 1280, "height": 900})
    page.get_by_role("tab", name="Custom rules", exact=True).click()

    def menu(action):
        listing.get_by_role("button", name=f"Actions for “{name}”", exact=True).click()
        page.get_by_role("menuitem", name=action, exact=True).click()

    menu("Copy as new rule set")
    dialog = page.get_by_role("dialog")
    expect(dialog.get_by_placeholder("e.g. 4K freeleech, smaller series releases")).to_have_value(
        f"{name} copy"
    )
    dialog.get_by_role("button", name="Save", exact=True).click()
    expect(dialog).to_have_count(0)
    copies = context.request.get(f"{stack}/api/v1/rule-sets").json()["data"]
    copied = next(item for item in copies if item["name"] == f"{name} copy")
    assert copied["spec"] == saved["spec"] and copied["match_rules"] == []
    menu("Set as default")
    expect(row.get_by_text("Default", exact=True)).to_be_visible()
    listing.get_by_role("button", name=f"Actions for “{name}”", exact=True).click()
    expect(page.get_by_role("menuitem", name=re.compile("^Delete"))).to_be_disabled()
    page.keyboard.press("Escape")

    # Change language using the actual account setting, then return to the same data.
    page.evaluate("window.ruleLanguageMarker = 812")
    for language, button, tab in (
        ("zh-Hans", "订阅规则", "自定义规则"),
        ("en", "Subscription rules", "Custom rules"),
    ):
        current_en = page.locator("html").get_attribute("lang") == "en"
        page.get_by_role(
            "button", name="Back to dashboard" if current_en else "返回工作台", exact=True
        ).click()
        _change_language(page, language)
        page.get_by_role("button", name=re.compile("^(AD admin|Account menu$|账号菜单$)")).click()
        page.get_by_role(
            "button", name="设置" if language == "zh-Hans" else "Settings", exact=True
        ).click()
        page.get_by_role("button", name=button, exact=True).click()
        page.get_by_role("tab", name=tab, exact=True).click()
        expect(
            page.get_by_role("list").get_by_role("button", name=name, exact=True)
        ).to_be_visible()
        if language == "zh-Hans":
            chinese_row = page.get_by_role("listitem").filter(
                has=page.get_by_role("button", name=name, exact=True)
            )
            for original in (
                "适用 剧集 · 日本 · 动画",
                "洗到 1080p 蓝光 · DV",
                "字幕: 中文（不限简繁）",
                "音轨: 国语",
                "仅免费",
                "单集 1000–2000MB",
            ):
                expect(chinese_row.get_by_text(original, exact=True)).to_be_visible()
        assert page.evaluate("window.ruleLanguageMarker") == 812
    listing = page.get_by_role("list", name="Rule sets", exact=True)
    listing.get_by_role("button", name="Actions for “Default rule set”", exact=True).click()
    page.get_by_role("menuitem", name="Set as default", exact=True).click()
    menu("Delete")
    page.get_by_role("dialog").get_by_role("button", name="Delete", exact=True).click()
    expect(listing.get_by_role("button", name=name, exact=True)).to_have_count(0)
    assert context.request.delete(f"{stack}/api/v1/rule-sets/{copied['id']}").ok
    assert not errors
    context.close()

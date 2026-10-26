"""Inspect and manage a subscription through real Next/API/SQLite in both themes."""

import re

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run
from .test_i18n_subscription_lifecycle_browser import stack as stack
from .test_library_manage_browser import _wait_for

browser = theme.browser
pytestmark = pytest.mark.integration


async def _set_episode_evidence(database_url, subscription_id, source, count):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Subscription

    database = Database(database_url)
    try:
        async with database.session() as session:
            subscription = await session.get(Subscription, subscription_id)
            subscription.episode_evidence = {
                "seasons": {"1": {source: count, "site_title": "Fixture.Show.S01E06"}}
            }
            session.add(subscription)
            await session.commit()
    finally:
        await database.dispose()


def test_inspector_management_and_episode_floor_in_both_languages(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/subscription-inspector"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    root = stack["roots"]["shows"]
    library = api(
        "post", "/libraries", data={"name": "我的剧集", "kind": "tv", "root_paths": [str(root)]}
    )
    default = next(rule for rule in api("get", "/rule-sets") if rule["is_default"])
    custom = api(
        "post", "/rule-sets", data={"name": "我的规则组", "spec": {"resolutions": ["1080p"]}}
    )
    sub_id = api(
        "post",
        "/subscriptions",
        data={
            "title_ref": "tmdb:tv:200",
            "selected_seasons": [1],
            "follow_future": True,
            "selection_mode": "rules",
            "library_id": library["id"],
            "rule_set_id": default["id"],
        },
    )["subscription"]["id"]
    path = f"/subscriptions/{sub_id}"

    def detail():
        return api("get", path)

    def english(locator):
        text = locator.inner_text()
        for raw in ("测试剧集", "我的剧集", "我的规则组"):
            text = text.replace(raw, "")
        assert not re.search(r"[\u3400-\u9fff]", text), text

    def action(label, *, menu_label=None):
        page.get_by_role("button", name="More", exact=True).click()
        item = page.get_by_role("menuitem", name=menu_label or label, exact=True)
        if item.count():
            item.click()
        else:
            page.get_by_role("dialog", name="Manage subscription", exact=True).get_by_role(
                "button", name=label, exact=True
            ).click()

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + path)
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")
        expect(page.get_by_role("heading", name=re.compile("^测试剧集 2024$"))).to_be_visible()
        expect(page.get_by_text("Collection progress", exact=True)).to_be_visible()
        expect(page.get_by_text("Default rule set", exact=True)).to_be_visible()
        english(page.locator("body"))
        manual = page.get_by_role("link", name="Choose torrent", exact=True)
        expect(manual).to_have_attribute("href", re.compile(f"for_sub={sub_id}"))
        assert "Test+Show" in manual.get_attribute("href") or "Test%20Show" in manual.get_attribute(
            "href"
        )
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-overview-en.png")

        action("Pause tracking")
        confirmation = page.get_by_role("dialog", name="Pause tracking “测试剧集”?", exact=True)
        english(confirmation)
        confirmation.get_by_role("button", name="Pause tracking", exact=True).click()
        _wait_for(
            lambda: detail()["status"] == "paused", timeout=10, what="subscription state to persist"
        )
        expect(page.get_by_role("button", name="Search now", exact=True)).not_to_be_visible()
        action("Resume tracking")
        confirmation = page.get_by_role("dialog", name="Resume tracking “测试剧集”?", exact=True)
        confirmation.get_by_role("button", name="Resume tracking", exact=True).click()
        _wait_for(
            lambda: detail()["status"] == "active", timeout=10, what="subscription state to persist"
        )
        expect(page.get_by_role("button", name="Search now", exact=True)).to_be_visible()
        action("Stop following future releases")
        _wait_for(
            lambda: detail()["follow_future"] is False,
            timeout=10,
            what="subscription state to persist",
        )
        action("Follow future releases")
        _wait_for(
            lambda: detail()["follow_future"] is True,
            timeout=10,
            what="subscription state to persist",
        )

        for rule in (custom, default):
            action("Change rule set", menu_label="Change rule set…")
            dialog = page.get_by_role("dialog", name="Change rule set", exact=True)
            english(dialog)
            dialog.get_by_role(
                "button", name=re.compile("^我的规则组" if rule == custom else "^Default rule set")
            ).click()
            expect(dialog).not_to_be_visible()
            _wait_for(
                lambda rule_id=rule["id"]: detail()["rule_set_id"] == rule_id,
                timeout=10,
                what="subscription state to persist",
            )

        action("Adjust episode counts", menu_label="Adjust episode counts…")
        dialog = page.get_by_role("dialog", name="Adjust episode counts", exact=True)
        english(dialog)
        count = dialog.get_by_role("spinbutton", name="Episode count for season 1", exact=True)
        count.fill("2001")
        expect(dialog.get_by_role("button", name="Save", exact=True)).to_be_disabled()
        count.fill("5")
        expect(dialog.get_by_role("button", name="Save", exact=True)).to_be_enabled()
        _snapshot(page, shots / f"{theme_id}-{width}-episodes-en.png")
        dialog.get_by_role("button", name="Save", exact=True).click()
        expect(dialog).not_to_be_visible()
        _wait_for(
            lambda: len(detail()["wanted"]) == 5, timeout=10, what="subscription state to persist"
        )
        assert detail()["episode_seasons"][0]["floor"] == 5
        episode = page.get_by_role("button", name=re.compile("^E04 "))
        episode.click()
        expect(
            page.get_by_text(
                "This episode is not listed on TMDB. Tracking uses the configured episode count.",
                exact=True,
            )
        ).to_be_visible()
        english(page.locator("body"))
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-milestones-en.png")
        action("Adjust episode counts", menu_label="Adjust episode counts…")
        dialog = page.get_by_role("dialog", name="Adjust episode counts", exact=True)
        dialog.get_by_role("spinbutton", name="Episode count for season 1", exact=True).fill("3")
        dialog.get_by_role("button", name="Save", exact=True).click()
        expect(dialog).not_to_be_visible()
        _wait_for(
            lambda: len(detail()["wanted"]) == 3, timeout=10, what="subscription state to persist"
        )
        assert detail()["episode_seasons"][0]["floor"] is None

        source = "site" if theme_id == "silver" else "douban"
        _run(_set_episode_evidence(stack["database_url"], sub_id, source, 6))
        page.reload()
        expect(
            page.get_by_text("Season 1 may still have missing episodes", exact=True)
        ).to_be_visible()
        evidence = (
            "Episode 6 is available on a site, while TMDB lists only 3 episodes"
            if source == "site"
            else "Douban lists 6 episodes, while TMDB lists only 3 episodes"
        )
        expect(page.get_by_text(evidence, exact=True)).to_be_visible()
        english(page.locator("body"))
        hint = page.locator("section").filter(has=page.get_by_text(evidence, exact=True))
        bounds = hint.bounding_box()
        for button in hint.get_by_role("button").all():
            box = button.bounding_box()
            assert (
                box["x"] >= bounds["x"] and box["x"] + box["width"] <= bounds["x"] + bounds["width"]
            )
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-hint-en.png")
        page.get_by_role("button", name="Ignore", exact=True).click()
        _wait_for(
            lambda: not detail()["episode_hints"], timeout=10, what="episode hint to be dismissed"
        )
        assert detail()["episode_seasons"][0]["floor"] is None
        _run(_set_episode_evidence(stack["database_url"], sub_id, source, 7))
        page.reload()
        page.get_by_role("button", name="Continue with 7 episodes", exact=True).click()
        _wait_for(
            lambda: detail()["episode_seasons"][0]["floor"] == 7,
            timeout=10,
            what="suggested episode count to persist",
        )
        action("Adjust episode counts", menu_label="Adjust episode counts…")
        dialog = page.get_by_role("dialog", name="Adjust episode counts", exact=True)
        dialog.get_by_role("spinbutton", name="Episode count for season 1", exact=True).fill("3")
        dialog.get_by_role("button", name="Save", exact=True).click()
        expect(dialog).not_to_be_visible()
        page.get_by_role("button", name="Ignore", exact=True).click()
        _wait_for(
            lambda: not detail()["episode_hints"], timeout=10, what="episode hint to be dismissed"
        )

    page.set_viewport_size({"width": 1280, "height": 1000})
    page.evaluate("window.inspectorMarker = 903")
    for locale in ("zh-Hans", "en"):
        _change_language(page, locale)
        expect(
            page.get_by_text(
                "收录进度" if locale == "zh-Hans" else "Collection progress", exact=True
            )
        ).to_be_visible()
        assert page.evaluate("window.inspectorMarker") == 903
        assert detail()["follow_future"] is True
        assert detail()["rule_set_id"] == default["id"]
        assert detail()["library_id"] == library["id"]
        if locale == "zh-Hans":
            expect(page.get_by_text("第 1 季", exact=True).first).to_be_visible()
            expect(page.get_by_text("默认规则组", exact=True)).to_be_visible()
        else:
            english(page.locator("body"))
        _snapshot(page, shots / f"same-document-{locale}.png")
    assert len(api("get", "/subscriptions")) == 1
    assert not errors
    context.close()

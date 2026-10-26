"""Subscription form choices and persistence through real Next/API/SQLite, in both themes."""

from __future__ import annotations

import re

import pytest

from . import test_smart_memory_browser as lab
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_smart_settings_browser import _api, _english

stack = lab.stack
browser = lab.browser
pytestmark = pytest.mark.integration


def test_subscribe_rules_scope_smart_and_existing_title(stack, browser, tmp_path):
    from playwright.sync_api import expect

    base, _ = stack
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/subscribe"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        return _api(context, base, method, path, **kwargs)

    defaults = api("get", "/subscriptions/smart-defaults")
    api(
        "put",
        "/subscriptions/smart-defaults",
        data={
            "movie_revision": defaults["movie_revision"],
            "tv_revision": defaults["tv_revision"],
            "resolution": "1080p",
            "source": "blu-ray",
            "allow_upgrade": True,
            "strict_resolution": False,
            "movie_wait_seconds": 86400,
            "tv_wait_seconds": 10800,
        },
    )
    libraries = []
    for name in ("默认剧集库", "我的收藏库"):
        path = tmp_path / name
        path.mkdir()
        libraries.append(
            api(
                "post",
                "/libraries",
                data={
                    "name": name,
                    "kind": "tv",
                    "root_paths": [str(path)],
                },
            )
        )
    # A user-provided Chinese name stays raw; the marked seed has a translated label.
    api("get", "/rule-sets")
    custom = api(
        "post",
        "/rule-sets",
        data={
            "name": "默认规则组（自建）",
            "spec": {"resolutions": ["1080p"], "upgrade_source": "blu-ray"},
        },
    )
    assert custom["name_key"] is None

    titles = ("请回答1988", "机智的医生生活", "鱿鱼游戏", "绝命毒师")
    for index, (theme_id, width) in enumerate(
        (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320))
    ):
        identity = 801 + index
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(f"{base}/media/tv/{identity}")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")
        page.get_by_role("button", name="Track this title", exact=True).click()
        dialog = page.get_by_role("dialog", name=f"Subscribe to “{titles[index]}”", exact=True)
        expect(dialog.get_by_role("region", name="Smart selection", exact=True)).to_be_visible()
        _english(dialog, titles[index], "默认剧集库", "我的收藏库", "默认规则组（自建）")
        confirm = dialog.get_by_role("button", name="Confirm subscription", exact=True)
        expect(confirm).to_be_enabled()
        scope = dialog.get_by_role("region", name="Tracking scope", exact=True)
        scope.get_by_role("button", name=re.compile("^Tracking scope")).click()
        season = scope.get_by_role("button", name=re.compile("^Season 1"))
        expect(scope.get_by_text("All 2 episodes have aired", exact=True)).to_be_visible()
        season.click()
        expect(confirm).to_be_disabled()
        expect(
            scope.get_by_text(
                "Choose at least one season, or enable following future releases.", exact=True
            )
        ).to_be_visible()
        following = scope.get_by_role("switch", name=re.compile("^Follow future releases"))
        following.click()
        expect(confirm).to_be_enabled()
        following.click()
        expect(confirm).to_be_disabled()
        season.click()
        expect(confirm).to_be_enabled()
        options = dialog.get_by_role("region", name="More subscription options", exact=True)
        options.get_by_role("button", name=re.compile("^More options")).click()
        options.get_by_role("button", name=re.compile("^Selection mode")).click()
        page.get_by_role("menuitemradio", name="Rule mode", exact=True).click()
        expect(dialog.get_by_role("region", name="Rule selection", exact=True)).to_be_visible()
        options.get_by_role("button", name=re.compile("^Release rules")).click()
        expect(
            page.get_by_role("menuitemradio", name="Default rule set (default)", exact=True)
        ).to_be_visible()
        page.get_by_role("menuitemradio", name="默认规则组（自建）", exact=True).click()
        options.get_by_role("button", name=re.compile("^Import to")).click()
        page.get_by_role("menuitemradio", name="我的收藏库", exact=True).click()
        expect(
            dialog.get_by_role("region", name="Rule selection").get_by_text(
                "默认规则组（自建）", exact=True
            )
        ).to_be_visible()
        expect(options.get_by_text("1080p · Upgrade to 1080p Blu-ray", exact=True)).to_be_visible()
        _english(dialog, titles[index], "默认剧集库", "我的收藏库", "默认规则组（自建）")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-rules-en.png")
        confirm.click()
        expect(dialog).not_to_be_visible()
        rows = api("get", "/subscriptions")
        sub = next(row for row in rows if row["media"]["tmdb_id"] == identity)
        assert sub["selection_mode"] == "rules" and sub["rule_set_id"] == custom["id"]
        assert sub["selected_seasons"] == [1] and sub["follow_future"] is False
        assert sub["library_id"] == libraries[1]["id"]
        page.get_by_role("button", name=re.compile("^Subscribed")).click()
        expect(
            dialog.get_by_text(
                "This series is already subscribed to. movieclaw is continuing to track releases.",
                exact=True,
            )
        ).to_be_visible()
        _english(dialog, titles[index])
        _snapshot(page, shots / f"{theme_id}-{width}-existing-en.png")
        page.keyboard.press("Escape")
        expect(dialog).not_to_be_visible()

    # Language settings affect the interface, while the saved policy, season and names stay intact.
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.evaluate("window.subscribeLanguageMarker = 734")
    _change_language(page, "zh-Hans")
    page.get_by_role("button", name=re.compile("^已订阅")).click()
    chinese = page.get_by_role("dialog", name="订阅《绝命毒师》", exact=True)
    expect(
        chinese.get_by_text("该剧集已在订阅中，movieclaw 正在持续追踪资源。", exact=True)
    ).to_be_visible()
    _snapshot(page, shots / "existing-zh.png")
    page.keyboard.press("Escape")
    expect(chinese).not_to_be_visible()
    _change_language(page, "en")
    assert page.evaluate("window.subscribeLanguageMarker") == 734
    path = tmp_path / "movies"
    path.mkdir()
    api("post", "/libraries", data={"name": "我的电影", "kind": "movie", "root_paths": [str(path)]})
    page.goto(base + "/media/movie/705")
    page.get_by_role("button", name="Track this title", exact=True).click()
    dialog = page.get_by_role("dialog", name="Subscribe to “消失的她”", exact=True)
    expect(dialog.get_by_role("region", name="Smart selection")).to_be_visible()
    _english(dialog, "消失的她", "我的电影")
    dialog.get_by_role("button", name="Confirm subscription", exact=True).click()
    expect(dialog).not_to_be_visible()
    movie = next(row for row in api("get", "/subscriptions") if row["media"]["tmdb_id"] == 705)
    assert movie["selection_mode"] == "smart" and movie["smart_policy"]["resolution"] == "1080p"
    assert not errors
    context.close()

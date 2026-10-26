"""Real video → live activity → device confirmation → history → clear own records."""

import re

import pytest

from . import test_rewatch_resume_browser as player
from .test_i18n_content_browser import _change_language, _snapshot
from .test_library_manage_browser import _wait_for

stack = player.stack
pytestmark = pytest.mark.integration


def test_live_history_and_device_actions_in_both_themes(stack):
    from playwright.sync_api import expect, sync_playwright

    base, media = stack["base"], stack["media"]
    clip = media / "Watch fixture.mp4"
    player._make_movie(clip)
    original = clip.read_bytes()
    shots = player.REPO / ".tmp-uidev/i18n/watch-activity"
    shots.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            **player._chromium_kwargs(),
            args=["--autoplay-policy=no-user-gesture-required"],
        )
        control_context = browser.new_context(
            locale="en-US", viewport={"width": 1280, "height": 1000}
        )
        play_context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 720})
        page, playing = control_context.new_page(), play_context.new_page()
        for target in (page, playing):
            target.set_default_timeout(20_000)
            player._login(target, base)
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))

        def api(method, path, **kwargs):
            response = getattr(page.request, method)(base + "/api/v1" + path, **kwargs)
            assert response.ok, response.text()
            return response.json()["data"]

        library = api(
            "post",
            "/libraries",
            data={
                "name": "原始媒体库",
                "kind": "video",
                "source": "local",
                "root_paths": [str(media)],
            },
        )
        items = _wait_for(
            lambda: api("get", f"/libraries/{library['id']}/items"),
            timeout=90,
            what="watch activity real video scan",
        )
        item_id = next(item["media_item_id"] for item in items if "Watch fixture" in item["title"])

        def english(scope):
            assert not re.search(
                r"[\u3400-\u9fff]", scope.inner_text().replace("原始媒体库", "")
            ), scope.inner_text()
            assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

        for theme_id, width in (
            ("silver", 1280),
            ("silver", 320),
            ("netflix", 1280),
            ("netflix", 320),
        ):
            prefs = api("get", "/ui/preferences")
            prefs.update(
                theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en"
            )
            api("put", "/ui/preferences", data=prefs)
            for context in (control_context, play_context):
                context.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
            playing.goto(base + f"/play/{item_id}")
            player._wait_playing(playing)
            player._seek(playing, 35)
            _wait_for(
                lambda: api("get", "/playback/activity")["sessions"],
                timeout=25,
                what="live playback session",
            )
            page.set_viewport_size({"width": width, "height": 1000})
            page.goto(base + "/activity?view=playing")
            expect(
                page.get_by_role("link", name=re.compile("^Watch fixture")).first
            ).to_be_visible()
            english(page.locator("main"))
            _snapshot(page, shots / f"{theme_id}-{width}-playing-en.png")
            actions = page.get_by_role("button", name=re.compile("^Device actions for"))
            actions.first.click()
            page.get_by_role("menuitem", name="End playback", exact=True).click()
            dialog = page.get_by_role("dialog", name="End playback", exact=True)
            english(dialog)
            _snapshot(page, shots / f"{theme_id}-{width}-end-en.png")
            dialog.get_by_role("button", name="Cancel", exact=True).click()
            assert api("get", "/playback/activity")["sessions"]
            actions.first.click()
            page.get_by_role("menuitem", name="Sign out this device", exact=True).click()
            revoke = page.get_by_role("dialog", name="Sign out device", exact=True)
            english(revoke)
            revoke.get_by_role("button", name="Cancel", exact=True).click()
            assert playing.request.get(base + "/api/v1/auth/me").ok
            page.goto(base + "/activity?view=plays")
            expect(
                page.get_by_role("link", name=re.compile("^Watch fixture")).first
            ).to_be_visible()
            english(page.locator("main"))
            _snapshot(page, shots / f"{theme_id}-{width}-history-en.png")

        prefs = api("get", "/ui/preferences")
        prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": 1280, "height": 1000})
        page.goto(base + "/activity?view=plays")
        page.get_by_role("button", name="Filters", exact=True).click()
        page.get_by_role("menuitemradio", name="Super administrator", exact=True).click()
        expect(page.get_by_role("link", name=re.compile("^Watch fixture")).first).to_be_visible()
        page.get_by_role("button", name="Filters", exact=True).click()
        expect(
            page.get_by_role("menuitemradio", name="Super administrator", exact=True)
        ).to_be_checked()
        page.keyboard.press("Escape")
        page.evaluate("window.watchActivityMarker = 421")
        for language in ("zh-Hans", "en"):
            _change_language(page, language)
            expect(
                page.get_by_role("link", name=re.compile("^Watch fixture")).first
            ).to_be_visible()
            if language == "en":
                english(page.locator("main"))
            assert page.evaluate("window.watchActivityMarker") == 421
        # Actually end the isolated playback through the translated confirmation.
        page.goto(base + "/activity?view=playing")
        page.get_by_role("button", name=re.compile("^Device actions for")).first.click()
        page.get_by_role("menuitem", name="End playback", exact=True).click()
        with page.expect_response(
            lambda response: "/activity/sessions/" in response.url and response.url.endswith("/end")
        ) as ended:
            page.get_by_role("dialog", name="End playback", exact=True).get_by_role(
                "button", name="End playback", exact=True
            ).click()
        assert ended.value.ok
        _wait_for(
            lambda: not api("get", "/playback/activity")["sessions"],
            timeout=20,
            what="ended live session",
        )
        assert playing.request.get(base + "/api/v1/auth/me").ok
        assert api("get", "/playback/history")["entries"]
        _wait_for(
            lambda: api("get", "/playback/up-next")["items"],
            timeout=30,
            what="saved continue-watching progress",
        )
        page.goto(base + "/library")
        expect(page.get_by_role("heading", name="Continue watching", exact=True)).to_be_visible()
        page.get_by_role("button", name="Clear watch history", exact=True).click()
        english(page.get_by_role("menu"))
        page.get_by_role("menuitem", name="Clear today’s watch history…", exact=True).click()
        clear = page.get_by_role("dialog")
        english(clear)
        _snapshot(page, shots / "clear-today-en.png")
        clear.get_by_role("button", name="Cancel", exact=True).click()
        assert api("get", "/playback/up-next")["items"]
        page.get_by_role("button", name="Clear watch history", exact=True).click()
        page.get_by_role("menuitem", name="Clear a library’s watch history…", exact=True).click()
        clear = page.get_by_role("dialog", name="Clear a library’s watch history", exact=True)
        english(clear)
        _snapshot(page, shots / "clear-library-en.png")
        with page.expect_response(
            lambda response: (
                "/playback/history?" in response.url and response.request.method == "DELETE"
            )
        ) as cleared:
            clear.get_by_role("button", name="Clear “原始媒体库”", exact=True).click()
        assert cleared.value.ok
        assert cleared.value.json()["data"]["deleted_states"] > 0
        assert api("get", "/playback/up-next")["items"] == []
        assert clip.read_bytes() == original
        assert not errors
        browser.close()

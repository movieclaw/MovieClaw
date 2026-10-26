"""Localized player menus with real scanned video, subtitles and HTTP errors."""

from __future__ import annotations

import re
import subprocess

import pytest

from .test_library_manage_browser import _wait_for
from .test_rewatch_resume_browser import (  # noqa: F401
    REPO,
    _chromium_kwargs,
    _login,
    _wait_playing,
    stack,
)

pytestmark = pytest.mark.integration


def test_player_languages_with_real_media(request):
    stack_data = request.getfixturevalue("stack")
    from playwright.sync_api import expect, sync_playwright

    base, media = stack_data["base"], stack_data["media"]
    clip = media / "Language probe.mp4"
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=size=320x180:rate=24:duration=90", "-f", "lavfi", "-i",
            "sine=frequency=440:duration=90", "-map", "0:v", "-map", "1:a", "-map", "1:a",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=jpn",
            "-movflags", "+faststart", str(clip),
        ],
        check=True,
    )  # fmt: skip
    (media / "Language probe.en.srt").write_text(
        "1\n00:00:00,000 --> 00:01:30,000\nEnglish subtitle probe\n", encoding="utf8"
    )
    artifacts = REPO / ".tmp-uidev/i18n/player"
    artifacts.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            **_chromium_kwargs(), args=["--autoplay-policy=no-user-gesture-required"]
        )
        context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 720})
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        _login(page, base)
        response = page.request.post(
            f"{base}/api/v1/libraries",
            data={
                "name": "User library",
                "kind": "video",
                "source": "local",
                "root_paths": [str(media)],
            },
        )
        assert response.ok, response.text()
        library_id = response.json()["data"]["id"]
        items = _wait_for(
            lambda: page.request.get(f"{base}/api/v1/libraries/{library_id}/items").json()["data"],
            timeout=90,
            what="localized player media scan",
        )
        item_id = items[0]["media_item_id"]
        for locale, settings, fit, audio, subtitles, diagnostics in [
            ("en", "Settings", "Fill and crop", "Audio track", "Subtitles", "Playback diagnostics"),
            ("zh-Hans", "设置", "铺满裁切", "音轨", "字幕", "播放诊断"),
        ]:
            context.add_cookies([{"name": "mc_locale", "value": locale, "url": base}])
            page.goto(f"{base}/play/{item_id}")
            _wait_playing(page)
            activity = _wait_for(
                lambda: page.request.get(f"{base}/api/v1/playback/activity")
                .json()["data"]["sessions"],
                timeout=20,
                what="actual playback delivery classification",
            )
            delivery = activity[0]["delivery"]
            assert "execution_kind" in delivery
            assert delivery["execution_kind"] in (None, "hardware", "software", "remote")
            if delivery["mode"] != "transcode":
                assert delivery["execution_kind"] is None
            video = page.locator("video")
            video.evaluate("v => { window.localeTestVideo = v; v.pause(); }")
            source = video.get_attribute("src")
            page.get_by_role("button", name=settings, exact=True).click()
            page.get_by_role("button", name=re.compile("^" + fit)).click()
            expect(video).to_have_css("object-fit", "cover")
            assert video.evaluate("v => v === window.localeTestVideo")
            assert video.get_attribute("src") == source
            page.get_by_role("button", name=audio, exact=True).click()
            expect(
                page.get_by_role(
                    "button", name=re.compile("^" + ("English" if locale == "en" else "英语"))
                )
            ).to_be_visible()
            page.get_by_role("button", name=audio, exact=True).click()
            page.get_by_role("button", name=subtitles, exact=True).click()
            page.get_by_role("button", name="Off" if locale == "en" else "关闭", exact=True).click()
            page.get_by_role("button", name=settings, exact=True).click()
            page.get_by_role("button", name=diagnostics, exact=True).click()
            expect(page.get_by_role("heading", name=diagnostics)).to_be_visible()
            if locale == "en":
                assert not re.search(
                    r"[\u3400-\u9fff]", page.locator("media-controller").inner_text()
                )
            page.screenshot(path=str(artifacts / f"menus-{locale}.png"))
        context.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
        clip.unlink()
        page.goto(f"{base}/play/{item_id}")
        expect(page.get_by_role("button", name="Retry", exact=True)).to_be_visible(timeout=60000)
        expect(page.get_by_role("button", name="Back", exact=True)).to_be_visible()
        assert not re.search(r"[\u3400-\u9fff]", page.locator("media-controller").inner_text())
        page.screenshot(path=str(artifacts / "source-error-en.png"))
        assert not errors
        browser.close()

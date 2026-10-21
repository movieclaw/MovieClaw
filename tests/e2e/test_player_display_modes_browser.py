"""真播放器缩放回归：模式切换不换 video、不重开会话，换片恢复默认。"""

from __future__ import annotations

import subprocess

import pytest

from .test_library_manage_browser import _wait_for
from .test_rewatch_resume_browser import (  # noqa: F401
    _chromium_kwargs,
    _login,
    _wait_playing,
    stack,
)

pytestmark = pytest.mark.integration


def test_display_modes_preserve_playback_and_reset_per_file(request):
    stack_data = request.getfixturevalue("stack")
    from playwright.sync_api import expect, sync_playwright

    media, base = stack_data["media"], stack_data["base"]
    for name, size in [("wide", "640x360"), ("classic", "480x360")]:
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                f"testsrc2=size={size}:rate=24:duration=90",
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
                str(media / f"{name}.mp4"),
            ],
            check=True,
        )
        (media / f"{name}.zh.srt").write_text(
            "1\n00:00:00,000 --> 00:01:30,000\n缩放字幕回归\n", encoding="utf8"
        )
    with sync_playwright() as p:
        browser = p.chromium.launch(**_chromium_kwargs())
        page = browser.new_page(viewport={"width": 1280, "height": 589})
        _login(page, base)
        response = page.request.post(
            f"{base}/api/v1/libraries",
            data={
                "name": "缩放回归",
                "kind": "video",
                "source": "local",
                "root_paths": [str(media)],
            },
        )
        assert response.ok
        library = response.json()["data"]["id"]
        items = _wait_for(
            lambda: (
                rows
                if len(
                    rows := page.request.get(f"{base}/api/v1/libraries/{library}/items").json()[
                        "data"
                    ]
                )
                == 2
                else []
            ),
            timeout=90,
            what="缩放样片扫描",
        )
        assert len(items) == 2
        page.goto(f"{base}/play/{items[0]['media_item_id']}")
        _wait_playing(page)
        video = page.locator("video")
        video.evaluate("v => { window.displayTestVideo = v; v.pause(); }")
        source = video.get_attribute("src")
        for name in ["完整显示", "适应宽度", "铺满裁切", "拉伸铺满"]:
            button = page.get_by_role("button", name=f"画面缩放：{name}", exact=True)
            expect(button).to_be_visible()
            assert video.evaluate("v => v === window.displayTestVideo")
            assert video.get_attribute("src") == source
            button.click()
        expect(page.get_by_role("button", name="画面缩放：完整显示", exact=True)).to_be_visible()
        page.get_by_role("button", name="画面缩放：完整显示", exact=True).click()
        page.set_viewport_size({"width": 390, "height": 844})
        expect(page.get_by_role("button", name="画面缩放：适应宽度", exact=True)).to_be_visible()
        page.goto(f"{base}/play/{items[1]['media_item_id']}")
        _wait_playing(page)
        page.locator("video").evaluate("v => v.pause()")
        expect(page.get_by_role("button", name="画面缩放：完整显示", exact=True)).to_be_visible()
        browser.close()

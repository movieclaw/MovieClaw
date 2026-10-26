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
        position = video.evaluate("v => v.currentTime")
        expect(page.get_by_test_id("player-display-mode")).to_have_count(0)
        for name, fit in [("铺满裁切", "cover"), ("拉伸铺满", "fill"), ("完整显示", "contain")]:
            page.get_by_role("button", name="设置", exact=True).click()
            expect(page.get_by_role("button", name="适应宽度")).to_have_count(0)
            page.get_by_role("button", name=name).click()
            expect(video).to_have_css("object-fit", fit)
            assert video.evaluate("v => v === window.displayTestVideo")
            assert video.get_attribute("src") == source
            assert video.evaluate("v => v.currentTime") == position
        page.get_by_role("button", name="设置", exact=True).click()
        page.get_by_role("button", name="铺满裁切").click()
        page.set_viewport_size({"width": 390, "height": 844})
        expect(video).to_have_css("object-fit", "cover")
        page.goto(f"{base}/play/{items[1]['media_item_id']}")
        _wait_playing(page)
        page.locator("video").evaluate("v => v.pause()")
        expect(page.locator("video")).to_have_css("object-fit", "contain")
        browser.close()


def test_positioned_ass_stays_on_its_video_marker(request, tmp_path):
    """绿色 ASS 矢量块应始终位于视频的红框内，覆盖 worker 初始化和缩放。"""
    import io

    from PIL import Image, ImageChops
    from playwright.sync_api import sync_playwright

    stack_data = request.getfixturevalue("stack")
    media = tmp_path / "ass-media"
    media.mkdir()
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=0x303030:s=640x360:r=24:d=40",
            "-vf",
            "drawbox=x=160:y=90:w=40:h=40:color=red:t=fill",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(media / "position.mp4"),
        ],
        check=True,
    )
    (media / "position.zh.ass").write_text(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n"
        "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, Alignment\n"
        "Style: Default,Arial,24,&H0000FF00,7\n[Events]\n"
        "Format: Layer, Start, End, Style, Text\n"
        "Dialogue: 0,0:00:00.00,0:00:40.00,Default,"
        r"{\an7\pos(165,95)\p1\bord0\shad0}m 0 0 l 30 0 l 30 30 l 0 30"
        "\n",
        encoding="utf8",
    )

    def markers_align(page):
        image = Image.open(io.BytesIO(page.locator("media-controller").screenshot())).convert("RGB")
        red, green, blue = image.split()

        def low(channel):
            return channel.point(lambda value: 255 if value < 100 else 0)

        def high(channel):
            return channel.point(lambda value: 255 if value > 180 else 0)

        red_box = ImageChops.multiply(
            high(red), ImageChops.multiply(low(green), low(blue))
        ).getbbox()
        green_box = ImageChops.multiply(
            high(green), ImageChops.multiply(low(red), low(blue))
        ).getbbox()
        if not red_box or not green_box:
            return False
        return (
            red_box[0] < green_box[0] < green_box[2] < red_box[2]
            and red_box[1] < green_box[1] < green_box[3] < red_box[3]
        )

    with sync_playwright() as p:
        browser = p.chromium.launch(**_chromium_kwargs())
        page = browser.new_page(viewport={"width": 1280, "height": 589})
        base = stack_data["base"]
        _login(page, base)
        response = page.request.post(
            f"{base}/api/v1/libraries",
            data={
                "name": "ASS 定位回归",
                "kind": "video",
                "source": "local",
                "root_paths": [str(media)],
            },
        )
        assert response.ok
        library = response.json()["data"]["id"]
        items = _wait_for(
            lambda: page.request.get(f"{base}/api/v1/libraries/{library}/items").json()["data"],
            timeout=90,
            what="ASS 样片扫描",
        )
        page.goto(f"{base}/play/{items[0]['media_item_id']}")
        _wait_playing(page)
        page.locator("video").evaluate("v => v.pause()")
        for name in ["完整显示", "铺满裁切", "拉伸铺满", "完整显示"]:
            page.get_by_role("button", name="设置", exact=True).click()
            page.get_by_role("button", name=name).click()
            _wait_for(lambda: markers_align(page), timeout=30, what=f"{name} ASS 与画面对齐")
        browser.close()

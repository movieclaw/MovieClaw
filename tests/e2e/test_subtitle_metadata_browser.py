"""真实字幕元数据：ffmpeg → 扫描落库 → 详情/播放 API → 菜单/预览/轨记忆。

覆盖桌面和 320px 窄屏，含空白/缺失标题、同名轨、长标题、Unicode、HTML 字样、
未知语言、强制标记和 AI 外挂。真实生成视频，不伪造播放接口。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

from .test_library_manage_browser import _wait_for
from .test_rewatch_resume_browser import (  # noqa: F401
    _chromium_kwargs,
    _login,
    _wait_playing,
    stack,
)

pytestmark = pytest.mark.integration
LONG_TITLE = "国配简体特效 · 蓝光修订版 · " + "保留屏幕文字与歌曲翻译🎬" * 12
TITLES = [
    "English",
    "国配繁体特效",
    LONG_TITLE,
    "　 ",
    "简英特效",
    "简英特效",
    None,
    '<img src=x onerror="alert(1)"> · 日本語عربي',
]


@pytest.fixture(scope="module")
def subtitle_stack(request):
    if path := os.environ.get("MC_SUBTITLE_E2E_STACK"):
        return json.loads(Path(path).read_text())
    return request.getfixturevalue("stack")


def _make_movie(media: Path) -> None:
    args = [
        "ffmpeg",
        "-y",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=320x180:rate=24:duration=180",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=180",
    ]
    for index in range(len(TITLES)):
        cue = media / f"cue-{index}.srt"
        cue.write_text(f"1\n00:00:00,000 --> 00:03:00,000\nTRACK_{index + 1}\n", encoding="utf8")
        args.extend(["-i", str(cue)])
    args.extend(["-map", "0:v", "-map", "1:a"])
    for index in range(len(TITLES)):
        args.extend(["-map", f"{index + 2}:s"])
    args.extend(
        [
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "48",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-c:s",
            "srt",
            "-movflags",
            "+faststart",
        ]
    )
    for index, title in enumerate(TITLES):
        language = "eng" if index == 0 else "und" if index >= 6 else "chi"
        args.extend([f"-metadata:s:s:{index}", f"language={language}"])
        if title is not None:
            args.extend([f"-metadata:s:s:{index}", f"title={title}"])
        args.extend(
            [
                f"-disposition:s:{index}",
                "forced" if index == 5 else "default" if index == 0 else "0",
            ]
        )
    args.append(str(media / "某电影 (2020).mkv"))
    subprocess.run(args, check=True)  # noqa: S603
    (media / "某电影 (2020).ai-chs.srt").write_text(
        "1\n00:00:00,000 --> 00:03:00,000\nAI_EXTERNAL\n", encoding="utf8"
    )


def _api(page, base, method, path, **kwargs):
    response = getattr(page.request, method)(f"{base}/api/v1{path}", **kwargs)
    assert response.ok, response.text()
    return response.json()["data"]


def _no_overflow(locator):
    assert locator.evaluate("e => e.scrollWidth <= e.clientWidth + 1"), locator.inner_text()


def test_subtitle_metadata_from_media_to_selection(subtitle_stack):  # noqa: PLR0915
    from playwright.sync_api import expect, sync_playwright

    base = subtitle_stack["base"]
    media, shots = Path(subtitle_stack["media"]), Path(subtitle_stack["shots"])
    shots.mkdir(exist_ok=True)
    _make_movie(media)
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True, args=["--autoplay-policy=no-user-gesture-required"], **_chromium_kwargs()
        )
        context = browser.new_context(viewport={"width": 1440, "height": 900}, locale="zh-CN")
        page = context.new_page()
        page.set_default_timeout(30_000)
        page.set_default_navigation_timeout(120_000)
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        _login(page, base)
        libraries = _api(page, base, "get", "/libraries")
        library = next((library for library in libraries if library["name"] == "字幕验收"), None)
        if library is None:
            library = _api(
                page,
                base,
                "post",
                "/libraries",
                data={"name": "字幕验收", "kind": "movie", "root_paths": [str(media)]},
            )
        items = _wait_for(
            lambda: _api(page, base, "get", f"/libraries/{library['id']}/items"),
            timeout=90,
            what="扫描入库",
        )
        item = items[0]["media_item_id"]
        detail_path = f"/libraries/{library['id']}/items/{item}"
        detail = _wait_for(
            lambda: (
                view
                if len(
                    (view := _api(page, base, "get", detail_path))["files"][0]["subtitle_streams"]
                    or []
                )
                >= 9
                else None
            ),
            timeout=90,
            what="字幕探测落库",
        )
        streams = detail["files"][0]["subtitle_streams"]
        embedded = [stream for stream in streams if not stream["external"]]
        assert [stream["title"] for stream in embedded] == TITLES
        assert embedded[5]["forced"] is True
        detail_url = f"{base}/library/{library['id']}/item/{item}"
        if os.environ.get("MC_SUBTITLE_E2E_STACK"):
            Path("/tmp/mc-576-native.json").write_text(
                json.dumps({"base": base, "item": item, "library": library["id"]})
            )
        for width in (1440, 320):
            page.set_viewport_size({"width": width, "height": 900})
            page.goto(detail_url)
            page.get_by_role("button", name=re.compile(r"中文.*×5")).click()
            long_row = page.get_by_role(
                "button", name=re.compile("^预览字幕：.*" + re.escape(LONG_TITLE))
            )
            expect(long_row).to_be_visible()
            _no_overflow(long_row)
            expect(long_row).to_contain_text("内封轨 3")
            expect(
                page.get_by_role("button", name=re.compile("^预览字幕：.*内封轨 4"))
            ).to_be_visible()
            duplicate = page.get_by_role("button", name=re.compile("^预览字幕：.*简英特效"))
            expect(duplicate).to_have_count(2)
            expect(duplicate.filter(has_text="内封轨 5")).to_have_count(1)
            expect(duplicate.filter(has_text="内封轨 6")).to_have_count(1)
            expect(duplicate.filter(has_text="内封轨 6")).to_contain_text("强制")
            assert page.locator('img[src="x"]').count() == 0
            page.screenshot(path=str(shots / f"detail-{width}.png"))
            long_row.click()
            expect(page.get_by_text("TRACK_3", exact=True)).to_be_visible(timeout=60_000)
            expect(page.get_by_text(re.compile(re.escape(LONG_TITLE))).first).to_be_visible()
            page.get_by_role("button", name="关闭字幕预览").click()
            page.goto(detail_url)
            page.get_by_role("button", name=re.compile(r"^(播放|继续观看|重新播放)")).first.click()
            page.wait_for_url(re.compile(r"/play/"))
            _wait_playing(page)
            page.mouse.move(width / 2, 700)
            page.get_by_role("button", name="字幕", exact=True).click()
            row = page.get_by_role("button", name=re.compile(re.escape(LONG_TITLE)))
            expect(row).to_be_visible()
            _no_overflow(row)
            _no_overflow(row.locator("span").first)
            same_name = page.get_by_role("button", name=re.compile("^简英特效"))
            expect(same_name).to_have_count(2)
            target = page.get_by_role("button", name=re.compile("^简英特效.*内封轨 6.*强制"))
            expect(page.get_by_role("button", name=re.compile("^内封轨 4"))).to_be_visible()
            expect(
                page.get_by_role("button", name=re.compile("^内封轨 7.*未知语言"))
            ).to_be_visible()
            expect(page.get_by_role("button", name=re.compile(".*AI 生成"))).to_be_visible()
            assert page.locator('img[src="x"]').count() == 0
            page.screenshot(path=str(shots / f"player-{width}.png"))
            target.click()
            expect(page.get_by_text("TRACK_6", exact=True)).to_be_visible(timeout=60_000)
            _wait_for(
                lambda: (
                    _api(page, base, "get", "/playback/resume", params={"media_item_id": item})[
                        "subtitle_track"
                    ]
                    == "embedded:5"
                ),
                timeout=30,
                what="选轨记忆",
            )
            page.goto(detail_url)
            page.get_by_role("button", name=re.compile(r"^(播放|继续观看|重新播放)")).first.click()
            page.wait_for_url(re.compile(r"/play/"))
            _wait_playing(page)
            page.mouse.move(width / 2, 700)
            page.get_by_role("button", name="字幕", exact=True).click()
            expect(
                page.get_by_role("button", name=re.compile("^简英特效.*内封轨 6.*强制"))
            ).to_have_attribute("aria-pressed", "true")
            assert errors == [], errors
        browser.close()

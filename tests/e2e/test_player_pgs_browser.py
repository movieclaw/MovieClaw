"""#1174：手动选 PGS 不再把直放的片子顶成转码，压制进画面是显式操作。

真 API / 前端 / Chrome + 真 PGS 轨（ffmpeg 没有 PGS 编码器，字幕流由 pgs_sup 手工拼出）。
片子是黑屏，两条字幕轨各是一个位置不同的白色矩形：看画面那一块亮不亮，就知道哪条字幕真的上了屏，
不管它是播放器画的还是压制进视频的。
"""

from __future__ import annotations

import io
import re
import subprocess
import sys
import time
from pathlib import Path

import pytest

from .test_library_manage_browser import _wait_for
from .test_rewatch_resume_browser import (  # noqa: F401
    _chromium_kwargs,
    _login,
    _video_time,
    _wait_playing,
    stack,
)

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module", autouse=True)
def _no_hardware_transcode():
    """走报告者的环境（无显卡）。autouse 排在同级的 stack 之前，后端子进程带得上这个变量。"""
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_NO_HW_TRANSCODE", "1")
        yield


_WIDTH, _HEIGHT = 640, 360
_DURATION_S = 400
#: 矩形避开中央播放簇和底部控制条：控制条浮着的时候也量得准
_TRACK_CHI = {"x": 40, "y": 60, "w": 200, "h": 50}
_TRACK_ENG = {"x": 40, "y": 190, "w": 200, "h": 50}
_LIT, _DARK = 170, 60
_ENG_REF = "embedded:1"
#: libbitsub 的画布。冻结帧那块常驻 canvas 带 aria-hidden，不算
_OVERLAY_CANVAS = "canvas[noautohide]:not([aria-hidden])"


def _make_movie(path: Path, work: Path) -> None:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "playback"))
    from pgs_sup import make_sup

    subs = []
    for name, track in (("chi", _TRACK_CHI), ("eng", _TRACK_ENG)):
        sup = work / f"{name}.sup"
        # 每两秒一条，像真字幕：压制是从当前位置开新会话，ffmpeg -ss 之前的显示事件读不到，
        # 只有一条长字幕的话压制后就再也出不来了
        sup.write_bytes(
            b"".join(
                make_sup(video_w=_WIDTH, video_h=_HEIGHT, start_s=at, end_s=at + 1.8, **track)
                for at in range(0, _DURATION_S - 5, 2)
            )
        )
        subs.append(sup)
    subprocess.run(  # noqa: S603
        [
            "ffmpeg", "-v", "error", "-y",
            "-f", "lavfi", "-i", f"color=c=black:s={_WIDTH}x{_HEIGHT}:r=12:d={_DURATION_S}",
            "-f", "lavfi", "-i", f"anullsrc=r=48000:cl=stereo:d={_DURATION_S}",
            "-f", "sup", "-i", str(subs[0]),
            "-f", "sup", "-i", str(subs[1]),
            "-map", "0:v", "-map", "1:a", "-map", "2:s", "-map", "3:s",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "24", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "32k",
            "-c:s", "copy",
            "-metadata:s:s:0", "language=chi", "-metadata:s:s:1", "language=eng",
            str(path),
        ],
        check=True,
    )


def _brightness(page, track: dict) -> float:
    from PIL import Image

    box = page.evaluate(
        "() => { const r = document.querySelector('video').getBoundingClientRect();"
        " return {x: r.x, y: r.y, width: r.width, height: r.height}; }"
    )
    scale = box["width"] / _WIDTH
    x = box["x"] + (track["x"] + track["w"] / 2) * scale
    y = box["y"] + (track["y"] + track["h"] / 2) * scale
    png = page.screenshot(clip={"x": x - 8, "y": y - 8, "width": 16, "height": 16})
    gray = Image.open(io.BytesIO(png)).convert("L")
    return sum(gray.getdata()) / (gray.width * gray.height)


def _wait_shown(page, track: dict) -> None:
    _wait_for(lambda: _brightness(page, track) > _LIT, timeout=45, what=f"字幕上屏 {track}")


def _open_subtitle_menu(page):
    # next dev 把 console.error 记成左下角的徽标，正好压着字幕按钮（生产构建没有）
    page.evaluate("() => document.querySelector('nextjs-portal')?.remove()")
    page.mouse.move(600, 640)
    page.mouse.move(640, 650)
    page.get_by_role("button", name="字幕", exact=True).click()
    return page.get_by_test_id("subtitle-burn-note")


def _assert_keeps_playing(page) -> None:
    before = _video_time(page)
    deadline = time.time() + 15
    while time.time() < deadline:
        page.wait_for_timeout(300)
        if _video_time(page) > before + 0.5:
            return
    raise AssertionError(f"视频停在 {before} 秒没有走")


def _wait_sessions(page, sessions: list, more_than: int) -> dict:
    """等新的开会话请求落定。等待要走 Playwright：拦截请求的回调只在它的调用里才跑，
    ``time.sleep`` 会让请求一直挂着。"""
    deadline = time.time() + 60
    while len(sessions) <= more_than:
        assert time.time() < deadline, f"等不到新的会话：{sessions!r}"
        page.wait_for_timeout(200)
    return sessions[-1]


def _capture(store: list):
    def handler(route) -> None:
        response = route.fetch()
        store.append({"request": route.request.post_data_json, "response": response.json()["data"]})
        route.fulfill(response=response)

    return handler


def test_manual_pgs_keeps_direct_play_and_burn_is_explicit(stack, tmp_path) -> None:  # noqa: F811, PLR0915
    from playwright.sync_api import expect, sync_playwright

    base, media = stack["base"], stack["media"]
    _make_movie(media / "pgs-demo.mkv", tmp_path)

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=["--autoplay-policy=no-user-gesture-required"],
            **_chromium_kwargs(),
        )
        page = browser.new_page(viewport={"width": 1280, "height": 720}, locale="zh-CN")
        page.set_default_timeout(60_000)
        page.set_default_navigation_timeout(180_000)
        _login(page, base)
        library = page.request.post(
            f"{base}/api/v1/libraries",
            data={
                "name": "PGS 回归",
                "kind": "video",
                "source": "local",
                "root_paths": [str(media)],
            },
        )
        assert library.ok, library.text()
        library_id = library.json()["data"]["id"]

        def scanned():
            items = page.request.get(f"{base}/api/v1/libraries/{library_id}/items").json()["data"]
            return [i for i in items if i.get("media_item_id")]

        item_id = _wait_for(scanned, timeout=120, what="样片扫描")[0]["media_item_id"]

        sessions: list[dict] = []
        decides: list[dict] = []
        page.route("**/api/v1/playback/sessions", _capture(sessions))
        page.route("**/api/v1/playback/decide", _capture(decides))

        # 起播：网页申报自己画 PGS，这片直放
        page.goto(f"{base}/play/{item_id}")
        _wait_playing(page, past=1.0)
        assert sessions[-1]["request"]["capability"]["pgs_overlay"] is True
        assert sessions[-1]["response"]["decision"]["video"]["action"] == "copy"
        file_id = sessions[-1]["response"]["decision"]["file_id"]

        # 手动选 PGS：字幕上屏，视频不重开、不暂停（#1174 的主诉）
        baseline = len(sessions)
        _open_subtitle_menu(page)
        page.get_by_role("button", name=re.compile("PGS 图形")).last.click()
        _wait_shown(page, _TRACK_ENG)
        assert _brightness(page, _TRACK_CHI) < _DARK, "选的是另一条轨"
        _assert_keeps_playing(page)
        assert len(sessions) == baseline, "选 PGS 不该重开会话"
        page.screenshot(path=str(tmp_path / "overlay.png"))

        # 显式压制，软转没开：先问，不动会话；不压制就什么都不变
        note = _open_subtitle_menu(page)
        expect(note).to_contain_text("画中画")
        page.wait_for_timeout(400)  # 等菜单淡入完，截图才看得清
        page.screenshot(path=str(tmp_path / "menu-overlay.png"))
        note.get_by_role("button", name="压制进画面").click()
        dialog = page.get_by_role("dialog")
        expect(dialog).to_contain_text("把字幕压制进画面")
        page.screenshot(path=str(tmp_path / "burn-prompt.png"))
        assert decides[-1]["request"]["burn_requested"] is True
        assert decides[-1]["request"]["subtitle_track"] == _ENG_REF
        assert decides[-1]["response"]["outcome"] == "consent"
        assert len(sessions) == baseline
        dialog.get_by_role("button", name="不压制").click()
        expect(dialog).to_have_count(0)
        _assert_keeps_playing(page)
        assert len(sessions) == baseline

        # 确认压制：真 ffmpeg 软转烧录，字幕还在，已经不是播放器画的了
        _open_subtitle_menu(page).get_by_role("button", name="压制进画面").click()
        page.get_by_role("dialog").get_by_role("button", name="开启并压制").click()
        burned = _wait_sessions(page, sessions, baseline)
        assert burned["request"]["burn_requested"] is True
        assert burned["request"]["file_id"] == file_id, "压制要锁定正在放的版本"
        assert burned["response"]["decision"]["video"]["burn_subtitle"] == _ENG_REF
        assert burned["response"]["decision"]["video"]["action"] == "transcode"
        _wait_playing(page, past=1.0)
        expect(page.locator(_OVERLAY_CANVAS)).to_have_count(0)
        _wait_shown(page, _TRACK_ENG)
        page.screenshot(path=str(tmp_path / "burned.png"))

        # 取消压制：回到直放，播放器重新画
        note = _open_subtitle_menu(page)
        expect(note).to_contain_text("已压制进画面")
        page.wait_for_timeout(400)
        page.screenshot(path=str(tmp_path / "menu-burned.png"))
        count = len(sessions)
        note.get_by_role("button", name="取消压制").click()
        restored = _wait_sessions(page, sessions, count)
        assert "burn_requested" not in restored["request"]
        assert restored["response"]["decision"]["video"]["action"] == "copy"
        assert restored["response"]["decision"]["video"]["burn_subtitle"] is None
        _wait_playing(page, past=1.0)
        _wait_shown(page, _TRACK_ENG)
        assert page.locator(_OVERLAY_CANVAS).count() >= 1

        # 重新打开：记住了这条字幕，但不能因此整片转码（只改前端就会踩的坑）
        count = len(sessions)
        page.reload()
        reopened = _wait_sessions(page, sessions, count)
        _wait_playing(page, past=1.0)
        assert "subtitle_track" not in reopened["request"]
        assert "burn_requested" not in reopened["request"]
        assert reopened["response"]["watch"]["subtitle_track"] == _ENG_REF
        assert reopened["response"]["decision"]["video"]["action"] == "copy"
        _wait_shown(page, _TRACK_ENG)

        # 软转开关开着也要问：全局开关同意的不是这一次的代价
        count = len(sessions)
        _open_subtitle_menu(page).get_by_role("button", name="压制进画面").click()
        dialog = page.get_by_role("dialog")
        expect(dialog.get_by_role("button", name="继续压制")).to_be_visible()
        assert decides[-1]["response"]["outcome"] == "plan"
        assert decides[-1]["response"]["tier"] == 4
        dialog.get_by_role("button", name="不压制").click()
        assert len(sessions) == count

        # 压制不了（HDR 片只有 VAAPI / QSV，服务端撤掉了烧录）：告诉用户，正在放的片不受影响
        def no_burn(route) -> None:
            response = route.fetch()
            payload = response.json()
            video = payload["data"]["video"] or {}
            payload["data"].update(tier=1, video={**video, "action": "copy", "burn_subtitle": None})
            route.fulfill(response=response, json=payload)

        page.unroute("**/api/v1/playback/decide")
        page.route("**/api/v1/playback/decide", no_burn)
        _open_subtitle_menu(page).get_by_role("button", name="压制进画面").click()
        expect(page.get_by_text("这台服务器压制不了这条字幕")).to_be_visible()
        _assert_keeps_playing(page)
        assert len(sessions) == count
        page.unroute("**/api/v1/playback/decide")

        # 字幕还没抽好：有提示，视频不等它
        held = []
        page.route(re.compile(r"/playback/files/\d+/subtitles\?"), lambda route: held.append(route))
        page.reload()
        _wait_playing(page, past=1.0)
        preparing = page.get_by_test_id("subtitle-preparing")
        expect(preparing).to_be_visible()
        _assert_keeps_playing(page)
        page.screenshot(path=str(tmp_path / "preparing.png"))
        page.unroute(re.compile(r"/playback/files/\d+/subtitles\?"))
        for route in held:
            route.continue_()
        expect(preparing).to_have_count(0)
        _wait_shown(page, _TRACK_ENG)

        # 加载失败：明说，并指出路
        page.route(
            re.compile(r"/playback/files/\d+/subtitles\?"),
            lambda route: route.fulfill(status=404, json={"message": "not found"}),
        )
        page.reload()
        _wait_playing(page, past=1.0)
        expect(page.get_by_text("图形字幕加载失败")).to_be_visible()
        expect(page.get_by_test_id("subtitle-preparing")).to_have_count(0)
        _assert_keeps_playing(page)

        # 那条出路走得通；这次试算改成硬件档：有硬件就不弹窗，直接开始
        def hardware(route) -> None:
            response = route.fetch()
            payload = response.json()
            payload["data"]["tier"] = 3
            route.fulfill(response=response, json=payload)

        page.route("**/api/v1/playback/decide", hardware)
        count = len(sessions)
        _open_subtitle_menu(page).get_by_role("button", name="压制进画面").click()
        burned = _wait_sessions(page, sessions, count)
        assert page.get_by_role("dialog").count() == 0
        assert burned["response"]["decision"]["video"]["burn_subtitle"] == _ENG_REF
        _wait_playing(page, past=1.0)
        _wait_shown(page, _TRACK_ENG)
        browser.close()

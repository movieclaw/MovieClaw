"""手机网页片段页（/reels）收尾两处的浏览器验收：自带后端、片库与前端，不依赖外部服务。

片库是一个「其他」库里两段生成的测试视频（不走 TMDB），信息流只有两条、没有下一页：
1. 滑到最后的「没有更多了」那页：上一条的视频框（黑底）不能留着盖住这句话；
2. 从片段点「看全片」离开：最后一条的「离开」事件（带看了多久）要报给服务端。
"""

from __future__ import annotations

import io
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from .test_library_manage_browser import (
    REPO,
    WEB,
    _chromium_kwargs,
    _free_port,
    _wait_for,
    _wait_http,
)
from .test_other_library_browser import _gen_clip

pw = pytest.importorskip("playwright.sync_api")
pytestmark = pytest.mark.integration

ADMIN = {"username": "reels-admin", "password": "isolated-test-only"}
PHONE = {
    "viewport": {"width": 393, "height": 852},
    "device_scale_factor": 2,
    "is_mobile": True,
    "has_touch": True,
}


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("reels-phone-end")
    home = root / "media" / "home"
    # 片段挑 30～60 秒的一段：每段给两分半
    for name in ("春节团圆饭", "海边日落"):
        _gen_clip(home / f"{name}.mp4", 150)
    tmdb_log = root / "tmdb-requests.log"
    tmdb_log.touch()
    api_port, web_port = _free_port(), _free_port()
    data = root / "data"
    data.mkdir()
    env = {
        **os.environ,
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(api_port),
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'app.db'}",
        "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "MOVIECLAW_DATA_DIR": str(data),
        "SCHEDULER_ENABLED": "false",
        "E2E_TMDB_LOG": str(tmdb_log),
        "PYTHONPATH": os.pathsep.join([str(REPO / "src"), os.environ.get("PYTHONPATH", "")]),
    }
    api_log = (root / "api.log").open("w")
    api = subprocess.Popen(  # noqa: S603
        [sys.executable, str(Path(__file__).with_name("_api_launcher.py"))],
        env=env,
        stdout=api_log,
        stderr=subprocess.STDOUT,
        cwd=str(REPO),
    )
    web_log = (root / "web.log").open("w")
    web = subprocess.Popen(  # noqa: S603
        ["pnpm", "dev", "-p", str(web_port)],
        env={
            **os.environ,
            "NEXT_DIST_DIR": ".next-e2e-reels-end",
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
        cwd=str(WEB),
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 90)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 240)
        yield {"base": f"http://127.0.0.1:{web_port}", "home": home, "shots": root / "shots"}
    finally:
        for proc in (web, api):
            proc.terminate()
        for proc in (web, api):
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        api_log.close()
        web_log.close()


@pytest.fixture(scope="module")
def browser():
    with pw.sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True, **_chromium_kwargs())
        yield browser
        browser.close()


@pytest.fixture(scope="module")
def library(stack, browser):
    """建库（建好就开始扫描），等片段信息流里两条都挑好片段（第一次要现算）。"""
    context = browser.new_context()
    base = stack["base"]
    assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN).ok
    created = context.request.post(
        f"{base}/api/v1/libraries",
        data={"name": "家庭录像", "kind": "video", "root_paths": [str(stack["home"])]},
    )
    assert created.ok, created.text()

    def feed_ready():
        page = context.request.get(f"{base}/api/v1/reels?modes=seek,clip&limit=8").json()["data"]
        return page if len(page["items"]) == 2 and not page["has_more"] else None

    _wait_for(feed_ready, timeout=180, what="片段信息流挑好两条")
    context.close()


def _phone(browser, stack):
    context = browser.new_context(**PHONE)
    response = context.request.post(
        f"{stack['base']}/api/v1/auth/login", data={**ADMIN, "remember": False}
    )
    assert response.ok and response.json()["success"]
    return context


def _first_reel_playing(page):
    page.get_by_test_id("reels-page").first.wait_for(timeout=90000)
    pw.expect(page.get_by_test_id("reels-video")).to_have_attribute(
        "data-status", "playing", timeout=60000
    )


def _bright_pixels(png: bytes) -> int:
    from PIL import Image

    image = Image.open(io.BytesIO(png)).convert("L")
    return sum(1 for value in image.getdata() if value > 60)


def test_last_page_message_is_not_covered_by_the_video(stack, library, browser):
    context = _phone(browser, stack)
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(f"{stack['base']}/reels")
    _first_reel_playing(page)

    # 一口气滑到最后的「没有更多了」（只有两条，没有下一页）
    end = page.get_by_text("没有更多了", exact=True)
    end.wait_for(state="attached", timeout=30000)
    page.get_by_test_id("reels-pager").evaluate("el => el.scrollTo({ top: el.scrollHeight })")
    page.wait_for_timeout(1200)  # 停稳（140 ms）+ 视频框淡出（200 ms）
    stack["shots"].mkdir(parents=True, exist_ok=True)
    page.screenshot(path=str(stack["shots"] / "reels-end-page.png"))

    box = end.bounding_box()
    assert box is not None
    band = page.get_by_test_id("reels-video").evaluate(
        "el => { const frame = el.parentElement; const r = frame.getBoundingClientRect();"
        " const opacity = getComputedStyle(frame).opacity;"
        " return { top: r.top, bottom: r.bottom, opacity }; }"
    )
    overlaps = band["top"] < box["y"] + box["height"] and box["y"] < band["bottom"]
    assert not (overlaps and float(band["opacity"]) > 0), f"视频框盖在「没有更多了」上：{band}"
    # 画面上真能看到这句话（灰字在黑底上），不是一块黑
    assert _bright_pixels(page.screenshot(clip=box)) > 20
    assert not errors
    context.close()


def test_leaving_from_watch_full_reports_the_last_leave(stack, library, browser):
    context = _phone(browser, stack)
    page = context.new_page()
    reported: list[dict] = []

    def capture(request):
        if request.method == "POST" and request.url.endswith("/api/v1/reels/events"):
            reported.extend(request.post_data_json["events"])

    page.on("request", capture)
    page.goto(f"{stack['base']}/reels")
    _first_reel_playing(page)
    page.wait_for_timeout(1500)  # 看一会儿再走

    active = page.locator("[data-testid=reels-page][data-active]")
    active.get_by_test_id("reels-watch-full").click()
    page.wait_for_url("**/play/**", timeout=30000)

    # 开发模式的 StrictMode 会先装卸一次，留下一条几十毫秒的「离开」；要的是看了一会儿才走的那条
    def watched_leave():
        return next((e for e in reported if e["kind"] == "leave" and e["watched_ms"] >= 1000), None)

    deadline = time.time() + 10
    while time.time() < deadline and watched_leave() is None:
        page.wait_for_timeout(200)
    kinds = [(e["kind"], e.get("watched_ms")) for e in reported]
    assert any(kind == "impression" for kind, _ in kinds), kinds
    assert watched_leave() is not None, f"离开片段页时没报这一条的「离开」：{kinds}"
    context.close()

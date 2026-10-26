"""真实浏览器 → hls.js → NAS → Windows 转码器（NVENC）：转出来的分片真能在 Chrome 里播、能拖。

ffmpeg 解 HLS 很宽容，MSE 不是——分片的时间戳衔接、init 与首片段的配合、seek 重启后的接续出了问题，
只有真浏览器的播放器会卡住或报错。这里起一个与接口同源的最小播放页（hls.js，网页播放器同一个库），
用系统 Chrome 点播：开始播放、时间走动、拖到没转到的位置继续播、全程没有致命错误。

需要 NVIDIA 显卡与 jellyfin-ffmpeg、Playwright 和 Chrome（``E2E_CHROMIUM`` 指到 chrome.exe；
Playwright 自带的 Chromium 放不了 H.264）、``pnpm install`` 过（hls.js 取自 apps/web）。
缺哪样跳过哪样。
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from urllib.parse import quote

import pytest
from windows_transcoder_stack import (
    ROOT,
    diagnostics,
    end_session,
    make_source,
    require_nvenc_worker,
    running_stack,
    seed,
    start_session,
)

pw = pytest.importorskip("playwright.sync_api")
pytestmark = [pytest.mark.integration]

HLS_JS = ROOT / "apps" / "web" / "node_modules" / "hls.js" / "dist" / "hls.min.js"
CHROME_CANDIDATES = [
    os.environ.get("E2E_CHROMIUM"),
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    "/usr/bin/google-chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
]

PLAYER_PAGE = """<!doctype html>
<meta charset="utf-8"><title>bench</title>
<video id="v" muted playsinline width="640"></video>
<script src="hls.min.js"></script>
<script>
  const src = new URLSearchParams(location.search).get("src");
  const state = (window.__state = { errors: [], warnings: 0, playing: false });
  const video = document.getElementById("v");
  const hls = new Hls();
  hls.on(Hls.Events.ERROR, (_event, data) => {
    if (data.fatal) state.errors.push(data.type + ":" + data.details);
    else state.warnings += 1;
  });
  hls.loadSource(src);
  hls.attachMedia(video);
  video.addEventListener("playing", () => (state.playing = true));
  video.play().catch((error) => state.errors.push("play:" + error.name));
</script>
"""


def _chrome() -> str:
    for candidate in CHROME_CANDIDATES:
        if candidate and Path(candidate).exists():
            return candidate
    pytest.skip(
        "需要系统 Chrome（E2E_CHROMIUM 指到 chrome.exe）：Playwright 自带的 Chromium 放不了 H.264"
    )
    raise AssertionError("unreachable")


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    ffmpeg, _caps = require_nvenc_worker()
    if not HLS_JS.exists():
        pytest.skip("找不到 hls.js：先在仓库根目录 pnpm install")
    chrome = _chrome()
    tmp = tmp_path_factory.mktemp("windows-transcoder-browser")
    bench = tmp / "bench"
    bench.mkdir()
    (bench / "player.html").write_text(PLAYER_PAGE, encoding="utf-8")
    shutil.copy(HLS_JS, bench / "hls.min.js")
    stack_dir = tmp / "stack"
    stack_dir.mkdir()
    with running_stack(stack_dir, ffmpeg, bench_dir=bench) as running:
        running["chrome"] = chrome
        yield running


def test_chrome_plays_the_transcoded_stream_and_follows_a_seek(stack):
    """HEVC 1080p，客户端只会 H.264：NAS 交给 Windows 转码器，Chrome 里点播、拖到 40 秒也能播。"""
    source = make_source(stack, "browser.mkv", seconds=60)
    data = start_session(stack, seed(stack, source))
    try:
        assert diagnostics(stack, data)["backend"] == "nvenc"
        page_url = f"{stack['url']}/__bench/player.html?src={quote(data['stream_url'], safe='')}"
        with pw.sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path=stack["chrome"],
                headless=True,
                args=["--autoplay-policy=no-user-gesture-required"],
            )
            try:
                page = browser.new_page()
                page.goto(page_url)
                page.wait_for_function("window.__state.playing", timeout=60_000)
                page.wait_for_function(
                    "document.getElementById('v').currentTime > 3", timeout=30_000
                )
                size = page.evaluate(
                    "({w: document.getElementById('v').videoWidth,"
                    " h: document.getElementById('v').videoHeight})"
                )
                assert size == {"w": 1920, "h": 1080}, size

                # 拖到还没转到的位置：旧一轮被叫停、从目标分片起重开一轮，播放器接着播
                page.evaluate("document.getElementById('v').currentTime = 40")
                page.wait_for_function(
                    "document.getElementById('v').currentTime > 43"
                    " && document.getElementById('v').readyState >= 3",
                    timeout=60_000,
                )
                state = page.evaluate("window.__state")
                assert state["errors"] == [], state
            finally:
                browser.close()
    finally:
        end_session(stack, data)

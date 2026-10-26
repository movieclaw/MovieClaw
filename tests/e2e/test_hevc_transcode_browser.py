"""#1008：网页播放器拿到硬件转码的 HEVC 输出，真浏览器里真放起来；浏览器嘴上说能解 HEVC、
实际解不了时，自己改要 H.264（仍是硬件转码），不落到软件转码。

真后端 + 真前端 + Chrome + 真 ffmpeg。替身只有两处：硬件自检结论（``_hevc_api_launcher``）
和 PATH 里包的 ffmpeg——把 VAAPI 命令换成软件编码（hevc_vaapi → libx265、h264_vaapi →
libx264），所以浏览器拿到的是真 HEVC / H.264 分片。

标 integration：要 ffmpeg（含 libx264 / libx265）、pnpm（apps/web 已 install）与能硬解 HEVC
的 Chrome（Apple 芯片的 Mac 上的系统 Chrome 即可）。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from tests.api.test_offline_download import _FAKE_VAAPI_FFMPEG
from tests.e2e.test_hw_transcode_startup_failure_browser import _gen_mpeg2_clip
from tests.e2e.test_media_share_browser import (
    ADMIN,
    REPO,
    WEB,
    _chromium_kwargs,
    _free_port,
    _play_current_video,
    _wait_for,
    _wait_http,
)

playwright = pytest.importorskip("playwright.sync_api")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要系统 ffmpeg"),
    pytest.mark.skipif(shutil.which("pnpm") is None, reason="需要 pnpm 启动前端 dev server"),
    pytest.mark.skipif(
        not (WEB / "node_modules").is_dir(), reason="apps/web 未安装依赖（pnpm install）"
    ),
]

#: 浏览器嘴上说能解 HEVC、真喂进去不行：探测一律报支持，建 HEVC 的 SourceBuffer 时却抛「不支持」
#: ——hls.js 报 bufferAddCodecError，与真机上「探测说能解、实际解不了」的现场同一个错误
_CLAIM_HEVC = """
(() => {
  const mc = navigator.mediaCapabilities;
  const real = mc.decodingInfo.bind(mc);
  mc.decodingInfo = (config) => {
    const type = (config.video && config.video.contentType) || "";
    if (type.includes("hvc1")) {
      return Promise.resolve({ supported: true, smooth: true, powerEfficient: true });
    }
    return real(config);
  };
  for (const ctor of [window.MediaSource, window.ManagedMediaSource]) {
    if (!ctor) continue;
    const add = ctor.prototype.addSourceBuffer;
    ctor.prototype.addSourceBuffer = function (mime) {
      if (/hvc1|hev1/.test(mime)) {
        throw new DOMException("e2e: HEVC 解不了", "NotSupportedError");
      }
      return add.call(this, mime);
    };
  }
})();
"""


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("hevc-transcode-e2e")
    movie_root = root / "media" / "movies"
    _gen_mpeg2_clip(movie_root / "某电影 (2020)" / "某电影.2020.720p.mkv", 40)
    real_ffmpeg = shutil.which("ffmpeg")
    assert real_ffmpeg
    fake_bin = root / "bin"
    fake_bin.mkdir()
    script = fake_bin / "ffmpeg"
    script.write_text(_FAKE_VAAPI_FFMPEG.format(python=sys.executable, real=real_ffmpeg))
    script.chmod(0o755)
    ffmpeg_log = root / "ffmpeg.log"
    ffmpeg_log.touch()
    tmdb_log = root / "tmdb-requests.log"
    tmdb_log.touch()

    api_port, web_port = _free_port(), _free_port()
    data = root / "data"
    data.mkdir()
    env = {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
        "PYTHONPATH": f"{REPO / 'src'}{os.pathsep}{os.environ.get('PYTHONPATH', '')}",
        "FAKE_FFMPEG_LOG": str(ffmpeg_log),
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(api_port),
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'app.db'}",
        "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "E2E_TMDB_LOG": str(tmdb_log),
    }
    api_log_path = root / "api.log"
    api_log = api_log_path.open("w")
    api = subprocess.Popen(  # noqa: S603
        [sys.executable, str(Path(__file__).with_name("_hevc_api_launcher.py"))],
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
            "NEXT_DIST_DIR": ".next-e2e",
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
        cwd=str(WEB),
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 90)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 180)
        yield {
            "base": f"http://127.0.0.1:{web_port}",
            "movie_root": movie_root,
            "shots": root / "shots",
            "api_log": api_log_path,
            "ffmpeg_log": ffmpeg_log,
        }
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


def _open_movie(p, stack, *, launch_args: list[str], init_script: str | None):
    base = stack["base"]
    browser = p.chromium.launch(headless=True, args=launch_args, **_chromium_kwargs())
    context = browser.new_context(viewport={"width": 1280, "height": 800}, locale="zh-CN")
    if init_script:
        context.add_init_script(init_script)
    page = context.new_page()
    api = context.request
    api.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)  # 第二个用例时已建过，忽略结果
    login = api.post(f"{base}/api/v1/auth/login", data=ADMIN)
    assert login.ok, login.text()
    libraries = api.get(f"{base}/api/v1/libraries").json()["data"]
    if isinstance(libraries, dict):
        libraries = libraries.get("items", [])
    library_id = next((lib["id"] for lib in libraries if lib["name"] == "电影"), None)
    if library_id is None:
        created = api.post(
            f"{base}/api/v1/libraries",
            data={"name": "电影", "kind": "movie", "root_paths": [str(stack["movie_root"])]},
        )
        assert created.ok, created.text()
        library_id = created.json()["data"]["id"]

    def scanned():
        rows = api.get(f"{base}/api/v1/libraries/{library_id}/items").json()["data"]
        if isinstance(rows, dict):
            rows = rows.get("items", [])
        return next((row for row in rows if row["title"] == "某电影"), None)

    movie = _wait_for(scanned, timeout=180, what="电影扫描入库")
    # 请求在发出时就记下申报了什么，决策（档位、编码）放完之后从响应里补
    sessions: list[dict] = []

    def on_request(request):
        if request.method == "POST" and request.url.endswith("/api/v1/playback/sessions"):
            body = request.post_data_json
            sessions.append(
                {
                    "hevc_transcode": body["capability"].get("hevc_transcode"),
                    "failed_tiers": body.get("failed_tiers"),
                    "request": request,
                }
            )

    page.on("request", on_request)
    page.goto(f"{base}/play/{movie['media_item_id']}")
    return browser, page, sessions


def _wait_in_page(page, fn, *, timeout_s: float, what: str) -> None:
    """同步版 Playwright 只在调用它的接口时派发事件：轮询要用 page.wait_for_timeout 让出，
    用 time.sleep 等的话请求事件一直积压、永远等不到。"""
    for _ in range(int(timeout_s * 2)):
        if fn():
            return
        page.wait_for_timeout(500)
    raise AssertionError(f"等待超时：{what}")


def _decisions(sessions: list[dict]) -> list[dict]:
    """补上每个开会话请求的决策（档位与编码）。"""
    for entry in sessions:
        response = entry.pop("request").response()
        assert response is not None and response.ok
        decision = response.json()["data"]["decision"]
        entry["tier"] = decision["tier"]
        entry["codec"] = (decision.get("video") or {}).get("codec")
    return sessions


def _video_size(page) -> tuple[int, int]:
    return page.evaluate(
        "() => { const v = document.querySelector('video'); return [v.videoWidth, v.videoHeight]; }"
    )


def test_browser_plays_the_hevc_transcode(stack):
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser, page, sessions = _open_movie(p, stack, launch_args=[], init_script=None)
        _wait_in_page(page, lambda: sessions, timeout_s=60, what="开播放会话")
        _play_current_video(page)
        assert _video_size(page)[1] == 720
        stack["shots"].mkdir(exist_ok=True)
        page.screenshot(path=str(stack["shots"] / "hevc-transcode-playing.png"))
        decided = _decisions(sessions)
        browser.close()
    if decided[0]["codec"] != "hevc":
        pytest.skip(f"这个 Chrome 探测不到 HEVC 解码，拿到的是 {decided[0]}")
    assert decided == [{"hevc_transcode": True, "failed_tiers": [], "tier": 3, "codec": "hevc"}]
    assert "-c:v hevc_vaapi" in stack["ffmpeg_log"].read_text()


def test_browser_that_cannot_decode_hevc_falls_back_to_hardware_h264(stack):
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser, page, sessions = _open_movie(
            p,
            stack,
            launch_args=[],
            init_script=_CLAIM_HEVC,
        )
        _wait_in_page(page, lambda: len(sessions) >= 2, timeout_s=60, what="HEVC 放不了之后重开")
        _play_current_video(page)
        assert _video_size(page)[1] == 720
        stack["shots"].mkdir(exist_ok=True)
        page.screenshot(path=str(stack["shots"] / "hevc-refused-h264-playing.png"))
        decided = _decisions(sessions)
        browser.close()
    first, second = decided[0], decided[-1]
    assert (first["tier"], first["codec"], first["hevc_transcode"]) == (3, "hevc", True), decided
    # 改要 H.264：仍是硬件转码，没有把档 3 记成失败（否则会落到软件转码或同意弹窗）
    assert (second["tier"], second["codec"], second["hevc_transcode"]) == (3, "h264", False)
    assert 3 not in (second["failed_tiers"] or []), decided
    assert len(decided) == 2, decided

"""慢转码不能触发带宽重开，也不能污染同一播放器下一会话的 downlink_bps。

复用真 API / 前端 / Chrome，HLS 供片端用可控的 HTTP fixture：init 立即返回，
媒体分片模拟软件转码等待 20 秒（带半成品标记）。不依赖机器实际转码性能。
"""

from __future__ import annotations

import re
import subprocess
import threading
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import pytest

from .test_library_manage_browser import _wait_for
from .test_rewatch_resume_browser import (  # noqa: F401
    _chromium_kwargs,
    _login,
    stack,
)

pytestmark = pytest.mark.integration


def test_slow_transcode_does_not_poison_later_session(request, tmp_path):
    stack_data = request.getfixturevalue("stack")
    from playwright.sync_api import sync_playwright

    media, base = stack_data["media"], stack_data["base"]
    clip = media / "bandwidth.mp4"
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=24:duration=30",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "144",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(clip),
        ],
        check=True,
    )
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-i",
            str(clip),
            "-c",
            "copy",
            "-hls_time",
            "6",
            "-hls_segment_type",
            "fmp4",
            "-hls_list_size",
            "0",
            "-hls_segment_filename",
            str(tmp_path / "seg%05d.m4s"),
            str(tmp_path / "index.m3u8"),
        ],
        check=True,
    )
    segment_requested = threading.Event()
    stop = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            path = tmp_path / urlsplit(self.path).path.lstrip("/")
            if path.suffix == ".m4s":
                segment_requested.set()
                stop.wait(20)
            body = path.read_bytes()
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Timing-Allow-Origin", "*")
            self.send_header("Access-Control-Expose-Headers", "X-MovieClaw-Partial-Segment")
            self.send_header(
                "Content-Type",
                "application/vnd.apple.mpegurl" if path.suffix == ".m3u8" else "video/mp4",
            )
            self.send_header("Content-Length", str(len(body)))
            if path.suffix == ".m4s":
                self.send_header("X-MovieClaw-Partial-Segment", "1")
            self.end_headers()
            # 换会话会取消旧分片请求。
            with suppress(BrokenPipeError, ConnectionResetError):
                self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                args=["--autoplay-policy=no-user-gesture-required"],
                **_chromium_kwargs(),
            )
            page = browser.new_page(viewport={"width": 1280, "height": 720})
            page.set_default_timeout(60_000)
            page.set_default_navigation_timeout(120_000)
            _login(page, base)
            library_response = page.request.post(
                f"{base}/api/v1/libraries",
                data={
                    "name": "带宽回归",
                    "kind": "video",
                    "source": "local",
                    "root_paths": [str(media)],
                },
            )
            assert library_response.ok
            library = library_response.json()["data"]["id"]
            items = _wait_for(
                lambda: page.request.get(f"{base}/api/v1/libraries/{library}/items").json()["data"],
                timeout=90,
                what="带宽样片扫描",
            )
            sessions = []

            def session_response(route):
                sessions.append(route.request.post_data_json)
                response = route.fetch()
                payload = response.json()
                session = payload["data"]
                session["decision"]["container"] = "hls-fmp4"
                session["decision"]["video"].update(action="transcode", height=2160)
                session["source"]["resolution"] = "2160p"
                session["stream_url"] = f"http://127.0.0.1:{server.server_port}/index.m3u8"
                session["master_url"] = None
                route.fulfill(response=response, json=payload)

            page.route("**/api/v1/playback/sessions", session_response)
            with page.expect_response("**/init.mp4", timeout=90_000):
                page.goto(f"{base}/play/{items[0]['media_item_id']}")
            # 必须超过 QualitySuggestion 的 8 秒长等阈值；init 的少量字节会形成极低加载速度。
            page.wait_for_timeout(11_000)
            assert segment_requested.is_set(), "播放器没有请求媒体分片"
            assert len(sessions) == 1, f"服务端等待导致自动重开：{sessions}"
            assert page.get_by_test_id("quality-offer").count() == 0
            page.mouse.move(600, 650)
            page.get_by_role("button", name="设置", exact=True).click()
            with page.expect_response("**/api/v1/playback/sessions"):
                page.get_by_role("button", name=re.compile(r"^1080p")).click()
            assert len(sessions) == 2, sessions
            assert sessions[1]["max_height"] == 1080
            assert "downlink_bps" not in sessions[1], sessions[1]
            browser.close()
    finally:
        stop.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)

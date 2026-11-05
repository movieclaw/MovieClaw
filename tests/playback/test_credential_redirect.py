"""厂商令牌头不能跟着跨源 302 走（PR #1190 评审）。

同源跳转仍带着。转发、按区间读、交给 ffmpeg 的三条路各验一次。
"""

from __future__ import annotations

import asyncio
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from movieclaw_playback.remote_range import RemoteRangeFile
from movieclaw_playback.streaming import RemoteRelayResponse, StrmLink, strm_source_input

TOKEN = "emby-secret"
BODY = b"0123456789abcdef"


class _Origin:
    def __init__(self, *, redirect_to: str | None) -> None:
        origin = self
        self.seen: list[dict[str, str | None]] = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                path = self.path.split("?", 1)[0]
                origin.seen.append(
                    {
                        "path": path,
                        "token": self.headers.get("X-Emby-Token"),
                        "ua": self.headers.get("User-Agent"),
                        "referer": self.headers.get("Referer"),
                    }
                )
                # 只跳 /start，避免 /file 再跳回自己
                if redirect_to and path == "/start":
                    self.send_response(302)
                    self.send_header("Location", redirect_to)
                    self.end_headers()
                    return
                size = len(BODY)
                header = self.headers.get("Range") or ""
                if header.startswith("bytes="):
                    start_s, _, end_s = header.removeprefix("bytes=").partition("-")
                    start = int(start_s or 0)
                    end = int(end_s) if end_s else size - 1
                    end = min(end, size - 1)
                    chunk = BODY[start : end + 1]
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                else:
                    chunk = BODY
                    self.send_response(200)
                self.send_header("Content-Length", str(len(chunk)))
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                self.wfile.write(chunk)

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.http.server_address[1]}"

    def close(self) -> None:
        self.http.shutdown()
        self.http.server_close()


def _headers() -> dict[str, str]:
    return {
        "User-Agent": "MovieClaw",
        "Referer": "https://emby.local/web",
        "X-Emby-Token": TOKEN,
    }


def test_cross_origin_redirect_strips_vendor_token_on_every_read_path():
    dest = _Origin(redirect_to=None)
    src = _Origin(redirect_to=f"{dest.base}/file")
    try:
        with RemoteRangeFile(f"{src.base}/start", headers=_headers(), min_fetch=8) as remote:
            assert remote.read(4) == BODY[:4]
            assert remote.read(4) == BODY[4:8]
        assert src.seen[0]["token"] == TOKEN
        assert dest.seen and all(item["token"] is None for item in dest.seen)
        assert all(item["ua"] == "MovieClaw" for item in dest.seen)
        assert all(item["referer"] == "https://emby.local/web" for item in dest.seen)
        # 第一跳之后直接打最终地址，不再回到原来的源
        assert len(src.seen) == 1

        async def relay() -> tuple[int, bytes]:
            response = RemoteRelayResponse(f"{src.base}/start", upstream_headers=_headers())
            body = bytearray()
            status = 0

            async def send(message: dict) -> None:
                nonlocal status
                if message["type"] == "http.response.start":
                    status = message["status"]
                elif message["type"] == "http.response.body":
                    body.extend(message.get("body") or b"")

            async def receive() -> dict:
                await asyncio.Event().wait()
                return {"type": "http.disconnect"}

            await response({"type": "http", "method": "GET"}, receive, send)
            return status, bytes(body)

        before = len(dest.seen)
        status, body = asyncio.run(relay())
        assert status == 200 and body == BODY
        assert dest.seen[before]["token"] is None
        assert src.seen[-1]["token"] == TOKEN

        url, args = strm_source_input(StrmLink(url=f"{src.base}/start", headers=_headers()))
        assert url.startswith(dest.base)
        flat = " ".join(args)
        assert "X-Emby-Token" not in flat and TOKEN not in flat
        assert "MovieClaw" in flat and "https://emby.local/web" in flat
        assert dest.seen[-1]["token"] is None
    finally:
        src.close()
        dest.close()


def test_same_origin_redirect_keeps_vendor_token():
    src = _Origin(redirect_to="/file")
    try:
        with RemoteRangeFile(f"{src.base}/start", headers=_headers(), min_fetch=8) as remote:
            assert remote.read(4) == BODY[:4]
        assert [item["path"] for item in src.seen] == ["/start", "/file"]
        assert [item["token"] for item in src.seen] == [TOKEN, TOKEN]

        url, args = strm_source_input(StrmLink(url=f"{src.base}/start", headers=_headers()))
        assert url == f"{src.base}/start"
        assert TOKEN in " ".join(args)
    finally:
        src.close()

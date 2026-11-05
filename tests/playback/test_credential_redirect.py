"""厂商令牌头不能跟着跨源 302 走（PR #1190 评审）。

同源跳转仍带着。转发、按区间读、交给 ffmpeg 的三条路各验一次。
"""

from __future__ import annotations

import asyncio
import socket
import threading
import time
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import pytest
import uvicorn
from fastapi import FastAPI

from movieclaw_api.api.routes.ffmpeg_relay import relay_url, router
from movieclaw_playback import credential_redirects
from movieclaw_playback.remote_range import RemoteRangeFile
from movieclaw_playback.streaming import RemoteRelayResponse, StrmLink, strm_source_input

TOKEN = "emby-secret"
BODY = b"0123456789abcdef"


class _Origin:
    def __init__(
        self, *, redirect_to: str | None, probe_stays: bool = False, delay: float = 0
    ) -> None:
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
                time.sleep(delay)
                # 只跳 /start，避免 /file 再跳回自己
                if (
                    redirect_to
                    and path == "/start"
                    and not (probe_stays and self.headers.get("Range") == "bytes=0-0")
                ):
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
                # 截止时间测试会主动断开连接
                with suppress(ConnectionError):
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
        assert httpx.get(url, trust_env=False).content == BODY
        flat = " ".join(args)
        assert "X-Emby-Token" not in flat and TOKEN not in flat
        assert dest.seen[-1]["ua"] == "MovieClaw"
        assert dest.seen[-1]["referer"] == "https://emby.local/web"
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
        assert TOKEN not in " ".join(args)
        assert httpx.get(url, trust_env=False).content == BODY
        assert [item["token"] for item in src.seen] == [TOKEN] * 4
    finally:
        src.close()


@pytest.fixture(autouse=True)
def host_relay(monkeypatch):
    app = FastAPI()
    app.include_router(router)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    base = f"http://127.0.0.1:{sock.getsockname()[1]}"
    server = uvicorn.Server(uvicorn.Config(app, log_level="error"))
    thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 5
        while not server.started:
            assert thread.is_alive() and time.monotonic() < deadline
            time.sleep(0.01)
        monkeypatch.setattr(
            credential_redirects,
            "_ffmpeg_relay",
            lambda url, headers: relay_url(base, url, headers),
        )
        yield
    finally:
        server.should_exit = True
        thread.join(timeout=5)
        sock.close()


def test_ffmpeg_actual_redirect_after_same_origin_range_probe():
    dest = _Origin(redirect_to=None)
    src = _Origin(redirect_to=f"{dest.base}/file", probe_stays=True)
    try:
        # 旧预探测会看到同源 206；实际 ffmpeg 请求仍会被跳到另一端口。
        assert (
            httpx.get(
                f"{src.base}/start", headers={**_headers(), "Range": "bytes=0-0"}, trust_env=False
            ).status_code
            == 206
        )
        url, args = strm_source_input(StrmLink(url=f"{src.base}/start", headers=_headers()))
        assert len(src.seen) == 1  # 输入装配没有同步网络请求
        assert "/internal/ffmpeg-stream/" in url
        assert TOKEN not in url and TOKEN not in " ".join(args)
        assert "X-Emby-Token" not in " ".join(args)
        # 模拟 ffmpeg 的取流、seek 和重连；走真实宿主转发，不依赖外部二进制。
        for headers, status, expected in (
            ({}, 200, BODY),
            ({"Range": "bytes=4-7"}, 206, BODY[4:8]),
            ({"Range": "bytes=8-"}, 206, BODY[8:]),
        ):
            response = httpx.get(url, headers=headers, trust_env=False)
            assert response.status_code == status
            assert response.content == expected
        assert [item["token"] for item in src.seen] == [TOKEN] * 4
        assert [item["token"] for item in dest.seen] == [None] * 3
        assert all(item["ua"] == "MovieClaw" for item in dest.seen)
        assert all(item["referer"] == "https://emby.local/web" for item in dest.seen)
    finally:
        src.close()
        dest.close()


def test_redirect_chain_deadline_and_event_loop_progress():
    src = _Origin(redirect_to="/file", delay=0.4)
    try:

        async def run():
            ticks = 0

            async def ticker():
                nonlocal ticks
                while True:
                    ticks += 1
                    await asyncio.sleep(0.01)

            async with httpx.AsyncClient(trust_env=False, timeout=1) as client:
                task = asyncio.create_task(ticker())
                started = time.monotonic()
                try:
                    with pytest.raises(httpx.ReadTimeout, match="deadline"):
                        await credential_redirects.open_followed_stream(
                            client, f"{src.base}/start", _headers(), timeout=0.65
                        )
                    assert time.monotonic() - started < 0.85
                    assert ticks >= 10
                finally:
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)

        asyncio.run(run())
        assert len(src.seen) == 2  # 两跳各低于单次超时，合计超过整链预算
        assert (
            credential_redirects.final_status(f"{src.base}/start", _headers(), timeout=0.65) is None
        )
    finally:
        src.close()


@pytest.mark.asyncio
async def test_async_probe_uses_relay_without_blocking_loop(monkeypatch):
    from movieclaw_api.services.playback import strm_probe

    src = _Origin(redirect_to=None, delay=0.3)
    try:
        source = StrmLink(url=f"{src.base}/movie.mkv", headers=_headers())
        monkeypatch.setattr(strm_probe, "parse_strm", lambda _: source)
        loop_thread = threading.get_ident()

        def probe(url, *, input_args):
            assert threading.get_ident() != loop_thread
            assert TOKEN not in " ".join(input_args)
            assert httpx.get(url, trust_env=False).content == BODY
            return None

        async def failure(_source):
            return "test failure"

        async def record(_file_id, _path, url, _reason):
            assert url == source.url  # 不把内部票据记成片源身份
            return strm_probe._Outcome(None)

        monkeypatch.setattr(strm_probe, "probe_media", probe)
        monkeypatch.setattr(strm_probe, "_failure_reason", failure)
        monkeypatch.setattr(strm_probe, "_record_failure", record)
        task = asyncio.create_task(strm_probe._probe_and_store(1, "test.strm"))
        ticks = 0
        while not task.done():
            ticks += 1
            await asyncio.sleep(0.01)
        await task
        assert ticks >= 10
    finally:
        strm_probe._failed_at.pop("test.strm", None)
        await asyncio.to_thread(src.close)


def test_credentialed_input_fails_closed_without_host(monkeypatch):
    monkeypatch.setattr(credential_redirects, "_ffmpeg_relay", None)
    with pytest.raises(RuntimeError, match="requires the host"):
        strm_source_input(StrmLink("https://example.com/video", _headers()))
    assert (
        strm_source_input(StrmLink("https://example.com/video"))[0] == "https://example.com/video"
    )


@pytest.mark.asyncio
async def test_host_relay_requires_local_connection_and_valid_ticket():
    app = FastAPI()
    app.include_router(router)
    url = relay_url("http://host", "http://upstream/video", _headers())
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app, client=("192.0.2.1", 1234)), base_url="http://host"
    ) as client:
        assert (await client.get(url)).status_code == 403
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app, client=("127.0.0.1", 1234)), base_url="http://host"
    ) as client:
        assert (await client.get("/internal/ffmpeg-stream/invalid")).status_code == 404

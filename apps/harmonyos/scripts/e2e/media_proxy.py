#!/usr/bin/env python3
"""Local-only NAS media proxy for reproducible buffer stalls. Never logs signed URLs.
Forward an emulator port with hdc rport tcp:53123 tcp:53123.
POST /__control with {"bytesPerSecond": 0} to stall, -1 to restore full speed.
GET /__control returns byte counters only. The backend URL has no credentials.
"""

import argparse
import contextlib
import http.server
import json
import threading
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--upstream", required=True)
parser.add_argument("--port", type=int, default=53123)
args = parser.parse_args()
lock = threading.Lock()
rate = -1
next_send = 0.0
transferred = 0
requests = 0


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def control(self):
        body = json.dumps(
            {"bytesPerSecond": rate, "bytes": transferred, "requests": requests}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global rate, next_send
        if self.path != "/__control":
            self.send_error(404)
            return
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        with lock:
            rate = int(data["bytesPerSecond"])
            next_send = time.monotonic()
        self.control()

    def do_HEAD(self):
        self.relay(True)

    def do_GET(self):
        if self.path == "/__control":
            self.control()
        else:
            self.relay(False)

    def relay(self, head):
        global requests, transferred, next_send
        headers = {"Accept-Encoding": "identity"}
        for name in ("Range", "If-Range", "User-Agent"):
            if self.headers.get(name):
                headers[name] = self.headers[name]
        request = urllib.request.Request(
            args.upstream.rstrip("/") + self.path, headers=headers, method="HEAD" if head else "GET"
        )
        response_started = False
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                with lock:
                    requests += 1
                self.send_response(response.status)
                for name in (
                    "Content-Type",
                    "Content-Length",
                    "Content-Range",
                    "Accept-Ranges",
                    "ETag",
                    "Last-Modified",
                ):
                    if response.headers.get(name):
                        self.send_header(name, response.headers[name])
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                response_started = True
                if head:
                    return
                while chunk := response.read(16384):
                    while rate == 0:
                        time.sleep(0.1)
                    with lock:
                        if rate > 0:
                            scheduled = max(next_send, time.monotonic())
                            next_send = scheduled + len(chunk) / rate
                            delay = max(0, scheduled - time.monotonic())
                        else:
                            delay = 0
                    if delay:
                        time.sleep(delay)
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    with lock:
                        transferred += len(chunk)
        except (OSError, urllib.error.URLError):
            if not response_started:
                with contextlib.suppress(OSError):
                    self.send_error(502)
            self.close_connection = True


http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Proxy).serve_forever()

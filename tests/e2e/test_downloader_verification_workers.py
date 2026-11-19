"""Verify downloader ownership through independent API processes and loopback RPC."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx

_ROOT = Path(__file__).resolve().parents[2]
_WORKER = """
import sys
from datetime import timedelta

import uvicorn
from movieclaw_api.services import downloader_config
from movieclaw_db.repositories import downloader_repo

clock = downloader_repo.utcnow
offset = timedelta(seconds=int(sys.argv[2]))
downloader_repo.utcnow = lambda: clock() + offset
# Leave time for a cold peer startup while the synthetic RPC is paused.
downloader_config._TEST_TIMEOUT = 20
uvicorn.run("movieclaw_api.main:app", factory=True, host="127.0.0.1", port=int(sys.argv[1]))
"""


def _wait_for(check, *, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for the isolated API")


def test_worker_start_preserves_live_verification_and_expiry_recovers_after_exit(tmp_path):
    rpc_started = threading.Event()
    release_rpc = threading.Event()

    class TransmissionRPC(BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.path == "/transmission/rpc"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert body["method"] == "session-get"
            if self.headers.get("X-Transmission-Session-Id") != "loopback-fixture":
                self.send_response(409)
                self.send_header("X-Transmission-Session-Id", "loopback-fixture")
                self.end_headers()
                return
            rpc_started.set()
            assert release_rpc.wait(timeout=20)
            response = json.dumps(
                {
                    "result": "success",
                    "arguments": {"version": "4.0.6", "rpc-version": 17, "rpc-version-minimum": 14},
                    "tag": body.get("tag"),
                }
            ).encode()
            with suppress(BrokenPipeError, ConnectionResetError):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        def log_message(self, *_):
            pass

    processes = []
    env = {
        **os.environ,
        "PYTHONPATH": str(_ROOT / "src"),
        "DATABASE_URL": f"sqlite+aiosqlite:///{(tmp_path / 'workers.db').as_posix()}",
        "MOVIECLAW_DATA_DIR": str(tmp_path / "data"),
        "MASTER_KEY": "synthetic-worker-test-key",
        "SCHEDULER_ENABLED": "false",
        "APP_ENV": "production",
    }

    def start_worker(client, *, offset=0):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        output = tmp_path / f"worker-{port}.log"
        with output.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                [sys.executable, "-c", _WORKER, str(port), str(offset)],
                cwd=tmp_path,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        processes.append(process)
        base = f"http://127.0.0.1:{port}/api/v1"

        def ready():
            assert process.poll() is None, output.read_text(encoding="utf-8")
            with suppress(httpx.ConnectError):
                return client.get(f"{base}/auth/bootstrap").is_success
            return False

        _wait_for(ready, timeout=30)
        return base, process

    with (
        ThreadingHTTPServer(("127.0.0.1", 0), TransmissionRPC) as rpc,
        httpx.Client(headers={"Accept-Language": "en"}, trust_env=False) as client,
    ):
        thread = threading.Thread(target=rpc.serve_forever, daemon=True)
        thread.start()
        try:
            first, owner = start_worker(client)
            client.post(
                f"{first}/auth/bootstrap",
                json={"username": "tester", "password": "synthetic-worker-password"},
            ).raise_for_status()
            payload = {
                "name": "Synthetic Transmission",
                "client_type": "transmission",
                "url": f"http://127.0.0.1:{rpc.server_port}",
            }
            created = client.post(f"{first}/downloaders", json=payload).raise_for_status()
            path = f"/downloaders/{created.json()['data']['id']}"
            assert rpc_started.wait(timeout=3)

            def detail(base):
                return client.get(base + path).raise_for_status().json()["data"]

            second, peer = start_worker(client)
            assert detail(second)["status"] == "verifying"
            assert client.post(f"{second}{path}/verify").status_code == 409
            assert client.put(second + path, json=payload).status_code == 409
            release_rpc.set()
            _wait_for(lambda: detail(second)["status"] == "active")
            checked_at = detail(second)["last_checked_at"]

            rpc_started.clear()
            release_rpc.clear()
            simultaneous = threading.Barrier(2)

            def request_verification(base):
                simultaneous.wait(timeout=3)
                return client.post(f"{base}{path}/verify").status_code

            with ThreadPoolExecutor(max_workers=2) as requests:
                replies = [requests.submit(request_verification, base) for base in (first, second)]
                codes = [reply.result(timeout=5) for reply in replies]
            assert sorted(codes) == [200, 409]
            assert rpc_started.wait(timeout=3)
            winner, survivor = (owner, second) if codes[0] == 200 else (peer, first)
            winner.kill()
            winner.wait(timeout=5)
            assert detail(survivor)["status"] == "verifying"
            release_rpc.set()

            # Advance the repository clock in the next process to exercise expiry without sleeping.
            restarted, _ = start_worker(client, offset=120)
            recovered = detail(survivor)
            assert recovered["status"] == "failed"
            assert "interrupted" in recovered["last_error"]
            assert recovered["last_checked_at"] == checked_at
            client.post(f"{restarted}{path}/verify").raise_for_status()
            _wait_for(lambda: detail(survivor)["status"] == "active")
            assert detail(restarted)["version"] == "4.0.6"
        finally:
            release_rpc.set()
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
            rpc.shutdown()
            thread.join(timeout=5)

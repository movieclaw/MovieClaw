"""Exercise app update and snapshot rollback across real, serial backend restarts."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tarfile
import threading
from contextlib import closing, suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from .test_downloader_verification_workers import _wait_for

pytestmark = pytest.mark.integration

_ROOT = Path(__file__).resolve().parents[2]
_OLD_VERSION = "0.51.0"
_FIXTURE_VERSION = "0.51.1"
_OLD_REV = "a7d2e9c41b58"
_LEASE_REV = "be3b7498a20c"
_API_ENTRY = """
import os
from pathlib import Path
import httpx
from movieclaw_api.services import app_update
from movieclaw_api.main import run

async def fixture_github(path, _what, **_kwargs):
    async with httpx.AsyncClient(trust_env=False) as client:
        return (await client.get(os.environ["E2E_RELEASE_ORIGIN"] + path)).raise_for_status().json()

app_update._github_get = fixture_github
interrupt = Path(os.environ["E2E_INTERRUPT_BEFORE_SWITCH"])
if interrupt.exists():
    switch = app_update._switch_rollback_links

    def stop_once(*args, **kwargs):
        if interrupt.exists():
            interrupt.unlink()
            os._exit(86)
        return switch(*args, **kwargs)

    app_update._switch_rollback_links = stop_once
run()
"""


@pytest.fixture
def release_artifacts(tmp_path):
    """Build a release-layout backend and a stub frontend, with a test-only signed manifest."""
    backend = tmp_path / "backend"
    for name in ("src", "alembic"):
        shutil.copytree(
            _ROOT / name, backend / name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc")
        )
    shutil.copyfile(_ROOT / "alembic.ini", backend / "alembic.ini")
    package = backend / "src/movieclaw_api"
    (package / "__init__.py").write_text(f'__version__ = "{_FIXTURE_VERSION}"\n', encoding="utf-8")
    subprocess.run(
        [
            sys.executable,
            "-m",
            "movieclaw_api.export_openapi",
            "-o",
            str(package / "data/spec.json"),
        ],
        cwd=tmp_path,
        env={**os.environ, "PYTHONPATH": str(backend / "src"), "PYTHONDONTWRITEBYTECODE": "1"},
        check=True,
        capture_output=True,
    )
    web = tmp_path / "web"
    (web / "apps/web").mkdir(parents=True)
    (web / "apps/web/server.js").write_text("// Fixture entrypoint for layout check\n")
    artifacts = {}
    for path in (backend, web):
        name = f"app-{path.name}.tar.gz"
        with tarfile.open(tmp_path / name, "w:gz") as output:
            for child in sorted(path.iterdir()):
                output.add(child, arcname=child.name)
        artifacts[name] = (tmp_path / name).read_bytes()
    manifest = json.dumps(
        {
            "version": _FIXTURE_VERSION,
            "requires_runtime": 1,
            "files": {
                name: {"sha256": hashlib.sha256(body).hexdigest(), "size": len(body)}
                for name, body in artifacts.items()
            },
        }
    ).encode()
    key = Ed25519PrivateKey.generate()
    artifacts["manifest.json"] = manifest
    artifacts["manifest.json.sig"] = base64.b64encode(key.sign(manifest))
    return artifacts, base64.b64encode(key.public_key().public_bytes_raw()).decode()


def _assert_database(path, revision, names):
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
        assert db.execute("PRAGMA quick_check").fetchall() == [("ok",)]
        assert db.execute("SELECT version_num FROM alembic_version").fetchall() == [(revision,)]
        assert [r[0] for r in db.execute("SELECT name FROM downloader_client ORDER BY id")] == names


def test_v051_applies_and_rolls_back_paired_snapshot(tmp_path, request):
    baseline_path = os.environ.get("MOVIECLAW_E2E_V051_ROOT")
    if not baseline_path:
        pytest.skip("set MOVIECLAW_E2E_V051_ROOT to a clean v0.51.0 source archive")
    baseline = Path(baseline_path).resolve()
    artifacts, pubkey = request.getfixturevalue("release_artifacts")
    data = tmp_path / "data"
    data.mkdir()
    db = data / "movieclaw.db"
    updates = data / "updates"
    runtime = tmp_path / "runtime"
    runtime.write_text("1\n")
    damage_download = threading.Event()
    release_path = f"https://github.com/movieclaw/MovieClaw/releases/download/v{_FIXTURE_VERSION}"

    class FixtureHTTP(BaseHTTPRequestHandler):
        def send_body(self, raw, *, status=200, headers=None):
            self.send_response(status)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            path = urlsplit(self.path).path
            name = path.rsplit("/", 1)[-1]
            if path == "/git/matching-refs/tags/v":
                body = json.dumps([{"ref": f"refs/tags/v{_FIXTURE_VERSION}"}]).encode()
            elif path == f"/releases/tags/v{_FIXTURE_VERSION}":
                body = json.dumps(
                    {
                        "tag_name": f"v{_FIXTURE_VERSION}",
                        "assets": [
                            {"name": a, "browser_download_url": f"{release_path}/{a}"}
                            for a in artifacts
                        ],
                    }
                ).encode()
            elif name in artifacts:
                body = (
                    b"incomplete download"
                    if name == "app-backend.tar.gz" and damage_download.is_set()
                    else artifacts[name]
                )
            else:
                self.send_body(b"", status=404)
                return
            self.send_body(body)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert self.path == "/transmission/rpc" and body["method"] == "session-get"
            if self.headers.get("X-Transmission-Session-Id") != "fixture":
                self.send_body(b"", status=409, headers={"X-Transmission-Session-Id": "fixture"})
                return
            self.send_body(
                json.dumps(
                    {
                        "result": "success",
                        "arguments": {
                            "version": "4.0.6",
                            "rpc-version": 17,
                            "rpc-version-minimum": 14,
                        },
                        "tag": body.get("tag"),
                    }
                ).encode()
            )

        def log_message(self, *_):
            pass

    with (
        ThreadingHTTPServer(("127.0.0.1", 0), FixtureHTTP) as server,
        httpx.Client(trust_env=False, headers={"Accept-Language": "en"}) as client,
    ):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        origin = f"http://127.0.0.1:{server.server_port}"
        interrupt = tmp_path / "interrupt-before-switch"
        env = {
            **os.environ,
            "APP_RELOAD": "false",
            "APP_HOST": "127.0.0.1",
            "SCHEDULER_ENABLED": "false",
            "MOVIECLAW_DATA_DIR": str(data),
            "MOVIECLAW_UPDATES_DIR": str(updates),
            "DATABASE_URL": f"sqlite+aiosqlite:///{db}",
            "SECRET_KEY_FILE": str(data / ".secret_key"),
            "MOVIECLAW_APP_ROOT": str(baseline),
            "MOVIECLAW_RUNTIME_FILE": str(runtime),
            "MOVIECLAW_RUNTIME_VERSION": "1",
            "MOVIECLAW_CLI_LINK": str(tmp_path / "mclaw"),
            "MOVIECLAW_PYTHON_BIN": sys.executable,
            "E2E_RELEASE_ORIGIN": origin,
            "E2E_INTERRUPT_BEFORE_SWITCH": str(interrupt),
            "UPDATE_DOWNLOAD_MIRROR": origin,
            "UPDATE_MANIFEST_PUBKEY": pubkey,
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        process = None

        def boot(label, source_expected):
            nonlocal process
            assert process is None or process.poll() is not None
            output = subprocess.check_output(
                ["bash", str(baseline / "docker/entrypoint.sh"), "resolve"], env=env, text=True
            )
            resolved = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
            assert resolved["source"] == source_expected
            with socket.socket() as port:
                port.bind(("127.0.0.1", 0))
                api_port = port.getsockname()[1]
            log = tmp_path / f"{label}.log"
            with log.open("w", encoding="utf-8") as stream:
                process = subprocess.Popen(
                    [sys.executable, "-c", _API_ENTRY],
                    cwd=tmp_path,
                    env={
                        **env,
                        "PYTHONPATH": str(Path(resolved["backend_root"]) / "src"),
                        "MOVIECLAW_CODE_SOURCE": resolved["source"],
                        "MOVIECLAW_OVERLAY_VERSION": resolved["version"],
                        "APP_PORT": str(api_port),
                    },
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                )
            api = f"http://127.0.0.1:{api_port}/api/v1"

            def ready():
                assert process.poll() is None, log.read_text(encoding="utf-8")
                with suppress(httpx.ConnectError):
                    return client.get(api + "/health").is_success
                return False

            _wait_for(ready, timeout=35)
            assert client.get(api + "/health").json()["version"] == (
                _OLD_VERSION if source_expected == "baseline" else _FIXTURE_VERSION
            )
            return api

        def stop_for_restart():
            assert process.wait(timeout=30) == 43

        admin = {"username": "tester", "password": "synthetic-update-password"}
        payload = {"client_type": "transmission", "url": origin, "name": "Legacy downloader"}

        def get(api, path):
            return client.get(api + path).raise_for_status().json()["data"]

        def create(api, **overrides):
            response = client.post(api + "/downloaders", json={**payload, **overrides})
            return f"/downloaders/{response.raise_for_status().json()['data']['id']}"

        try:
            api = boot("old-initial", "baseline")
            client.post(api + "/auth/bootstrap", json=admin).raise_for_status()
            path = create(api)
            _wait_for(lambda: get(api, path)["status"] == "active")
            process.terminate()
            process.wait(timeout=15)
            with closing(sqlite3.connect(db)) as connection, connection:
                # Represent a v0.51.0 database left with a verification from hours earlier.
                connection.execute(
                    "UPDATE downloader_client SET status = 'VERIFYING', "
                    "updated_at = datetime('now', '-5 hours')"
                )

            api = boot("old-update", "baseline")
            assert get(api, path)["status"] == "verifying"
            damage_download.set()
            client.post(api + "/app/update/apply").raise_for_status()
            _wait_for(lambda: get(api, "/app/update/progress")["phase"] == "failed")
            assert not (updates / "current").is_symlink()
            _assert_database(db, _OLD_REV, ["Legacy downloader"])
            damage_download.clear()
            client.post(api + "/app/update/apply").raise_for_status()
            stop_for_restart()
            _assert_database(db, _OLD_REV, ["Legacy downloader"])
            (snapshot,) = (updates / "backup").glob("movieclaw-v0.51.0-*.db")
            _assert_database(snapshot, _OLD_REV, ["Legacy downloader"])

            api = boot("candidate", "overlay")
            _assert_database(db, _LEASE_REV, ["Legacy downloader"])
            assert get(api, path)["status"] == "failed"
            assert "interrupted" in get(api, path)["last_error"]
            client.post(api + path + "/verify").raise_for_status()
            _wait_for(lambda: get(api, path)["status"] == "active")
            added = create(api, name="Candidate-only downloader")
            _wait_for(lambda: get(api, added)["status"] == "active")
            option = get(api, "/app/update/rollback/options")["targets"][-1]
            assert (option["kind"], option["version"], option["schema_action"]) == (
                "baseline",
                _OLD_VERSION,
                "restore",
            )
            response = client.post(
                api + "/app/update/rollback", json={"target": "baseline", "restore_backup": False}
            )
            assert response.status_code == 400
            assert client.post(api + "/app/update/rollback").status_code == 400

            rollback = {"target": "baseline", "restore_backup": True}
            saved = snapshot.read_bytes()
            client.post(api + "/app/update/rollback", json=rollback).raise_for_status()
            snapshot.write_bytes(b"incomplete snapshot")
            stop_for_restart()
            _assert_database(db, _LEASE_REV, ["Legacy downloader", "Candidate-only downloader"])
            snapshot.write_bytes(saved)
            api = boot("candidate-after-failed-restore", "overlay")
            assert get(api, added)["status"] == "active"

            process.terminate()
            process.wait(timeout=15)
            interrupt.touch()
            api = boot("candidate-before-interruption", "overlay")
            client.post(api + "/app/update/rollback", json=rollback).raise_for_status()
            assert process.wait(timeout=30) == 86
            _assert_database(db, _OLD_REV, ["Legacy downloader"])
            assert (updates / "current").is_symlink()
            api = boot("candidate-recovered", "overlay")
            _assert_database(db, _LEASE_REV, ["Legacy downloader", "Candidate-only downloader"])
            assert get(api, added)["status"] == "active"
            assert not (updates / "state/restore-in-progress.json").exists()

            client.post(api + "/app/update/rollback", json=rollback).raise_for_status()
            stop_for_restart()
            _assert_database(db, _OLD_REV, ["Legacy downloader"])
            archives = sorted((updates / "backup").glob(f"movieclaw-v{_FIXTURE_VERSION}-*.db"))
            _assert_database(
                archives[-1], _LEASE_REV, ["Legacy downloader", "Candidate-only downloader"]
            )
            api = boot("old-restored", "baseline")
            client.post(api + "/auth/login", json=admin).raise_for_status()
            assert client.get(api + added).status_code == 404
            # The original fixture included an interrupted row. Restore the exact snapshot.
            assert get(api, path)["status"] == "verifying"
            fresh = create(api, name="New v0.51.0 downloader")
            _wait_for(lambda: get(api, fresh)["status"] == "active")
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            server.shutdown()
            thread.join(timeout=5)

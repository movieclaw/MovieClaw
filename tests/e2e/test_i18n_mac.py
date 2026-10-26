"""Mac account isolation through a QA app, real API, SQLite and XCTest UI automation.

Build MovieClawMacEnglish for testing, then set APPLE_I18N_MAC_XCTESTRUN and
APPLE_I18N_MAC_APP to a QA bundle built with MC_BUNDLE_ID_PREFIX=io.movieclaw.i18nqa.
The app bundle must have keychain access and the Mac must be unlocked.
"""

from __future__ import annotations

import hashlib
import os
import plistlib
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest

from . import test_theme_device_class_browser as theme

pytestmark = pytest.mark.integration


def test_mac_account_language_and_isolation(tmp_path):
    original = os.environ.get("APPLE_I18N_MAC_XCTESTRUN")
    app_path = os.environ.get("APPLE_I18N_MAC_APP")
    if not original or not app_path:
        pytest.skip("Requires a built Mac English UI scheme and a QA app bundle")
    source, bundle = Path(original).resolve(), Path(app_path).resolve()
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    app_id = info["CFBundleIdentifier"]
    assert app_id.startswith("io.movieclaw.i18nqa"), "Never run against the user's app profile"
    config = plistlib.loads(source.read_bytes())
    config["MovieClawMacUITests"]["UITargetAppPath"] = str(bundle)
    data, media = tmp_path / "data", tmp_path / "media"
    data.mkdir()
    media.mkdir()
    port = theme._free_port()
    base = f"http://127.0.0.1:{port}"
    env = {
        **os.environ,
        "APP_PORT": str(port),
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "SCHEDULER_ENABLED": "false",
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'app.db'}",
        "MOVIECLAW_DATA_DIR": str(data),
        "METADATA_DIR": str(data / "metadata"),
        "IMAGE_CACHE_DIR": str(data / "cache/images"),
        "PEOPLE_IMAGES_DIR": str(data / "metadata/people"),
        "MOVIECLAW_PLAYBACK_SUBS_CACHE_DIR": str(data / "cache/subtitles"),
        "MOVIECLAW_TRANSCODE_DIR": str(data / "transcodes"),
        "MOVIECLAW_TRICKPLAY_CACHE_DIR": str(data / "cache/trickplay"),
        "AGENT_SESSIONS_DIR": str(data / "agent-sessions"),
        "AGENT_WORKSPACE_DIR": str(data / "agent-workspace"),
        "AGENT_SKILLS_DIR": str(data / "agent-skills"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "E2E_TMDB_LOG": str(tmp_path / "tmdb.log"),
    }
    artifacts = theme.REPO / ".tmp-uidev/i18n/mac-automated"
    artifacts.mkdir(parents=True, exist_ok=True)
    member = "qa-" + str(time.time_ns())[-12:]
    run = source.with_name("i18n-mac-fixture.xctestrun")
    with (artifacts / "api.log").open("w") as api_log:
        api = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("_api_launcher.py"))],
            env=env,
            cwd=tmp_path,
            stdout=api_log,
            stderr=subprocess.STDOUT,
        )
        try:
            theme._wait_http(base + "/api/v1/auth/bootstrap", 90)
            video = media / "Mac account fixture.mp4"
            subprocess.run(
                [
                    "ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=160x90:rate=12:duration=600", "-c:v", "libx264",
                    "-preset", "ultrafast", "-crf", "35", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(video),
                ], check=True,
            )  # fmt: skip
            digest = hashlib.sha256(video.read_bytes()).digest()
            with httpx.Client(base_url=base, timeout=15) as client:
                assert client.post("/api/v1/auth/bootstrap", json=theme.ADMIN).is_success
                library = client.post(
                    "/api/v1/libraries",
                    json={
                        "name": "Mac account fixture",
                        "kind": "video",
                        "source": "local",
                        "root_paths": [str(media)],
                    },
                )
                assert library.is_success, library.text
                library_id = library.json()["data"]["id"]
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    items = client.get(f"/api/v1/libraries/{library_id}/items").json()["data"]
                    if items:
                        break
                    time.sleep(0.2)
                assert items
                item_id = items[0]["media_item_id"]
                progress = client.post(
                    "/api/v1/playback/progress",
                    json={
                        "media_item_id": item_id,
                        "event": "stop",
                        "position_ms": 60000,
                    },
                )
                assert progress.is_success, progress.text
                assert (
                    client.get(
                        "/api/v1/playback/resume",
                        params={
                            "media_item_id": item_id,
                        },
                    ).json()["data"]["position_ms"]
                    == 60000
                )
                assert client.post(
                    "/api/v1/members",
                    json={
                        "username": member,
                        "nickname": "QA member",
                        "password": theme.ADMIN["password"],
                    },
                ).is_success
            config["MovieClawMacUITests"]["EnvironmentVariables"].update(
                {
                    "MC_TEST_I18N": "1",
                    "MC_TEST_SERVER": base,
                    "MC_TEST_PASSWORD": theme.ADMIN["password"],
                    "MC_TEST_APP_BUNDLE_ID": app_id,
                    "MC_TEST_APP_PATH": str(bundle),
                    "MC_TEST_PLAYER_ITEM": str(item_id),
                    "MC_TEST_MEMBER": member,
                    "MC_TEST_MEMBER_NICKNAME": "QA member",
                }
            )
            run.write_bytes(plistlib.dumps(config))
            with (artifacts / "xcodebuild.log").open("w") as log:
                result = subprocess.run(
                    [
                        "xcodebuild",
                        "test-without-building",
                        "-xctestrun",
                        str(run),
                        "-destination",
                        "platform=macOS,arch=arm64",
                        "-parallel-testing-enabled",
                        "NO",
                        "-only-testing:MovieClawMacUITests/MacLocalizationUITests",
                    ],
                    cwd=theme.REPO,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=300,
                )
            output = (artifacts / "xcodebuild.log").read_text()
            assert result.returncode == 0, output[-12000:]
            assert "testAccountSwitchClearsPreviousDetails]' passed" in output, output[-12000:]
            assert hashlib.sha256(video.read_bytes()).digest() == digest
            with sqlite3.connect(data / "app.db") as connection:
                rows = connection.execute(
                    "SELECT member_id,position_ms FROM playback_state WHERE media_item_id=?",
                    (item_id,),
                ).fetchall()
            assert rows == [(0, 60000)]
        finally:
            run.unlink(missing_ok=True)
            theme._stop(api)
            api.wait(timeout=20)
            for username in ("admin", member):
                subprocess.run(
                    [
                        "security",
                        "delete-generic-password",
                        "-s",
                        "io.movieclaw.app.tokens",
                        "-a",
                        base + "#" + username,
                    ],
                    capture_output=True,
                )

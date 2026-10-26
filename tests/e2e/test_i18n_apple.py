"""Run the built MovieClawEnglish scheme against an isolated real API and SQLite.

Build with xcodebuild build-for-testing first; set APPLE_I18N_XCTESTRUN to its
MovieClawEnglish_*.xctestrun and APPLE_I18N_SIMULATOR to an iPhone simulator UUID.
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


@pytest.mark.parametrize("platform", ["ios", "tvos"])
def test_apple_language_flow(tmp_path, platform):
    prefix = "APPLE_I18N_TV" if platform == "tvos" else "APPLE_I18N"
    original = os.environ.get(f"{prefix}_XCTESTRUN")
    simulator = os.environ.get(f"{prefix}_SIMULATOR")
    if not original or not simulator:
        pytest.skip(f"Requires a built English scheme and an {platform} simulator")
    source = Path(original).resolve()
    config = plistlib.loads(source.read_bytes())
    port = theme._free_port()
    base = f"http://127.0.0.1:{port}"
    data = tmp_path / "data"
    data.mkdir()
    database = data / "app.db"
    env = {
        **os.environ,
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(port),
        "DATABASE_URL": f"sqlite+aiosqlite:///{database}",
        "MOVIECLAW_DATA_DIR": str(data),
        "AGENT_SESSIONS_DIR": str(data / "agent-sessions"),
        "AGENT_WORKSPACE_DIR": str(data / "agent-workspace"),
        "AGENT_SKILLS_DIR": str(data / "agent-skills"),
        "IMAGE_CACHE_DIR": str(data / "cache/images"),
        "MOVIECLAW_PLAYBACK_SUBS_CACHE_DIR": str(data / "cache/subtitles"),
        "MOVIECLAW_SUBTITLE_GEN_CACHE_DIR": str(data / "cache/subtitle-generation"),
        "MOVIECLAW_TRANSCODE_DIR": str(data / "transcodes"),
        "MOVIECLAW_TRICKPLAY_CACHE_DIR": str(data / "cache/trickplay"),
        "PEOPLE_IMAGES_DIR": str(data / "metadata/people"),
        "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "E2E_TMDB_LOG": str(tmp_path / "tmdb.log"),
    }
    run = source.with_name("i18n-fixture.xctestrun")
    artifacts = theme.REPO / ".tmp-uidev/i18n/apple"
    if platform == "tvos":
        artifacts = artifacts / "tvos"
    artifacts.mkdir(parents=True, exist_ok=True)
    with (artifacts / "api.log").open("w") as api_log:
        api = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("_api_launcher.py"))],
            env=env,
            cwd=tmp_path,
            stdout=api_log,
            stderr=subprocess.STDOUT,
        )
        try:
            theme._wait_http(f"{base}/api/v1/auth/bootstrap", 90)
            with httpx.Client(base_url=base) as fixture:
                assert fixture.post("/api/v1/auth/bootstrap", json=theme.ADMIN).is_success
                if platform == "ios":
                    cached = data / "cache/images/native-fixture/asset.bin"
                    cached.parent.mkdir(parents=True)
                    cached.write_bytes(b"native cache cleanup fixture")
                player_item = None
                media = tmp_path / "media"
                media.mkdir()
                subprocess.run(
                    [
                        "ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                        "testsrc2=size=320x180:rate=24:duration=90", "-f", "lavfi", "-i",
                        "sine=frequency=440:duration=90",
                        "-map", "0:v", "-map", "1:a", "-map", "1:a",
                        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-metadata:s:a:0", "language=eng",
                        "-metadata:s:a:1", "language=jpn",
                        "-movflags", "+faststart", str(media / "English playback.mp4"),
                    ],
                    check=True,
                )  # fmt: skip
                video_digest = hashlib.sha256(
                    (media / "English playback.mp4").read_bytes()
                ).digest()
                (media / "English playback.en.srt").write_text(
                    "1\n00:00:00,000 --> 00:01:30,000\nEnglish subtitle probe\n",
                    encoding="utf8",
                )
                response = fixture.post(
                    "/api/v1/libraries",
                    json={
                        "name": "Playback fixture",
                        "kind": "video",
                        "source": "local",
                        "root_paths": [str(media)],
                    },
                )
                assert response.is_success, response.text
                library = response.json()["data"]["id"]
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    items = fixture.get(f"/api/v1/libraries/{library}/items").json()["data"]
                    if items:
                        player_item = items[0]["media_item_id"]
                        break
                    time.sleep(0.2)
                assert player_item is not None
            for name in (
                ("MovieClawTVUITests",)
                if platform == "tvos"
                else ("MovieClawTests", "MovieClawUITests")
            ):
                config[name]["EnvironmentVariables"].update(
                    {
                        "MC_TEST_I18N": "1",
                        "MC_TEST_SERVER": base,
                        "MC_TEST_PASSWORD": theme.ADMIN["password"],
                    }
                )
                if name == "MovieClawTests":
                    config[name].setdefault("OnlyTestIdentifiers", []).append(
                        "MaintenanceSettingsTests"
                    )
                if player_item is not None:
                    config[name]["EnvironmentVariables"]["MC_TEST_PLAYER_ITEM"] = str(player_item)
            run.write_bytes(plistlib.dumps(config))
            with (artifacts / "xcodebuild.log").open("w") as log:
                result = subprocess.run(
                    [
                        "xcodebuild",
                        "test-without-building",
                        "-xctestrun",
                        str(run),
                        "-destination",
                        f"platform={'tvOS' if platform == 'tvos' else 'iOS'} Simulator,"
                        f"id={simulator}",
                        "-parallel-testing-enabled",
                        "NO",
                        "-collect-test-diagnostics",
                        "never",
                        *(
                            [
                                "-only-testing:MovieClawTests/LocalizationTests",
                                "-only-testing:MovieClawTests/MaintenanceSettingsTests",
                                "-only-testing:MovieClawUITests/LocalizationUITests",
                            ]
                            if platform == "ios"
                            else []
                        ),
                    ],
                    cwd=theme.REPO,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=600,
                )
            output = (artifacts / "xcodebuild.log").read_text()
            assert result.returncode == 0, output[-12000:]
            expected = (
                [
                    "testEnglishAccountAndAboutUseRealServer",
                    "testEnglishPlaybackPanelUsesRealMedia",
                    "testTraditionalChineseUsesSimplifiedAlias",
                ]
                if platform == "tvos"
                else [
                    "testFreshSignInUsesEnglishAndChineseMessages",
                    "testEnglishNetworkAndValidationErrors",
                    "testEnglishPluralVariations",
                    "testPlaybackMenusUseTheEffectiveLanguage",
                    "testStorageCleanupUsesTheReaderLanguage",
                    "testScheduledTaskDraftDiscardAndSaveUseEnglish",
                ]
            )
            for test_name in expected:
                assert f"{test_name}]' passed" in output, output[-12000:]
            if platform == "ios":
                assert "Suite MaintenanceSettingsTests passed" in output
                with httpx.Client(base_url=base) as verification:
                    assert verification.post("/api/v1/auth/login", json=theme.ADMIN).is_success
                    tasks = verification.get("/api/v1/scheduled-tasks").json()["data"]
                    task = next(row for row in tasks if row["key"] == "library_reconcile")
                    assert task["enabled"] and task["interval_seconds"] == 25200
                    assert task["trigger_type"] == "interval" and task["next_run_at"]
                assert not cached.exists()
                assert (
                    hashlib.sha256((media / "English playback.mp4").read_bytes()).digest()
                    == video_digest
                )
                assert (artifacts / "api.log").read_text().count("缓存清理完成：图片缓存") == 2
            with sqlite3.connect(database) as connection:
                devices = connection.execute(
                    "SELECT locale,timezone FROM login_device WHERE kind=?", (platform,)
                ).fetchall()
            assert devices
            assert all(locale in {"en", "zh-Hans"} and timezone for locale, timezone in devices)
        finally:
            run.unlink(missing_ok=True)
            theme._stop(api)
            try:
                api.wait(timeout=15)
            except subprocess.TimeoutExpired:
                api.kill()

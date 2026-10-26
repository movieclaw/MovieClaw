"""Isolated update UI fixture: fake GitHub metadata; record the process-restart boundary."""

import hashlib
import json
import os
import sqlite3
import time
from pathlib import Path

from tests.e2e._smart_api_launcher import app

from movieclaw_api import __version__
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import app_update
from movieclaw_api.settings.schemas import (
    AppUpdatePrefsSetting,
    AppUpdateStateSetting,
    save_app_update_prefs,
    save_app_update_state,
)

root = Path(os.environ["E2E_UPDATE_ROOT"]).resolve()
assert root.name.startswith("update-browser")
assert Path(get_settings().updates_dir).resolve().is_relative_to(root)
remote = root / "github.json"
restarts = root / "restart-requests.jsonl"


def record_restart(code=42):
    with restarts.open("a") as stream:
        stream.write(json.dumps({"code": code}) + "\n")


# The UI runs against real update services and disk operations, without exiting pytest's API.
app_update.schedule_restart = record_restart


async def github_release():
    spec = json.loads(remote.read_text())
    manifest = {
        "schema": 1,
        "version": spec["version"],
        "requires_runtime": spec["runtime"],
        "files": {
            name: {"sha256": "0" * 64, "size": 3}
            for name in ("app-backend.tar.gz", "app-web.tar.gz")
        },
        "raw": b"{}",
    }
    return {"body": "Raw release notes", "published_at": "2026-10-24T00:00:00Z"}, manifest


async def github_model_release():
    return {"tag_name": "torrent-ner-v999", "assets": [], "published_at": "2026-10-24T00:00:00Z"}


app_update._fetch_latest_release = github_release
app_update._fetch_latest_model_release = github_model_release


@app.post("/api/v1/__lab/update/seed")
async def seed():
    updates = Path(get_settings().updates_dir)
    versions, backups, state = updates / "versions", updates / "backup", updates / "state"
    for path in (versions, backups, state):
        path.mkdir(parents=True, exist_ok=True)
    database = Path(get_settings().database_url.split(":///", 1)[1])
    with sqlite3.connect(database) as connection:
        revision = connection.execute("SELECT version_num FROM alembic_version").fetchone()[0]
        for version, rev in (("0.4.0", revision), ("0.3.0", "fixture-old-revision")):
            backup = backups / f"movieclaw-v{version}-20261001-100000.db"
            with sqlite3.connect(backup) as target:
                connection.backup(target)
            backup.with_name(backup.name + ".json").write_text(
                json.dumps(
                    {
                        "from_version": version,
                        "alembic_rev": rev,
                        "taken_at": "2026-10-01T10:00:00+00:00",
                    }
                )
            )
    for version in ("0.2.0", "0.3.0", "0.4.0", __version__, "0.6.0"):
        directory = versions / f"v{version}"
        directory.mkdir(exist_ok=True)
        (directory / "manifest.json").write_text(
            json.dumps({"version": version, "requires_runtime": 1})
        )
        (directory / "release-info.json").write_text(
            json.dumps(
                {
                    "changelog": "Raw release notes",
                    "installed_at": "2026-10-01T12:00:00Z",
                }
            )
        )
        (directory / "fixture.txt").write_text("retained release artifact")
    for name, version in (("current", "0.6.0"), ("previous", "0.4.0")):
        link = updates / name
        link.unlink(missing_ok=True)
        link.symlink_to(versions / f"v{version}")
    (state / "bad-0.6.0").touch()
    (state / "bad-9.9.9").unlink(missing_ok=True)
    (state / "last-exit.json").write_text(
        json.dumps(
            {
                "ts": int(time.time()),
                "reason": "api_crash",
                "exit_code": 3,
                "detail": "后端进程异常退出",
            },
            ensure_ascii=False,
        )
    )
    await save_app_update_prefs(AppUpdatePrefsSetting(keep_versions=5))
    await save_app_update_state(AppUpdateStateSetting(baseline_version="0.1.0"))
    app_update.reset_progress_for_tests()
    restarts.unlink(missing_ok=True)
    remote.write_text(json.dumps({"version": "9.9.9", "runtime": 1}))
    return {"ok": True, "database_sha256": hashlib.sha256(database.read_bytes()).hexdigest()}

"""两套类型设置合并成一套：剧集与电影画质不同的老用户，升级后行为不变。"""

import json
import sqlite3
from contextlib import closing

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def _profile(db, kind, resolution, source, wait):
    prefs = {
        "resolution": resolution,
        "source": source,
        "wait_seconds": wait,
        "allow_upgrade": True,
        "strict_resolution": False,
    }
    db.execute(
        "INSERT INTO smart_profile (kind,created_at,updated_at,revision,preferences) "
        "VALUES (?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,2,?)",
        (kind, json.dumps(prefs)),
    )


def _upgrade(tmp_path, monkeypatch, seed):
    tmp_path.mkdir(parents=True, exist_ok=True)
    path = tmp_path / "data.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, "c5f1a8e3d9b2")
    with closing(sqlite3.connect(path)) as db, db:
        seed(db)
    command.upgrade(config, "head")
    with closing(sqlite3.connect(path)) as db:
        profiles = {
            kind: json.loads(prefs)
            for kind, prefs in db.execute("SELECT kind, preferences FROM smart_profile")
        }
        memory = db.execute("SELECT revision, languages, habits FROM smart_memory").fetchone()
    get_settings.cache_clear()
    return profiles, (memory[0], json.loads(memory[1]), json.loads(memory[2]))


def test_differing_tv_quality_becomes_an_all_tv_habit(tmp_path, monkeypatch):
    def seed(db):
        _profile(db, "movie", "2160p", "remux", 86400)
        _profile(db, "tv", "1080p", "remux", 10800)

    profiles, (revision, languages, habits) = _upgrade(tmp_path, monkeypatch, seed)
    assert profiles["tv"]["resolution"] == "2160p" and profiles["tv"]["wait_seconds"] == 10800
    assert profiles["movie"]["resolution"] == "2160p"
    assert (revision, languages) == (0, [])
    assert habits == [
        {
            "scope": "kind",
            "value": "tv",
            "kind": "tv",
            "resolution": "1080p",
            "source_title": None,
            "at": None,
        }
    ]


def test_matching_profiles_and_fresh_installs_need_no_habit(tmp_path, monkeypatch):
    def seed(db):
        _profile(db, "movie", "2160p", "web-dl", 86400)
        _profile(db, "tv", "2160p", "web-dl", 10800)

    profiles, (_rev, _langs, habits) = _upgrade(tmp_path, monkeypatch, seed)
    assert habits == [] and profiles["tv"]["wait_seconds"] == 10800
    _profiles, (_rev, _langs, fresh) = _upgrade(tmp_path / "x", monkeypatch, lambda db: None)
    assert fresh == []

"""个人评分（PR #1332）撤回后的数据库兼容与端到端回归测试。

硬门禁覆盖三条路径（全部使用独立临时 SQLite，绝不触碰生产库）：
1. 全新安装：迁移到 head（c4e8a1d7f293 空操作兼容位），不建多余评分列，评分入口已撤回；
2. v0.52.1（be3b7498a20c）升级：无损推进到 head，原有观看进度与收藏数据完整保留；
3. 已跑过评分主干（c4e8a1d7f293）且含评分与观看数据的库：可正常启动、观看/收藏/
   首页/同步/Jellyfin 读写正常，已有 user_rating / rated_at 列与数据保持休眠不丢失，
   旧界面偏好（超管 app_setting 与成员 member.ui_prefs）中的 rated 首页行与 my_rating
   角标也能兼容读取而不崩。
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from alembic import command
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.migrations import _build_config

_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}


def _configure_env(tmp_path: Path, monkeypatch, db_path: Path) -> None:
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    monkeypatch.setattr("movieclaw_api.api.routes.playback.available_backends", lambda: ())


def _reset_singletons() -> None:
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _columns(db_path: Path, table: str) -> set[str]:
    with sqlite3.connect(db_path) as conn:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def _revision(db_path: Path) -> str:
    with sqlite3.connect(db_path) as conn:
        row = conn.execute("SELECT version_num FROM alembic_version").fetchone()
        assert row is not None
        return str(row[0])


def _seed_library_and_movies(db_path: Path, media_root: Path, count: int) -> list[int]:
    media_root.mkdir(parents=True, exist_ok=True)
    now = "2026-11-26 09:00:00"
    item_ids: list[int] = []
    with sqlite3.connect(db_path) as conn:
        cur = conn.execute(
            "INSERT INTO library "
            "(name, kind, root_paths, is_default, match_rules, created_at, updated_at) "
            "VALUES (?, 'movie', ?, 1, '[]', ?, ?)",
            ("测试电影库", json.dumps([str(media_root)]), now, now),
        )
        library_id = int(cur.lastrowid)
        for idx in range(1, count + 1):
            tmdb_id = 5000 + idx
            cur = conn.execute(
                "INSERT INTO media_item "
                "(kind, tmdb_id, external_id, title, original_title, aliases, "
                "created_at, updated_at) "
                "VALUES ('movie', ?, ?, ?, ?, '[]', ?, ?)",
                (tmdb_id, f"tmdb:movie:{tmdb_id}", f"电影 {idx}", f"Movie {idx}", now, now),
            )
            item_id = int(cur.lastrowid)
            item_ids.append(item_id)
            f = media_root / f"movie_{idx}.mkv"
            f.write_bytes(b"FAKE" * 16)
            conn.execute(
                "INSERT INTO library_file ("
                "library_id, media_item_id, season_number, episode_number, "
                "file_path, size_bytes, source, state, duration_seconds, created_at, updated_at"
                ") VALUES (?, ?, 0, 0, ?, ?, 'scanned', 'in_place', 600, ?, ?)",
                (library_id, item_id, str(f), f.stat().st_size, now, now),
            )
        conn.commit()
    return item_ids


def test_fresh_install_boots_without_rating_feature(tmp_path: Path, monkeypatch) -> None:
    db_path = tmp_path / "fresh.db"
    _configure_env(tmp_path, monkeypatch, db_path)
    try:
        from movieclaw_api.app import create_app

        with TestClient(create_app()) as client:
            assert client.post("/api/v1/auth/bootstrap", json=_ADMIN).status_code == 200
            assert _revision(db_path) == "c4e8a1d7f293"
            cols = _columns(db_path, "playback_state")
            assert "user_rating" not in cols
            assert "rated_at" not in cols

            # 已撤回的评分端点与偏好形状不再暴露
            assert client.get("/api/v1/playback/rated").status_code == 404
            bad_pref = client.put(
                "/api/v1/ui/preferences",
                json={"home": {"rows": [{"id": "rated"}]}},
            )
            assert bad_pref.status_code == 422

            prefs = client.get("/api/v1/ui/preferences").json()["data"]
            assert "my_rating" not in prefs["poster_badges"]
    finally:
        _reset_singletons()


def test_upgrade_from_v0521_preserves_watch_and_favorite_data(
    tmp_path: Path, monkeypatch
) -> None:
    db_path = tmp_path / "v0521.db"
    _configure_env(tmp_path, monkeypatch, db_path)
    try:
        # 模拟 v0.52.1 库（迁移位置 be3b7498a20c，含真实观看进度与收藏）
        command.upgrade(_build_config(), "be3b7498a20c")
        assert _revision(db_path) == "be3b7498a20c"
        [movie_id] = _seed_library_and_movies(db_path, tmp_path / "media", 1)
        now = "2026-11-25 20:00:00"
        with sqlite3.connect(db_path) as conn:
            conn.execute(
                "INSERT INTO playback_state ("
                "media_item_id, season_number, episode_number, member_id, "
                "position_ms, played, play_count, is_favorite, "
                "favorited_at, last_played_at, created_at, updated_at"
                ") VALUES (?, 0, 0, 0, 180000, 1, 2, 1, ?, ?, ?, ?)",
                (movie_id, now, now, now, now),
            )
            conn.commit()

        from movieclaw_api.app import create_app

        with TestClient(create_app()) as client:
            assert client.post("/api/v1/auth/bootstrap", json=_ADMIN).status_code == 200
            assert _revision(db_path) == "c4e8a1d7f293"
            cols = _columns(db_path, "playback_state")
            assert "user_rating" not in cols
            assert "rated_at" not in cols

            marks = client.get(
                "/api/v1/playback/marks", params={"media_item_id": movie_id}
            ).json()["data"]
            assert marks["played"] is True
            assert marks["is_favorite"] is True
            assert "user_rating" not in marks

            favs = client.get("/api/v1/playback/favorites").json()["data"]["items"]
            assert [item["media_item_id"] for item in favs] == [movie_id]
    finally:
        _reset_singletons()


def test_existing_c4e8a1d7f293_db_boots_and_preserves_dormant_rating_data(
    tmp_path: Path, monkeypatch
) -> None:
    db_path = tmp_path / "rating_main.db"
    _configure_env(tmp_path, monkeypatch, db_path)
    try:
        # 构造「已跑过评分主干（c4e8a1d7f293）且含评分+观看+偏好数据」的隔离库
        command.upgrade(_build_config(), "be3b7498a20c")
        with sqlite3.connect(db_path) as conn:
            conn.execute("ALTER TABLE playback_state ADD COLUMN user_rating SMALLINT")
            conn.execute("ALTER TABLE playback_state ADD COLUMN rated_at DATETIME")
            conn.execute("UPDATE alembic_version SET version_num = 'c4e8a1d7f293'")
            conn.commit()

        movie_watched_rated, movie_rated_only, movie_fresh = _seed_library_and_movies(
            db_path, tmp_path / "media", 3
        )
        now = "2026-11-26 10:00:00"
        rated_only_at = "2026-11-26 11:00:00"
        legacy_prefs = {
            "home": {
                "rows": [
                    {"id": "rated", "sort": "my_rating"},
                    {"id": "up-next"},
                    {"id": "favorites", "sort": "favorited_at"},
                ]
            },
            "poster_badges": {"my_rating": True, "rating": True},
        }
        with sqlite3.connect(db_path) as conn:
            # 1) 既看过、收藏又评过分的电影
            conn.execute(
                "INSERT INTO playback_state ("
                "media_item_id, season_number, episode_number, member_id, "
                "position_ms, played, play_count, is_favorite, "
                "favorited_at, last_played_at, user_rating, rated_at, created_at, updated_at"
                ") VALUES (?, 0, 0, 0, 120000, 1, 2, 1, ?, ?, 9, ?, ?, ?)",
                (movie_watched_rated, now, now, now, now, now),
            )
            # 2) 只评过分、从未观看也未收藏的电影
            conn.execute(
                "INSERT INTO playback_state ("
                "media_item_id, season_number, episode_number, member_id, "
                "position_ms, played, play_count, is_favorite, "
                "user_rating, rated_at, created_at, updated_at"
                ") VALUES (?, 0, 0, 0, 0, 0, 0, 0, 7, ?, ?, ?)",
                (movie_rated_only, rated_only_at, rated_only_at, rated_only_at),
            )
            # 3) 评分主干下保存过的首页行与海报角标偏好
            conn.execute(
                "INSERT INTO app_setting (namespace, value_json, created_at, updated_at) "
                "VALUES ('ui.preferences', ?, ?, ?)",
                (json.dumps(legacy_prefs), now, now),
            )
            conn.commit()

        from movieclaw_api.app import create_app

        with TestClient(create_app()) as client:
            assert client.post("/api/v1/auth/bootstrap", json=_ADMIN).status_code == 200
            assert _revision(db_path) == "c4e8a1d7f293"

            # 含旧 rated 行的界面偏好可正常读取（读时忽略 rated，不写库删原数据）
            prefs_resp = client.get("/api/v1/ui/preferences")
            assert prefs_resp.status_code == 200
            prefs = prefs_resp.json()["data"]
            assert [r["id"] for r in prefs["home"]["rows"]] == ["up-next", "favorites"]
            assert prefs["poster_badges"]["rating"] is True
            assert "my_rating" not in prefs["poster_badges"]

            # 创建成员并写入残留 rated 首页行的 member.ui_prefs，重启后按成员登录验证
            member_resp = client.post(
                "/api/v1/members",
                json={
                    "username": "alice",
                    "password": "MemberPass123!",
                    "nickname": "Alice",
                },
            )
            assert member_resp.status_code == 200
            member_id = member_resp.json()["data"]["id"]
            with sqlite3.connect(db_path) as conn:
                conn.execute(
                    "UPDATE member SET ui_prefs = ? WHERE id = ?",
                    (json.dumps(legacy_prefs), member_id),
                )
                conn.commit()

            # 既有观看与收藏正常读出，且只评分未观看条目不污染续播/收藏
            marks_a = client.get(
                "/api/v1/playback/marks", params={"media_item_id": movie_watched_rated}
            ).json()["data"]
            assert marks_a == {"played": True, "is_favorite": True, "unplayed_count": None}

            favs = client.get("/api/v1/playback/favorites").json()["data"]["items"]
            assert [item["media_item_id"] for item in favs] == [movie_watched_rated]

            up_next = client.get("/api/v1/playback/up-next").json()["data"]["items"]
            assert movie_rated_only not in [item["media_item_id"] for item in up_next]

            # 在含休眠列的既有行上做正常业务更新，不得破坏休眠评分列
            upd = client.post(
                "/api/v1/playback/marks",
                json={"media_item_id": movie_watched_rated, "favorite": False},
            )
            assert upd.status_code == 200
            assert upd.json()["data"]["is_favorite"] is False

            # 在含休眠列的表上插入全新播放状态行也必须正常
            ins = client.post(
                "/api/v1/playback/marks",
                json={"media_item_id": movie_fresh, "played": True},
            )
            assert ins.status_code == 200
            assert ins.json()["data"]["played"] is True

            # 同步目录接口正常，不暴露 user_rating
            sync_resp = client.get("/api/v1/playback/sync/catalog")
            assert sync_resp.status_code == 200
            for item in sync_resp.json()["data"]["items"]:
                assert "user_rating" not in item

            # Jellyfin 兼容接口在含休眠列的库上可正常认证并读出播放状态
            jf_auth = client.post(
                "/Users/AuthenticateByName",
                json={"Username": _ADMIN["username"], "Pw": _ADMIN["password"]},
                headers={
                    "X-Emby-Authorization": (
                        'MediaBrowser Client="Test", Device="Dev", '
                        'DeviceId="dev-1", Version="1.0"'
                    )
                },
            )
            assert jf_auth.status_code == 200
            jf_token = jf_auth.json()["AccessToken"]
            jf_uid = jf_auth.json()["User"]["Id"]
            jf_items = client.get(
                f"/Users/{jf_uid}/Items",
                params={"Recursive": "true", "IncludeItemTypes": "Movie"},
                headers={"X-Emby-Token": jf_token},
            )
            assert jf_items.status_code == 200
            assert jf_items.json()["TotalRecordCount"] == 3
            for jf_item in jf_items.json()["Items"]:
                assert "Rating" not in jf_item.get("UserData", {})

        # 二次重启并以普通成员登录：验证 c4e8a1d7f293 重启稳定 + member.ui_prefs 兼容读取
        with TestClient(create_app()) as member_client:
            login_resp = member_client.post(
                "/api/v1/auth/login",
                json={"username": "alice", "password": "MemberPass123!"},
            )
            assert login_resp.status_code == 200
            mprefs = member_client.get("/api/v1/ui/preferences")
            assert mprefs.status_code == 200
            assert [r["id"] for r in mprefs.json()["data"]["home"]["rows"]] == [
                "up-next",
                "favorites",
            ]

        # 核对底层 SQLite：休眠列、全部历史评分数据与原始偏好记录均完好无损
        cols = _columns(db_path, "playback_state")
        assert {"user_rating", "rated_at"}.issubset(cols)
        with sqlite3.connect(db_path) as conn:
            rows = {
                r[0]: r[1:]
                for r in conn.execute(
                    "SELECT media_item_id, user_rating, rated_at, played, is_favorite "
                    "FROM playback_state"
                ).fetchall()
            }
            raw_prefs = conn.execute(
                "SELECT value_json FROM app_setting WHERE namespace = 'ui.preferences'"
            ).fetchone()
        assert rows[movie_watched_rated] == (9, now, 1, 0)
        assert rows[movie_rated_only] == (7, rated_only_at, 0, 0)
        assert rows[movie_fresh] == (None, None, 1, 0)
        assert raw_prefs is not None
        assert json.loads(raw_prefs[0]) == legacy_prefs

        # downgrade + 再 upgrade 也不得删除休眠列或评分数据
        command.downgrade(_build_config(), "be3b7498a20c")
        command.upgrade(_build_config(), "head")
        assert _revision(db_path) == "c4e8a1d7f293"
        with sqlite3.connect(db_path) as conn:
            kept = dict(
                conn.execute(
                    "SELECT media_item_id, user_rating FROM playback_state "
                    "WHERE user_rating IS NOT NULL"
                ).fetchall()
            )
        assert kept == {movie_watched_rated: 9, movie_rated_only: 7}
    finally:
        _reset_singletons()

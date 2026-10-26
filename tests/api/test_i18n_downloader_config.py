"""Downloader presentation is reader-local; credentials, paths and legacy text stay intact."""

import copy
import json
import sqlite3

import pytest
from alembic import command
from sqlalchemy.engine import make_url
from tests.api import test_downloaders as downloaders

from movieclaw_api.core.config import get_settings
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value
from movieclaw_db.migrations import _build_config
from movieclaw_downloader import (
    DownloaderAuthError,
    DownloaderConnectError,
    DownloaderDeleteError,
    DownloaderSubmitError,
    TorrentParseError,
)
from movieclaw_downloader.registry import builtin_adapters
from movieclaw_sdk.config_schema import connection_schema

client = downloaders.client


@pytest.mark.parametrize(
    "kind",
    [
        DownloaderAuthError,
        DownloaderConnectError,
        DownloaderDeleteError,
        DownloaderSubmitError,
        TorrentParseError,
    ],
)
def test_default_exception_has_provenance_but_explicit_third_party_text_stays_raw(kind):
    owned = kind()
    raw = str(owned)
    ref = copy.deepcopy(owned.message_ref)
    for locale in ["en", "zh-Hans", "en"]:
        with use_locale(locale):
            displayed = render_value(owned.message_ref)
        assert displayed == raw if locale == "zh-Hans" else displayed != raw
        assert owned.message_ref == ref
        assert str(owned) == raw
    explicit = kind(raw)
    assert explicit.message_ref is None
    unknown = kind("第三方原始错误", message_key="plugin.unknown.reason")
    for locale in ["en", "zh-Hans"]:
        with use_locale(locale):
            assert render_value(unknown.message_ref) == "第三方原始错误"


def test_builtin_connection_schema_uses_locale_without_mutating_shared_metadata(client):
    client, _ = client
    before = {key: connection_schema(adapter) for key, adapter in builtin_adapters().items()}
    saved = copy.deepcopy(before)
    for locale in ["en", "zh-Hans", "en"]:
        rows = client.get("/api/v1/downloaders/types", headers={"Accept-Language": locale}).json()[
            "data"
        ]
        types = {row["type"]: row for row in rows}
        for key, url in [("qbittorrent", "WebUI URL"), ("transmission", "RPC URL")]:
            row = types[key]
            assert row["title"] == ("qBittorrent" if key == "qbittorrent" else "Transmission")
            assert (
                row["url_label"] == url
                if locale == "en"
                else row["url_label"] == saved[key]["properties"]["url"]["title"]
            )
            assert row["connection"]["properties"]["password"]["writeOnly"]
            assert row["connection"]["properties"]["username"]["title"] == (
                "Username" if locale == "en" else "用户名"
            )
            assert row["connection"]["required"] == ["url"]
    assert before == saved
    assert {key: connection_schema(adapter) for key, adapter in builtin_adapters().items()} == saved


def test_path_health_persists_chinese_and_renders_each_reader_without_modifying_db(
    client, tmp_path
):
    client, _ = client
    empty = tmp_path / "empty"
    empty.mkdir()
    response = client.post(
        "/api/v1/downloaders",
        headers={"Accept-Language": "en"},
        json={
            "name": "Path fixture",
            "client_type": "qbittorrent",
            "url": "http://fixture",
            "path_mappings": [{"local": str(empty), "remote": "/downloads"}],
        },
    )
    assert response.is_success
    did = response.json()["data"]["id"]
    database = make_url(get_settings().database_url).database
    with sqlite3.connect(database) as connection:
        original = connection.execute(
            "SELECT path_health FROM downloader_client WHERE id=?", (did,)
        ).fetchone()[0]
        stored = json.loads(original)[0]
        assert stored["detail_key"] == "errors.downloadPath.empty"
        assert "重启" in stored["detail"]
    for locale in ["en", "zh-Hans", "en"]:
        detail = client.get(
            f"/api/v1/downloaders/{did}", headers={"Accept-Language": locale}
        ).json()["data"]
        assert detail["status"] == "active" and not detail["paths_healthy"]
        probe = detail["path_health"][0]
        assert (
            probe["state"] == "empty"
            and probe["local"] == str(empty)
            and probe["remote"] == "/downloads"
        )
        assert (
            "重启" in probe["detail"]
            if locale == "zh-Hans"
            else "restart" in probe["detail"].lower()
        )
    with sqlite3.connect(database) as connection:
        assert (
            connection.execute(
                "SELECT path_health FROM downloader_client WHERE id=?", (did,)
            ).fetchone()[0]
            == original
        )


def test_downloader_legacy_error_upgrade_and_rollback(tmp_path, monkeypatch):
    path = tmp_path / "legacy-downloader.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    with sqlite3.connect(path) as connection:
        connection.executescript(
            "CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY);"
            "INSERT INTO alembic_version VALUES ('b7d29a60c3e1');"
            "CREATE TABLE downloader_client (id INTEGER PRIMARY KEY,last_error TEXT);"
            "INSERT INTO downloader_client VALUES (1,'第三方旧错误原文');"
        )
    try:
        config = _build_config()
        command.upgrade(config, "c8e40b72a6f9")
        with sqlite3.connect(path) as connection:
            assert connection.execute(
                "SELECT last_error,last_error_ref FROM downloader_client"
            ).fetchone() == ("第三方旧错误原文", None)
        command.downgrade(config, "b7d29a60c3e1")
        with sqlite3.connect(path) as connection:
            assert connection.execute("SELECT last_error FROM downloader_client").fetchone() == (
                "第三方旧错误原文",
            )
    finally:
        get_settings.cache_clear()

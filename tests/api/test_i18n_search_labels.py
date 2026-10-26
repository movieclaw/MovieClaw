"""Built-in search scope labels follow the reader; custom and legacy names stay raw."""

import json
import sqlite3

from movieclaw_api.core.config import get_settings

from . import test_search_history as history

client = history.client


def _rows(client, locale):
    response = client.get("/api/v1/search/history", headers={"Accept-Language": locale})
    assert response.status_code == 200
    return {row["keyword"]: row for row in response.json()["data"]}


def test_builtin_and_user_named_scopes_are_not_confused(client):
    for word, label_key in (("Built-in scope", "search.categories.movie"), ("用户关键词", None)):
        params = {"keyword": word, "categories": "movie", "label": "电影"}
        if label_key:
            params["label_key"] = label_key
        response = client.get(
            "/api/v1/search/torrents", params=params, headers={"Accept-Language": "en"}
        )
        assert response.status_code == 200, response.text
        assert response.json()["data"]["label"] == ("Movies" if label_key else "电影")
    for locale in ("en", "zh-Hans", "en"):
        rows = _rows(client, locale)
        assert rows["Built-in scope"]["label"] == ("Movies" if locale == "en" else "电影")
        assert rows["Built-in scope"]["label_key"] == "search.categories.movie"
        assert rows["用户关键词"]["label"] == "电影"
        assert rows["用户关键词"]["label_key"] is None
        for word in rows:
            response = client.get(
                f"/api/v1/search/history/{rows[word]['id']}/results",
                headers={"Accept-Language": locale},
            )
            assert response.status_code == 200, response.text
            assert response.json()["data"]["label"] == rows[word]["label"]
    database = get_settings().database_url.removeprefix("sqlite+aiosqlite:///")
    with sqlite3.connect(database) as connection:
        assert connection.execute(
            "SELECT label, label_key FROM search_history WHERE keyword = ?", ("Built-in scope",)
        ).fetchone() == ("电影", "search.categories.movie")


def test_search_stream_replays_the_same_run_in_each_readers_language(client):
    params = {
        "keyword": "Shared run",
        "categories": "movie",
        "label_key": "search.categories.movie",
    }
    for locale, label in (("en", "Movies"), ("zh-Hans", "电影"), ("en", "Movies")):
        response = client.get(
            "/api/v1/search/torrents/stream",
            params={**params, "label": label},
            headers={"Accept-Language": locale},
        )
        assert response.status_code == 200, response.text
        events = [
            json.loads(line[6:]) for line in response.text.splitlines() if line.startswith("data: ")
        ]
        assert events[0]["label"] == label
        assert events[0]["label_key"] == "search.categories.movie"
        rows = _rows(client, locale)
        assert rows["Shared run"]["search_count"] == 1
        assert rows["Shared run"]["label"] == label
    invalid = client.get("/api/v1/search/torrents", params={**params, "label_key": "common.delete"})
    assert invalid.status_code == 422


def test_user_name_matching_an_unambiguous_legacy_message_is_not_translated(client):
    for label in ("音乐", "其他", "关闭"):
        response = client.get(
            "/api/v1/search/torrents",
            params={"keyword": "Custom " + label, "label": label, "categories": "movie"},
            headers={"Accept-Language": "en"},
        )
        assert response.status_code == 200, response.text
        assert response.json()["data"]["label"] == label
        row = _rows(client, "en")["Custom " + label]
        assert row["label"] == label and row["label_key"] is None
        snapshot = client.get(
            f"/api/v1/search/history/{row['id']}/results", headers={"Accept-Language": "en"}
        )
        assert snapshot.status_code == 200, snapshot.text
        assert snapshot.json()["data"]["label"] == label

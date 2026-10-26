"""Shared search runs and persisted snapshots render failures for each reader."""

import json
import re
import sqlite3

import httpx
import pytest

from movieclaw_api.core.config import get_settings
from movieclaw_tracker.exceptions import TrackerNetworkError, TrackerParseError

from . import test_library_search as library
from . import test_search as search
from . import test_search_history as history

client = history.client
db = library.db
library_client = library.client


def test_stream_and_snapshot_do_not_freeze_the_first_readers_error_language(client, monkeypatch):
    calls = []

    class Site(search._FakeSite):
        async def search(self, query):
            calls.append(query.keyword)
            raise TrackerParseError(details={"login_redirect": True})

    search._wire(monkeypatch, {"test": Site()})
    query = {"keyword": "Original title", "label_key": "search.categories.movie"}
    for locale in ("en", "zh-Hans", "en"):
        response = client.get(
            "/api/v1/search/torrents/stream", params=query, headers={"Accept-Language": locale}
        )
        assert response.status_code == 200, response.text
        events = [
            json.loads(line[6:]) for line in response.text.splitlines() if line.startswith("data: ")
        ]
        failure = next(event for event in events if "error_key" in event)
        assert failure["error_key"] == "errors.siteDiagnostic.loginRedirect"
        assert failure["error"].startswith(
            "The site redirected" if locale == "en" else "登录已失效"
        )
        assert events[-1]["sites"][0]["error"] == failure["error"]
        rows = client.get("/api/v1/search/history").json()["data"]
        assert len(rows) == 1 and rows[0]["search_count"] == 1
        snapshot = client.get(
            f"/api/v1/search/history/{rows[0]['id']}/results", headers={"Accept-Language": locale}
        ).json()["data"]
        assert snapshot["sites"][0]["error"] == failure["error"]
    assert calls == ["Original title"]
    database = get_settings().database_url.removeprefix("sqlite+aiosqlite:///")
    with sqlite3.connect(database) as connection:
        saved = json.loads(
            connection.execute("SELECT snapshot_json FROM search_history").fetchone()[0]
        )
        assert saved["sites"][0]["error"].startswith("登录已失效")


@pytest.mark.parametrize(
    "error,key",
    [
        (TrackerNetworkError(), "errors.siteDiagnostic.network"),
        (TrackerParseError(), "errors.siteDiagnostic.parse"),
        (
            httpx.HTTPStatusError(
                "status",
                request=httpx.Request("GET", "https://fixture.invalid"),
                response=httpx.Response(429),
            ),
            "errors.siteDiagnostic.rateLimited",
        ),
    ],
)
def test_synchronous_search_uses_the_readers_language(client, monkeypatch, error, key):
    search._wire(monkeypatch, {"test": search._FakeSite(error=error)})
    for locale in ("en", "zh-Hans"):
        data = client.get(
            "/api/v1/search/torrents",
            params={"keyword": "Original"},
            headers={"Accept-Language": locale},
        ).json()["data"]
        status = data["sites"][0]
        assert status["error_key"] == key
        assert bool(re.search(r"[\u3400-\u9fff]", status["error"])) == (locale == "zh-Hans")


@pytest.mark.asyncio
async def test_library_evidence_keeps_ranking_and_original_names_across_languages(
    db, library_client
):
    await library._seed_advanced(db)
    for query, key in [
        ("xingjichuanyue", "search.match.pinyin"),
        ("星际效应", "search.match.alias"),
        ("nolan", "search.match.person"),
    ]:
        identities = None
        for locale in ("en", "zh-Hans", "en"):
            response = await library_client.get(
                "/api/v1/search/library", params={"q": query}, headers={"Accept-Language": locale}
            )
            assert response.status_code == 200, response.text
            data = response.json()["data"]
            assert data["items"]
            current = [
                (hit["item"]["media_item_id"], hit["match"]["matched_name"])
                for hit in data["items"]
            ]
            if identities is None:
                identities = current
            assert current == identities
            match = data["items"][0]["match"]
            assert match["label_key"] == key
            if locale == "en":
                assert match["label"].startswith(
                    {"xingjichuanyue": "Pinyin", "星际效应": "Alias", "nolan": "Director:"}[query]
                )
            assert data["items"][0]["item"]["title"] == "星际穿越"

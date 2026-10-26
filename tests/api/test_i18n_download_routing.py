"""Download previews keep routing semantics and re-render nested fact labels."""

import pytest

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.services.library.routing import RoutingFacts, route
from movieclaw_db.repositories.library_repo import LibraryRepository

from . import test_library_routing as routing
from . import test_subscription_routing as subscriptions

client = subscriptions.client
db = routing.db


def test_preview_labels_warnings_and_selected_ids_are_reader_specific(client, monkeypatch):
    default = subscriptions._create_lib(client, name="默认剧集库", root="/media/tv")
    anime = subscriptions._create_lib(
        client, name="动漫库", root="/media/anime", rules=subscriptions._ANIME_RULES
    )
    monkeypatch.setattr(
        "movieclaw_api.services.media_discover.get_tmdb_client", subscriptions._fake_tmdb
    )
    rule = client.post(
        "/api/v1/rule-sets",
        json={
            "name": "动画规则",
            "spec": {},
            "match_rules": [
                {"field": "kind", "op": "any_of", "values": ["tv"]},
                {"field": "genres", "op": "any_of", "values": [16]},
            ],
        },
    )
    assert rule.status_code == 200, rule.text
    for locale in ("en", "zh-Hans", "en"):
        response = client.get(
            "/api/v1/subscriptions/download-routing-preview",
            params={"kind": "tv", "tmdb_id": 300},
            headers={"Accept-Language": locale},
        )
        assert response.status_code == 200, response.text
        data = response.json()["data"]
        assert data["library_id"] == anime and data["route_matched"]
        assert data["rule_set_id"] == rule.json()["data"]["id"]
        assert data["route_reason_key"] == "library.routing.matchedLibrary"
        assert data["warning_key"] == "download.preview.defaultMissing"
        if locale == "en":
            assert data["route_reason"] == "Matched “动漫库”: Genre=Animation"
            assert "Series, Genre=Animation" in data["rule_set_reason"]
            assert data["warning"].startswith("No default downloader")
        else:
            assert data["route_reason"] == "命中「动漫库」：类型=动画"
            assert "剧集、类型=动画" in data["rule_set_reason"]
        assert data["path"] == "/media/anime"
    explicit = client.get(
        "/api/v1/subscriptions/download-routing-preview",
        params={"kind": "tv", "tmdb_id": 300, "library_id": default},
    ).json()["data"]
    assert explicit["library_id"] == default and explicit["route_reason_key"] is None


@pytest.mark.asyncio
async def test_routing_object_keeps_a_chinese_rollback_and_unknown_fact_values(db):
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="我的库",
            kind="tv",
            root_paths=["/media/tv"],
            match_rules=[{"field": "origin_countries", "op": "any_of", "values": ["JP", "ZZ"]}],
        )
        decision = await route(session, "tv", RoutingFacts(origin_countries=("JP", "ZZ")))
        assert decision.library.id == library.id
        original = decision.reason
        assert original == "命中「我的库」：区域=日本/ZZ"
        for locale, expected in (
            ("en", "Matched “我的库”: Region=Japan/ZZ"),
            ("zh-Hans", original),
        ):
            with use_locale(locale):
                assert render_value(decision.reason_message) == expected
            assert decision.reason == original

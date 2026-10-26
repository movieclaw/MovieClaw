"""Cached provider data stays neutral while API collection headings follow each reader."""

from . import test_discover as discovery

client = discovery.client


def test_discovery_headings_follow_each_request_without_mutating_provider(client, monkeypatch):
    from movieclaw_api.services import media_discover

    provider = discovery._StubTmdbService()
    monkeypatch.setattr(media_discover, "get_media_service", lambda: provider)
    for language, featured, popular in (
        ("en", "Featured this week", "Popular movies"),
        ("zh-Hans", "本周精选", "热门电影"),
        ("en", "Featured this week", "Popular movies"),
    ):
        headers = {"Accept-Language": language}
        manifest = client.get("/api/v1/ui/discovery/movie", headers=headers)
        assert manifest.status_code == 200, manifest.text
        assert [section["title"] for section in manifest.json()["data"]["sections"]] == [
            featured,
            popular,
        ]
        collection = client.get(
            "/api/v1/discover/collections/tmdb:movie:popular/titles", headers=headers
        )
        assert collection.status_code == 200, collection.text
        data = collection.json()["data"]
        assert data["collection"]["name"] == popular
        assert data["titles"][0]["title"] == "示例电影"
        assert provider.layout(None).rows[0].title == "热门电影"


def test_cached_duration_is_rendered_without_rewriting_the_provider_card(client, monkeypatch):
    from movieclaw_api.services import media_discover
    from movieclaw_media.models import MediaKind

    provider = discovery._StubTmdbService()
    detail = client.portal.call(provider.media_detail, MediaKind.MOVIE, 438631)
    detail.card.extent = "95 分钟"
    detail.card.extent_key = "units.duration.minutes"
    detail.card.extent_params = {"count": 95}

    async def cached_detail(*_args):
        return detail

    monkeypatch.setattr(provider, "media_detail", cached_detail)
    monkeypatch.setattr(media_discover, "get_media_service", lambda: provider)
    for language, expected in (("en", "95 minutes"), ("zh-Hans", "95 分钟"), ("en", "95 minutes")):
        result = client.get(
            "/api/v1/discover/titles/tmdb:movie:438631", headers={"Accept-Language": language}
        )
        assert result.status_code == 200, result.text
        assert result.json()["data"]["title"]["extent_label"] == expected
        assert detail.card.extent == "95 分钟"
        assert detail.card.extent_params == {"count": 95}


def test_all_builtin_collection_titles_have_bilingual_messages():
    from movieclaw_api.i18n import messages
    from movieclaw_api.services.title_discovery import _COLLECTION_TITLE_KEYS

    for locale in ("zh-Hans", "en"):
        assert set(_COLLECTION_TITLE_KEYS.values()) <= messages(locale).keys()

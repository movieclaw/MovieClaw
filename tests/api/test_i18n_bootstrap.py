from __future__ import annotations

import pytest

from . import test_auth as auth

client = auth.client


@pytest.mark.parametrize(
    "language,expected",
    [
        ("en-US", ["en-US"]),
        ("zh-TW", ["zh-CN", "en-US"]),
        ("ja", ["en-US"]),
    ],
)
def test_first_setup_presets_metadata_once_from_request_language(
    client, language, expected, monkeypatch
):
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.scrape_config import effective_languages

    monkeypatch.delenv("TMDB_LANGUAGE", raising=False)
    get_settings.cache_clear()
    response = client.post(
        "/api/v1/auth/bootstrap", json=auth._ADMIN, headers={"Accept-Language": language}
    )
    assert response.status_code == 200
    assert effective_languages() == expected
    client.get("/api/v1/auth/me", headers={"Accept-Language": "zh-Hans"})
    client.put("/api/v1/ui/preferences", json={"language": "en"})
    assert effective_languages() == expected


def test_setup_keeps_an_explicit_metadata_language_configuration(client):
    from movieclaw_api.services.scrape_config import effective_languages, save_scrape_setting
    from movieclaw_api.settings.metadata import MetadataScrapeSetting

    client.portal.call(
        save_scrape_setting, MetadataScrapeSetting(language_priority=["fr-FR", "en-US"])
    )
    assert (
        client.post(
            "/api/v1/auth/bootstrap", json=auth._ADMIN, headers={"Accept-Language": "en"}
        ).status_code
        == 200
    )
    assert effective_languages() == ["fr-FR", "en-US"]


def test_setup_respects_explicit_environment_metadata_language(client, monkeypatch):
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.scrape_config import effective_languages

    monkeypatch.setenv("TMDB_LANGUAGE", "fr-FR")
    get_settings.cache_clear()
    assert (
        client.post(
            "/api/v1/auth/bootstrap", json=auth._ADMIN, headers={"Accept-Language": "en"}
        ).status_code
        == 200
    )
    assert effective_languages() == ["fr-FR", "en-US"]


def test_setup_leaves_discovery_services_alone(client, monkeypatch):
    """发现页按读者语言取数（content-locale.md §3），不再捕获媒体库语言，初始化不必重建它。"""
    from movieclaw_api.services import media_discover

    closed = []

    class Discovery:
        async def aclose(self):
            closed.append(True)

    existing_client = media_discover._tmdb_client
    monkeypatch.setitem(media_discover._services, "en-US", Discovery())
    response = client.post(
        "/api/v1/auth/bootstrap", json=auth._ADMIN, headers={"Accept-Language": "en"}
    )
    assert response.status_code == 200
    assert closed == []
    assert "en-US" in media_discover._services
    assert media_discover._tmdb_client is existing_client

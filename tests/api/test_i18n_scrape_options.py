"""Real HTTP country choices translate per reader without mutating shared provider data."""

import copy

import pytest

from . import test_scrape_settings as scrape

client = scrape.client


@pytest.mark.parametrize("fallback", [False, True])
def test_country_options_cache_is_language_independent(client, monkeypatch, fallback):
    from movieclaw_api.api.routes import scrape_settings as routes

    original = copy.deepcopy(routes._BUILTIN_COUNTRIES)
    options = [
        routes.CountryOption(code="DE", name="德国"),
        routes.CountryOption(code="CN", name="中国"),
    ]
    monkeypatch.setattr(routes, "_country_cache", None if fallback else options)

    class UnavailableTMDB:
        async def get(self, *_args):
            raise ConnectionError("offline fixture")

    monkeypatch.setattr(routes, "get_tmdb_client", lambda: UnavailableTMDB())
    for locale in ("en", "zh-Hans", "en"):
        response = client.get("/api/v1/scrape/country-options", headers={"Accept-Language": locale})
        assert response.status_code == 200
        countries = {row["code"]: row["name"] for row in response.json()["data"]}
        assert countries["DE"] == ("Germany" if locale == "en" else "德国")
        assert countries["CN"] == ("China" if locale == "en" else "中国")
        assert options[0].name == "德国"
        assert original == routes._BUILTIN_COUNTRIES

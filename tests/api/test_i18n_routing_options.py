"""Library criteria translate labels while IDs, country groups and raw tables stay unchanged."""

import copy
import re

from . import test_library_routing as routing

client = routing.client


def test_routing_options_are_localized_per_reader(client):
    from movieclaw_media.genres import COUNTRY_NAMES, MOVIE_GENRES, REGION_PRESETS, TV_GENRES

    original = copy.deepcopy((MOVIE_GENRES, TV_GENRES, COUNTRY_NAMES, REGION_PRESETS))
    for language in ("en", "zh-Hans", "en"):
        response = client.get(
            "/api/v1/libraries/routing-options", headers={"Accept-Language": language}
        )
        assert response.status_code == 200, response.text
        data = response.json()["data"]
        assert {item["id"] for item in data["movie_genres"]} == MOVIE_GENRES.keys()
        assert {item["id"] for item in data["tv_genres"]} == TV_GENRES.keys()
        assert [(p["key"], p["countries"]) for p in data["region_presets"]] == [
            (p["key"], p["countries"]) for p in REGION_PRESETS
        ]
        if language == "en":
            assert {"id": 16, "label": "Animation"} in data["movie_genres"]
            assert data["country_names"]["CN"] == "Mainland China"
            assert not re.search(r"[\u3400-\u9fff]", str(data))
        else:
            assert data == {
                "movie_genres": [
                    {"id": key, "label": value} for key, value in MOVIE_GENRES.items()
                ],
                "tv_genres": [{"id": key, "label": value} for key, value in TV_GENRES.items()],
                "country_names": COUNTRY_NAMES,
                "region_presets": REGION_PRESETS,
            }
        assert original == (MOVIE_GENRES, TV_GENRES, COUNTRY_NAMES, REGION_PRESETS)


def test_routing_label_catalog_covers_every_static_option():
    from movieclaw_api.i18n import media_labels, messages
    from movieclaw_media.genres import COUNTRY_NAMES, MOVIE_GENRES, REGION_PRESETS, TV_GENRES

    assert media_labels._GENRE_MESSAGE_KEYS.keys() == (MOVIE_GENRES | TV_GENRES).keys()
    assert media_labels._COUNTRY_MESSAGE_KEYS.keys() == COUNTRY_NAMES.keys()
    assert media_labels._PRESET_MESSAGE_KEYS.keys() == {p["key"] for p in REGION_PRESETS}
    for locale in ("en", "zh-Hans"):
        for labels in (
            media_labels._GENRE_MESSAGE_KEYS,
            media_labels._COUNTRY_MESSAGE_KEYS,
            media_labels._PRESET_MESSAGE_KEYS,
        ):
            assert set(labels.values()) <= messages(locale).keys()
    assert media_labels.genre_label("movie", 10759) == "10759"
    assert media_labels.genre_label("tv", 28) == "28"

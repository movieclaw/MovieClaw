"""Request-local labels for library criteria; stored genre IDs and country codes stay neutral."""

from babel import Locale

from movieclaw_api.i18n import current_locale, t
from movieclaw_api.i18n.stored import reference
from movieclaw_media.genres import COUNTRY_NAMES, MOVIE_GENRES, REGION_PRESETS, TV_GENRES

_GENRE_MESSAGE_KEYS = {
    28: "media.genres.action",
    12: "media.genres.adventure",
    16: "media.genres.animation",
    35: "media.genres.comedy",
    80: "media.genres.crime",
    99: "media.genres.documentary",
    18: "media.genres.drama",
    10751: "media.genres.family",
    14: "media.genres.fantasy",
    36: "media.genres.history",
    27: "media.genres.horror",
    10402: "media.genres.music",
    9648: "media.genres.mystery",
    10749: "media.genres.romance",
    878: "media.genres.scienceFiction",
    10770: "media.genres.tvMovie",
    53: "media.genres.thriller",
    10752: "media.genres.war",
    37: "media.genres.western",
    10759: "media.genres.actionAdventure",
    10762: "media.genres.kids",
    10763: "media.genres.news",
    10764: "media.genres.reality",
    10765: "media.genres.scienceFictionFantasy",
    10766: "media.genres.soap",
    10767: "media.genres.talk",
    10768: "media.genres.warPolitics",
}

_COUNTRY_MESSAGE_KEYS = {
    "CN": "media.regions.mainlandChina",
    "HK": "media.regions.hongKong",
    "TW": "media.regions.taiwan",
    "SG": "media.regions.singapore",
    "JP": "media.regions.japan",
    "KR": "media.regions.southKorea",
    "US": "media.regions.unitedStates",
    "GB": "media.regions.unitedKingdom",
    "FR": "media.regions.france",
    "DE": "media.regions.germany",
    "IT": "media.regions.italy",
    "ES": "media.regions.spain",
    "CA": "media.regions.canada",
    "AU": "media.regions.australia",
    "NZ": "media.regions.newZealand",
    "IE": "media.regions.ireland",
    "IN": "media.regions.india",
    "TH": "media.regions.thailand",
    "RU": "media.regions.russia",
}

_PRESET_MESSAGE_KEYS = {
    "mainland": "library.routing.mainland",
    "hk_tw": "library.routing.hongKongTaiwan",
    "jp_kr": "library.routing.japanKorea",
    "us": "library.routing.unitedStates",
    "europe": "library.routing.europe",
    "minor_lang": "library.routing.otherLanguages",
}


def genre_reference(kind: str, genre_id: int) -> dict | str:
    genres = MOVIE_GENRES if kind == "movie" else TV_GENRES
    return reference(_GENRE_MESSAGE_KEYS[genre_id]) if genre_id in genres else str(genre_id)


def country_reference(code: str) -> dict | str:
    key = _COUNTRY_MESSAGE_KEYS.get(code)
    return reference(key) if key else code


def genre_label(kind: str, genre_id: int) -> str:
    genres = MOVIE_GENRES if kind == "movie" else TV_GENRES
    return t(_GENRE_MESSAGE_KEYS[genre_id]) if genre_id in genres else str(genre_id)


def country_label(code: str) -> str:
    """常用地区走消息键（与筛选面板同名），其余用 CLDR 的本地化名，再不认识的原样给代码。"""
    key = _COUNTRY_MESSAGE_KEYS.get(code)
    if key:
        return t(key)
    return Locale.parse(current_locale.get(), sep="-").territories.get(code, code)


def routing_options_labels() -> dict:
    return {
        "movie_genres": [
            {"id": value, "label": genre_label("movie", value)} for value in MOVIE_GENRES
        ],
        "tv_genres": [{"id": value, "label": genre_label("tv", value)} for value in TV_GENRES],
        "region_presets": [
            {**preset, "label": t(_PRESET_MESSAGE_KEYS[preset["key"]])} for preset in REGION_PRESETS
        ],
        "country_names": {code: t(_COUNTRY_MESSAGE_KEYS[code]) for code in COUNTRY_NAMES},
    }

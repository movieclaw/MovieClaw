"""Display labels at rendering boundaries; domain identifiers remain unchanged."""

from movieclaw_api.i18n import t

LANGUAGES = {
    "zh": "media.language.zh",
    "yue": "media.language.yue",
    "en": "media.language.en",
    "ja": "media.language.ja",
    "ko": "media.language.ko",
    "fr": "media.language.fr",
    "de": "media.language.de",
    "es": "media.language.es",
    "it": "media.language.it",
    "ru": "media.language.ru",
    "pt": "media.language.pt",
    "hi": "media.language.hi",
    "th": "media.language.th",
    "sv": "media.language.sv",
    "da": "media.language.da",
    "no": "media.language.no",
    "nl": "media.language.nl",
    "pl": "media.language.pl",
    "tr": "media.language.tr",
}
DEVICE_KINDS = {
    "web": "auth.deviceKind.web",
    "ios": "auth.deviceKind.ios",
    "tvos": "auth.deviceKind.tvos",
    "macos": "auth.deviceKind.macos",
    "android": "auth.deviceKind.android",
    "androidtv": "auth.deviceKind.androidtv",
    "cli": "auth.deviceKind.cli",
    "worker": "auth.deviceKind.worker",
    "manual": "auth.deviceKind.manual",
    "player": "auth.deviceKind.player",
}


def language_name(code: str | None) -> str:
    if not code:
        return t("media.language.foreign")
    code = "yue" if code == "cn" else code
    key = LANGUAGES.get(code)
    return t(key) if key else code


def device_kind(kind: str, fallback: str | None = None) -> str:
    key = DEVICE_KINDS.get(kind)
    return t(key) if key else fallback or kind

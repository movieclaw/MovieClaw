"""Smart presentation follows the reader; quality and understood languages do not."""

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.services.subscription.smart_presentation import smart_presentation
from movieclaw_matcher.smart import SmartPreferences
from movieclaw_matcher.smart_memory import (
    LANGUAGE_LABELS,
    SmartFacts,
    SmartMemory,
    language_reference,
    resolve,
    scope_reference,
)

from . import test_smart_memory_routes as memory

client = memory.client


def test_same_result_renders_both_languages_without_translating_user_metadata():
    resolved = resolve(
        SmartPreferences(wait_seconds=86400),
        SmartFacts(kind="tv", title="我的电影", language="ja", region="US", network="所有剧集"),
        SmartMemory(),
    )
    original = resolved.model_dump()
    with use_locale("en"):
        english = smart_presentation(resolved)
        assert english["quality_label"] == "Prefer 4K WEB-DL"
        assert english["scope_options"][-1]["label"] == "所有剧集 series"
        assert english["subtitle_line"] == "Japanese · Only releases with Chinese subtitles"
    with use_locale("zh-Hans"):
        assert smart_presentation(resolved) == original
    assert resolved.model_dump() == original


def test_known_language_and_country_references_exist_and_unknown_values_stay_raw():
    for locale in ("en", "zh-Hans"):
        with use_locale(locale):
            for code in LANGUAGE_LABELS:
                assert render_value(language_reference(code))
            for code in (
                "CN",
                "HK",
                "TW",
                "SG",
                "JP",
                "KR",
                "US",
                "GB",
                "FR",
                "DE",
                "IT",
                "ES",
                "CA",
                "AU",
                "NZ",
                "IE",
                "IN",
                "TH",
                "RU",
            ):
                assert render_value(scope_reference("region", code, "tv"))
            assert render_value(language_reference("unknown-code")) == "unknown-code"
            assert "ZZ" in render_value(scope_reference("region", "ZZ", "movie"))


def _read(client, method, path, locale="en", **kwargs):
    response = getattr(client, method)(
        memory.BASE + path, headers={"Accept-Language": locale}, **kwargs
    )
    return memory._data(response)


def test_preview_and_language_memory_are_reader_specific_without_changing_policy(client):
    memory._defaults(client, resolution="1080p", source="blu-ray", strict_resolution=True)
    original = memory._preview(client, "tmdb:movie:701")
    for locale in ("en", "zh-Hans", "en"):
        plan = _read(
            client, "post", "/title-preview", locale, json={"title_ref": "tmdb:movie:701"}
        )["smart"]
        assert plan["resolution"] == original["resolution"] == "1080p"
        assert plan["source"] == original["source"] == "blu-ray"
        if locale == "en":
            assert plan["quality_label"] == "Prefer 1080p Blu-ray"
            assert (
                plan["wait_label"]
                == "Wait up to 1 day · Stop upgrading at the target · Only accept 1080p"
            )
            assert plan["subtitle_line"] == "English · Only releases with Chinese subtitles"
            assert (
                plan["question"]["prompt"] == "This title is in English. Require Chinese subtitles?"
            )
            assert plan["question"]["understood_label"] == "No, I understand English"
            assert [option["label"] for option in plan["scope_options"]] == [
                "Only this title",
                "All movies",
                "Movies from the United States",
            ]
        else:
            assert plan == original
    sub = memory._subscribe(client, "tmdb:movie:701", original, smart_language_answer="subtitles")
    assert sub["smart_policy"]["watchable_languages"] == ["zh"]
    record = _read(client, "get", "/smart-memory")
    assert record["languages"] == [
        {"key": "zh", "label": "Chinese", "removable": False, "source_title": None}
    ]
    _read(
        client,
        "patch",
        "/smart-memory",
        json={"revision": record["revision"], "language": "en", "understood": True},
    )
    english = _read(client, "get", f"/{sub['id']}")
    chinese = _read(client, "get", f"/{sub['id']}", "zh-Hans")
    assert english["smart_policy"] == chinese["smart_policy"]
    assert english["smart_policy"]["watchable_languages"] == []
    assert english["smart_subtitle"]["line"] == "English · Subtitles not required"
    assert chinese["smart_subtitle"]["line"] == "英语 · 不需要字幕"
    english_events = _read(client, "get", f"/{sub['id']}/activities")
    chinese_events = _read(client, "get", f"/{sub['id']}/activities", "zh-Hans")
    english_event = next(item for item in english_events if item["type"] == "adjusted")
    chinese_event = next(item for item in chinese_events if item["id"] == english_event["id"])
    assert english_event["message_key"] == "subscription.smart.policyAdjusted"
    assert english_event["message"].startswith("Following current smart settings and memory:")
    assert chinese_event["message"].startswith("已跟随当前智能设置与记忆：")


def test_habit_sources_and_shadow_labels_follow_the_reader(client):
    memory._defaults(client)
    korean = memory._preview(client, "tmdb:tv:801")
    memory._subscribe(
        client, "tmdb:tv:801", korean, smart_resolution="1080p", smart_scope="region:tv:KR"
    )
    netflix = memory._preview(client, "tmdb:tv:803")
    memory._subscribe(
        client, "tmdb:tv:803", netflix, smart_resolution="2160p", smart_scope="network:tv:Netflix"
    )
    for locale, note, shadow in (
        ("en", "Using the “Netflix series” preference", "“Series from South Korea” prefers 1080p"),
        ("zh-Hans", "按「Netflix 的剧」的习惯", "「韩国的剧」是 1080p"),
    ):
        plan = _read(client, "post", "/title-preview", locale, json={"title_ref": "tmdb:tv:806"})[
            "smart"
        ]
        assert plan["quality_note"] == note and plan["quality_shadow"] == shadow
        assert plan["resolution"] == "2160p"
    record = _read(client, "get", "/smart-memory")
    assert [row["label"] for row in record["habits"]] == [
        "Series from South Korea",
        "Netflix series",
    ]
    assert [row["source_title"] for row in record["habits"]] == ["请回答1988", "鱿鱼游戏"]

"""Track-choice reasons are localized at read time while choices and memory stay stable."""

from . import test_playback_default_tracks as tracks

client = tracks.client


def test_default_track_explanations_follow_each_reader(client, tmp_path):
    library_id, item_id = tracks.seed(client, tmp_path)
    signatures = []
    for locale, audio, subtitle in (
        ("en", "Original audio", "Subtitles in the library language"),
        ("zh-Hans", "影片原声", "媒体库语言的字幕"),
        ("en", "Original audio", "Subtitles in the library language"),
    ):
        response = client.get(
            f"/api/v1/libraries/{library_id}/items/{item_id}",
            headers={"Accept-Language": locale},
        )
        assert response.status_code == 200, response.text
        defaults = response.json()["data"]["files"][0]["playback_defaults"]
        assert defaults["audio_note"] == audio
        assert defaults["subtitle_note"] == subtitle
        signatures.append({k: v for k, v in defaults.items() if not k.endswith("_note")})
    assert signatures[0] == signatures[1] == signatures[2]
    tracks.report(client, item_id, event="start", audio_track="embedded:0", subtitle_track="off")
    for locale, expected in (
        ("en", "You turned subtitles off last time"),
        ("zh-Hans", "你上次看时关掉了字幕"),
    ):
        response = client.get(
            f"/api/v1/libraries/{library_id}/items/{item_id}",
            headers={"Accept-Language": locale},
        )
        defaults = response.json()["data"]["files"][0]["playback_defaults"]
        assert defaults["audio_track"] == "embedded:0"
        assert defaults["subtitle_track"] is None
        assert defaults["subtitle_note"] == expected
    assert tracks.remembered(client, item_id) == ("embedded:0", "off")


def test_all_track_default_reason_keys_exist_in_both_languages():
    from movieclaw_api.i18n import messages
    from movieclaw_api.services.playback.track_defaults import (
        _AUDIO_NOTES,
        _SUBTITLE_NOTES,
        _SUBTITLE_OFF_NOTES,
    )

    keys = (
        set(_AUDIO_NOTES.values())
        | set(_SUBTITLE_NOTES.values())
        | set(_SUBTITLE_OFF_NOTES.values())
    )
    for locale in ("en", "zh-Hans"):
        assert keys <= messages(locale).keys()

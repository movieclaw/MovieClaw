from copy import deepcopy

from movieclaw_api.i18n import use_locale
from movieclaw_api.services.playback.plan import to_view
from movieclaw_playback.capability import AudioSupport, ClientCapability, VideoSupport
from movieclaw_playback.decide import (
    AudioTrack,
    MediaProfile,
    PlaybackPolicy,
    decide_playback,
)

from . import test_playback_stream as streaming

stream_client = streaming.client


def test_activity_renders_the_same_session_reason_for_each_reader(stream_client, tmp_path):
    file_id = streaming.seed(stream_client, tmp_path, container="mkv")
    streaming.start_session(stream_client, file_id, device_id="browser-i18n")
    response = stream_client.post(
        "/api/v1/playback/progress",
        json={
            "media_item_id": streaming._item_id_of(stream_client, file_id),
            "event": "start",
            "device_id": "browser-i18n",
        },
    )
    assert response.status_code == 200, response.text
    for locale, label, reason in [
        ("en", "Remux", "Video codec H264 can be copied"),
        ("zh-Hans", "重封装", "视频编码 H264 可直通"),
    ]:
        response = stream_client.get(
            "/api/v1/playback/activity", headers={"Accept-Language": locale}
        )
        assert response.status_code == 200, response.text
        delivery = response.json()["data"]["sessions"][0]["delivery"]
        assert delivery["label"] == label
        assert isinstance(delivery["reason"], str)
        assert reason in delivery["reason"]


def test_same_playback_decision_can_render_in_multiple_languages_without_mutation():
    decision = decide_playback(
        MediaProfile(
            file_id=1,
            container="mp4",
            video_codec="h264",
            audio_tracks=(AudioTrack(ref="embedded:0", codec="aac", channels=2),),
        ),
        ClientCapability(
            video=(VideoSupport("h264"),),
            audio=(AudioSupport("aac"),),
            containers=frozenset({"mp4"}),
        ),
        PlaybackPolicy(),
        can_self_enable=True,
    )
    original = deepcopy(decision)
    for locale, reason in [
        ("en", "Video codec H264 can be copied; Audio codec AAC can be copied"),
        ("zh-Hans", "视频编码 H264 可直通；音轨 AAC 可直通"),
        ("en", "Video codec H264 can be copied; Audio codec AAC can be copied"),
    ]:
        with use_locale(locale):
            assert to_view(decision).reason == reason
        assert decision == original


def test_playback_start_error_preserves_its_nested_reference():
    from movieclaw_api.exceptions import ServiceUnavailableException, exception_fields
    from movieclaw_api.i18n.stored import reference
    from movieclaw_api.services.playback.session import SessionStartError

    with use_locale("zh-Hans"):
        error = SessionStartError(reference("errors.playback.processStart", reason="No such file"))
        assert str(error) == "转码进程启动失败：No such file"
    with use_locale("en"):
        http_error = ServiceUnavailableException(
            message_key="errors.playback.startFailed", params={"reason": exception_fields(error)}
        )
        assert http_error.message == (
            "Playback failed to start: The transcoding process failed to start: No such file"
        )


def test_transcode_executor_classification_is_independent_of_reader_language():
    from movieclaw_api.services.playback_activity import _delivery_view
    from movieclaw_playback.decide import AudioPlan, VideoPlan

    from .test_playback_activity import _fake_transcode

    video = VideoPlan(action="transcode", codec="h264", height=1080)
    for kind, options in [
        ("software", {}),
        ("hardware", {"hw": "qsv"}),
        ("remote", {"hw": "videotoolbox", "remote": True, "worker": "raw-worker"}),
    ]:
        session = _fake_transcode(video, AudioPlan(action="copy"), **options)
        views = []
        for locale in ("en", "zh-Hans", "en"):
            with use_locale(locale):
                view = _delivery_view(session, streaming=True)
            assert view.mode == "transcode" and view.execution_kind == kind
            views.append(view)
        assert views[0] == views[2]
        assert views[0].label != views[1].label
        assert views[0].target == views[1].target
    assert _delivery_view(None, streaming=True).execution_kind is None

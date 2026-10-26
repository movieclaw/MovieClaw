"""Playback diagnostics translate MovieClaw's own sentences and pass third-party text through."""

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value, source_render
from movieclaw_api.services.playback.hwprobe import BACKEND_LABELS, _explain_failure
from movieclaw_api.services.playback.qoe import REASON_LABELS, SOURCE_CLASS_LABELS, _label
from movieclaw_api.services.playback.remote_worker import RemoteWorkerUnavailable
from movieclaw_api.services.playback.session import _remote_job_failure_message


def test_hardware_probe_explanations_render_per_reader():
    detail = _explain_failure("vaapi: Permission denied")
    assert source_render(detail).startswith("驱动报权限不足")
    with use_locale("en"):
        assert render_value(detail).startswith("The driver reports insufficient permissions")
        assert render_value(BACKEND_LABELS["qsv"]) == "Intel integrated graphics (QSV)"
    fallback = _explain_failure("some unknown ffmpeg error")
    with use_locale("en"):
        assert render_value(fallback) == (
            "The hardware encoding probe failed: some unknown ffmpeg error"
        )


def test_remote_failure_keeps_worker_text_and_translates_our_own():
    own = _remote_job_failure_message({"exit_code": 1, "stderr_tail": "boom"})
    assert source_render(own) == (
        "远程 Worker 未产出请求的分片；ffmpeg 退出码：1；ffmpeg stderr：boom"
    )
    with use_locale("en"):
        assert render_value(own) == (
            "The remote worker didn’t produce the requested segment; ffmpeg exit code: 1; "
            "ffmpeg stderr: boom"
        )
    # Worker 自己的话原样保留；它已经说过退出码就不再重复
    worker = _remote_job_failure_message({"error": "ffmpeg 退出码：9", "exit_code": 9})
    with use_locale("en"):
        assert render_value(worker) == "ffmpeg 退出码：9"


def test_worker_unavailable_carries_reference():
    exc = RemoteWorkerUnavailable("player.worker.segmentTooOld", type="mpegts")
    assert "不支持 mpegts 分片" in str(exc)
    with use_locale("en"):
        assert render_value(exc.ref).startswith(
            "The online worker is too old or doesn’t support mpegts"
        )


def test_qoe_labels_follow_reader_and_keep_spec_names():
    with use_locale("en"):
        assert _label(REASON_LABELS, "startup_slow") == "Slow start"
        assert _label(SOURCE_CLASS_LABELS, "bluray") == "Blu-ray disc"
        assert _label(SOURCE_CLASS_LABELS, "4k") == "4K"
        assert _label(SOURCE_CLASS_LABELS, "mystery") == "mystery"

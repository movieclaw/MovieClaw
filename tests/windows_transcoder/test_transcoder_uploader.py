"""产物回传：带重试的常驻连接，以及把分片化 MP4 切段、分块传给 NAS 的上传线程。

对端是 ``miniserver.FakeNas``：记录每次 PUT 的名字、query 与请求体，并按脚本回状态码。
真实 NAS 端点（原子追加 ``.segNNNNN.m4s.partial``、``final=1`` 时改名）的行为由
``tests/playback/test_windows_transcoder_e2e.py`` 的端到端覆盖。
"""

from __future__ import annotations

import pytest
from fmp4 import fragment, init_segment, video_stream
from miniserver import FakeNas, Upload, wait_until
from movieclaw_transcoder import uploader
from movieclaw_transcoder.uploader import (
    MAX_ATTEMPTS,
    ArtifactClient,
    ProgressiveUploader,
    split_artifact_url,
)

TOKEN = "token=tok"


@pytest.fixture(autouse=True)
def no_retry_delay(monkeypatch):
    """重试的退避总共约 7.5 秒：测试里压成 0，重试次数照旧。"""
    monkeypatch.setattr(uploader, "RETRY_DELAYS", (0.0, 0.0, 0.0, 0.0))


# -- 地址 ------------------------------------------------------------------


def test_split_artifact_url_separates_the_directory_from_the_signed_query():
    url = (
        "https://nas.example/api/v1/transcode-worker/sessions/S1/artifacts/stream.mp4?token=abc&x=1"
    )

    assert split_artifact_url(url) == (
        "https://nas.example/api/v1/transcode-worker/sessions/S1/artifacts",
        "token=abc&x=1",
    )


def test_split_artifact_url_keeps_a_reverse_proxy_prefix():
    url = "https://host/movieclaw/api/v1/transcode-worker/sessions/S1/artifacts/stream.mp4?token=t"

    assert split_artifact_url(url) == (
        "https://host/movieclaw/api/v1/transcode-worker/sessions/S1/artifacts",
        "token=t",
    )


@pytest.mark.parametrize(
    "url",
    ["ftp://x/artifacts/a.mp4", "http://x/other/a.mp4?token=t", "not a url", "/artifacts/a.mp4"],
)
def test_split_artifact_url_rejects_what_is_not_an_artifact_address(url):
    assert split_artifact_url(url) is None


# -- 带重试的连接 ------------------------------------------------------------


def test_put_sends_the_signed_query_and_the_part_flags():
    with FakeNas() as nas:
        client = ArtifactClient(nas.base_url, TOKEN)
        assert client.put("init.mp4", b"INIT").ok
        assert client.put("seg00007.m4s", b"abc", part=3).ok
        assert client.put("seg00007.m4s", b"", part=4, final=True).ok
        client.close()

    assert [(u.name, u.query, u.body) for u in nas.uploads] == [
        ("init.mp4", {"token": "tok"}, b"INIT"),
        ("seg00007.m4s", {"token": "tok", "part": "3"}, b"abc"),
        ("seg00007.m4s", {"token": "tok", "part": "4", "final": "1"}, b""),
    ]


def test_the_connection_is_kept_alive_across_uploads():
    """分片按秒级节奏产出：逐个新建连接会让每次上传都重做握手，落在起播和 seek 最怕延迟的时刻。"""
    with FakeNas() as nas:
        client = ArtifactClient(nas.base_url, TOKEN)
        for part in range(5):
            assert client.put("seg00000.m4s", b"x", part=part).ok
        client.close()

    assert nas.connections == 1


def test_transient_errors_are_retried_until_the_upload_goes_through():
    statuses = iter([503, 502, 201])
    with FakeNas(lambda _upload: next(statuses)) as nas:
        result = ArtifactClient(nas.base_url, TOKEN).put("init.mp4", b"x")

    assert result.ok and result.attempts == 3
    assert [upload.status for upload in nas.uploads] == [503, 502, 201]


def test_a_client_error_is_not_retried():
    """409 = 中间缺了一块：重试同一块没有用，要由上层改成整段重传。"""
    with FakeNas(lambda _upload: 409) as nas:
        result = ArtifactClient(nas.base_url, TOKEN).put("seg00000.m4s", b"x", part=2)

    assert (result.ok, result.status, result.attempts) == (False, 409, 1)
    assert result.message == "NAS 返回 HTTP 409"
    assert len(nas.uploads) == 1


def test_retries_stop_at_the_attempt_limit():
    with FakeNas(lambda _upload: 503) as nas:
        result = ArtifactClient(nas.base_url, TOKEN).put("init.mp4", b"x")

    assert (result.ok, result.status, result.attempts) == (False, 503, MAX_ATTEMPTS)
    assert len(nas.uploads) == MAX_ATTEMPTS


def test_an_unreachable_nas_is_reported_as_a_bad_gateway(monkeypatch):
    monkeypatch.setattr(uploader, "MAX_ATTEMPTS", 2)  # Windows 上每次被拒的连接要等约 2 秒
    with FakeNas() as nas:
        base_url = nas.base_url

    result = ArtifactClient(base_url, TOKEN).put("init.mp4", b"x")

    assert (result.ok, result.status, result.attempts) == (False, 502, 2)
    assert result.message is not None and "连接 NAS 失败" in result.message


def test_a_cancelled_upload_makes_no_request():
    with FakeNas() as nas:
        result = ArtifactClient(nas.base_url, TOKEN, cancelled=lambda: True).put("init.mp4", b"x")

    assert (result.status, result.attempts) == (499, 1)
    assert nas.uploads == []


def test_cancelling_between_retries_stops_retrying():
    cancelled = {"now": False}

    def respond(_upload: Upload) -> int:
        cancelled["now"] = True  # 第一次失败后任务被叫停
        return 503

    with FakeNas(respond) as nas:
        client = ArtifactClient(nas.base_url, TOKEN, cancelled=lambda: cancelled["now"])
        result = client.put("init.mp4", b"x")

    assert (result.status, result.attempts) == (499, 2)
    assert len(nas.uploads) == 1


# -- 切段并分块回传 -----------------------------------------------------------


class Run:
    """一个接着模拟 NAS 的 ProgressiveUploader，并收集两个回调。"""

    def __init__(self, nas: FakeNas, *, start_segment: int | None = 5) -> None:
        self.abandoned: list[tuple[str, int, str]] = []
        self.uploaded: list[str] = []
        self.uploader = ProgressiveUploader(
            ArtifactClient(nas.base_url, TOKEN),
            segment_seconds=4.0,
            start_segment=start_segment,
            on_abandoned=lambda *args: self.abandoned.append(args),
            on_uploaded=self.uploaded.append,
        )
        self.uploader.start()


def segment_fragments(seconds: float = 12, gop_ms: int = 2000) -> dict[int, list[bytes]]:
    """``video_stream`` 切完后每一段包含的片段字节（起转分片号 5，段长 4 秒）。"""
    per_segment = int(4000 / 500)
    frames = [
        fragment(start_ms=t, sync=t % gop_ms == 0) for t in range(0, int(seconds * 1000), 500)
    ]
    return {5 + i: frames[i * per_segment : (i + 1) * per_segment] for i in range(len(frames) // 8)}


def test_a_stream_goes_up_as_init_then_one_part_per_fragment_and_a_closing_part_per_segment():
    with FakeNas() as nas:
        run = Run(nas)
        assert run.uploader.feed(video_stream(seconds=12)) is None
        assert run.uploader.finish(10.0)

    expected: list[tuple[str, int | None, bool]] = [("init.mp4", None, False)]
    for segment in (5, 6, 7):
        name = f"seg{segment:05d}.m4s"
        expected += [(name, part, False) for part in range(8)] + [(name, 8, True)]
    assert [(u.name, u.part, u.final) for u in nas.uploads] == expected
    assert run.abandoned == []
    # init 与每个分片的第一块传上去时通知任务层（它拿去记起播分段计时）
    assert run.uploaded == ["init.mp4", "seg00005.m4s", "seg00006.m4s", "seg00007.m4s"]
    # 内容：init 整个传；同一分片各块按序拼起来就是切出来的片段；收尾块是空的
    assert nas.named("init.mp4")[0].body == init_segment(with_audio=False)
    for segment, frames in segment_fragments().items():
        parts = nas.named(f"seg{segment:05d}.m4s")
        assert [u.body for u in parts[:-1]] == frames
        assert parts[-1].body == b""


def test_a_rejected_part_sends_the_whole_segment_when_it_is_finished():
    """某一块传不上去（409 说中间缺了一块）：这一段不再分块，转完把攒着的整段一次传上去——
    NAS 那边的半截随之作废。其余分片不受影响。"""

    def respond(upload: Upload) -> int:
        return 409 if (upload.name == "seg00005.m4s" and upload.part == 3) else 201

    with FakeNas(respond) as nas:
        run = Run(nas)
        run.uploader.feed(video_stream(seconds=12))
        assert run.uploader.finish(10.0)

    broken = nas.named("seg00005.m4s")
    assert [(u.part, u.final, u.status) for u in broken] == [
        (0, False, 201),
        (1, False, 201),
        (2, False, 201),
        (3, False, 409),
        (None, False, 201),  # 整段重传：没有 part 参数
    ]
    assert broken[-1].body == b"".join(segment_fragments()[5])
    assert nas.named("seg00006.m4s")[-1].final  # 下一段照常分块
    assert run.abandoned == []


def test_a_rejected_closing_part_also_falls_back_to_the_whole_segment():
    def respond(upload: Upload) -> int:
        return 409 if (upload.name == "seg00006.m4s" and upload.final) else 201

    with FakeNas(respond) as nas:
        run = Run(nas)
        run.uploader.feed(video_stream(seconds=12))
        assert run.uploader.finish(10.0)

    resent = nas.named("seg00006.m4s")[-1]
    assert (resent.part, resent.final, resent.status) == (None, False, 201)
    assert resent.body == b"".join(segment_fragments()[6])


def test_an_upload_that_runs_out_of_retries_is_reported_as_abandoned():
    """重试用尽：交给任务层上报 job.artifact_failed，NAS 按补片台账从这一片重启。"""
    with FakeNas(lambda upload: 503 if upload.name == "init.mp4" else 201) as nas:
        run = Run(nas)
        run.uploader.feed(video_stream(seconds=4))
        assert run.uploader.finish(10.0)

    assert run.abandoned == [("init.mp4", 503, "NAS 返回 HTTP 503")]
    assert "init.mp4" not in run.uploaded
    assert len(nas.named("init.mp4")) == MAX_ATTEMPTS


def test_cancel_stops_uploading_and_never_sends_the_closing_part():
    with FakeNas() as nas:
        run = Run(nas)
        run.uploader.feed(init_segment(with_audio=False) + fragment(start_ms=0))
        wait_until(lambda: len(nas.uploads) >= 2, what="init 与第一块传到")
        run.uploader.cancel()
        run.uploader._thread.join(5.0)

    assert not run.uploader._thread.is_alive()
    assert not any(upload.final for upload in nas.uploads)


def test_feed_reports_a_stream_too_broken_to_cut():
    with FakeNas() as nas:
        run = Run(nas)
        reason = run.uploader.feed(init_segment(with_audio=False) + b"\x7f\xff\xff\xffjunk")
        run.uploader.cancel()

    assert reason is not None and "长度不合理" in reason

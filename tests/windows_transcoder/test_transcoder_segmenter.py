"""分片器：把 ffmpeg 写出的分片化 MP4 流切成 init 与按 HLS 栅格归段的片段。

切段规则与 macOS 转码器的 ``ProgressiveSegments.swift`` 一致，这是播放列表与分片能对上的前提：
第一段的编号是 NAS 给的起转分片号；之后从这一轮第一帧起算，满一格后的第一个同步帧开新的一段。
流用 ``fmp4.py`` 手工拼，每个边界都能精确构造，不需要 ffmpeg。
"""

from __future__ import annotations

import struct

import pytest
from fmp4 import fragment, init_segment, video_stream
from movieclaw_transcoder.segmenter import FragmentOutput, FragmentSegmenter

SEGMENT_SECONDS = 4.0


def run(data: bytes, *, start_segment: int | None = 5) -> list[FragmentOutput]:
    return FragmentSegmenter(SEGMENT_SECONDS, start_segment).append(data)


def fragments(outputs: list[FragmentOutput]) -> list[FragmentOutput]:
    return [output for output in outputs if output.kind == "fragment"]


def segment_starts(outputs: list[FragmentOutput], step_ms: int = 500) -> dict[int, float]:
    """每个分片号是从第几秒的片段开始的（流里的片段每 ``step_ms`` 一个、按序排列）。"""
    starts: dict[int, float] = {}
    for index, output in enumerate(fragments(outputs)):
        if output.starts_segment:
            assert output.segment is not None
            starts[output.segment] = index * step_ms / 1000
    return starts


def test_init_segment_is_ftyp_plus_moov_and_comes_first():
    outputs = run(video_stream(seconds=1))

    assert outputs[0].kind == "init"
    assert outputs[0].segment is None
    assert outputs[0].data == init_segment(with_audio=False)
    assert all(output.kind == "fragment" for output in outputs[1:])


def test_segments_follow_the_grid_and_numbering_starts_at_the_given_segment():
    """12 秒、GOP 2 秒、每 4 秒一格：第 5、6、7 段各 8 个 0.5 秒的片段，每段第一个片段开段。"""
    outputs = run(video_stream(seconds=12, gop_ms=2000), start_segment=5)

    by_segment: dict[int, list[bytes]] = {}
    for output in fragments(outputs):
        assert output.segment is not None
        by_segment.setdefault(output.segment, []).append(output.data)
    expected = {
        5: range(0, 4000, 500),
        6: range(4000, 8000, 500),
        7: range(8000, 12000, 500),
    }
    assert by_segment == {
        segment: [fragment(start_ms=t, sync=t % 2000 == 0) for t in times]
        for segment, times in expected.items()
    }
    assert segment_starts(outputs) == {5: 0.0, 6: 4.0, 7: 8.0}


def test_a_segment_is_extended_to_the_next_sync_frame_when_the_grid_line_has_none():
    """GOP 3 秒、4 秒一格：3 秒处的同步帧还没满一格，4 秒处没有同步帧，所以第 1 段从 6 秒起——
    分片比播放列表声明的长。这就是编码器必须把 -force_key_frames 落成真 IDR 的原因。"""
    outputs = run(video_stream(seconds=15, gop_ms=3000), start_segment=0)

    assert segment_starts(outputs) == {0: 0.0, 1: 6.0, 2: 9.0, 3: 12.0}


def test_the_grid_is_anchored_on_the_first_frame_not_on_zero():
    """seek 重启后这一轮的第一帧不在栅格线上（1.5 秒）：栅格从它起算，4.0 秒处的同步帧不算数。"""
    outputs = run(video_stream(seconds=12, gop_ms=2000, offset_ms=1500), start_segment=3)

    # 同步帧在 1.5、3.5、5.5、7.5、9.5…；满一格 = 5.499 → 5.5 秒；再满一格 = 9.499 → 9.5 秒
    assert segment_starts(outputs) == {3: 0.0, 4: 4.0, 5: 8.0}


def test_without_a_start_segment_the_first_frame_time_picks_the_index():
    outputs = run(video_stream(seconds=6, gop_ms=2000, offset_ms=8000), start_segment=None)

    assert fragments(outputs)[0].segment == 2  # round(8.0 / 4)
    assert segment_starts(outputs) == {2: 0.0, 3: 4.0}


@pytest.mark.parametrize("chunk", [1, 7, 1000])
def test_the_result_does_not_depend_on_how_the_bytes_arrive(chunk):
    data = video_stream(seconds=12, gop_ms=2000)
    whole = run(data)

    segmenter = FragmentSegmenter(SEGMENT_SECONDS, 5)
    pieces: list[FragmentOutput] = []
    for at in range(0, len(data), chunk):
        pieces += segmenter.append(data[at : at + chunk])

    assert pieces == whole


def test_audio_fragments_ahead_of_the_first_video_fragment_travel_with_it():
    audio_first = fragment(track_id=2, start_ms=0)
    video_first = fragment(track_id=1, start_ms=0)
    stream = init_segment() + audio_first + video_first

    outputs = run(stream)

    assert [output.kind for output in outputs] == ["init", "fragment"]
    assert outputs[1].data == audio_first + video_first
    assert outputs[1].starts_segment


def test_audio_fragments_never_start_a_segment_even_past_the_grid_line():
    stream = (
        init_segment()
        + fragment(track_id=1, start_ms=0)
        + fragment(track_id=2, start_ms=9000)  # 早就过了第一格，但它是音频
        + fragment(track_id=1, start_ms=500, sync=False)
    )

    outputs = fragments(run(stream))

    assert [(output.segment, output.starts_segment) for output in outputs] == [
        (5, True),
        (5, False),
        (5, False),
    ]


def test_a_non_sync_fragment_never_cuts_even_when_it_is_past_the_grid_line():
    stream = (
        init_segment(with_audio=False)
        + fragment(start_ms=0)
        + fragment(start_ms=4500, sync=False)  # 过了一格，但不是同步帧
        + fragment(start_ms=5000, sync=True)
    )

    outputs = fragments(run(stream))

    assert [(output.segment, output.starts_segment) for output in outputs] == [
        (5, True),
        (5, False),
        (6, True),
    ]


def test_the_cut_is_decided_on_presentation_time_not_decode_time():
    """带 B 帧的流里同步帧的 pts 比 dts 晚：3.9 秒起解码、pts 是 4.025 秒的帧已经满一格。"""
    with_offset = (
        init_segment(with_audio=False)
        + fragment(start_ms=0)
        + fragment(start_ms=3900, composition_ms=125)
    )
    without_offset = init_segment(with_audio=False) + fragment(start_ms=0) + fragment(start_ms=3900)
    negative_offset = (
        init_segment(with_audio=False)
        + fragment(start_ms=0)
        + fragment(start_ms=4100, composition_ms=-100)
    )

    assert segment_starts(run(with_offset), step_ms=3900) == {5: 0.0, 6: 3.9}
    assert segment_starts(run(without_offset), step_ms=3900) == {5: 0.0}
    assert segment_starts(run(negative_offset), step_ms=4100) == {5: 0.0, 6: 4.1}


def test_sync_flag_can_come_from_the_track_defaults_and_time_can_be_32_bit():
    sync = init_segment(with_audio=False) + fragment(start_ms=0, flags_in="tfhd", tfdt_version=0)
    stream = sync + fragment(start_ms=4000, flags_in="tfhd", tfdt_version=0)
    not_sync = sync + fragment(start_ms=4000, sync=False, flags_in="tfhd", tfdt_version=0)

    assert segment_starts(run(stream), step_ms=4000) == {5: 0.0, 6: 4.0}
    assert segment_starts(run(not_sync), step_ms=4000) == {5: 0.0}


def test_a_64_bit_box_size_is_read_and_the_box_passes_through_intact():
    big = fragment(start_ms=0, large_mdat=True, size=500)

    outputs = fragments(run(init_segment(with_audio=False) + big))

    assert [output.data for output in outputs] == [big]


@pytest.mark.parametrize(
    "garbage",
    [
        struct.pack(">I", 0x7FFFFFFF) + b"free",  # 大得离谱：流已经错位
        struct.pack(">I", 3) + b"free",  # 比盒头还小
    ],
    ids=["oversized", "undersized"],
)
def test_a_misaligned_stream_stops_with_a_reason_instead_of_buffering_forever(garbage):
    segmenter = FragmentSegmenter(SEGMENT_SECONDS, 5)
    segmenter.append(init_segment(with_audio=False) + fragment(start_ms=0))

    assert segmenter.append(garbage) == []

    assert segmenter.failure is not None and "长度不合理" in segmenter.failure
    # 之后喂什么都不再产出，也不抛异常
    assert segmenter.append(fragment(start_ms=500)) == []

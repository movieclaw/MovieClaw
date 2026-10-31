"""AI 字幕：没有任何可用字幕时从音轨识别台词（docs/design/subtitle-asr.md §9.1）。

识别子进程用假 worker 脚本代替（输出约定好的 JSON 行），翻译用假模型；真实模型的
用例只在本机放好模型文件时跑（``data/models/asr`` 或 ``MOVIECLAW_ASR_DIR``）。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import signal
import sys
import textwrap
import wave
from pathlib import Path

import numpy as np
import pytest

from movieclaw_api.services import media_extract
from movieclaw_api.services.subtitle_gen import asr, auto, extract, source, tasks, translate
from movieclaw_db.models import LibraryFile

CTX = translate.FilmContext(title="测试影片", year=2024, genres=["剧情"], overview="简介")
_AVAILABLE = asr.Capability(True, None, Path("/models/asr"), True)
_MISSING = asr.Capability(False, "model", Path("/models/asr"), True)


def _row(
    *,
    audio: list[dict] | None = None,
    subtitles: list[dict] | None = None,
    external: list[dict] | None = None,
    path: str = "/media/Movie.mkv",
) -> LibraryFile:
    row = LibraryFile(
        library_id=1,
        media_item_id=1,
        file_path=path,
        duration_seconds=7200,
        audio_streams=audio,
        subtitle_streams=subtitles if subtitles is not None else [],
        external_subtitles=external if external is not None else [],
        source="scanned",
    )
    row.id = 42
    return row


_ENGLISH_51 = {"codec": "eac3", "language": "eng", "channels": 6, "channel_layout": "5.1(side)"}


@pytest.fixture
def available(monkeypatch):
    monkeypatch.setattr(asr, "capability", lambda: _AVAILABLE)


# ---------------------------------------------------------------------------
# 规划：选音轨、判语言（纯计算）
# ---------------------------------------------------------------------------


def test_language_aliases_cover_track_tags_and_tmdb_codes() -> None:
    assert asr.normalize_language("eng") == ("en", None)
    assert asr.normalize_language("JPN") == ("ja", None)
    assert asr.normalize_language("cn") == ("yue", None)  # TMDB 的 cn 是粤语
    assert asr.normalize_language("zh") == ("zh", None)
    assert asr.normalize_language("und") == (None, None)
    assert asr.normalize_language(None) == (None, None)
    assert asr.normalize_language("fre") == (None, "fre")


def test_track_choice_prefers_original_language_and_skips_commentary() -> None:
    streams = [
        {"codec": "aac", "language": "chi", "title": "国语配音"},
        {"codec": "truehd", "language": "eng", "title": "Director's Commentary"},
        {"codec": None, "language": "eng"},  # ffmpeg 解不了（如 Audio Vivid）
        {"codec": "eac3", "language": "eng"},
    ]
    assert asr.choose_track(streams, "en") == 3
    # 原语言找不到合适的轨：用第一条能用的
    assert asr.choose_track(streams, "ja") == 0
    assert asr.choose_track([{"codec": None}], None) == 0


def test_plan_reads_language_from_track_before_metadata(available) -> None:
    plan = asr.plan_audio("/m.mkv", [_ENGLISH_51], "ja", remote=False)
    assert plan is not None
    assert (plan.index, plan.language, plan.language_token) == (0, "en", "eng")
    assert plan.center_channel and plan.refusal is None

    untagged = asr.plan_audio("/m.mkv", [{"codec": "aac", "language": "und"}], "cn", remote=False)
    assert untagged is not None and untagged.language == "yue" and untagged.language_token == "chi"

    unknown = asr.plan_audio("/m.mkv", [{"codec": "aac", "channels": 2}], None, remote=False)
    assert unknown is not None and unknown.language is None and unknown.refusal is None
    assert not unknown.center_channel


def test_plan_refuses_unsupported_language_remote_files_and_missing_runtime(monkeypatch) -> None:
    monkeypatch.setattr(asr, "capability", lambda: _AVAILABLE)
    french = asr.plan_audio("/m.mkv", [{"codec": "aac", "language": "fre"}], "fr", remote=False)
    assert french is not None and french.refusal == "asr_language" and french.raw_language == "fre"
    remote = asr.plan_audio("/m.strm", [_ENGLISH_51], "en", remote=True)
    assert remote is not None and remote.refusal == "asr_remote"

    monkeypatch.setattr(asr, "capability", lambda: _MISSING)
    missing = asr.plan_audio("/m.mkv", [_ENGLISH_51], "en", remote=False)
    assert missing is not None and missing.refusal == "asr_unavailable"
    assert asr.plan_audio("/m.mkv", [], "en", remote=False) is None


def test_center_channel_only_for_layouts_with_a_center() -> None:
    assert asr.wants_center({"channel_layout": "7.1"})
    assert asr.wants_center({"channels": 6})
    assert not asr.wants_center({"channel_layout": "stereo", "channels": 2})
    assert not asr.wants_center({"channel_layout": "quad", "channels": 4})


def test_estimate_uses_cpu_speed_class(monkeypatch) -> None:
    monkeypatch.setattr(asr, "capability", lambda: _AVAILABLE)
    assert asr.estimate_minutes(7200) == 15  # 8 倍实时
    monkeypatch.setattr(asr, "capability", lambda: asr.Capability(True, None, Path("/m"), False))
    assert asr.estimate_minutes(7200) == 40  # 没有 AVX2 先按 3 倍
    assert asr.estimate_minutes(None) == 1


# ---------------------------------------------------------------------------
# 断句（§4.3）
# ---------------------------------------------------------------------------


def _english(start: int, words: list[str], step: int = 300) -> asr.Segment:
    tokens = tuple(
        (("" if i == 0 else " ") + word, start + i * step) for i, word in enumerate(words)
    )
    return asr.Segment(start, start + len(words) * step + 300, " ".join(words), tokens)


def test_sentences_become_separate_cues_without_overlap() -> None:
    segment = _english(1000, ["Is", "he", "here?", "Yes,", "it's", "fine."])
    cues = asr.build_cues([segment], "eng")
    assert [text for _s, _e, text in cues] == ["Is he here?", "Yes, it's fine."]
    (s1, e1, _), (s2, e2, _) = cues
    assert s1 == 900  # 提前 0.1 秒出现
    assert e1 + 80 <= s2  # 条间留缝，不重叠
    assert e2 == segment.end_ms


def test_long_runs_are_cut_at_the_last_comma_or_pause() -> None:
    # 词各不相同：相同 token 连着出现会被当成识别复读折叠掉
    words = [f"w{i}" for i in range(10)] + ["comma,"] + [f"m{i}" for i in range(10)]
    cue_texts = [text for _s, _e, text in asr.build_cues([_english(0, words, step=400)], "eng")]
    assert len(cue_texts) >= 2
    assert cue_texts[0].endswith("comma,")
    assert " ".join(cue_texts) == " ".join(words)
    # 单条不超过 7 秒
    long_run = [f"a{i}" for i in range(40)]
    cues = asr.build_cues([_english(0, long_run, step=400)], "eng")
    assert len(cues) >= 2
    for start, end, _text in cues:
        assert end - start <= 7000 + 800


def test_chinese_cues_join_characters_and_respect_two_line_capacity() -> None:
    text = "我们今天一起去公园散步然后回家吃饭再看一部很长很长的电影一直看到深夜才去睡觉"
    tokens = tuple((char, 1000 + i * 200) for i, char in enumerate(text))
    cues = asr.build_cues([asr.Segment(1000, 1000 + len(text) * 200, text, tokens)], "chi")
    assert len(cues) >= 2
    assert all(" " not in body for _s, _e, body in cues)
    assert all(len(body) <= 36 for _s, _e, body in cues)
    assert "".join(body for _s, _e, body in cues) == text


def test_repeats_and_punctuation_only_pieces_are_dropped() -> None:
    tokens = (("哈", 0), ("哈", 100), ("哈", 200), ("哈", 300), ("。", 400), ("……", 2000))
    cues = asr.build_cues([asr.Segment(0, 2500, "哈哈哈哈。……", tokens)], "chi")
    assert [body for _s, _e, body in cues] == ["哈哈。"]


def test_short_cues_are_stretched_to_be_readable() -> None:
    cues = asr.build_cues([asr.Segment(0, 300, "Hi.", (("Hi.", 0),))], "eng")
    ((start, end, _),) = cues
    assert end - start >= 800


# ---------------------------------------------------------------------------
# 选源兜底与预检（§3 / §2）
# ---------------------------------------------------------------------------


def test_audio_is_offered_only_when_nothing_else_is_usable(available) -> None:
    bare = _row(audio=[_ENGLISH_51])
    ranked = tasks._with_audio_fallback(bare, [], None, "en")
    assert [c.candidate.kind for c in ranked] == ["audio"]
    assert ranked[0].candidate.spoken_language == "en"
    assert tasks.candidate_selectable(ranked[0])

    pgs_track = {"codec": "hdmv_pgs_subtitle", "language": "eng"}
    with_pgs = _row(audio=[_ENGLISH_51], subtitles=[pgs_track])
    pgs_ranked = source.rank_candidates(with_pgs, original_language="en", target_language="chs")
    assert all(
        c.candidate.kind != "audio"
        for c in tasks._with_audio_fallback(with_pgs, pgs_ranked, None, "en")
    )

    # 已有目标语言字幕不是「没有字幕」
    has_target = _row(audio=[_ENGLISH_51], subtitles=[{"codec": "subrip", "language": "chi"}])
    target_ranked = source.rank_candidates(
        has_target, original_language="en", target_language="chi"
    )
    assert tasks._with_audio_fallback(has_target, target_ranked, None, "en") == target_ranked


def test_transcribed_files_list_the_track_only_for_an_explicit_retranscribe(available) -> None:
    """识别过的文件：默认用识别外挂，音轨仍列出来供用户主动选它重新识别。"""
    sidecar = {"filename": "Movie.asr.eng.srt", "language": "eng", "title": "asr", "format": "srt"}
    row = _row(audio=[_ENGLISH_51], external=[sidecar])
    ranked = source.rank_candidates(row, original_language="en", target_language="chs")
    ranked = tasks._with_audio_fallback(row, ranked, None, "en")
    audio = next(c for c in ranked if c.candidate.kind == "audio")
    assert audio.on_request and tasks.candidate_selectable(audio)
    assert "识别过" in " ".join(audio.reasons)
    default = tasks._select_reference(ranked, None)
    assert tasks.candidate_key(default) == "external:Movie.asr.eng.srt"
    assert tasks.candidate_key(tasks._select_reference(ranked, "audio:0")) == "audio:0"

    # 识别结果本身就是目标语言：默认结论仍是「已经有了」，不会默认去重新识别
    same = source.rank_candidates(row, original_language="en", target_language="eng")
    same = tasks._with_audio_fallback(row, same, None, "en")
    assert any(c.candidate.kind == "audio" for c in same)
    assert tasks._select_reference(same, None) is None
    assert tasks._preview_blocker(same, None, "eng").code == "target_exists"


def test_explicit_audio_request_is_accepted_even_with_subtitles(available) -> None:
    row = _row(audio=[_ENGLISH_51], subtitles=[{"codec": "subrip", "language": "eng"}])
    ranked = source.rank_candidates(row, original_language="en", target_language="chs")
    ranked = tasks._with_audio_fallback(row, ranked, "audio:0", "en")
    assert tasks.candidate_key(tasks._select_reference(ranked, "audio:0")) == "audio:0"


def test_automatic_generation_never_triggers_transcription(available) -> None:
    """入库自动生成仍只认文本字幕：没有字幕的文件不会被批量拉去识别。"""
    assert not auto._has_reference(_row(audio=[_ENGLISH_51]), "chs")


def test_transcribed_sidecars_rank_after_ocr_and_before_ai_output() -> None:
    row = _row(
        external=[
            {"filename": "Movie.ai.eng.srt", "language": "eng", "format": "srt"},
            {"filename": "Movie.asr.eng.srt", "language": "eng", "format": "srt"},
        ]
    )
    ranked = source.rank_candidates(row, original_language=None, target_language="chs")
    assert [c.candidate.key for c in ranked] == ["Movie.asr.eng.srt", "Movie.ai.eng.srt"]
    assert ranked[0].candidate.provenance == "asr"


async def _preview(
    monkeypatch, row: LibraryFile, original: str | None, target: str = "chs", **kwargs
):
    async def load_row(_session, _file_id):  # noqa: ANN001
        return row

    async def context(_session, _row):  # noqa: ANN001
        return CTX, original

    monkeypatch.setattr(tasks, "_load_row", load_row)
    monkeypatch.setattr(tasks, "_film_context", context)
    return await tasks.preview(None, 42, target, **kwargs)  # type: ignore[arg-type]


def _media_row(tmp_path: Path, monkeypatch, *, external: list[dict] | None = None) -> LibraryFile:
    video = tmp_path / "Movie.mkv"
    video.write_bytes(b"video")
    monkeypatch.setattr(extract, "cache_dir", lambda: tmp_path / "cache")
    return _row(audio=[_ENGLISH_51], external=external, path=str(video))


async def test_preview_says_the_previous_transcript_is_reused_unless_asked_again(
    monkeypatch, tmp_path: Path, available
) -> None:
    sidecar = {"filename": "Movie.asr.eng.srt", "language": "eng", "title": "asr", "format": "srt"}
    row = _media_row(tmp_path, monkeypatch, external=[sidecar])
    _complete_sidecar(tmp_path / "Movie.asr.eng.srt", Path(row.file_path))

    reuse = await _preview(monkeypatch, row, "en", source_candidate_key="audio:0")
    notice = reuse.reference_notice or ""
    assert reuse.selected_source_key == "audio:0" and reuse.blocker is None
    assert "已经识别过" in notice and "Movie.asr.eng.srt" in notice and "不再重新识别" in notice
    assert reuse.event_count == 60 and reuse.estimated_tokens > 0, "按已有识别结果估算翻译量"

    again = await _preview(
        monkeypatch, row, "en", source_candidate_key="audio:0", retranscribe=True
    )
    notice = again.reference_notice or ""
    assert "不用上次的识别结果，重新用本地语音模型" in notice and "约 15 分钟" in notice


async def test_preview_resumes_an_interrupted_transcription(
    monkeypatch, tmp_path: Path, available
) -> None:
    row = _media_row(tmp_path, monkeypatch)
    checkpoint = asr.Checkpoint(
        tmp_path / "cache" / "42.a0.asr.jsonl", tasks._asr_identity(row, 0, "en")
    )
    checkpoint.open()
    checkpoint.append({"type": "language", "language": "en"})
    checkpoint.append(
        {"type": "segment", "start_ms": 2_418_000, "end_ms": 2_420_000, "text": "Hi.",
         "tokens": ["Hi."], "timestamps": [0.1]}
    )  # fmt: skip
    checkpoint.close()

    result = await _preview(monkeypatch, row, "en")
    notice = result.reference_notice or ""
    assert "上次已识别到 00:40:20，这次接着识别，预计还要约 10 分钟" in notice


async def test_preview_explains_transcription_and_estimates_by_runtime(
    monkeypatch, available
) -> None:
    result = await _preview(monkeypatch, _row(audio=[_ENGLISH_51]), "en")
    assert result.blocker is None
    assert result.selected_source_key == "audio:0"
    assert result.chosen is not None and result.chosen.candidate.kind == "audio"
    notice = result.reference_notice or ""
    assert "本地语音模型" in notice and "英语" in notice and "约 15 分钟" in notice
    assert "Movie.asr.eng.srt" in notice and "翻译成简体中文" in notice
    assert result.estimated_tokens > 0  # 要翻译：按片长粗估
    assert result.output_filename == "Movie.ai-chs.chi.srt"


async def test_same_language_output_needs_no_model(monkeypatch, available) -> None:
    result = await _preview(monkeypatch, _row(audio=[_ENGLISH_51]), "en", target="eng")
    assert result.estimated_tokens == 0
    assert result.output_filename == "Movie.asr.eng.srt"
    assert "不调用 AI 模型" in (result.reference_notice or "")


@pytest.mark.parametrize(
    ("row", "original", "capability", "code"),
    [
        (
            _row(audio=[{"codec": "aac", "language": "fre"}]),
            "fr",
            _AVAILABLE,
            "asr_language_unsupported",
        ),
        (_row(audio=[_ENGLISH_51], path="/media/Movie.strm"), "en", _AVAILABLE, "asr_remote"),
        (_row(audio=[_ENGLISH_51]), "en", _MISSING, "asr_unavailable"),
        (_row(audio=None), "en", _AVAILABLE, "no_subtitle"),
    ],
)
async def test_preview_blockers_say_why_transcription_cannot_run(
    monkeypatch, row, original, capability, code
) -> None:
    monkeypatch.setattr(asr, "capability", lambda: capability)
    result = await _preview(monkeypatch, row, original)
    assert result.chosen is None
    assert result.blocker is not None and result.blocker.code == code
    if code == "asr_language_unsupported":
        assert "fre" in result.blocker.message


# ---------------------------------------------------------------------------
# 任务：读取 → 识别 → 外挂 → 翻译（假识别、假模型）
# ---------------------------------------------------------------------------


class _FakeDatabase:
    @contextlib.asynccontextmanager
    async def session(self):
        yield None


def _transcript() -> asr.Transcript:
    segments = [_english(i * 100_000 + 1000, ["Line", f"{i}", "here."]) for i in range(60)]
    return asr.Transcript(segments=segments, language="en", speech_seconds=120.0)


def _wire_job(monkeypatch, tmp_path: Path, row: LibraryFile, original: str | None) -> dict:
    video = tmp_path / "Movie.mkv"
    video.write_bytes(b"video")
    row.file_path = str(video)
    calls: dict = {"extract": 0, "transcribe": 0, "chat": 0, "languages": []}

    async def load_row(_session, _file_id):  # noqa: ANN001
        return row

    async def context(_session, _row):  # noqa: ANN001
        return CTX, original

    async def extract_audio(_file, index, out_path, *, center_channel):  # noqa: ANN001
        calls["extract"] += 1
        calls["center"] = center_channel
        out_path.write_bytes(b"RIFF")
        return None

    async def transcribe(_wav, language, *, on_progress, on_paused, checkpoint=None):  # noqa: ANN001
        calls["transcribe"] += 1
        calls["languages"].append(language)
        calls["checkpoint"] = checkpoint
        if checkpoint is not None:
            checkpoint.open()
            checkpoint.append({"type": "language", "language": "en"})
            checkpoint.close()
        on_progress(1800.0)
        on_paused(True)
        on_paused(False)
        return _transcript()

    async def build_chat(_session, **_kwargs):  # noqa: ANN001, ANN003
        async def chat(system: str, user: str, call: translate.ChatCall) -> str:
            calls["chat"] += 1
            calls.setdefault("systems", []).append(system)
            if call.purpose == "glossary":
                return "[]"
            block = json.loads(user.split("翻译下列对白：\n", 1)[1])
            return json.dumps([{"i": e["i"], "t": f"译{e['i']}"} for e in block])

        return chat

    async def refresh(_db, _file_id):  # noqa: ANN001
        return None

    monkeypatch.setattr(tasks, "get_database", lambda: _FakeDatabase())
    monkeypatch.setattr(tasks, "_load_row", load_row)
    monkeypatch.setattr(tasks, "_film_context", context)
    monkeypatch.setattr(tasks, "_build_chat", build_chat)
    monkeypatch.setattr(tasks, "_refresh_subtitle_inventory", refresh)
    monkeypatch.setattr(media_extract, "extract_audio_async", extract_audio)
    monkeypatch.setattr(asr, "transcribe", transcribe)
    monkeypatch.setattr(extract, "cache_dir", lambda: tmp_path / "cache")
    monkeypatch.setattr(translate, "cache_dir", lambda: tmp_path / "cache")
    (tmp_path / "cache").mkdir()
    return calls


def _complete_sidecar(path: Path, video: Path, text: str = "Old line") -> None:
    """一份完整的识别外挂（覆盖大半部片子），修改时间晚于视频。"""
    cues = [(i * 100_000 + 1000, i * 100_000 + 3000, f"{text} {i}.") for i in range(60)]
    translate.write_srt(cues, path)
    stamp = video.stat().st_mtime_ns + 10**9
    os.utime(path, ns=(stamp, stamp))


async def test_same_language_job_writes_the_transcript_without_calling_a_model(
    monkeypatch, tmp_path: Path, available
) -> None:
    row = _row(audio=[_ENGLISH_51])
    calls = _wire_job(monkeypatch, tmp_path, row, "en")
    state = tasks.GenState()

    result = await tasks._run(42, "eng", state, cancelled=lambda: False)

    assert result.ok, result.message
    assert result.filename == "Movie.asr.eng.srt"
    assert calls == {**calls, "extract": 1, "transcribe": 1, "chat": 0}
    assert calls["center"] is True and calls["languages"] == ["en"]
    written = (tmp_path / "Movie.asr.eng.srt").read_text(encoding="utf-8")
    assert written.count("-->") == 60 and "Line 0 here." in written
    assert not (tmp_path / "cache" / "42.a0.16k.wav").exists(), "成功后应删掉音频缓存"
    checkpoint = calls["checkpoint"]
    assert checkpoint.path == tmp_path / "cache" / "42.a0.asr.jsonl"
    assert checkpoint.identity["track"] == 0 and checkpoint.identity["center"] is True
    assert not checkpoint.path.exists(), "外挂落盘后应删掉识别断点"
    assert state.uses_asr and "未调用 AI" in result.message


async def test_translation_job_keeps_the_transcript_and_tells_the_model_it_is_asr(
    monkeypatch, tmp_path: Path, available
) -> None:
    row = _row(audio=[_ENGLISH_51])
    calls = _wire_job(monkeypatch, tmp_path, row, "en")
    progress: list[dict] = []
    state = tasks.GenState()

    result = await tasks._run(42, "chs", state, cancelled=lambda: False)
    progress.append(tasks._job_progress(state))

    assert result.ok, result.message
    assert result.filename == "Movie.ai-chs.chi.srt"
    assert (tmp_path / "Movie.asr.eng.srt").exists(), "识别原文另存为外挂"
    assert calls["chat"] > 0
    assert any("语音识别结果" in system for system in calls["systems"])
    assert result.sync_score is None, "音轨识别不做同步检测"
    assert "本地语音识别" in (result.source_desc or "")


@pytest.mark.parametrize(("count", "step"), [(41, 7500), (60, 1000), (1, 1000)])
async def test_completed_sparse_transcription_can_be_written_and_reused(
    monkeypatch, tmp_path: Path, available, count: int, step: int
) -> None:
    row = _row(audio=[_ENGLISH_51])
    row.duration_seconds = 320
    calls = _wire_job(monkeypatch, tmp_path, row, "en")
    transcript = asr.Transcript(
        segments=[_english(i * step + 1000, ["Line", f"{i}", "here."]) for i in range(count)],
        language="en",
        speech_seconds=float(count),
    )
    monkeypatch.setattr(sys.modules[__name__], "_transcript", lambda: transcript)

    result = await tasks._run(42, "eng", tasks.GenState(), cancelled=lambda: False)

    assert result.ok, result.message
    sidecar = tmp_path / "Movie.asr.eng.srt"
    assert sidecar.read_text(encoding="utf-8").count("-->") == count
    reused = await tasks._run(42, "eng", tasks.GenState(), cancelled=lambda: False)
    assert reused.ok, reused.message
    assert calls["transcribe"] == 1 and calls["extract"] == 1


@pytest.mark.parametrize("worker_failed", [False, True])
async def test_empty_or_failed_transcription_does_not_publish_a_sidecar(
    monkeypatch, tmp_path: Path, available, worker_failed: bool
) -> None:
    row = _row(audio=[_ENGLISH_51])
    _wire_job(monkeypatch, tmp_path, row, "en")

    async def transcribe(*_args, **_kwargs):
        if worker_failed:
            raise asr.TranscribeError({"message": "worker failed"})
        return asr.Transcript(language="en")

    monkeypatch.setattr(asr, "transcribe", transcribe)
    result = await tasks._run(42, "eng", tasks.GenState(), cancelled=lambda: False)

    assert not result.ok
    assert result.message_key == (
        "library.subtitleJob.asrIncomplete"
        if worker_failed
        else "library.subtitleJob.asrAssessment"
    )
    assert not list(tmp_path.glob("*.srt"))


async def test_restart_reuses_a_fresh_transcript_instead_of_transcribing_again(
    monkeypatch, tmp_path: Path, available
) -> None:
    row = _row(audio=[_ENGLISH_51])
    calls = _wire_job(monkeypatch, tmp_path, row, "en")
    _complete_sidecar(tmp_path / "Movie.asr.eng.srt", Path(row.file_path))

    result = await tasks._run(42, "eng", tasks.GenState(), cancelled=lambda: False)

    assert result.ok
    assert calls["extract"] == 0 and calls["transcribe"] == 0


async def test_empty_or_outdated_transcripts_are_not_reused(
    monkeypatch, tmp_path: Path, available
) -> None:
    """空外挂、视频换过之后的旧外挂都不复用，重新识别。"""
    row = _row(audio=[_ENGLISH_51])
    calls = _wire_job(monkeypatch, tmp_path, row, "en")
    sidecar = tmp_path / "Movie.asr.eng.srt"
    translate.write_srt([], sidecar)
    video = Path(row.file_path)
    os.utime(sidecar, ns=(video.stat().st_mtime_ns + 10**9,) * 2)

    assert (await tasks._run(42, "eng", tasks.GenState(), cancelled=lambda: False)).ok
    assert calls["transcribe"] == 1

    _complete_sidecar(sidecar, video)
    os.utime(video, ns=(sidecar.stat().st_mtime_ns + 10**9,) * 2)  # 洗版：视频比外挂新
    assert (await tasks._run(42, "eng", tasks.GenState(), cancelled=lambda: False)).ok
    assert calls["transcribe"] == 2


async def test_retranscribe_ignores_the_old_transcript_but_survives_restarts(
    monkeypatch, tmp_path: Path, available
) -> None:
    row = _row(audio=[_ENGLISH_51])
    calls = _wire_job(monkeypatch, tmp_path, row, "en")
    sidecar = tmp_path / "Movie.asr.eng.srt"
    _complete_sidecar(sidecar, Path(row.file_path))
    stale = tasks._asr_stale(row, 0, "en")
    assert stale["sidecars"] == {"Movie.asr.eng.srt": tasks._file_identity(sidecar)}

    result = await tasks._run(42, "eng", tasks.GenState(), asr_stale=stale, cancelled=lambda: False)
    assert result.ok and calls["transcribe"] == 1
    assert "Line 0 here." in sidecar.read_text(encoding="utf-8"), "旧外挂被新结果原子替换"

    # 同一个任务重启（崩溃、断电、更新后由调度器重新执行）：这次自己写出的结果照常复用
    result = await tasks._run(42, "eng", tasks.GenState(), asr_stale=stale, cancelled=lambda: False)
    assert result.ok and calls["transcribe"] == 1


async def test_transcript_used_as_text_reference_still_warns_the_model(
    monkeypatch, tmp_path: Path, available
) -> None:
    """识别外挂被当成普通文本参考（第二次生成另一种语言）时，同样提示模型这是语音识别结果。"""
    row = _row(
        audio=[_ENGLISH_51],
        external=[
            {"filename": "Movie.asr.eng.srt", "language": "eng", "title": "asr", "format": "srt"}
        ],
    )
    calls = _wire_job(monkeypatch, tmp_path, row, "en")
    _complete_sidecar(tmp_path / "Movie.asr.eng.srt", Path(row.file_path))

    result = await tasks._run(42, "chs", tasks.GenState(), cancelled=lambda: False)

    assert result.ok, result.message
    assert calls["transcribe"] == 0 and calls["extract"] == 0
    assert any("语音识别结果" in system for system in calls["systems"])


def test_transcribing_progress_is_determinate_and_stops_at_once() -> None:
    state = tasks.GenState(
        phase="transcribing", transcribe_position_seconds=1800, transcribe_duration_seconds=7200
    )
    snapshot = tasks._job_progress(state)
    assert snapshot["percent"] == 25.0 and snapshot["phase_index"] == 1
    assert "transcribing" in tasks._STOP_AT_ONCE_PHASES


async def test_enqueue_serializes_transcription_and_skips_model_for_same_language(
    monkeypatch, available
) -> None:
    from movieclaw_api.services import jobs

    row = _row(audio=[_ENGLISH_51])
    created: dict = {}

    async def load_row(_session, _file_id):  # noqa: ANN001
        return row

    async def context(_session, _row):  # noqa: ANN001
        return CTX, "en"

    async def fingerprint(_row, _key):  # noqa: ANN001
        return {"size_bytes": 1, "file_mtime_ns": 1}

    async def create_job(_session, **kwargs):  # noqa: ANN001, ANN003
        created.update(kwargs)
        return jobs.CreateJobResult(job=None, created=True)  # type: ignore[arg-type]

    async def no_router(_session):  # noqa: ANN001
        raise AssertionError("同语种识别不该要求配置模型")

    from movieclaw_api.services import llm_config

    monkeypatch.setattr(tasks, "_load_row", load_row)
    monkeypatch.setattr(tasks, "_film_context", context)
    monkeypatch.setattr(tasks, "_source_fingerprint", fingerprint)
    monkeypatch.setattr(jobs, "create_job", create_job)
    monkeypatch.setattr(llm_config, "acquire_llm_router", no_router)

    await tasks.enqueue_generation_job(None, 42, "eng")  # type: ignore[arg-type]

    keys = {(ref.resource_type, ref.resource_id) for ref in created["resources"]}
    assert ("asr_engine", "local") in keys
    assert created["input_data"]["source_candidate_key"] == "audio:0"
    assert created["input_data"]["asr_language"] == "en"
    assert created["input_data"]["asr_model"] == asr.MODEL_ID
    assert created["input_data"]["model_ref"] is None


async def test_enqueue_retranscribe_records_the_results_to_ignore(
    monkeypatch, tmp_path: Path, available
) -> None:
    from movieclaw_api.services import jobs

    sidecar = {"filename": "Movie.asr.eng.srt", "language": "eng", "title": "asr", "format": "srt"}
    row = _media_row(tmp_path, monkeypatch, external=[sidecar])
    _complete_sidecar(tmp_path / "Movie.asr.eng.srt", Path(row.file_path))
    checkpoint = asr.Checkpoint(
        tmp_path / "cache" / "42.a0.asr.jsonl", tasks._asr_identity(row, 0, "en")
    )
    checkpoint.open()
    checkpoint.close()
    created: dict = {}

    async def load_row(_session, _file_id):  # noqa: ANN001
        return row

    async def context(_session, _row):  # noqa: ANN001
        return CTX, "en"

    async def create_job(_session, **kwargs):  # noqa: ANN001, ANN003
        created.update(kwargs)
        return jobs.CreateJobResult(job=None, created=True)  # type: ignore[arg-type]

    monkeypatch.setattr(tasks, "_load_row", load_row)
    monkeypatch.setattr(tasks, "_film_context", context)
    monkeypatch.setattr(jobs, "create_job", create_job)

    await tasks.enqueue_generation_job(
        None, 42, "eng", source_candidate_key="audio:0", retranscribe=True  # type: ignore[arg-type]
    )

    stale = created["input_data"]["asr_stale"]
    assert stale["sidecars"] == {
        "Movie.asr.eng.srt": tasks._file_identity(tmp_path / "Movie.asr.eng.srt")
    }
    assert stale["checkpoint"] == checkpoint.created_ns
    assert created["progress"]["phase"] == "extracting"

    # 不勾重新识别：直接复用，排队时不说「先读取音轨」，也不记要作废的结果
    await tasks.enqueue_generation_job(
        None, 42, "eng", source_candidate_key="audio:0"  # type: ignore[arg-type]
    )
    assert "asr_stale" not in created["input_data"]
    assert created["progress"]["phase"] == "preparing"


# ---------------------------------------------------------------------------
# 识别断点：崩溃、断电、重启后接着识别（§4.5）
# ---------------------------------------------------------------------------

_IDENTITY = {"video": ["/media/Movie.mkv", 10, 20], "track": 0, "center": True, "language": "en"}


def _segment_event(start_ms: int) -> dict:
    return {"type": "segment", "start_ms": start_ms, "end_ms": start_ms + 800, "text": "Hi.",
            "tokens": ["Hi."], "timestamps": [0.1]}  # fmt: skip


def test_checkpoint_keeps_the_valid_prefix_and_rejects_other_identities(tmp_path: Path) -> None:
    path = tmp_path / "42.a0.asr.jsonl"
    checkpoint = asr.Checkpoint(path, _IDENTITY)
    checkpoint.open()
    checkpoint.append({"type": "language", "language": "ja"})
    checkpoint.append(_segment_event(1000))
    checkpoint.append(_segment_event(5000))
    checkpoint.close()
    with open(path, "a", encoding="utf-8") as fh:
        fh.write('{"type": "segment", "start_ms": 9000, "end')  # 断电时写了一半的尾行

    loaded = asr.Checkpoint.load(path, _IDENTITY)
    assert loaded.language == "ja" and [e["start_ms"] for e in loaded.segments] == [1000, 5000]
    assert loaded.position == 5.8 and loaded.created_ns == checkpoint.created_ns

    loaded.open()  # 重写有效部分，再接着追加
    loaded.append(_segment_event(9000))
    loaded.close()
    again = asr.Checkpoint.load(path, _IDENTITY)
    assert [e["start_ms"] for e in again.segments] == [1000, 5000, 9000]

    other = {**_IDENTITY, "video": ["/media/Movie.mkv", 10, 21]}  # 视频换了
    assert asr.Checkpoint.load(path, other).segments == []
    stale = asr.Checkpoint.load(path, _IDENTITY, stale_created_ns=checkpoint.created_ns)
    assert stale.segments == [] and stale.created_ns == 0, "重新识别要作废的那份断点"


async def test_crashed_transcription_resumes_where_it_stopped(fake_worker, monkeypatch) -> None:
    path = fake_worker.parent / "42.a0.asr.jsonl"
    monkeypatch.setenv("FAKE_CRASH_AFTER", "2")
    with pytest.raises(asr.TranscribeError):
        await asr.transcribe(
            fake_worker, None, on_progress=lambda _p: None, on_paused=lambda _f: None,
            checkpoint=asr.Checkpoint.load(path, _IDENTITY), playback_busy=lambda: False,
        )  # fmt: skip
    saved = asr.Checkpoint.load(path, _IDENTITY)
    assert saved.language == "en" and len(saved.segments) == 2 and saved.position == 1.8

    monkeypatch.delenv("FAKE_CRASH_AFTER")
    progress: list[float] = []
    result = await asr.transcribe(
        fake_worker, None, on_progress=progress.append, on_paused=lambda _f: None,
        checkpoint=saved, playback_busy=lambda: False,
    )  # fmt: skip

    params = json.loads(Path(str(fake_worker) + ".params").read_text())
    assert params["start"] == 1.8 and params["language"] == "en", "从断点位置、用锁定的语言接着识别"
    assert params["parent"] == os.getpid()
    starts = [s.start_ms for s in result.segments]
    assert starts == [0, 1000, 1800, 2800, 3800] and result.language == "en"
    assert progress[0] > 1.8
    assert len(asr.Checkpoint.load(path, _IDENTITY).segments) == 5


@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="PR_SET_PDEATHSIG 只有 Linux 有")
async def test_worker_dies_with_the_server_even_while_paused(tmp_path: Path) -> None:
    """主进程被杀（崩溃、OOM、断电重启前）时，暂停中的识别子进程也要跟着结束，不留孤儿。"""
    worker_dir = Path(asr._WORKER).parent
    launcher = textwrap.dedent(
        f"""
        import os, signal, subprocess, sys, time
        # 子进程不继承这里的标准输出：否则它活着时管道不关，测试会一直卡在 wait()
        child = subprocess.Popen([sys.executable, "-I", "-c", (
            "import sys; sys.path.insert(0, {str(worker_dir)!r});"
            "import os, signal, asr_worker;"
            "asr_worker._die_with_parent(os.getppid());"
            "os.kill(os.getpid(), signal.SIGSTOP)"
        )], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(child.pid, flush=True)
        for _ in range(200):
            with open(f"/proc/{{child.pid}}/stat") as fh:
                if fh.read().rsplit(")", 1)[1].split()[0] == "T":
                    break
            time.sleep(0.01)
        os._exit(0)  # 不收尸、不发信号：模拟主进程被 SIGKILL
        """
    )
    proc = await asyncio.create_subprocess_exec(
        sys.executable, "-c", launcher, stdout=asyncio.subprocess.PIPE
    )
    pid = int((await proc.stdout.readline()).decode())
    await proc.wait()
    for _ in range(100):
        try:
            with open(f"/proc/{pid}/stat") as fh:
                state = fh.read().rsplit(")", 1)[1].split()[0]
        except FileNotFoundError:
            return
        if state in {"Z", "X"}:
            return
        await asyncio.sleep(0.05)
    os.kill(pid, signal.SIGKILL)
    pytest.fail(f"暂停中的子进程在主进程退出后还活着（状态 {state}）")


def test_worker_buffer_never_forgets_samples_it_has_not_read(tmp_path: Path) -> None:
    """续跑重放 VAD 时左边界在断点、还没读到那里：丢弃位置不能越过已读位置，否则切片错位。"""
    from movieclaw_api.services.subtitle_gen import asr_worker

    wav_path = tmp_path / "ramp.wav"
    samples = (np.arange(16_000 * 25) % 20_000).astype(np.int16)
    with wave.open(str(wav_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16_000)
        w.writeframes(samples.tobytes())
    audio = asr_worker._Audio(str(wav_path))
    audio.next_chunk()  # 读到 10 秒
    audio.forget_before(16_000 * 20)  # 断点在 20 秒
    assert audio.offset == audio.read == 160_000 and len(audio.buffer) == 0
    audio.next_chunk()  # 读到 20 秒
    piece = audio.slice(170_000, 170_005)
    assert [int(round(x * 32768)) for x in piece] == list(samples[170_000:170_005])


def test_stale_partial_audio_files_are_removed_before_reading(tmp_path: Path) -> None:
    out = tmp_path / "42.a0.16k.wav"
    stale = tmp_path / ".42.a0.16k.0123abcd.part.wav"
    other = tmp_path / ".43.a0.16k.0123abcd.part.wav"
    for path in (stale, other):
        path.write_bytes(b"half")
    media_extract._remove_stale_parts(out)
    assert not stale.exists() and other.exists()


# ---------------------------------------------------------------------------
# 识别子进程：逐行事件、为转码让路、停止即结束
# ---------------------------------------------------------------------------


_FAKE_WORKER = textwrap.dedent(
    """
    import json, os, sys, time
    params = json.loads(sys.stdin.readline())
    with open(params["wav"] + ".params", "w") as fh:
        json.dump(params, fh)
    with open(params["wav"] + ".pid", "w") as fh:
        fh.write(str(os.getpid()))
    delay = float(os.environ.get("FAKE_DELAY", "0"))
    crash_after = int(os.environ.get("FAKE_CRASH_AFTER", "0"))
    base = int(float(params.get("start") or 0) * 1000)
    print(json.dumps({"type": "language", "language": params.get("language") or "en"}), flush=True)
    for i in range(3):
        if crash_after and i == crash_after:
            os._exit(9)
        time.sleep(delay)
        position = base / 1000 + (i + 1) * 10.0
        print(json.dumps({"type": "progress", "position": position}), flush=True)
        print(json.dumps({"type": "segment", "start_ms": base + i * 1000,
                          "end_ms": base + i * 1000 + 800,
                          "text": f"line {i}", "tokens": ["line", f" {i}"],
                          "timestamps": [0.1, 0.4], "lang": "en"}), flush=True)
    if os.environ.get("FAKE_FAIL"):
        sys.stderr.write("model exploded\\n")
        sys.exit(3)
    print(json.dumps({"type": "done", "language": "en", "speech_seconds": 2.4}), flush=True)
    """
)


@pytest.fixture
def fake_worker(tmp_path: Path, monkeypatch):
    script = tmp_path / "worker.py"
    script.write_text(_FAKE_WORKER, encoding="utf-8")
    monkeypatch.setattr(asr, "_WORKER", script)
    monkeypatch.setattr(asr, "capability", lambda: asr.Capability(True, None, tmp_path, True))
    monkeypatch.setattr(asr, "_PLAYBACK_POLL_SECONDS", 0.02)
    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"RIFF")
    return wav


async def test_worker_events_become_segments_with_absolute_token_times(fake_worker) -> None:
    progress: list[float] = []
    result = await asr.transcribe(
        fake_worker, "en", on_progress=progress.append, on_paused=lambda _f: None,
        playback_busy=lambda: False,
    )  # fmt: skip
    assert [s.text for s in result.segments] == ["line 0", "line 1", "line 2"]
    assert result.segments[2].tokens == (("line", 2100), (" 2", 2400))
    assert result.language == "en" and progress == [10.0, 20.0, 30.0]


async def test_worker_failure_carries_its_stderr(fake_worker, monkeypatch) -> None:
    monkeypatch.setenv("FAKE_FAIL", "1")
    with pytest.raises(asr.TranscribeError) as caught:
        await asr.transcribe(
            fake_worker, "en", on_progress=lambda _p: None, on_paused=lambda _f: None,
            playback_busy=lambda: False,
        )  # fmt: skip
    assert "model exploded" in str(caught.value)


@pytest.mark.skipif(not hasattr(signal, "SIGSTOP"), reason="需要 POSIX 的 SIGSTOP/SIGCONT")
async def test_transcription_pauses_while_the_server_transcodes(fake_worker, monkeypatch) -> None:
    monkeypatch.setenv("FAKE_DELAY", "0.2")
    busy = iter([True] * 10)
    events: list[bool] = []
    result = await asr.transcribe(
        fake_worker, "en", on_progress=lambda _p: None, on_paused=events.append,
        playback_busy=lambda: next(busy, False),
    )  # fmt: skip
    assert events[:2] == [True, False], "转码时暂停，结束后继续"
    assert len(result.segments) == 3


@pytest.mark.skipif(os.name != "posix", reason="进程组回收只在 POSIX 上验证")
async def test_stopping_kills_the_worker_even_when_paused(fake_worker, monkeypatch) -> None:
    monkeypatch.setenv("FAKE_DELAY", "30")
    pid_file = Path(str(fake_worker) + ".pid")
    paused: list[bool] = []
    task = asyncio.create_task(
        asr.transcribe(
            fake_worker, "en", on_progress=lambda _p: None, on_paused=paused.append,
            # worker 写出 pid 之后才「开始转码」，否则它还没起来就被停住了
            playback_busy=lambda: pid_file.exists() and bool(pid_file.read_text()),
        )
    )  # fmt: skip
    for _ in range(200):
        if pid_file.exists() and pid_file.read_text():
            break
        await asyncio.sleep(0.05)
    pid = int(pid_file.read_text())
    for _ in range(100):
        if paused:
            break
        await asyncio.sleep(0.02)
    assert paused == [True], "应当先被暂停"
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.sleep(0.2)
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


# ---------------------------------------------------------------------------
# 读取音轨：真 ffmpeg
# ---------------------------------------------------------------------------


async def test_audio_extraction_writes_16k_mono_and_takes_the_center(
    tmp_path: Path, monkeypatch
) -> None:
    if media_extract.shutil.which("ffmpeg") is None:
        pytest.skip("需要 ffmpeg")
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "progress")
    media = tmp_path / "surround.mkv"
    # 6 声道，只有中置（第 3 声道）有声音
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "2", "-af", "pan=5.1|c2=c0", "-c:a", "pcm_s16le", str(media),
    )  # fmt: skip
    assert await proc.wait() == 0
    row = _row(path=str(media))
    peaks = {}
    for center in (True, False):
        out = tmp_path / f"out-{center}.wav"
        assert await media_extract.extract_audio_async(row, 0, out, center_channel=center) is None
        with wave.open(str(out)) as w:
            assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2)
            samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        peaks[center] = int(np.abs(samples).max())
    # 只取中置声道保留对白的完整音量；整体下混把它和其余（这里静音的）声道平均掉
    assert peaks[True] > 2 * peaks[False] > 0
    assert not list(tmp_path.glob("**/*.part.wav")), "临时文件应原子替换掉"


# ---------------------------------------------------------------------------
# 真实模型（本机放好模型文件时才跑）
# ---------------------------------------------------------------------------


def _real_model_dir() -> Path | None:
    candidate = Path(os.environ.get("MOVIECLAW_ASR_DIR", "data/models/asr"))
    files = asr.model_files(candidate)
    smoke = candidate / "smoke-en.wav"
    if all(path.is_file() for path in files.values()) and smoke.is_file():
        return candidate
    return None


@pytest.mark.skipif(_real_model_dir() is None, reason="本机没有放 SenseVoice 模型")
async def test_real_model_transcribes_the_bundled_sample(monkeypatch) -> None:
    pytest.importorskip("sherpa_onnx")
    model_dir = _real_model_dir()
    assert model_dir is not None
    monkeypatch.setattr(asr, "capability", lambda: asr.Capability(True, None, model_dir, True))
    result = await asr.transcribe(
        model_dir / "smoke-en.wav", "en", on_progress=lambda _p: None, on_paused=lambda _f: None,
        playback_busy=lambda: False,
    )  # fmt: skip
    text = " ".join(s.text for s in result.segments)
    assert "chieftain" in text.lower() or "chief" in text.lower()
    cues = asr.build_cues(result.segments, "eng")
    assert cues and all(end > start for start, end, _ in cues)


@pytest.mark.skipif(_real_model_dir() is None, reason="本机没有放 SenseVoice 模型")
async def test_real_model_resume_matches_an_uninterrupted_run(monkeypatch, tmp_path) -> None:
    """断点续跑的结果必须与不中断完整识别逐段相同：VAD 从片头重放，断点之前的段只切不识别。"""
    pytest.importorskip("sherpa_onnx")
    model_dir = _real_model_dir()
    assert model_dir is not None
    monkeypatch.setattr(asr, "capability", lambda: asr.Capability(True, None, model_dir, True))
    with wave.open(str(model_dir / "smoke-en.wav")) as w:
        speech = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    silence = np.zeros(16_000 * 2, dtype=np.int16)
    wav = tmp_path / "three.wav"
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16_000)
        w.writeframes(np.concatenate([speech, silence, speech, silence, speech]).tobytes())

    def quiet(_value) -> None:  # noqa: ANN001
        return None

    full = await asr.transcribe(wav, "en", on_progress=quiet, on_paused=quiet,
                                playback_busy=lambda: False)  # fmt: skip
    assert len(full.segments) >= 3
    first = full.segments[0]
    checkpoint = asr.Checkpoint(tmp_path / "1.a0.asr.jsonl", _IDENTITY)
    checkpoint.language = "en"
    checkpoint.segments = [
        {"type": "segment", "start_ms": first.start_ms, "end_ms": first.end_ms,
         "text": first.text, "tokens": [t for t, _ in first.tokens],
         "timestamps": [(at - first.start_ms) / 1000 for _, at in first.tokens]}
    ]  # fmt: skip
    resumed = await asr.transcribe(wav, "en", on_progress=quiet, on_paused=quiet,
                                   checkpoint=checkpoint, playback_busy=lambda: False)  # fmt: skip

    def shape(segments: list[asr.Segment]) -> list[tuple[int, int, str]]:
        return [(s.start_ms, s.end_ms, s.text) for s in segments]

    assert shape(resumed.segments) == shape(full.segments)


def test_worker_script_runs_isolated_from_the_app() -> None:
    """worker 以 -I 启动，不能 import movieclaw（否则会读到镜像里的旧代码）。"""
    source_text = asr._WORKER.read_text(encoding="utf-8")
    assert "movieclaw" not in source_text.split('"""', 2)[2]
    assert sys.executable  # 主进程就用当前解释器起子进程

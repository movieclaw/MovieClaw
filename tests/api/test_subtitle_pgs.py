"""PGS → SRT 适配层：跨平台探测、原子转换与用户确认闸门。"""

from __future__ import annotations

import os
from dataclasses import replace
from pathlib import Path

import pytest

from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.subtitle_gen import pgs, source, tasks
from movieclaw_db.models import LibraryFile


def _file(path: Path) -> LibraryFile:
    return LibraryFile(
        id=42,
        library_id=1,
        media_item_id=1,
        file_path=str(path),
        duration_seconds=6000,
        subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "language": "eng"}],
        external_subtitles=[],
        source="scanned",
    )


def _candidate() -> source.SourceCandidate:
    return source.SourceCandidate(
        kind="embedded",
        key="0",
        language="eng",
        forced=False,
        sdh=False,
        format="hdmv_pgs_subtitle",
    )


def _capability(*, cached: bool = False) -> pgs.Capability:
    return pgs.Capability(
        available=True,
        platform="Linux",
        architecture="x64",
        engine="cache" if cached else "tesseract",
        ocr_language=None if cached else "eng",
        cached=cached,
        message="可用",
        seconv_path=None if cached else "/opt/seconv",
    )


def _decision(
    code: str = "eng",
    *,
    confirmation_required: bool = False,
) -> pgs.OcrLanguageDecision:
    return pgs.OcrLanguageDecision(
        code=code,
        label=pgs.OCR_LANGUAGE_LABELS[code],
        confirmation_required=confirmation_required,
        reason="测试语言结论",
    )


def test_capability_rejects_unsupported_architecture(monkeypatch) -> None:
    monkeypatch.setattr(pgs.sys, "platform", "linux")
    monkeypatch.setattr(pgs.platform, "machine", lambda: "armv7l")

    result = pgs.detect_capability("eng")

    assert not result.available
    assert "x64" in result.message and "ARM64" in result.message


def test_capability_reports_missing_seconv(monkeypatch) -> None:
    monkeypatch.setattr(pgs.sys, "platform", "linux")
    monkeypatch.setattr(pgs.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(
        pgs.shutil,
        "which",
        lambda name: "/usr/bin/ffmpeg" if name == "ffmpeg" else None,
    )
    monkeypatch.setattr(pgs, "_resolve_seconv", lambda: None)

    result = pgs.detect_capability("eng")

    assert not result.available
    assert "未找到 Subtitle Edit seconv" in result.message
    assert any("MOVIECLAW_SECONV_PATH" in item for item in result.suggestions)


def test_capability_selects_tesseract_language(monkeypatch) -> None:
    monkeypatch.setattr(pgs.sys, "platform", "linux")
    monkeypatch.setattr(pgs.platform, "machine", lambda: "aarch64")
    monkeypatch.setattr(
        pgs.shutil,
        "which",
        lambda name: {
            "ffmpeg": "/usr/bin/ffmpeg",
            "tesseract": "/usr/bin/tesseract",
        }.get(name),
    )
    monkeypatch.setattr(pgs, "_resolve_seconv", lambda: "/opt/seconv")
    monkeypatch.setattr(pgs, "_run_probe", lambda *_args: (True, "5.1.0"))
    monkeypatch.setattr(pgs, "_tesseract_languages", lambda _path: ({"eng"}, None))

    result = pgs.detect_capability("eng")

    assert result.available
    assert result.architecture == "arm64"
    assert result.engine == "tesseract" and result.ocr_language == "eng"


@pytest.mark.parametrize(
    ("language", "traineddata"),
    [
        ("chs", "chi_sim"),
        ("cht", "chi_tra"),
        ("jpn", "jpn"),
        ("kor", "kor"),
        ("fra", "fra"),
        ("deu", "deu"),
        ("spa", "spa"),
        ("ita", "ita"),
        ("por", "por"),
        ("rus", "rus"),
    ],
)
def test_capability_maps_bundled_tesseract_languages(
    monkeypatch,
    language: str,
    traineddata: str,
) -> None:
    monkeypatch.setenv("MOVIECLAW_PGS_OCR_ENGINE", "tesseract")
    monkeypatch.setattr(pgs.sys, "platform", "linux")
    monkeypatch.setattr(pgs.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(
        pgs.shutil,
        "which",
        lambda name: {
            "ffmpeg": "/usr/bin/ffmpeg",
            "tesseract": "/usr/bin/tesseract",
        }.get(name),
    )
    monkeypatch.setattr(pgs, "_resolve_seconv", lambda: "/opt/seconv")
    monkeypatch.setattr(pgs, "_run_probe", lambda *_args: (True, "5.1.0"))
    monkeypatch.setattr(
        pgs,
        "_tesseract_languages",
        lambda _path: ({traineddata}, None),
    )

    result = pgs.detect_capability(language)

    assert result.available
    assert result.engine == "tesseract"
    assert result.ocr_language == traineddata


def test_cached_conversion_bypasses_runtime_probe(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    video = tmp_path / "Movie.mkv"
    video.write_bytes(b"video")
    row = _file(video)
    cached = pgs.cached_srt_path(row, _candidate())
    cached.parent.mkdir(parents=True)
    cached.write_text("1\n00:00:01,000 --> 00:00:02,000\nhello\n", encoding="utf-8")
    os.utime(cached, ns=(video.stat().st_mtime_ns + 10**9,) * 2)
    monkeypatch.setattr(pgs, "detect_capability", lambda _language: pytest.fail("不应重新探测"))

    result = pgs.conversion_capability(row, _candidate())

    assert result.available and result.cached and result.engine == "cache"


def test_cache_name_is_safe_on_windows(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    video = tmp_path / "Movie.mkv"
    video.write_bytes(b"video")
    candidate = replace(_candidate(), language="en/US:main?")

    path = pgs.cached_srt_path(_file(video), candidate)

    assert path.name == "42.embedded0.en-us-main.pgs.srt"


def test_language_is_automatic_when_track_metadata_is_clear() -> None:
    result = pgs.infer_ocr_language(
        _file(Path("/media/Movie.mkv")),
        _candidate(),
        original_language="jpn",
    )

    assert result.code == "eng"
    assert not result.confirmation_required
    assert "轨道语言标记" in result.reason


def test_language_uses_original_as_confirmed_fallback() -> None:
    row = _file(Path("/media/Movie.mkv"))
    row.subtitle_streams[0]["language"] = None
    candidate = replace(_candidate(), language=None)

    result = pgs.infer_ocr_language(row, candidate, original_language="jpn")

    assert result.code == "jpn"
    assert result.confirmation_required
    assert "影片原语言" in result.reason


def test_language_conflict_prefers_title_but_requires_confirmation() -> None:
    row = _file(Path("/media/Movie.mkv"))
    row.subtitle_streams[0]["title"] = "Japanese SDH"

    result = pgs.infer_ocr_language(row, _candidate(), original_language="eng")

    assert result.code == "jpn"
    assert result.confirmation_required
    assert "不一致" in result.reason


def test_traditional_chinese_title_preserves_script_variant() -> None:
    row = _file(Path("/media/Movie.mkv"))
    row.subtitle_streams[0] = {
        "codec": "hdmv_pgs_subtitle",
        "language": "chi",
        "title": "繁體中文",
    }
    candidate = replace(_candidate(), language="chi")

    result = pgs.infer_ocr_language(row, candidate, original_language="chi")

    assert result.code == "cht"
    assert not result.confirmation_required


async def test_plan_asks_only_when_language_is_uncertain(monkeypatch) -> None:
    row = _file(Path("/media/Movie.mkv"))
    row.subtitle_streams[0]["language"] = None
    ranked = source.rank_candidates(row, original_language=None, target_language="chs")
    monkeypatch.setattr(pgs, "conversion_capability", lambda *_args: _capability())
    monkeypatch.setattr(
        pgs,
        "available_ocr_languages",
        lambda: ((("eng", "英语"),), _capability()),
    )

    plan = await tasks._pgs_plan(row, ranked, original_language=None)

    assert plan is not None
    assert plan.language.code is None
    assert plan.language.confirmation_required
    assert plan.language_options == (("eng", "英语"),)


async def test_plan_revalidates_confirmed_track_and_language(monkeypatch) -> None:
    row = _file(Path("/media/Movie.mkv"))
    ranked = source.rank_candidates(row, original_language="eng", target_language="chs")
    checked_languages: list[str | None] = []

    def fake_capability(_row, _candidate, language=None):  # noqa: ANN001
        checked_languages.append(language)
        return _capability()

    monkeypatch.setattr(pgs, "conversion_capability", fake_capability)

    plan = await tasks._pgs_plan(
        row,
        ranked,
        original_language="eng",
        requested_candidate_key="embedded:0",
        requested_ocr_language="jpn",
    )

    assert plan is not None
    assert plan.language.code == "jpn"
    assert not plan.language.confirmation_required
    assert checked_languages == ["jpn"]

    missing = await tasks._pgs_plan(
        row,
        ranked,
        requested_candidate_key="embedded:9",
        requested_ocr_language="jpn",
    )
    assert missing is None


async def test_pgs_reuses_shared_extraction_and_caches_ocr_atomically(
    tmp_path: Path, monkeypatch
) -> None:
    """.sup 走与播放器共用的整文件抽取（不再单独把整片再读一遍），OCR 结果
    原子落缓存，临时目录不留残片，第二次直接命中缓存。"""
    from movieclaw_api.services import media_extract
    from movieclaw_api.services.subtitle_gen import process

    monkeypatch.chdir(tmp_path)
    video = tmp_path / "Movie.mkv"
    video.write_bytes(b"video")
    row = _file(video)
    sup = tmp_path / "shared" / "42.s0.sup"
    sup.parent.mkdir()
    sup.write_bytes(b"PG")
    extracted: list[int] = []
    runs: list[list[str]] = []

    async def shared_extract(_file, index):  # noqa: ANN001
        extracted.append(index)
        return media_extract.ExtractedTrack(path=sup, format="sup")

    async def fake_seconv(argv, *, timeout):  # noqa: ANN001
        runs.append(argv)
        output_folder = next(v.split(":", 1)[1] for v in argv if v.startswith("--output-folder:"))
        Path(output_folder, "converted.srt").write_text(
            "1\n00:00:01,000 --> 00:00:02,000\nhello\n", encoding="utf-8"
        )
        return process.Completed(returncode=0, stdout=b"ok", stderr=b"")

    monkeypatch.setattr(media_extract, "extract_track_async", shared_extract)
    monkeypatch.setattr(pgs.process, "run", fake_seconv)

    sup_path = await pgs.extract_sup(row, _candidate())
    result = await pgs.ocr_to_srt(row, _candidate(), _capability(), "eng", sup_path)

    assert extracted == [0] and sup_path == sup
    assert "hello" in result.read_text(encoding="utf-8")
    assert runs[0][1] == str(sup) and "--ocr-engine:tesseract" in runs[0]
    assert not list(result.parent.glob("pgs-ocr-*")), "临时目录要清掉"

    again = await pgs.ocr_to_srt(row, _candidate(), _capability(), "eng", sup_path)
    assert again == result and len(runs) == 1, "缓存命中不该再跑 OCR"


async def test_pgs_extraction_failure_carries_the_reason(tmp_path: Path, monkeypatch) -> None:
    from movieclaw_api.services import media_extract

    row = _file(tmp_path / "Movie.mkv")

    async def failed(_file, _index):  # noqa: ANN001
        return None

    monkeypatch.setattr(media_extract, "extract_track_async", failed)
    monkeypatch.setattr(media_extract, "failure_reason", lambda _f, _i: "读取超时：13 分钟")

    with pytest.raises(pgs.PgsConversionError, match="读取超时：13 分钟"):
        await pgs.extract_sup(row, _candidate())


async def test_stopping_ocr_cleans_up_its_temp_dir(tmp_path: Path, monkeypatch) -> None:
    """停止任务时 OCR 随之取消（进程组由 process.run 结束），临时目录也不留。"""
    import asyncio

    monkeypatch.chdir(tmp_path)
    video = tmp_path / "Movie.mkv"
    video.write_bytes(b"video")
    row = _file(video)
    started = asyncio.Event()

    async def hanging_seconv(_argv, *, timeout):  # noqa: ANN001
        started.set()
        await asyncio.Event().wait()

    monkeypatch.setattr(pgs.process, "run", hanging_seconv)
    task = asyncio.create_task(
        pgs.ocr_to_srt(row, _candidate(), _capability(), "eng", tmp_path / "x.sup")
    )
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    cache = pgs.cached_srt_path(row, _candidate(), "eng").parent
    assert not list(cache.glob("pgs-ocr-*"))


def test_preview_offers_confirmed_pgs_conversion() -> None:
    row = _file(Path("/media/Movie.mkv"))
    ranked = source.rank_candidates(row, original_language="eng", target_language="chs")
    plan = tasks.PgsConversionPlan(ranked[0], _capability(), _decision())

    blocker = tasks._preview_blocker(ranked, plan)

    assert blocker.code == "pgs_conversion_required"
    assert blocker.title == "先识别图片字幕"
    assert "生成简体中文字幕" in blocker.message
    assert all(
        "Tesseract" not in text and "OCR" not in text
        for text in [blocker.title, blocker.message, *blocker.suggestions]
    )


def test_unavailable_preview_keeps_diagnostics_out_of_primary_message() -> None:
    row = _file(Path("/media/Movie.mkv"))
    ranked = source.rank_candidates(row, original_language="eng", target_language="chs")
    capability = replace(
        _capability(),
        available=False,
        engine=None,
        message="当前 macOS arm64 未找到 Subtitle Edit seconv",
        suggestions=("安装对应组件",),
    )
    plan = tasks.PgsConversionPlan(ranked[0], capability, _decision())

    blocker = tasks._preview_blocker(ranked, plan)

    assert blocker.code == "pgs_conversion_unavailable"
    assert "当前设备" in blocker.message and "Agent" in blocker.message
    assert "macOS" not in blocker.message and "seconv" not in blocker.message
    assert plan.capability.message == "当前 macOS arm64 未找到 Subtitle Edit seconv"


def test_preview_view_exposes_language_confirmation_options() -> None:
    from movieclaw_api.api.routes.subtitle_gen import _preview_view

    row = _file(Path("/media/Movie.mkv"))
    ranked = source.rank_candidates(row, original_language="eng", target_language="chs")
    decision = _decision("jpn", confirmation_required=True)
    plan = tasks.PgsConversionPlan(
        ranked[0],
        _capability(),
        decision,
        (("eng", "英语"), ("jpn", "日语")),
    )
    preview = tasks.Preview(
        candidates=ranked,
        chosen=None,
        event_count=0,
        estimated_tokens=0,
        already_generated=False,
        warnings=[],
        pgs_conversion=plan,
        blocker=tasks._preview_blocker(ranked, plan),
        selected_source_key="embedded:0",
    )

    view = _preview_view(preview)

    assert view.pgs_conversion is not None
    assert view.selected_source_key == "embedded:0"
    assert view.candidates[0].selectable and view.candidates[0].requires_ocr
    assert view.pgs_conversion.ocr_language == "jpn"
    assert view.pgs_conversion.language_confirmation_required
    assert [option.code for option in view.pgs_conversion.language_options] == [
        "eng",
        "jpn",
    ]


async def test_generation_preflight_requires_explicit_pgs_confirmation(monkeypatch) -> None:
    ranked = source.rank_candidates(
        _file(Path("/media/Movie.mkv")),
        original_language="eng",
        target_language="chs",
    )
    plan = tasks.PgsConversionPlan(ranked[0], _capability(), _decision())
    preview = tasks.Preview(
        candidates=ranked,
        chosen=None,
        event_count=0,
        estimated_tokens=0,
        already_generated=False,
        warnings=[],
        pgs_conversion=plan,
        blocker=tasks._preview_blocker(ranked, plan),
    )

    async def fake_preview(*_args, **_kwargs):  # noqa: ANN002, ANN003
        return preview

    monkeypatch.setattr(tasks, "preview", fake_preview)

    async def configured_router(_session):  # noqa: ANN001
        return object()

    from movieclaw_api.services import llm_config

    monkeypatch.setattr(llm_config, "acquire_llm_router", configured_router)

    with pytest.raises(BadRequestException, match="图片字幕"):
        await tasks._prepare_generation(None, 42, "chs")  # type: ignore[arg-type]

    result, initial = await tasks._prepare_generation(
        None,
        42,
        "chs",
        convert_pgs=True,  # type: ignore[arg-type]
    )
    assert result is preview
    assert initial.phase == "ocr"


async def test_generation_preflight_rejects_unconfirmed_ocr_language(monkeypatch) -> None:
    ranked = source.rank_candidates(
        _file(Path("/media/Movie.mkv")),
        original_language="eng",
        target_language="chs",
    )
    plan = tasks.PgsConversionPlan(
        ranked[0],
        _capability(),
        _decision("eng", confirmation_required=True),
        (("eng", "英语"),),
    )
    preview = tasks.Preview(
        candidates=ranked,
        chosen=None,
        event_count=0,
        estimated_tokens=0,
        already_generated=False,
        warnings=[],
        pgs_conversion=plan,
        blocker=tasks._preview_blocker(ranked, plan),
    )

    async def fake_preview(*_args, **_kwargs):  # noqa: ANN002, ANN003
        return preview

    monkeypatch.setattr(tasks, "preview", fake_preview)

    with pytest.raises(BadRequestException, match="选择"):
        await tasks._prepare_generation(
            None,
            42,
            "chs",
            convert_pgs=True,
        )  # type: ignore[arg-type]


def _stub_bundled_environment(monkeypatch) -> dict[str, int]:
    """模拟官方镜像：seconv 可用、Tesseract 装齐 11 种语言；返回各探针的调用次数。"""
    calls = {"seconv": 0, "tesseract": 0}
    monkeypatch.setattr(pgs.sys, "platform", "linux")
    monkeypatch.setattr(pgs.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(
        pgs.shutil,
        "which",
        lambda name: {"ffmpeg": "/usr/bin/ffmpeg", "tesseract": "/usr/bin/tesseract"}.get(name),
    )
    monkeypatch.setattr(pgs, "_resolve_seconv", lambda: "/opt/seconv")

    def seconv_probe(*_args):  # noqa: ANN002
        calls["seconv"] += 1
        return True, "5.1.0"

    def tesseract_probe(_path):  # noqa: ANN001
        calls["tesseract"] += 1
        return set(pgs._TESSERACT_LANGUAGES.values()), None

    monkeypatch.setattr(pgs, "_run_probe", seconv_probe)
    monkeypatch.setattr(pgs, "_tesseract_languages", tesseract_probe)
    return calls


def test_environment_is_probed_once_for_all_languages(monkeypatch) -> None:
    """列出可选识别语言曾对 11 种语言逐个起 seconv + tesseract（24 个子进程）。

    NAS 上 seconv 冷启动一两秒，一次预检就超过 iOS/网页的 20 秒超时。环境是
    部署时定下的，整个进程只该探测一次。
    """
    calls = _stub_bundled_environment(monkeypatch)

    pgs.detect_capability("chs")
    options, representative = pgs.available_ocr_languages()
    pgs.detect_capability("eng")

    assert calls == {"seconv": 1, "tesseract": 1}
    assert len(options) == len(pgs.OCR_LANGUAGE_LABELS)
    assert representative is not None and representative.available


def test_concurrent_first_detection_shares_one_probe(monkeypatch) -> None:
    """预检、确认生成、后台任务可能同时撞上首次探测，只能起一批子进程。"""
    import threading
    import time
    from concurrent.futures import ThreadPoolExecutor

    calls = _stub_bundled_environment(monkeypatch)
    lock = threading.Lock()

    def slow_seconv(*_args):  # noqa: ANN002
        with lock:
            calls["seconv"] += 1
        time.sleep(0.2)
        return True, "5.1.0"

    monkeypatch.setattr(pgs, "_run_probe", slow_seconv)

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(pgs.detect_capability, ["eng", "chs", "jpn", "kor"]))

    assert calls["seconv"] == 1
    assert all(result.available for result in results)


async def test_preview_of_ambiguous_pgs_spawns_no_probe(tmp_path: Path, monkeypatch) -> None:
    """环境预热之后，语言待确认的 PGS 预检不再现场起任何子进程。"""
    calls = _stub_bundled_environment(monkeypatch)
    pgs._environment()  # 相当于启动预热（conftest 已把 warm_capability 换成空操作）
    video = tmp_path / "Movie.mkv"
    video.write_bytes(b"video")
    row = LibraryFile(
        id=42,
        library_id=1,
        media_item_id=1,
        file_path=str(video),
        duration_seconds=6000,
        subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "language": "chi"}],
        external_subtitles=[],
        source="scanned",
    )

    async def fake_load_row(_session, _file_id):  # noqa: ANN001
        return row

    async def fake_context(_session, _row):  # noqa: ANN001
        from movieclaw_api.services.subtitle_gen import translate

        return translate.FilmContext(title="Movie", year=None, genres=[], overview=None), "zh"

    monkeypatch.setattr(tasks, "_load_row", fake_load_row)
    monkeypatch.setattr(tasks, "_film_context", fake_context)
    before = dict(calls)

    for _ in range(3):  # 拨双语开关、换语言、重新检查都会再发一次预检
        pv = await tasks.preview(
            None,  # type: ignore[arg-type]
            42,
            "chs",
            secondary_language="eng",
        )
        assert pv.pgs_conversion is not None
        assert pv.pgs_conversion.language.confirmation_required
        assert len(pv.pgs_conversion.language_options) == len(pgs.OCR_LANGUAGE_LABELS)

    assert calls == before, "预检不该再起 seconv/tesseract"


def test_missing_component_tells_user_to_restart(monkeypatch) -> None:
    """环境只在启动时检测：缺组件的提示要说清楚装好后重启才生效。"""
    monkeypatch.setattr(pgs.sys, "platform", "linux")
    monkeypatch.setattr(pgs.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(
        pgs.shutil,
        "which",
        lambda name: "/usr/bin/ffmpeg" if name == "ffmpeg" else None,
    )
    monkeypatch.setattr(pgs, "_resolve_seconv", lambda: None)

    result = pgs.detect_capability("eng")

    assert any("重启" in item for item in result.suggestions)

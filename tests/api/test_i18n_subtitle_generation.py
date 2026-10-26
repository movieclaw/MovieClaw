"""Subtitle preflight and persisted jobs render per reader, without mutating source data."""

from copy import deepcopy
from dataclasses import asdict

from httpx import ASGITransport, AsyncClient

from movieclaw_api.api.deps import require_admin, require_login
from movieclaw_api.api.routes.subtitle_gen import _preview_view
from movieclaw_api.app import create_app
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import localize_fields, stored_fields
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.subtitle_gen import pgs, source, tasks, translate
from movieclaw_db.models import FileSource, LibraryFile
from movieclaw_media.models import MediaKind

from . import test_library_organize as organize

db = organize.db


async def test_subtitle_preflight_http_diagnostics_follow_each_reader(db, tmp_path):
    root = tmp_path / "movies"
    async with db.session() as session:
        library = await organize._make_library(session, kind=MediaKind.MOVIE, root=root)
        video = root / "User video.mkv"
        video.write_bytes(b"video")
        subtitle = video.with_suffix(".eng.srt")
        subtitle.write_text("1\n00:00:01,000 --> 00:00:02,000\nOriginal dialogue\n")
        row = LibraryFile(
            library_id=library.id,
            file_path=str(video),
            source=FileSource.SCANNED,
            duration_seconds=120,
            subtitle_streams=[],
            external_subtitles=[{"filename": subtitle.name, "format": "srt", "language": "eng"}],
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        file_id = row.id
    app = create_app()
    principal = lambda: Principal(kind="admin", name="tester")  # noqa: E731
    app.dependency_overrides[require_login] = principal
    app.dependency_overrides[require_admin] = principal
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://testserver"
    ) as client:
        for locale in ("en", "zh-Hans", "en"):
            response = await client.get(
                f"/api/v1/libraries/files/{file_id}/subtitles/generation-preview",
                headers={"Accept-Language": locale},
            )
            assert response.status_code == 200, response.text
            view = response.json()["data"]
            assert view["blocker"]["code"] == "unusable_text"
            assert view["candidates"][0]["key"] == subtitle.name
            assert view["candidates"][0]["language"] == "eng"
            assert view["blocker"]["message"].startswith(
                "Candidate “External subtitle " if locale == "en" else "候选「外挂 "
            )
            assert ("Only 1 dialogue cue" in view["blocker"]["message"]) == (locale == "en")
            assert view["candidates"][0]["reasons"][-1] == (
                "Only 1 dialogue cue; the track may be incomplete"
                if locale == "en"
                else "对白仅 1 条，疑似残缺轨"
            )
    assert subtitle.read_text().endswith("Original dialogue\n")


def test_cached_ocr_preflight_is_rendered_at_the_boundary():
    row = LibraryFile(
        file_path="/media/用户文件.mkv",
        library_id=1,
        subtitle_streams=[
            {"codec": "hdmv_pgs_subtitle", "language": "eng", "title": "Original label"}
        ],
    )
    ranked = source.rank_candidates(row, original_language="en", target_language="chs")
    capability = pgs._decide(pgs._Environment(platform_name="macOS", architecture="arm64"), "eng")
    plan = tasks.PgsConversionPlan(
        candidate=ranked[0],
        capability=capability,
        language=pgs.infer_ocr_language(row, ranked[0].candidate, "en"),
        language_options=(("eng", "英语"), ("chs", "简体中文")),
    )
    pv = tasks.Preview(
        candidates=ranked,
        chosen=None,
        event_count=0,
        estimated_tokens=0,
        already_generated=False,
        warnings=[],
        pgs_conversion=plan,
        blocker=tasks._preview_blocker(ranked, plan),
    )
    before = deepcopy(asdict(pv))
    for locale in ("en", "zh-Hans", "en"):
        with use_locale(locale):
            view = _preview_view(pv)
        assert view.pgs_conversion.message == (
            "ffmpeg was not found, so PGS tracks cannot be extracted from the media file"
            if locale == "en"
            else "系统中未找到 ffmpeg，无法从媒体文件抽取 PGS 轨道"
        )
        assert view.pgs_conversion.ocr_language_label == ("English" if locale == "en" else "英语")
        assert view.pgs_conversion.language_options[1].label == (
            "Simplified Chinese" if locale == "en" else "简体中文"
        )
        assert view.pgs_conversion.language_reason == (
            "Detected English from the track language tag"
            if locale == "en"
            else "根据轨道语言标记自动识别为 英语"
        )
        assert view.blocker.suggestions[-1] == (
            "Restart MovieClaw after installing or changing components to run detection again"
            if locale == "en"
            else "安装或修改后请重启 MovieClaw，才会重新检测"
        )
        assert view.candidates[0].excluded.startswith(
            "PGS image subtitles" if locale == "en" else "PGS 图形字幕"
        )
    assert asdict(pv) == before


def test_job_result_references_and_zero_counts_preserve_chinese_formatting():
    candidate = source.SourceCandidate(
        kind="embedded", key="0", language="eng", forced=False, sdh=False, format="srt"
    )
    origin = tasks._cand_message(candidate)
    result = tasks.GenResult(
        ok=True,
        filename="User video.ai.chi.srt",
        source_desc=origin["message"],
        source_message=origin,
        **stored_fields(
            "library.subtitleJob.completed",
            filename="User video.ai.chi.srt",
            source=origin,
            count=1200,
            failed=0,
            compressed=1200,
            overrun=0,
        ),
    )
    payload = tasks._result_payload(result)
    assert payload["message"] == (
        "已生成 User video.ai.chi.srt（参考：内封轨 0（eng/srt），1200 条对白，"
        "压缩改写 1200 条超读速译文）"
    )
    before = deepcopy(payload)
    with use_locale("en"):
        english = localize_fields(payload)
    assert english["source_desc"] == "Embedded track 0 (eng/srt)"
    assert "1,200 lines of dialogue; 1,200 lines shortened" in english["message"]
    assert "failed block" not in english["message"]
    with use_locale("zh-Hans"):
        assert localize_fields(payload)["message"] == payload["message"]
    assert payload == before


async def test_translation_progress_callbacks_keep_refs_and_chinese_text(tmp_path, monkeypatch):
    import json

    monkeypatch.setattr(translate, "cache_dir", lambda: tmp_path)
    phases = []

    async def chat(_system, user, _call):
        if "找出其中反复出现的人名" in user:
            return '{"items": []}'
        entries = json.loads(user.split("翻译下列对白：\n", 1)[1])
        return json.dumps({"items": [{"i": entry["i"], "t": "译文"} for entry in entries]})

    await translate.translate_events(
        chat,
        [(0, 2000, "Original dialogue")],
        translate.FilmContext(title="原片名", year=None, genres=[], overview=None),
        "chs",
        file_id=81,
        phase=lambda phase, message: phases.append((phase, message)),
    )
    assert phases[0][1]["message"] == "正在统一人名和专有名词"
    with use_locale("en"):
        rendered = localize_fields([message for _, message in phases])
    assert rendered[0]["message"] == "Standardizing names and proper nouns"
    assert rendered[1]["message"].startswith("Translating dialogue with ")
    assert phases[0][1]["message"] == "正在统一人名和专有名词"

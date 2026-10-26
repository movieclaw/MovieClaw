"""Organization plans and persisted failures retain references across languages."""

from copy import deepcopy
from dataclasses import asdict

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import localize_fields, stored_fields, stored_message
from movieclaw_api.services.library.organize import (
    OrganizeSummary,
    _MoveError,
    _plan_from_job,
    build_organize_plan,
    organize_library,
    render_organize_errors,
)
from movieclaw_media.models import MediaKind

from . import test_jobs as jobs_tests
from . import test_library_organize as organize_tests
from .test_library_organize import _add_file, _make_item, _make_library

db = organize_tests.db
job_db = jobs_tests.job_db
job_client = jobs_tests.job_client


async def test_plan_references_survive_job_serialization_and_readers(db, tmp_path):
    root = tmp_path / "movies"
    async with db.session() as session:
        library = await _make_library(session, kind=MediaKind.MOVIE, root=root)
        clip = root / "unknown.mkv"
        clip.write_bytes(b"unidentified")
        _add_file(session, library, None, clip)
        await session.commit()
        with use_locale("en"):
            plan = await build_organize_plan(session, library)
    restored = _plan_from_job(asdict(plan))
    skip = restored.skips[0]
    assert skip.reason == "尚未识别身份，请先在「待识别」里认领"
    for locale in ("en", "zh-Hans", "en"):
        with use_locale(locale):
            text = stored_message(skip.reason, skip.reason_key, skip.reason_params)
            assert text == (
                "Not identified yet. Assign a title in Unidentified first"
                if locale == "en"
                else skip.reason
            )
    assert clip.read_bytes() == b"unidentified"


async def test_real_move_collision_is_preserved_and_retranslated_after_restart(db, tmp_path):
    root = tmp_path / "movies"
    async with db.session() as session:
        library = await _make_library(session, kind=MediaKind.MOVIE, root=root)
        movie = await _make_item(
            session, kind=MediaKind.MOVIE, tmdb_id=300, title="Film", year=2020
        )
        source = root / "messy.mkv"
        source.write_bytes(b"source")
        _add_file(session, library, movie, source)
        await session.commit()
        plan = await build_organize_plan(session, library)
    from pathlib import Path

    target = Path(plan.renames[0].target_path)
    target.parent.mkdir(parents=True)
    target.write_bytes(b"unrelated target")  # Created after the preview; never overwrite it.
    with use_locale("en"):
        summary = await organize_library(library.id, plan=plan)
    assert summary.renamed == 0
    assert summary.error_messages[0]["message_key"] == "library.organize.bothExist"
    saved = asdict(summary)
    before = deepcopy(saved)
    for locale in ("en", "zh-Hans", "en"):
        with use_locale(locale):
            errors = render_organize_errors(saved["errors"], saved["error_messages"])
            assert ("Both source and target exist" in errors[0]) == (locale == "en")
            assert str(source) in errors[0] and str(target) in errors[0]
    assert saved == before
    assert source.read_bytes() == b"source"
    assert target.read_bytes() == b"unrelated target"


def test_nested_sidecar_failures_and_legacy_conclusions():
    error = _MoveError(
        message_key="library.organize.sourceMissing", message_params={"path": "/User files/a.srt"}
    )
    summary = OrganizeSummary(library_id=1)
    summary.add_error(stored_fields("library.organize.sidecarFailed", detail=error.fields))
    with use_locale("en"):
        assert render_organize_errors(summary.errors, summary.error_messages) == [
            "Could not rename sidecar file: Source file is no longer at its original path; "
            "skipped: /User files/a.srt"
        ]
        assert render_organize_errors(["Historical third-party detail"], []) == [
            "Historical third-party detail"
        ]


def test_job_result_errors_and_plan_skip_references_render_without_rewriting_snapshots():
    message = stored_fields("library.organize.sourceMissing", path="/User files/a.mp4")
    result = {"errors": [message["message"]], "error_messages": [message]}
    plan = {"reason": "只在网盘上，不整理文件名", "reason_key": "library.organize.cloudOnly"}
    before = deepcopy((result, plan))
    for locale in ("en", "zh-Hans", "en"):
        with use_locale(locale):
            rendered = localize_fields(result)
            assert ("Source file" in rendered["errors"][0]) == (locale == "en")
            assert ("Files stored only" in localize_fields(plan)["reason"]) == (locale == "en")
    assert (result, plan) == before


async def test_persisted_organization_collision_follows_http_reader(job_db, job_client, tmp_path):
    from pathlib import Path

    from movieclaw_api.services import jobs
    from movieclaw_api.services.library.organize import enqueue_organize_job
    from movieclaw_db.models import JobStatus

    root = tmp_path / "movies"
    async with job_db.session() as session:
        library = await _make_library(session, kind=MediaKind.MOVIE, root=root)
        movie = await _make_item(
            session, kind=MediaKind.MOVIE, tmdb_id=300, title="Original title", year=2020
        )
        source = root / "messy.mkv"
        source.write_bytes(b"source")
        _add_file(session, library, movie, source)
        await session.commit()
        plan = await build_organize_plan(session, library)
        created = await enqueue_organize_job(session, library, plan)
    target = Path(plan.renames[0].target_path)
    target.parent.mkdir(parents=True)
    target.write_bytes(b"unrelated")
    await jobs.init_job_dispatcher(max_parallel=1)
    await jobs_tests._wait_status(created.job.id, JobStatus.SUCCEEDED, timeout=10)
    for locale in ("en", "zh-Hans", "en"):
        response = await job_client.get(
            f"/jobs/{created.job.id}", headers={"Accept-Language": locale}
        )
        assert response.status_code == 200, response.text
        row = response.json()["data"]
        assert ("Organization complete" in row["result"]["message"]) == (locale == "en")
        assert ("Both source and target exist" in row["result"]["errors"][0]) == (locale == "en")
        assert row["progress"]["message"] == row["result"]["message"]
    async with job_db.session() as session:
        saved = await jobs.get_job(session, created.job.id)
        assert saved.result["errors"][0].startswith("源与目标同时存在")
        assert saved.result["error_messages"][0]["message_key"] == "library.organize.bothExist"
    assert source.read_bytes() == b"source" and target.read_bytes() == b"unrelated"

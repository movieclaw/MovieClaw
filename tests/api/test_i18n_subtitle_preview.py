"""Subtitle diagnostics follow each reader, preserving reference and numeric data."""

from copy import deepcopy

from httpx import ASGITransport, AsyncClient

from movieclaw_api.api.deps import require_admin, require_login
from movieclaw_api.app import create_app
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import stored_fields, stored_message
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.subtitle_gen import source, tasks
from movieclaw_db.models import FileSource, LibraryFile
from movieclaw_media.models import MediaKind

from . import test_library_organize as organize

db = organize.db


async def test_preview_errors_and_calibration_follow_the_http_reader(db, tmp_path):
    root = tmp_path / "movies"
    async with db.session() as session:
        library = await organize._make_library(session, kind=MediaKind.MOVIE, root=root)
        video = root / "User video.mkv"
        video.write_bytes(b"unchanged video")
        subtitle = video.with_suffix(".eng.srt")
        subtitle.write_text("1\n00:00:01,000 --> 00:00:02,000\nUser dialogue\n")
        file = LibraryFile(
            library_id=library.id,
            file_path=str(video),
            source=FileSource.SCANNED,
            subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "language": "eng"}],
            external_subtitles=[{"filename": subtitle.name, "format": "srt", "language": "eng"}],
        )
        session.add(file)
        await session.commit()
        await session.refresh(file)
        file_id = file.id
    app = create_app()
    principal = lambda: Principal(kind="admin", name="tester")  # noqa: E731
    app.dependency_overrides[require_login] = principal
    app.dependency_overrides[require_admin] = principal
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://testserver"
    ) as client:
        for locale in ("en", "zh-Hans", "en"):
            headers = {"Accept-Language": locale}
            response = await client.get(
                f"/api/v1/libraries/files/{file_id}/subtitles/preview",
                params={"track": "embedded:0"},
                headers=headers,
            )
            assert response.status_code == 400, response.text
            error = response.json()
            assert error["message_key"] == "errors.subtitles.previewGraphic"
            assert error["params"] == {"format": "HDMV_PGS_SUBTITLE"}
            assert ("image subtitle" in error["message"].lower()) == (locale == "en")
            response = await client.post(
                f"/api/v1/libraries/files/{file_id}/subtitles/timing-calibration",
                json={"filename": subtitle.name},
                headers=headers,
            )
            assert response.status_code == 200, response.text
            result = response.json()["data"]
            assert result["ok"] is False
            assert result["message_key"] == "library.subtitleCalibration.tooFew"
            assert result["message"] == (
                "There are too few subtitle cues for reliable calibration"
                if locale == "en"
                else "字幕事件太少，无法可靠校准"
            )
    assert video.read_bytes() == b"unchanged video"
    assert subtitle.read_text().endswith("User dialogue\n")


def test_calibration_message_renders_nested_reference_and_precision():
    candidate = source.SourceCandidate(
        kind="embedded", key="2", language=None, forced=False, sdh=False, format="srt"
    )
    # These fields also supply the original Chinese description used by generation.
    reference = tasks._cand_message(candidate)
    assert tasks._cand_desc(candidate) == "内封轨 2（未知语言/srt）"
    result = stored_fields(
        "library.subtitleCalibration.completed", reference=reference, scale=1.0001, offset=-2.5
    )
    original = deepcopy(result)
    for locale in ("en", "zh-Hans", "en"):
        with use_locale(locale):
            message = stored_message(
                result["message"], result["message_key"], result["message_params"]
            )
        assert message == (
            "Calibration complete (reference: Embedded track 2 (unknown language/srt)): "
            "scale 1.0001, offset -2.50 seconds. The subtitle file has been updated."
            if locale == "en"
            else "校准完成（参考：内封轨 2（未知语言/srt））："
            "缩放 1.0001、平移 -2.50 秒，已覆盖写回"
        )
    assert result == original

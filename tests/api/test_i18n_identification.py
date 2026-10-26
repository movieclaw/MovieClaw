"""Identification evidence is stored once and rendered for each HTTP reader."""

from copy import deepcopy

from httpx import ASGITransport, AsyncClient

from movieclaw_api.api.deps import require_admin, require_login
from movieclaw_api.app import create_app
from movieclaw_api.i18n.stored import stored_fields
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.resolve import LocalEvidence, _Candidate, _to_user_candidate
from movieclaw_db.models import FileSource, LibraryFile
from movieclaw_media.models import MediaKind

from . import test_library_organize as organize

# A real migrated SQLite database; HTTP reads use separate sessions.
db = organize.db


async def test_unidentified_reason_and_candidate_evidence_follow_each_reader(db, tmp_path):
    from dataclasses import asdict

    root = tmp_path / "movies"
    message = stored_fields(
        "library.identification.unconfirmed",
        title="User title",
        dated="yes",
        year=2020,
        detailed="yes",
        detail=stored_fields("library.identification.noSearchResults"),
    )
    candidate = _to_user_candidate(
        MediaKind.TV,
        LocalEvidence(title="Original title", year=2020, season=2, local_episodes=8),
        _Candidate(
            tmdb_id=123,
            title="用户影片名",
            original_title="Original title",
            year=2020,
            season_count=3,
            episode_counts={2: 8},
        ),
    )
    async with db.session() as session:
        library = await organize._make_library(session, kind=MediaKind.MOVIE, root=root)
        file = LibraryFile(
            library_id=library.id,
            file_path=str(root / "User filename.mp4"),
            source=FileSource.SCANNED,
            unidentified_reason=message["message"],
            unidentified_message=message,
            unidentified_code="no_match",
            unidentified_candidates=[asdict(candidate)],
        )
        session.add(file)
        await session.commit()
        await session.refresh(file)
        file_id = file.id
    before = deepcopy((message, asdict(candidate)))
    app = create_app()
    principal = lambda: Principal(kind="admin", name="tester")  # noqa: E731
    app.dependency_overrides[require_login] = principal
    app.dependency_overrides[require_admin] = principal
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://testserver"
    ) as client:
        for locale in ("en", "zh-Hans", "en"):
            response = await client.get(
                "/api/v1/libraries/identification/unidentified-files",
                headers={"Accept-Language": locale},
            )
            assert response.status_code == 200, response.text
            group = response.json()["data"][0]
            assert ("Could not confirm" in group["reason"]) == (locale == "en")
            assert ("TMDB search returned no results" in group["reason"]) == (locale == "en")
            choice = group["candidates"][0]
            assert choice["title"] == "用户影片名" and choice["tmdb_id"] == 123
            assert choice["reasons"] == (
                ["Year matches", "At least 2 seasons", "8 local episodes match"]
                if locale == "en"
                else ["年份相同", "季数≥2", "本地 8 集吻合"]
            )
    async with db.session() as session:
        saved = await session.get(LibraryFile, file_id)
        assert saved.unidentified_message == before[0]
        assert saved.unidentified_candidates == [before[1]]
        assert saved.unidentified_reason == before[0]["message"]


async def test_root_reconciliation_keeps_reason_and_reference_together(db, tmp_path):
    from movieclaw_api.services.library.scan import _merge_same_file_rows

    root = tmp_path / "movies"
    async with db.session() as session:
        library = await organize._make_library(session, kind=MediaKind.MOVIE, root=root)
        for index, existing_message in enumerate(
            (None, stored_fields("library.identification.unparsable"))
        ):
            duplicate_message = stored_fields("library.identification.episodesInMovie")
            survivor = LibraryFile(
                library_id=library.id,
                file_path=str(root / f"old{index}.mp4"),
                source=FileSource.SCANNED,
                unidentified_reason=existing_message["message"] if existing_message else None,
                unidentified_message=existing_message,
            )
            duplicate = LibraryFile(
                library_id=library.id,
                file_path=str(root / f"new{index}.mp4"),
                source=FileSource.SCANNED,
                unidentified_reason=duplicate_message["message"],
                unidentified_message=duplicate_message,
            )
            session.add(survivor)
            session.add(duplicate)
            await session.commit()
            await session.refresh(survivor)
            await session.refresh(duplicate)
            await _merge_same_file_rows(session, survivor, duplicate, file_path=duplicate.file_path)
            await session.commit()
            await session.refresh(survivor)
            expected = existing_message or duplicate_message
            assert survivor.unidentified_reason == expected["message"]
            assert survivor.unidentified_message == expected

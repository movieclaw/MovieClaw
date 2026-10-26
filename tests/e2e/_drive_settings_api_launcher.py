"""Drive UI stack with the existing loopback metadata service used by real scans."""

from tests.e2e._ai_settings_api_launcher import app  # noqa: F401

from movieclaw_api.services import media_discover
from movieclaw_api.services.library import scan

scan.get_tmdb_client = media_discover.get_tmdb_client


@app.post("/api/v1/__lab/playback/clip")
async def install_prepared_clip(payload: dict):
    """Install a real temporary MP4 through the clip registry for settings E2E."""
    import shutil
    from pathlib import Path

    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.reels import clips
    from movieclaw_api.services.reels.segments import ReelSegment
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem
    from movieclaw_db.repositories.library_repo import LibraryRepository

    source = Path(payload["path"]).resolve()
    assert source.is_relative_to(Path(get_settings().data_dir).resolve())
    async with get_database().session() as session:
        item = MediaItem(
            kind="movie",
            tmdb_id=880000 + payload["library_id"],
            title="Fixture title",
            original_title="Fixture title",
            year=2024,
        )
        session.add(item)
        await session.flush()
        file = LibraryFile(
            library_id=payload["library_id"],
            media_item_id=item.id,
            file_path=str(source),
            size_bytes=source.stat().st_size,
            source=FileSource.SCANNED,
        )
        session.add(file)
        await session.commit()
        await LibraryRepository(session).refresh_stats([payload["library_id"]])
        folder = clips.clips_root() / str(file.id)
        folder.mkdir(parents=True, exist_ok=True)
        part = folder / "fixture.part"
        shutil.copyfile(source, part)
        installed = await clips.install(
            file,
            ReelSegment(
                file_id=int(file.id),
                start_ms=0,
                end_ms=8000,
                method="fixture",
                score=1,
                prefetch=(),
                cover=None,
            ),
            part,
        )
        return {"path": str(installed.path), "file_id": file.id}

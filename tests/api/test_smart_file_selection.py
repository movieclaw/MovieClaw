from unittest.mock import AsyncMock

import pytest

from movieclaw_api.services.subscription.file_selection import plan_strict_file_selection
from movieclaw_api.services.torrent_submit import apply_strict_file_selection
from movieclaw_downloader.models import SubmitResult, TorrentFile, TorrentStatus

FILES = [f"Cold.Hunt.S01/Cold.Hunt.S01E{i:02}.2160p.WEB-DL-UBWEB.mkv" for i in range(1, 19)]
NEEDED = {(1, 16), (1, 17), (1, 18)}


def test_only_last_three_and_no_archive_or_extra_files():
    plan = plan_strict_file_selection(
        FILES + ["Complete.zip", "poster.jpg"], NEEDED, known_seasons=[1]
    )
    assert plan.keep_indices == [15, 16, 17]
    assert len(plan.skip_indices) == 17


@pytest.mark.parametrize(
    "files",
    [
        ["Complete.zip"],
        FILES[:-1],
        ["S01E16-E18.mkv"],
        FILES + ["unknown.mkv"],
        FILES + [FILES[-1]],
    ],
)
def test_ambiguous_or_incomplete_files_fail_closed(files):
    with pytest.raises(ValueError):
        plan_strict_file_selection(files, NEEDED, known_seasons=[1])


@pytest.mark.parametrize("failure", [None, "write", "readback", "resume", "foreign"])
async def test_strict_selection_verifies_before_resume_and_retry_is_same_task(failure):
    state = TorrentStatus(
        info_hash="a" * 40,
        name="Cold Hunt",
        progress=0,
        completed=False,
        save_path="/downloads",
        state="paused",
        tags=["owner"],
        files=[TorrentFile(index=i * 2, path=f, size_bytes=100) for i, f in enumerate(FILES)],
    )
    if failure == "foreign":
        state.tags = ["other"]
    downloader = AsyncMock()
    downloader.get_torrent.side_effect = lambda *a, **kw: state.model_copy(deep=True)

    async def select(_hash, indices):
        assert _hash == state.info_hash
        assert indices == [30, 32, 34]  # 下载器真实索引，不假定列表位置。
        if failure == "write":
            raise RuntimeError("write failed")
        if failure != "readback":
            for f in state.files:
                f.selected = f.index in indices

    downloader.set_file_selection.side_effect = select
    if failure == "resume":
        downloader.resume.side_effect = RuntimeError("resume failed")
    result = SubmitResult(info_hash=state.info_hash, already_exists=True)
    if failure:
        with pytest.raises((ValueError, RuntimeError)):
            await apply_strict_file_selection(
                downloader, result, NEEDED, known_seasons=[1], owner="owner"
            )
        if failure != "resume":
            downloader.resume.assert_not_called()
        if failure == "foreign":
            downloader.set_file_selection.assert_not_called()
    else:
        for _ in range(2):
            result = await apply_strict_file_selection(
                downloader, result, NEEDED, known_seasons=[1], owner="owner"
            )
            assert result.skipped_file_count == 15 and not result.already_exists
        assert downloader.set_file_selection.await_count == 1
        downloader.submit.assert_not_called()


async def test_scope_cancelled_before_resume_stays_paused():
    state = TorrentStatus(
        info_hash="a" * 40,
        name="Cold Hunt",
        progress=0,
        completed=False,
        save_path="/downloads",
        state="paused",
        tags=["owner"],
        files=[TorrentFile(path=f, size_bytes=100, selected=i >= 15) for i, f in enumerate(FILES)],
    )
    downloader = AsyncMock()
    downloader.get_torrent.return_value = state
    check = AsyncMock(side_effect=ValueError("subscription paused"))
    with pytest.raises(ValueError, match="subscription paused"):
        await apply_strict_file_selection(
            downloader,
            SubmitResult(info_hash=state.info_hash),
            NEEDED,
            known_seasons=[1],
            owner="owner",
            before_resume=check,
        )
    downloader.resume.assert_not_called()


@pytest.mark.parametrize(
    "name", ["S01E16-E18.mkv", "1x16-18.mkv", "S01E16.S01E18.mkv", "EP16-EP18.mkv"]
)
def test_combined_episode_file_is_never_selected(name):
    with pytest.raises(ValueError):
        plan_strict_file_selection([name], {(1, 16)}, known_seasons=[1])


def test_explicit_filename_release_separator_and_unknown_season():
    assert plan_strict_file_selection(["S01E16-UBWEB.mkv"], {(1, 16)}).keep_indices == [0]
    with pytest.raises(ValueError):
        plan_strict_file_selection(["EP16.mkv"], {(1, 16)}, known_seasons=[1, 2])

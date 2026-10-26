from unittest.mock import AsyncMock

import pytest

from movieclaw_api.services.subscription.file_selection import (
    UnsatisfiableSelection,
    plan_strict_file_selection,
)
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


# NAS 现场（智能投递 #219）：13 集纪录片订阅被投到全 8 集的同名剧整季包
STAIRCASE = [
    "The.Staircase.S01.2160p.Max.WEB-DL.DDP.5.1.Atmos.DoVi.HDR.H.265-CHDWEB/"
    f"The.Staircase.S01E{n:02}.{title}.2160p.Max.WEB-DL.DDP.5.1.Atmos.DoVi.HDR.H.265-CHDWEB.mkv"
    for n, title in enumerate(
        [
            "911",
            "Chiroptera",
            "The.Great.Dissembler",
            "Common.Sense",
            "The.Beating.Heart",
            "Red.in.Tooth.and.Claw",
            "Seek.and.Ye.Shall",
            "Zlaticka.pro.kazdeho",
        ],
        start=1,
    )
]


def test_missing_episodes_are_a_definite_verdict_naming_the_units():
    with pytest.raises(UnsatisfiableSelection) as exc:
        plan_strict_file_selection(STAIRCASE, {(1, n) for n in range(1, 14)}, known_seasons=[1])
    assert exc.value.units == {(1, n) for n in range(9, 14)}
    assert "S01E09" in str(exc.value) and "S01E13" in str(exc.value)
    plan = plan_strict_file_selection(STAIRCASE, {(1, n) for n in range(1, 9)}, known_seasons=[1])
    assert plan.keep_indices == list(range(8))


def test_unclear_files_are_skipped_not_fatal_when_needed_units_are_all_present():
    """#996：认不出的文件只是不选，不连累整颗候选；需要的集仍须一一落在确定文件上。"""
    files = FILES + ["unknown.mkv", "Cold.Hunt.S01E01-E02.mkv", "Cold.Hunt.S01E00.mkv"]
    plan = plan_strict_file_selection(files, NEEDED, known_seasons=[1])
    assert plan.keep_indices == [15, 16, 17]
    assert {18, 19, 20} <= set(plan.skip_indices)
    with pytest.raises(UnsatisfiableSelection) as exc:
        plan_strict_file_selection(FILES[:-1] + ["unknown.mkv"], NEEDED, known_seasons=[1])
    assert exc.value.units == {(1, 18)}
    assert "1 个视频文件无法确定季集" in str(exc.value) and "unknown.mkv" in str(exc.value)


@pytest.mark.parametrize(
    "path,unit",
    [
        ("海绵宝宝 国语 12季/海绵宝宝第10季 第3集_3840x2160_H265_23.20_886.39MB.mp4", (10, 3)),
        ("海绵宝宝/海绵宝宝 - 第01季 第01集 国英双语 1080p.mkv", (1, 1)),
        ("海绵宝宝/海绵宝宝.第十季.第三集.mkv", (10, 3)),
        ("海绵宝宝/海绵宝宝 第1季第01集.mkv", (1, 1)),
        ("海绵宝宝/海绵宝宝 第一季 第一集.mkv", (1, 1)),
        ("海绵宝宝/第1季/海绵宝宝 第01集.mkv", (1, 1)),
        ("海绵宝宝/第1季/海绵宝宝 第01话.mkv", (1, 1)),
    ],
)
def test_chinese_season_episode_names_are_selectable(path, unit):
    """#996 验收表：中文「第N季 第N集」与季目录下的「第N集/话」。多季合辑不借单季台账猜季。"""
    other = "海绵宝宝/海绵宝宝 第2季 第5集.mkv"
    plan = plan_strict_file_selection([other, path], {unit}, known_seasons=[1, 2, 10])
    assert plan.keep_indices == [1]


@pytest.mark.parametrize(
    "name", ["海绵宝宝 第1季 第01-02集.mkv", "海绵宝宝 第1季 第01集-第02集.mkv", "第38集团军.mkv"]
)
def test_chinese_ranges_are_never_selected(name):
    with pytest.raises(UnsatisfiableSelection):
        plan_strict_file_selection([name], {(1, 1)}, known_seasons=[1])

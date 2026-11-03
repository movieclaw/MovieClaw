"""旁车文件的挑法（services/drives/sidecars.py，cloud-storage.md §5.5）。"""

from __future__ import annotations

import os
from collections import Counter
from pathlib import Path

from movieclaw_api.services.drives import sidecars
from movieclaw_api.services.drives.sidecars import sidecar_files


def _tree(root: Path, names: list[str]) -> None:
    for name in names:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x")


def _names(root: Path, found: list[Path]) -> set[str]:
    return {p.relative_to(root).as_posix() for p in found}


def test_episode_takes_its_own_sidecars_and_every_level_up_to_the_library_root(tmp_path):
    _tree(
        tmp_path,
        [
            "poster.jpg",  # 库根自己的图
            "剧集/tvshow.nfo",
            "剧集/poster.jpg",
            "剧集/clearlogo.png",
            "剧集/season01-poster.jpg",
            "剧集/第一季/S01E01.mkv",
            "剧集/第一季/S01E01.nfo",
            "剧集/第一季/S01E01-thumb.jpg",
            "剧集/第一季/S01E01.zh.srt",
            "剧集/第一季/S01E01.ass",
            "剧集/第一季/S01E02.mkv",
            "剧集/第一季/notes.txt",
            "剧集/第一季/S01E01.srt.part",
            "剧集/extras/behind.jpg",  # 旁边的子目录不算
        ],
    )
    found = sidecar_files(
        [str(tmp_path)], tmp_path / "剧集/第一季/S01E01.mkv", images=True, nfo=True
    )
    assert _names(tmp_path, found) == {
        "剧集/tvshow.nfo",
        "剧集/poster.jpg",
        "剧集/clearlogo.png",
        "剧集/season01-poster.jpg",
        "剧集/第一季/S01E01.nfo",
        "剧集/第一季/S01E01-thumb.jpg",
        "剧集/第一季/S01E01.zh.srt",
        "剧集/第一季/S01E01.ass",
    }


def test_video_at_the_library_root_only_takes_files_named_after_it(tmp_path):
    _tree(
        tmp_path,
        [
            "单片.mp4",
            "单片.nfo",
            "单片-poster.jpg",
            "单片.zh.srt",
            "单片续集.nfo",  # 主干前缀相同但不是它的
            "poster.jpg",
            "movie.nfo",
        ],
    )
    found = sidecar_files([str(tmp_path)], tmp_path / "单片.mp4", images=True, nfo=True)
    assert _names(tmp_path, found) == {"单片.nfo", "单片-poster.jpg", "单片.zh.srt"}


def test_switches_turn_off_artwork_and_nfo_but_not_subtitles(tmp_path):
    _tree(tmp_path, ["片/片.mkv", "片/poster.jpg", "片/movie.nfo", "片/片.zh.srt"])
    video = tmp_path / "片/片.mkv"
    assert _names(tmp_path, sidecar_files([str(tmp_path)], video, images=False, nfo=True)) == {
        "片/movie.nfo",
        "片/片.zh.srt",
    }
    assert _names(tmp_path, sidecar_files([str(tmp_path)], video, images=True, nfo=False)) == {
        "片/poster.jpg",
        "片/片.zh.srt",
    }
    assert _names(tmp_path, sidecar_files([str(tmp_path)], video, images=False, nfo=False)) == {
        "片/片.zh.srt"
    }


def test_multi_root_library_stops_at_the_right_root_and_ignores_outside_videos(tmp_path):
    first, second = tmp_path / "a", tmp_path / "b"
    _tree(second, ["片/片.mkv", "片/poster.jpg"])
    _tree(tmp_path, ["outside.mkv", "outside.nfo"])
    roots = [str(first), str(second)]
    found = sidecar_files(roots, second / "片/片.mkv", images=True, nfo=True)
    assert _names(second, found) == {"片/poster.jpg"}
    # b 的上一级（tmp_path）不是库根，不往上找
    assert sidecar_files(roots, tmp_path / "outside.mkv", images=True, nfo=True) == []


def test_one_pass_lists_each_directory_once_for_a_whole_season(tmp_path, monkeypatch):
    episodes = [f"剧集/第一季/S01E{n:02d}.mkv" for n in range(1, 11)]
    _tree(
        tmp_path,
        [
            *episodes,
            *(e.replace(".mkv", ".nfo") for e in episodes),
            "剧集/tvshow.nfo",
            "剧集/poster.jpg",
            "剧集/第二季/S02E01.mkv",
            "剧集/第二季/S02E01.zh.srt",
            "单片.mp4",
            "单片.nfo",
        ],
    )
    listed: Counter[str] = Counter()
    real_scandir = os.scandir

    def counting_scandir(path=".", *args):
        if isinstance(path, (str, os.PathLike)) and Path(path).is_relative_to(tmp_path):
            listed[Path(path).relative_to(tmp_path).as_posix()] += 1
        return real_scandir(path, *args)

    monkeypatch.setattr(sidecars.os, "scandir", counting_scandir)
    videos = [str(tmp_path / v) for v in [*episodes, "剧集/第二季/S02E01.mkv", "单片.mp4"]]
    pending = sidecars._changed(videos, [str(tmp_path)], {}, images=True, nfo=True)
    # 每个目录（季目录、剧集目录、库根）一轮只列一次
    assert listed == {"剧集/第一季": 1, "剧集/第二季": 1, "剧集": 1, ".": 1}
    # 列举结果共用后挑出的文件不变：每个旁车文件一份
    assert _names(tmp_path, [item.path for item in pending]) == {
        *(e.replace(".mkv", ".nfo") for e in episodes),
        "剧集/tvshow.nfo",
        "剧集/poster.jpg",
        "剧集/第二季/S02E01.zh.srt",
        "单片.nfo",
    }

"""库目录命名惯例的确定性判定（issue #497）。

识别链里"哪一层是季目录、哪一层是条目目录、季号从哪来"全部是确定性规则：
删除条目、待识别分组、NFO 写回都挂在这些判定上，必须可穷举、可证明、跨
模型版本稳定。本文件把整理工具（Emby/Jellyfin/Plex/TMM/MoviePilot）与
MovieClaw 自己的命名模板会产出的写法钉成回归用例：

- 纯季目录（``Season 4-第 4 季-(2007)`` 这类带装饰的写法）；
- 带片名的季包目录（``House.M.D.S04.1080p``、``豪斯医生 第四季``）；
- ``4x01`` 单集写法；
- 条目目录 × 季目录 × 文件名的布局矩阵：条目目录与季集号都得对；
- 命名模板往返：MovieClaw 自己写出的目录，扫描器必须读得回来。
"""

from __future__ import annotations

import itertools
from pathlib import Path
from types import SimpleNamespace

import pytest

from movieclaw_api.services.library.layout import (
    entry_dir_of,
    explicit_unit,
    pack_season,
    season_from_dir,
)
from movieclaw_api.services.library.naming import (
    DEFAULT_TEMPLATES,
    NamingTemplates,
    entry_dir_name_of,
    season_dir_name,
    validate_template,
)
from movieclaw_api.services.library.units import resolve_units


@pytest.mark.parametrize(
    ("name", "season"),
    [
        ("Season 04", 4),
        ("Season 4", 4),
        ("season.3", 3),
        ("S02", 2),
        ("Series 2", 2),
        ("Specials", 0),
        ("特别篇", 0),
        ("Season 0", 0),
        # issue #497：整理工具把 TMDB 季名与季播年拼进季目录
        ("Season 4-第 4 季-(2007)", 4),
        ("Season 12-第 12 季-(2016)", 12),
        ("Season 1 (2004)", 1),
        ("Season 01 [2004]", 1),
        ("S01 (2004)", 1),
        ("第4季", 4),
        ("第 4 季", 4),
        ("第四季", 4),
        ("第十二季", 12),
        ("第二十季", 20),
        ("第四季 (2007)", 4),
    ],
)
def test_season_dir_recognized(name: str, season: int) -> None:
    assert season_from_dir(Path(name)) == season


@pytest.mark.parametrize(
    "name",
    [
        "豪斯医生(2004)[tmdbid=1408]",
        # 带片名的季包目录不是"纯季目录"（它另由 pack_season 处理）
        "Show S01 1080p",
        "豪斯医生 第四季",
        "Season 1 - Pilot Arc",
        # 前后两个季号矛盾：宁可不认
        "Season 4-第 5 季",
        # 片名里的 S/Season/季字样
        "S.W.A.T. (2017)",
        "S1mple",
        "Season of the Witch (2011)",
        "SPY×FAMILY (2022)",
        "第四季度报告",
        "2004",
    ],
)
def test_non_season_dir_rejected(name: str) -> None:
    assert season_from_dir(Path(name)) is None


@pytest.mark.parametrize(
    ("name", "season"),
    [
        ("House.M.D.S04.1080p.BluRay.x264-DEMAND", 4),
        ("豪斯医生 第四季", 4),
        ("豪斯医生.第四季.2007.1080p", 4),
        ("House Season 4", 4),
        # 区间 = 多季合集，没有单一季号
        ("House.S01-S08.Complete", None),
        ("豪斯医生 第一至八季", None),
        # 单集名、词内片段、季度
        ("Show.S02E03", None),
        ("S1m0ne (2002)", None),
        ("第四季度", None),
        ("豪斯医生 (2004)", None),
    ],
)
def test_pack_season(name: str, season: int | None) -> None:
    assert pack_season(name) == season


def test_nxmm_episode_notation() -> None:
    """Kodi/Plex/Emby 都认的 ``4x01``；分辨率与编码尾巴不误吃。"""
    assert explicit_unit("House - 4x01 - Alone") == (4, 1)
    assert explicit_unit("House.M.D.4x12") == (4, 12)
    assert explicit_unit("Movie.1920x1080") is None
    assert explicit_unit("Show.x264-GROUP") is None
    # SxxEyy 仍然优先
    assert explicit_unit("Show.S02E03.2x05") == (2, 3)


@pytest.mark.parametrize(
    "stem,unit",
    [
        ("海绵宝宝第10季 第3集_3840x2160_H265_23.20_886.39MB", (10, 3)),
        ("海绵宝宝 - 第01季 第01集 国英双语 1080p", (1, 1)),
        ("海绵宝宝.第十季.第三集", (10, 3)),
        ("海绵宝宝 第1季第01集", (1, 1)),
        ("海绵宝宝 第一季 第一集", (1, 1)),
        ("某剧 第2季 第5话", (2, 5)),
        # 区间/合集、季度、无季号都不是确定的单集声明
        ("海绵宝宝 第1季 第01-02集", None),
        ("海绵宝宝 第1季 第01集-第02集", None),
        ("某剧 第2季度报告 第3集", None),
        ("海绵宝宝 第01集", None),
    ],
)
def test_chinese_season_episode_unit(stem: str, unit) -> None:
    """issue #996：中文「第N季 第M集」与 SxxEyy 同样是确定的季集声明。"""
    assert explicit_unit(stem) == unit


def test_title_bearing_season_pack_groups_under_entry(tmp_path: Path) -> None:
    """带片名的季包目录：父目录明确是条目时归到父目录，是分组目录时自己当条目。

    后一半是删除安全的底线——条目目录会被「删除条目」整目录删掉，把「欧美剧」
    误认成条目的代价是删光整个分组。
    """
    root = tmp_path / "tv"
    pack = "House.M.D.S04.1080p.BluRay"
    for show in ("豪斯医生 (2004)", "豪斯医生(2004)[tmdbid=1408]"):
        file = root / "欧美剧" / show / pack / "House.M.D.S04E01.mkv"
        assert entry_dir_of([root], file) == root / "欧美剧" / show
    loose = root / "欧美剧" / pack / "House.M.D.S04E01.mkv"
    assert entry_dir_of([root], loose) == root / "欧美剧" / pack


# ---------------------------------------------------------------------------
# 布局矩阵：条目目录 × 季目录 × 文件名，条目目录与 (季, 集) 都必须对
# ---------------------------------------------------------------------------

_SHOW_DIRS = {
    "pinned": "豪斯医生(2004)[tmdbid=1408]",
    "conv_zh": "豪斯医生 (2004)",
    "conv_en": "House M.D. (2004)",
    "bare": "豪斯医生",
    "torrent": "House.M.D.Complete.Series.1080p.BluRay",
}
_SEASON_DIRS = {
    "Season04": "Season 04",
    "issue497": "Season 4-第 4 季-(2007)",
    "cn_digit": "第4季",
    "cn_numeral": "第四季",
    "with_year": "Season 4 (2007)",
    "S04": "S04",
    "titled": "豪斯医生 第四季",
    "torrent_pack": "House.M.D.S04.1080p.BluRay.x264-DEMAND",
}
_FILES = {
    "emby": "豪斯医生 - S04E{e:02d} - 第 {e} 集.mkv",
    "scene": "House.M.D.S04E{e:02d}.1080p.BluRay.x264-DEMAND.mkv",
    "sxxeyy": "S04E{e:02d}.mkv",
    "cn_episode": "第{e:02d}集.mp4",
    "bare_number": "{e:02d}.mkv",
    "nxmm": "House - 4x{e:02d} - Title.mkv",
    "bare_e": "E{e:02d}.mkv",
}


@pytest.mark.parametrize(
    ("show_key", "season_key", "file_key"),
    list(itertools.product(_SHOW_DIRS, _SEASON_DIRS, _FILES)),
)
def test_layout_matrix(tmp_path: Path, show_key: str, season_key: str, file_key: str) -> None:
    """issue #497 的评估矩阵：修复前这 280 种布局里条目目录与季集号全对的只有 60 种。"""
    root = tmp_path / "tv"
    show = root / "欧美剧" / _SHOW_DIRS[show_key]
    files = [show / _SEASON_DIRS[season_key] / _FILES[file_key].format(e=e) for e in (1, 2)]

    titled_pack = season_key in ("titled", "torrent_pack")
    # 带片名的季包躺在「不明确是条目」的目录下时，保守地自成条目（见上一个用例）
    expected_entry = (
        show / _SEASON_DIRS[season_key] if titled_pack and show_key in ("bare", "torrent") else show
    )
    assert {entry_dir_of([root], f) for f in files} == {expected_entry}
    units = resolve_units(files)
    assert [(units[f].season, units[f].episode) for f in files] == [(4, 1), (4, 2)]


# ---------------------------------------------------------------------------
# 命名模板往返：MovieClaw 自己整理出的目录，扫描器必须原样读回
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "season_template",
    [
        DEFAULT_TEMPLATES.season_dir,
        "Season {season}",
        "Season {season} ({year})",
        "S{season:02d}",
        "第{season}季",
        "{title} 第{season}季",
        "{title} S{season:02d}",
    ],
)
@pytest.mark.parametrize("season", [1, 4, 12])
def test_naming_templates_round_trip(tmp_path: Path, season_template: str, season: int) -> None:
    """「命名同源」的另一半：模板校验放行的季目录写法，写出去必须读得回来。

    修复前 ``第{season}季``、``Season {season} ({year})`` 都能通过校验，扫描器
    却认不出自己写出的目录——整理过的库重扫就被按季拆散。
    """
    assert validate_template("season_dir", season_template) is None
    templates = NamingTemplates(season_dir=season_template)
    item = SimpleNamespace(
        title="豪斯医生", original_title="House", year=2004, tmdb_id=1408, imdb_id=None
    )
    root = tmp_path / "tv"
    entry = root / entry_dir_name_of(item, templates)
    file = entry / season_dir_name(season, item, templates) / "豪斯医生 - E01.mkv"
    assert entry_dir_of([root], file) == entry
    assert resolve_units([file])[file].season == season

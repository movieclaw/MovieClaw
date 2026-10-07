"""命名模板渲染器（docs/design/scrape-customization.md §2.3）。

本文件最重要的一条：**默认模板的渲染结果与模板化之前的写死行为逐字节
一致**——那是整个 P2 的可验证承诺，破了它就意味着所有存量库在升级后
突然"全部待整理"。
"""

from __future__ import annotations

import pytest

from movieclaw_api.services.library.naming import (
    DEFAULT_TEMPLATES,
    NamingTemplates,
    entry_dir_name,
    entry_dir_name_of,
    episode_file_name,
    movie_file_name,
    render,
    season_dir_name,
    validate_template,
    validate_templates,
)
from movieclaw_db.models import MediaItem


def _item(title="风筝", year=2017, **kw) -> MediaItem:
    return MediaItem(
        kind=kw.pop("kind", "tv"),
        tmdb_id=kw.pop("tmdb_id", 68035),
        title=title,
        original_title=kw.pop("original_title", "Kite"),
        year=year,
        **kw,
    )


# ---------------------------------------------------------------------------
# 默认模板 = 模板化之前的写死行为（字节级）
# ---------------------------------------------------------------------------


def _legacy_base(title: str, year: int | None) -> str:
    """模板化之前 entry_base_name / derive_entry_dir 的原始实现（复刻）。"""
    import re

    cleaned = re.sub(r'[\\/:*?"<>|]', " ", title)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .") or "未命名"
    return f"{cleaned} ({year})" if year is not None else cleaned


@pytest.mark.parametrize(
    "title,year",
    [
        ("风筝", 2017),
        ("沙丘：第二部", 2024),
        ("无年份纪录片", None),
        ("Dune: Part Two", 2024),  # 冒号是保留字符，须清洗成空格
        ("带/斜杠的 片名", 2001),  # 斜杠不能凭空造出一层目录
        ("  首尾空格  ", 1999),
    ],
)
def test_default_entry_dir_matches_legacy(title: str, year: int | None) -> None:
    """条目目录：默认模板与旧实现逐字节一致。"""
    assert entry_dir_name(title=title, year=year) == _legacy_base(title, year)
    assert entry_dir_name_of(_item(title=title, year=year)) == _legacy_base(title, year)


@pytest.mark.parametrize("season", [0, 1, 9, 10, 123])
def test_default_season_dir_matches_legacy(season: int) -> None:
    """季目录：默认模板与旧的 f"Season {season:02d}" 一致（含补零与三位数）。"""
    assert season_dir_name(season) == f"Season {season:02d}"


@pytest.mark.parametrize(
    "title,year,season,episode",
    [("风筝", 2017, 1, 3), ("某剧", None, 0, 12), ("三位集号", 2020, 2, 105)],
)
def test_default_episode_file_matches_legacy(
    title: str, year: int | None, season: int, episode: int
) -> None:
    """剧集文件名：默认模板与旧的 f"{base} - S{s:02d}E{e:02d}" 一致。"""
    legacy = f"{_legacy_base(title, year)} - S{season:02d}E{episode:02d}"
    assert episode_file_name(_item(title=title, year=year), season, episode) == legacy


def test_default_movie_file_matches_legacy() -> None:
    """电影文件名：默认模板即条目目录同名（旧实现两者共用一个 base）。"""
    item = _item(title="沙丘：第二部", year=2024, kind="movie")
    assert movie_file_name(item) == _legacy_base("沙丘：第二部", 2024)
    assert movie_file_name(item) == entry_dir_name_of(item)


# ---------------------------------------------------------------------------
# 渲染规则：缺失收缩、补零、清洗
# ---------------------------------------------------------------------------


def test_missing_token_collapses_brackets_and_separators() -> None:
    """字段缺失时连同相邻括号与重复分隔符收缩——这是"不引入条件语法"的补偿。"""
    assert render("{title} ({year})", {"title": "某片", "year": None}) == "某片"
    assert render("{title} [{resolution}] - {release_group}", {"title": "某片"}) == "某片"
    assert (
        render(
            "{title} - {resolution} - {media_source}", {"title": "某片", "media_source": "BluRay"}
        )
        == "某片 - BluRay"
    )


def test_padding_only_applies_to_digits() -> None:
    assert render("S{season:02d}", {"season": 7}) == "S07"
    assert render("S{season:03d}", {"season": 7}) == "S007"
    # 非数字值不补零（不会把标题填成 0 开头）
    assert render("{title:02d}", {"title": "某片"}) == "某片"


def test_token_values_are_sanitized_but_literals_kept() -> None:
    """占位符的值逐个清洗；模板字面文本原样保留。"""
    out = render("【{title}】{year}", {"title": "A/B:C", "year": 2020})
    assert "/" not in out and ":" not in out
    assert out.startswith("【") and "2020" in out


def test_extra_attrs_available_in_file_templates() -> None:
    """分辨率/片源/发布组可进文件名模板（收藏玩家的高频诉求）。"""
    tpl = NamingTemplates(
        episode_file="{title} - S{season:02d}E{episode:02d} - {resolution} {release_group}"
    )
    name = episode_file_name(_item(), 1, 3, templates=tpl, resolution="2160p", release_group="FRDS")
    assert name == "风筝 - S01E03 - 2160p FRDS"


# ---------------------------------------------------------------------------
# 校验：非法模板必须在保存时拒绝
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "field,template,keyword",
    [
        ("entry_dir", "", "不能为空"),
        ("entry_dir", "{title}/{year}", "路径分隔符"),
        ("entry_dir", "{title} {episode}", "不可用的占位符"),
        ("movie_file", "{release_name}\\{title}", "路径分隔符"),
        ("season_dir", "{episode}", "不可用的占位符"),
        ("episode_file", "{unknown}", "不可用的占位符"),
    ],
)
def test_invalid_templates_rejected(field: str, template: str, keyword: str) -> None:
    error = validate_template(field, template)
    assert error is not None and keyword in error


def test_default_templates_pass_validation() -> None:
    assert validate_templates(DEFAULT_TEMPLATES) is None


@pytest.mark.parametrize(
    "field,template",
    [
        ("entry_dir", "{year}"),
        ("entry_dir", "{tmdb_id}"),
        ("entry_dir", "{english_title}"),
        ("movie_file", "{release_name}"),
        ("movie_file", "movie"),
        ("season_dir", "Season"),
        ("season_dir", "{season_name}"),
        ("episode_file", "{release_name}"),
        ("episode_file", "{title} E{episode:02d}"),
        ("episode_file", "{title} S{season:02d}"),
    ],
)
def test_templates_do_not_require_specific_tokens(field: str, template: str) -> None:
    assert validate_template(field, template) is None


def test_custom_valid_templates_pass() -> None:
    assert (
        validate_templates(
            NamingTemplates(
                entry_dir="{original_title} ({year}) [tmdbid-{tmdb_id}]",
                movie_file="{title} ({year}) - {resolution}",
                season_dir="S{season:02d}",
                episode_file="{title}.S{season:02d}E{episode:02d}.{episode_title}",
            )
        )
        is None
    )


# ---------------------------------------------------------------------------
# 命名同源：四处调用点必须算出同一个名字（strm 回流链路的唯一衔接机制）
# ---------------------------------------------------------------------------


def test_all_call_sites_share_one_entry_dir_name(monkeypatch) -> None:
    """改了模板后，投递 save_path / 监听导入落点 / 整理目标目录三处的
    条目目录名必须完全一致——任何一处继续拼字符串，回流链路当场断裂。"""
    from movieclaw_api.services.library.config import derive_entry_dir, derive_save_path
    from movieclaw_api.services.library.naming import NamingTemplates
    from movieclaw_db.models import Library

    custom = NamingTemplates(entry_dir="{original_title} [{year}]")
    monkeypatch.setattr(
        "movieclaw_api.services.library.naming.effective_templates",
        lambda library=None: custom,
    )

    item = _item(title="风筝", original_title="Kite", year=2017)
    expected = "Kite [2017]"
    library = Library(name="剧集库", kind="tv", root_paths=["/media/tv"])

    # ① 监听导入的自定义目录落点（带条目）
    assert (
        derive_entry_dir("/staging", title=item.title, year=item.year, item=item)
        == f"/staging/{expected}"
    )
    # ② 投递 save_path（带条目）—— 与 ① 同一函数同一模板
    assert (
        derive_save_path(library, title=item.title, year=item.year, item=item)
        == f"/media/tv/{expected}"
    )
    # ③ 整理/镜像侧按条目算出的目录名
    assert entry_dir_name_of(item) == expected


def test_entry_dir_degrades_without_item(monkeypatch) -> None:
    """拿不到条目时（手动下载只输了片名，还没有 TMDB 身份），条目专属占位符
    渲染为空并被收缩——这是**已知且可接受**的降级：文件落盘后由扫描识别、
    整理给出规范名。带上条目的那条路径才是最终落点的权威口径。"""
    from movieclaw_api.services.library.config import derive_entry_dir
    from movieclaw_api.services.library.naming import NamingTemplates

    custom = NamingTemplates(entry_dir="{title} ({year}) [tmdbid-{tmdb_id}]")
    monkeypatch.setattr(
        "movieclaw_api.services.library.naming.effective_templates",
        lambda library=None: custom,
    )
    # 无条目：tmdbid 段整体收缩掉，不留 "[tmdbid-]" 这种残缺文本
    assert derive_entry_dir("/media", title="风筝", year=2017) == "/media/风筝 (2017)"
    # 有条目：占位符正常渲染
    assert (
        derive_entry_dir("/media", title="风筝", year=2017, item=_item())
        == "/media/风筝 (2017) [tmdbid-68035]"
    )


def test_organize_and_ingest_build_identical_paths(monkeypatch) -> None:
    """整理与入库对同一条目算出的相对路径必须逐字节相同。"""
    from movieclaw_api.services.library.naming import NamingTemplates

    custom = NamingTemplates(
        entry_dir="{title} ({year})",
        season_dir="S{season:02d}",
        episode_file="{title}.S{season:02d}E{episode:02d}",
    )
    monkeypatch.setattr(
        "movieclaw_api.services.library.naming.effective_templates",
        lambda library=None: custom,
    )
    item = _item()
    assert entry_dir_name_of(item) == "风筝 (2017)"
    assert season_dir_name(1, item) == "S01"
    assert episode_file_name(item, 1, 3) == "风筝.S01E03"


@pytest.mark.parametrize(
    "template,context,expected",
    [
        # Emby/Jellyfin 经典写法：tmdbid 段整体收干净，不留 "[tmdbid-]"
        ("{title} ({year}) [tmdbid-{tmdb_id}]", {"title": "风筝", "year": 2017}, "风筝 (2017)"),
        (
            "{title} ({year}) [tmdbid-{tmdb_id}]",
            {"title": "风筝", "year": 2017, "tmdb_id": 68035},
            "风筝 (2017) [tmdbid-68035]",
        ),
        # 组内部分有值：保留该组，内部空白自然收缩
        (
            "{title} [{resolution} {release_group}]",
            {"title": "某片", "resolution": "2160p"},
            "某片 [2160p]",
        ),
        # 纯字面括号（组里没有占位符）原样保留
        ("{title} (合集)", {"title": "某片"}, "某片 (合集)"),
        # 多组同时为空
        ("{title} ({year}) [{resolution}]", {"title": "某片"}, "某片"),
    ],
)
def test_empty_bracket_groups_dropped_with_literals(
    template: str, context: dict, expected: str
) -> None:
    """占位符全空的括号组连同组内字面文本一起丢弃。"""
    assert render(template, context) == expected


# ---------------------------------------------------------------------------
# issue #577：新开放的占位符、片名去重、超长截短
# ---------------------------------------------------------------------------


def test_new_identity_tokens_render_from_item() -> None:
    """英文名 / 豆瓣 ID 从条目取值，四个模板都能用。"""
    item = _item(english_title="Kite", douban_id="26340419")
    tpl = NamingTemplates(entry_dir="{title} ({year}) [{english_title}] [douban-{douban_id}]")
    assert entry_dir_name_of(item, templates=tpl) == "风筝 (2017) [Kite] [douban-26340419]"


def test_title_tokens_deduplicated_in_template_order() -> None:
    """国产片 title == original_title：后出现的那个渲染为空，括号组整组收掉。"""
    tpl = "{title} ({original_title}) ({year})"
    assert render(tpl, {"title": "风筝", "original_title": "风筝", "year": 2017}) == "风筝 (2017)"
    assert (
        render(tpl, {"title": "沙丘2", "original_title": "Dune: Part Two", "year": 2024})
        == "沙丘2 (Dune Part Two) (2024)"
    )
    # 先写原名则保留原名、去掉后面的同值片名；大小写差异视为同名
    assert (
        render(
            "{original_title} - {english_title}",
            {"original_title": "Dune", "english_title": "DUNE"},
        )
        == "Dune"
    )


def test_file_attrs_format_like_release_names() -> None:
    from movieclaw_api.services.library.naming import file_attrs

    attrs = file_attrs(
        video_codec="hevc",
        hdr="Dolby Vision",
        bit_depth=10,
        audio_streams=[
            {"codec": "aac", "channels": 2, "default": False},
            {
                "codec": "truehd",
                "profile": "Dolby TrueHD + Dolby Atmos",
                "channels": 8,
                "channel_layout": "7.1",
                "default": True,
            },
        ],
        site_id="hdsky",
        release_name="Dune.Part.Two.2024.2160p",
    )
    assert attrs["video_codec"] == "HEVC"
    assert attrs["hdr"] == "DV"
    assert attrs["bit_depth"] == "10bit"
    assert attrs["audio"] == "TrueHD Atmos 7.1"  # 取标了默认的那条
    assert attrs["site"] == "hdsky"
    assert attrs["release_name"] == "Dune.Part.Two.2024.2160p"
    # 未探测：全部为空，模板里随括号组收缩
    empty = file_attrs()
    assert all(v is None for v in empty.values())


@pytest.mark.parametrize(
    "stream,expected",
    [
        ({"codec": "eac3", "channels": 6, "channel_layout": "5.1(side)"}, "DDP 5.1"),
        ({"codec": "dts", "profile": "DTS-HD MA", "channels": 8}, "DTS-HD MA 7.1"),
        ({"codec": "aac", "profile": "LC", "channels": 2, "channel_layout": "stereo"}, "AAC 2.0"),
        ({"codec": "pcm_s24le", "channels": 2}, "LPCM 2.0"),
        ({"codec": "ac3", "channels": 6}, "DD 5.1"),
    ],
)
def test_audio_label(stream: dict, expected: str) -> None:
    from movieclaw_api.services.library.naming import file_attrs

    assert file_attrs(audio_streams=[stream])["audio"] == expected


def test_episode_and_season_names_render() -> None:
    """{episode_title}/{season_name} 由调用方按季集查好传进来。"""
    tpl = NamingTemplates(
        season_dir="Season {season:02d} {season_name}",
        episode_file="{title} - S{season:02d}E{episode:02d} - {episode_title}",
    )
    item = _item()
    assert season_dir_name(0, item, templates=tpl, season_name="特别篇") == "Season 00 特别篇"
    assert (
        episode_file_name(item, 1, 3, templates=tpl, episode_title="延安来的姑娘")
        == "风筝 - S01E03 - 延安来的姑娘"
    )
    # 没刮到集名：分隔符一并收缩，不留 "- " 尾巴
    assert episode_file_name(item, 1, 3, templates=tpl) == "风筝 - S01E03"


@pytest.mark.parametrize(
    "field,template",
    [
        ("entry_dir", "{title} {english_title} {douban_id}"),
        ("movie_file", "{title} {video_codec} {hdr} {bit_depth} {audio} {site} {release_name}"),
        ("season_dir", "{season_name} S{season}"),
        ("episode_file", "{title} S{season}E{episode} {season_name} {episode_title} {audio}"),
    ],
)
def test_new_tokens_accepted_where_resolvable(field: str, template: str) -> None:
    assert validate_template(field, template) is None


@pytest.mark.parametrize(
    "field,template",
    [
        # 条目目录在投递时就要算出来，那时还没有文件，文件属性必须拒绝
        ("entry_dir", "{title} {release_name}"),
        ("entry_dir", "{title} {site}"),
        ("movie_file", "{title} {season_name}"),
        ("season_dir", "S{season} {episode_title}"),
    ],
)
def test_new_tokens_rejected_where_unresolvable(field: str, template: str) -> None:
    assert "不可用的占位符" in (validate_template(field, template) or "")


def test_long_names_truncate_free_text_but_keep_episode_code() -> None:
    """超长时截短最长的自由文本，SxxEyy、年份与规格保持完整；结果幂等。"""
    from movieclaw_api.services.library.naming import MAX_SEGMENT_BYTES

    tpl = "{title} ({year}) - S{season:02d}E{episode:02d} - {episode_title} [{resolution}]"
    ctx = {
        "title": "很长的剧名" * 8,
        "year": 2017,
        "season": 1,
        "episode": 3,
        "episode_title": "非常非常长的集名" * 10,
        "resolution": "2160p",
    }
    name = render(tpl, ctx)
    assert len(name.encode()) <= MAX_SEGMENT_BYTES
    assert "(2017) - S01E03 - " in name and name.endswith("[2160p]")
    assert name.startswith("很长的剧名" * 8)  # 先截最长的集名，片名完整
    assert render(tpl, ctx) == name  # 确定性：入库与整理算出同一个名字


def test_long_literal_template_hard_cut() -> None:
    from movieclaw_api.services.library.naming import MAX_SEGMENT_BYTES

    name = render("{title} " + "字" * 100, {"title": "某片"})
    assert len(name.encode()) <= MAX_SEGMENT_BYTES and name.startswith("某片 ")

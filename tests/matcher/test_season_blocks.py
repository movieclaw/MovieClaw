"""站点季号推导（matcher/seasons.py）的纯函数测试。

对应 docs/design/subscription-season-split.md §「测试清单」的纯函数部分：
单季无断档恒等、280 天断档偏移 12、多季剧偏移全 0、89 天不切 / 91 天切、
未来集不参与（G1）、季 0 排除，外加边界（集号不连续、全无日期、单集季）。
"""

from __future__ import annotations

from datetime import date, timedelta

import pytest

from movieclaw_matcher.seasons import (
    SPLIT_GAP_DAYS,
    SeasonBlock,
    SeasonMapping,
    derive_season_mapping,
    mapping_from_json,
    mapping_to_json,
    translate_unit,
)

_TODAY = date(2026, 11, 3)


def _weekly(season: int, first: int, count: int, start: date) -> list[tuple[int, int, date]]:
    """一季里从 ``first`` 起连续 ``count`` 集、每周一集的台账行。"""
    return [(season, first + i, start + timedelta(days=7 * i)) for i in range(count)]


# issue #1155 的真实日期：《我独自升级》TMDB 一季 25 集，站点拆成 S01(12)/S02(13)
_SOLO_S1 = _weekly(1, 1, 12, date(2024, 1, 7))
_SOLO_S2 = _weekly(1, 13, 13, date(2025, 1, 5))


def test_single_season_without_gap_is_identity() -> None:
    """单季 10 集连续周更 → 一个 block，站点季 1 偏移 0。"""
    mapping = derive_season_mapping(_weekly(1, 1, 10, date(2024, 1, 7)), today=_TODAY)
    assert mapping.blocks == (SeasonBlock(site_season=1, season=1, start=1, end=10),)
    assert mapping.blocks[0].offset == 0


def test_280_day_gap_splits_into_two_blocks_with_offset_12() -> None:
    """issue #1155：E13 与 E12 相隔 280 天 → 两个 block，第二个偏移 12。"""
    mapping = derive_season_mapping(_SOLO_S1 + _SOLO_S2, today=_TODAY)
    assert mapping.blocks == (
        SeasonBlock(site_season=1, season=1, start=1, end=12),
        SeasonBlock(site_season=2, season=1, start=13, end=25),
    )
    assert mapping.by_site_season(2) is not None
    assert mapping.by_site_season(2).offset == 12
    assert translate_unit(mapping, 2, 1) == (1, 13)
    assert translate_unit(mapping, 2, 13) == (1, 25)
    assert translate_unit(mapping, 1, 1) == (1, 1)


def test_multi_season_show_keeps_every_offset_zero() -> None:
    """普通两季剧（S01 10 集 + S02 10 集）→ 两 block，偏移全 0。"""
    episodes = _weekly(1, 1, 10, date(2024, 1, 7)) + _weekly(2, 1, 10, date(2025, 3, 1))
    mapping = derive_season_mapping(episodes, today=_TODAY)
    assert mapping.blocks == (
        SeasonBlock(site_season=1, season=1, start=1, end=10),
        SeasonBlock(site_season=2, season=2, start=1, end=10),
    )
    assert all(block.offset == 0 for block in mapping.blocks)
    # 恒等：站点 S02E01 就是 TMDB S02E01
    assert translate_unit(mapping, 2, 1) == (2, 1)


def test_89_day_gap_does_not_split_but_91_does() -> None:
    """阈值两侧：89 天不切、90 天当天切（>= 判据）、91 天切。"""
    first = date(2024, 1, 7)
    gap89 = first + timedelta(days=89)
    gap91 = first + timedelta(days=91)
    two = [(1, 1, first), (1, 2, gap89)]
    assert len(derive_season_mapping(two, today=_TODAY).blocks) == 1
    two = [(1, 1, first), (1, 2, first + timedelta(days=SPLIT_GAP_DAYS))]
    assert len(derive_season_mapping(two, today=_TODAY).blocks) == 2
    two = [(1, 1, first), (1, 2, gap91)]
    assert len(derive_season_mapping(two, today=_TODAY).blocks) == 2


def test_future_block_is_excluded() -> None:
    """G1：**还没开播**的 block 不参与，已开播的（哪怕没播完）照常保留。"""
    today = date(2025, 2, 1)
    # E13 于 2025-01-05 开播，此刻已开播但未播完 → 保留完整区间
    episodes = _SOLO_S1 + _weekly(1, 13, 13, date(2025, 1, 5))
    mapping = derive_season_mapping(episodes, today=today)
    assert mapping.blocks == (
        SeasonBlock(site_season=1, season=1, start=1, end=12),
        SeasonBlock(site_season=2, season=1, start=13, end=25),
    )

    # 开播日还在未来：整块丢弃，映射为空
    assert not derive_season_mapping(_weekly(1, 1, 3, date(2025, 3, 1)), today=today)


def test_partially_aired_block_keeps_full_range() -> None:
    """在播中的块保留完整区间，未播集交给 covered_units 的发布时间上限剔除。

    真实场景（issue #1155）：剧播到 E18 时建立订阅。若整块丢掉，站点 S02 的
    已播单集 E13–E18 在整季播完前一条都收不到。
    """
    today = date(2025, 2, 20)  # E18 = 2025-02-16 已播，E19 = 2025-03-02 未播
    episodes = list(_SOLO_S1)
    episodes += _weekly(1, 13, 6, date(2025, 1, 5))  # E13–E18
    episodes += _weekly(1, 19, 7, date(2025, 3, 2))  # E19–E25（未播）
    mapping = derive_season_mapping(episodes, today=today)
    assert mapping.blocks == (
        SeasonBlock(site_season=1, season=1, start=1, end=12),
        SeasonBlock(site_season=2, season=1, start=13, end=25),
    )
    # 已播的 E13–E18 现在就能被站点 S02 覆盖；E19+ 由 air_date 上限挡在门外
    assert translate_unit(mapping, 2, 1) == (1, 13)


def test_block_starting_today_counts_as_aired() -> None:
    """开播日就是今天：判据是 <=，当天即参与（对齐 schedule_for 的当天可搜）。"""
    today = date(2025, 1, 5)
    mapping = derive_season_mapping(_SOLO_S1 + _SOLO_S2, today=today)
    assert mapping.blocks[1] == SeasonBlock(site_season=2, season=1, start=13, end=25)


def test_season_zero_is_excluded() -> None:
    """特别篇完全不参与推导：既不成块，也不影响其它季的编号。"""
    specials = [(0, 1, date(2024, 1, 1)), (0, 2, date(2025, 6, 1))]
    mapping = derive_season_mapping(_SOLO_S1 + _SOLO_S2 + specials, today=_TODAY)
    assert all(block.season != 0 for block in mapping.blocks)
    assert [block.site_season for block in mapping.blocks] == [1, 2]
    assert mapping.blocks[1] == SeasonBlock(site_season=2, season=1, start=13, end=25)


def test_non_contiguous_episode_numbers_stay_in_one_block() -> None:
    """集号不连续（TMDB 少见但存在）：仍按播出间隔分块，区间夹住整个跨度。"""
    episodes = [
        (1, 1, date(2024, 1, 7)),
        (1, 2, date(2024, 1, 14)),
        (1, 4, date(2024, 1, 28)),  # 缺 E03
        (1, 5, date(2024, 2, 4)),
    ]
    mapping = derive_season_mapping(episodes, today=_TODAY)
    assert mapping.blocks == (SeasonBlock(site_season=1, season=1, start=1, end=5),)


def test_all_episodes_without_air_date_yields_empty_mapping() -> None:
    """全无日期 → 断不了档、也过不了 G1，返回空映射。"""
    assert not derive_season_mapping([(1, 1, None), (1, 2, None)], today=_TODAY)


def test_undated_episodes_join_the_enclosing_block() -> None:
    """无日期的集不参与断档判定，但落在区间内就归那个 block（含末位）。"""
    episodes = [
        (1, 1, date(2024, 1, 7)),
        (1, 2, date(2024, 1, 14)),
        (1, 3, None),  # 未定档，夹在两集之间
        (1, 4, date(2024, 1, 28)),
        (1, 5, None),  # 未定档，落在末尾
    ]
    mapping = derive_season_mapping(episodes, today=_TODAY)
    assert mapping.blocks == (SeasonBlock(site_season=1, season=1, start=1, end=5),)


def test_single_episode_season_is_not_split() -> None:
    """一季只有 1 集：不切，恒等。"""
    mapping = derive_season_mapping([(1, 1, date(2024, 1, 7))], today=_TODAY)
    assert mapping.blocks == (SeasonBlock(site_season=1, season=1, start=1, end=1),)


def test_blocks_are_numbered_across_seasons_by_first_air_date() -> None:
    """跨季统一编号：站点季号按各 block 首播日期排序，不按 TMDB 季号。"""
    # TMDB S02 先播、S01 后播（倒序登记的现实情况），站点仍按播出顺序编号
    episodes = _weekly(2, 1, 3, date(2024, 1, 7)) + _weekly(1, 1, 3, date(2025, 5, 4))
    mapping = derive_season_mapping(episodes, today=_TODAY)
    assert [(b.site_season, b.season) for b in mapping.blocks] == [(1, 2), (2, 1)]


def test_json_round_trip_and_empty_states() -> None:
    """落库形状：裸列表，且**不含恒等块**；NULL 与 [] 都读成空映射。"""
    mapping = derive_season_mapping(_SOLO_S1 + _SOLO_S2, today=_TODAY)
    payload = mapping_to_json(mapping)
    # 站点 S01 == TMDB S01 且从 E01 起：不含需换算的信息，不落库
    assert payload == [{"number": 2, "season": 1, "start": 13, "end": 25}]
    assert mapping_from_json(payload) == SeasonMapping(
        blocks=(SeasonBlock(site_season=2, season=1, start=13, end=25),)
    )
    assert not mapping_from_json(None)
    assert not mapping_from_json([])
    # 设计文档 §6 的包裹写法也能读
    assert mapping_from_json({"site_seasons": payload}).by_site_season(2) is not None


def test_ordinary_show_persists_as_empty_mapping() -> None:
    """普通两季剧：推得出两块，但两块都是恒等块 → 落库为空列表。"""
    episodes = _weekly(1, 1, 10, date(2024, 1, 7)) + _weekly(2, 1, 10, date(2025, 3, 1))
    mapping = derive_season_mapping(episodes, today=_TODAY)
    assert len(mapping.blocks) == 2
    assert mapping_to_json(mapping) == []


def test_out_of_order_seasons_persist_as_empty_mapping() -> None:
    """TMDB 季号不按播出顺序（S02 先播）：落库仍为空，不得产生换算。

    这是「站点季号是 TMDB 季号的细化」判据的反例。逐块比较 ``site == season``
    会把这种剧的每一块都判成需要映射，于是 ``S01E05`` 被翻译成 ``S02E05``
    ——普通剧被改写入库季号，直接违反验收标准 6。
    """
    episodes = _weekly(2, 1, 10, date(2023, 1, 1)) + _weekly(1, 1, 10, date(2025, 1, 1))
    mapping = derive_season_mapping(episodes, today=_TODAY)
    # 客观事实：按播出顺序编号后，站点季 1 对应 TMDB 季 2
    assert mapping.blocks[0] == SeasonBlock(site_season=1, season=2, start=1, end=10)
    # 但这不是映射需求：每个 TMDB 季都只被切出一块
    assert mapping_to_json(mapping) == []


def test_second_block_of_a_split_season_needs_mapping() -> None:
    """一个 TMDB 季被切成两块时，第二块才是需要换算的那一块。"""
    mapping = derive_season_mapping(_SOLO_S1 + _SOLO_S2, today=_TODAY)
    assert [b.site_season for b in mapping.needs_mapping] == [2]
    assert mapping.needs_mapping[0] == SeasonBlock(site_season=2, season=1, start=13, end=25)


def test_by_range_finds_the_block_for_an_episode() -> None:
    """分集区反查：TMDB (1, 20) 落在站点第 2 季那块。"""
    mapping = derive_season_mapping(_SOLO_S1 + _SOLO_S2, today=_TODAY)
    block = mapping.by_range(1, 20)
    assert block is not None and block.site_season == 2
    assert mapping.by_range(1, 12).site_season == 1
    assert mapping.by_range(2, 1) is None


def test_translate_unit_leaves_unknown_season_untouched() -> None:
    """没命中映射的季号原样返回（消费侧据此保持原行为）。"""
    mapping = derive_season_mapping(_SOLO_S1 + _SOLO_S2, today=_TODAY)
    assert translate_unit(mapping, 3, 1) == (3, 1)
    assert translate_unit(SeasonMapping(), 2, 1) == (2, 1)


@pytest.mark.parametrize(
    "bad",
    [
        {"site_season": 0, "season": 1, "start": 1, "end": 1},
        {"site_season": 1, "season": 1, "start": 0, "end": 1},
        {"site_season": 1, "season": 1, "start": 5, "end": 4},
    ],
)
def test_invalid_block_is_rejected(bad: dict) -> None:
    """非法区间当场拒绝，不把坏映射带去下游。"""
    with pytest.raises(ValueError):
        SeasonBlock(**bad)

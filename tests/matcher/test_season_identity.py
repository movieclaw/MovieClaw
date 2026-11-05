"""站点季号归一（issue #1155）：内核把站点的 S02 换算成 TMDB 的 S01E13+。

设计文档 docs/design/subscription-season-split.md §3/§4：

- 换算**只在**解析出的季号不在 ``media.season_numbers`` 里时发生，
  且必须命中映射；
- 换算后 ``pack_seasons`` 置空、改成显式集列表——保留 ``{1}`` 会把已经下过的
  E01–E12 也标成"已覆盖"；
- 季号在 season_numbers 里 → 走原路，一个字节不动（普通剧零影响）。
"""

from __future__ import annotations

from datetime import date

from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher import MediaIdentity, TorrentCandidate, match_identity

#: 《我独自升级》：TMDB 只有第 1 季 25 集，站点拆成 S01(12)/S02(13)。
#: season_blocks 元组 = (站点季号, TMDB 季号, 起始集, 结束集)
_SOLO_BLOCKS = ((1, 1, 1, 12), (2, 1, 13, 25))


def _candidate(title: str, subtitle: str = "", **attrs) -> TorrentCandidate:
    return TorrentCandidate(
        site_id="testsite",
        torrent_id="1",
        title=title,
        subtitle=subtitle,
        attrs=TorrentAttrs(**attrs),
    )


def _solo(**kwargs) -> MediaIdentity:
    return MediaIdentity(
        kind="tv",
        year=2024,
        aliases=("Solo Leveling", "我独自升级"),
        season_numbers=(1,),
        season_blocks=_SOLO_BLOCKS,
        **kwargs,
    )


def _plain_tv() -> MediaIdentity:
    """普通两季剧：没有映射（season_blocks 空），站点季号都在台账里。"""
    return MediaIdentity(
        kind="tv",
        year=2024,
        aliases=("Some Show",),
        season_numbers=(1, 2),
    )


# ---------------------------------------------------------------------------
# 单集：S02E01 → (1, 13)
# ---------------------------------------------------------------------------


def test_site_season_two_single_episode_maps_to_tmdb_e13() -> None:
    match = match_identity(
        _candidate("Solo Leveling S02E01 1080p WEB-DL", seasons=[2], episodes=[1]), _solo()
    )
    assert match is not None
    assert match.episodes == frozenset({(1, 13)})
    assert match.pack_seasons == frozenset()


def test_site_season_two_episode_range_maps_each_unit() -> None:
    """S02E11-13 → E23–E25（偏移 12 逐集平移）。"""
    match = match_identity(
        _candidate("Solo Leveling S02E11-13 1080p WEB-DL", seasons=[2], episodes=[11, 12, 13]),
        _solo(),
    )
    assert match is not None
    assert match.episodes == frozenset({(1, 23), (1, 24), (1, 25)})


# ---------------------------------------------------------------------------
# 整季包：S02 Complete → (1,13)…(1,25)，pack_seasons 必须为空
# ---------------------------------------------------------------------------


def test_site_season_two_pack_becomes_explicit_episodes() -> None:
    """13 集的 S02 包 → (1,13)…(1,25)；**绝不能**留着 pack_seasons={2} 或 {1}。

    留着 {1} 会把第 1–12 集也标成已覆盖，等于把已经下过的集再下一次。
    """
    match = match_identity(
        _candidate("Solo Leveling 2025 S02 Complete 1080p WEB-DL", seasons=[2], complete=True),
        _solo(),
    )
    assert match is not None
    assert match.pack_seasons == frozenset()
    assert match.is_pack is True
    assert match.episodes == frozenset((1, ep) for ep in range(13, 26))


def test_declared_total_extends_the_upper_bound() -> None:
    """站点声明 15 集、TMDB 只录到 25（块终点）→ 上界取 max(25, 12+15=27)。"""
    match = match_identity(
        _candidate(
            "Solo Leveling S02 Complete 1080p",
            seasons=[2],
            complete=True,
            episodes_total=15,
        ),
        _solo(),
    )
    assert match is not None
    assert match.declared_total == 15
    assert max(ep for _season, ep in match.episodes) == 27
    assert (1, 12) not in match.episodes  # 下界不因声明而前移


def test_declared_total_below_block_end_truncates() -> None:
    """声明「全 5 集」：只认 E13–E17（PR #1176 评审第 3 点）。

    旧上界 ``max(块终点, 偏移 + 声明数)`` 会生成 E13–E25 全部单元，认领包里
    根本没有的 8 集，后续选择性下载或核验必然失败。
    """
    match = match_identity(
        _candidate(
            "Solo Leveling S02 Complete 1080p",
            seasons=[2],
            complete=True,
            episodes_total=5,
        ),
        _solo(),
    )
    assert match is not None
    assert match.episodes == frozenset((1, ep) for ep in range(13, 18))
    assert match.declared_total == 5
    # 整季包平移出来的集按整季包语义覆盖，而不是显式集号（见 covered_units）
    assert match.normalized_pack is True


def test_explicit_site_episodes_keep_explicit_semantics() -> None:
    """标题写明了集号的 S02E01-E03 不是整季包：仍走显式集号的覆盖语义。"""
    match = match_identity(
        _candidate("Solo Leveling S02E01-E03 1080p", seasons=[2], episodes=[1, 2, 3]), _solo()
    )
    assert match is not None
    assert match.episodes == frozenset({(1, 13), (1, 14), (1, 15)})
    assert match.normalized_pack is False


def test_site_season_episode_zero_is_not_shifted() -> None:
    """站点 S02E00（先导/特辑）不能平移成正片 (1, 12)（评审第 4 点）。"""
    match = match_identity(
        _candidate("Solo Leveling S02E00 Special 1080p", seasons=[2], episodes=[0]), _solo()
    )
    assert match is not None
    assert match.episodes == frozenset({(2, 0)})

    mixed = match_identity(
        _candidate("Solo Leveling S02E00-E01 1080p", seasons=[2], episodes=[0, 1]), _solo()
    )
    assert mixed is not None
    assert mixed.episodes == frozenset({(2, 0), (1, 13)})


def test_site_season_one_inside_ledger_stays_literal() -> None:
    """S01 在台账里 → 走原路。顺延编号的 S01E13-25 因此不受影响。"""
    match = match_identity(
        _candidate("Solo Leveling S01E13-25 2024 1080p", seasons=[1], episodes=[13, 25]),
        _solo(),
    )
    assert match is not None
    assert match.episodes == frozenset({(1, 13), (1, 25)})

    pack = match_identity(
        _candidate("Solo Leveling S01 Complete 1080p", seasons=[1], complete=True), _solo()
    )
    assert pack is not None
    assert pack.pack_seasons == frozenset({1})
    assert pack.episodes == frozenset()


# ---------------------------------------------------------------------------
# 无映射：保持原行为
# ---------------------------------------------------------------------------


def test_no_mapping_keeps_original_behaviour() -> None:
    """没有映射时，站点 S02 照旧落成 pack_seasons={2}（消费侧自然覆盖不到）。"""
    media = MediaIdentity(kind="tv", year=2024, aliases=("Solo Leveling",), season_numbers=(1,))
    match = match_identity(
        _candidate("Solo Leveling S02 Complete 1080p", seasons=[2], complete=True), media
    )
    assert match is not None
    assert match.pack_seasons == frozenset({2})
    assert match.episodes == frozenset()


def test_unknown_site_season_is_not_translated() -> None:
    """站点 S03 没有对应 block → 原样保留（不猜、不夹紧）。"""
    match = match_identity(
        _candidate("Solo Leveling S03E01 1080p", seasons=[3], episodes=[1]), _solo()
    )
    assert match is not None
    assert match.episodes == frozenset({(3, 1)})
    assert match.pack_seasons == frozenset()


# ---------------------------------------------------------------------------
# 普通剧零变化
# ---------------------------------------------------------------------------


def test_plain_two_season_show_is_untouched() -> None:
    """普通两季剧：S02 在台账里，映射字段根本不会被查询。"""
    match = match_identity(
        _candidate("Some Show S02 Complete 1080p", seasons=[2], complete=True), _plain_tv()
    )
    assert match is not None
    assert match.pack_seasons == frozenset({2})
    assert match.episodes == frozenset()

    single = match_identity(
        _candidate("Some Show S02E05 1080p", seasons=[2], episodes=[5]), _plain_tv()
    )
    assert single is not None
    assert single.episodes == frozenset({(2, 5)})


def test_mapping_does_not_affect_the_other_season() -> None:
    """映射只作用于命中它的季号：S01 仍按字面（设计 §8 验收 8）。"""
    media = MediaIdentity(
        kind="tv",
        year=2024,
        aliases=("Solo Leveling",),
        season_numbers=(1,),
        season_blocks=_SOLO_BLOCKS,
    )
    assert match_identity(
        _candidate("Solo Leveling S01E05 1080p", seasons=[1], episodes=[5]), media
    ).episodes == frozenset({(1, 5)})
    assert match_identity(
        _candidate("Solo Leveling S02E05 1080p", seasons=[2], episodes=[5]), media
    ).episodes == frozenset({(1, 17)})


# ---------------------------------------------------------------------------
# 反证不被误触发（设计 §4 其一）
# ---------------------------------------------------------------------------


def test_episode_count_conflict_is_skipped_for_normalised_pack() -> None:
    """归一转出来的 match 的 pack_seasons 为空，_episode_count_conflict 自然跳过。

    否则「S02 包声明 13 集、而第 1 季已播 25 集」会把正确资源判成同名他剧拒掉。
    """
    media = _solo(
        aired_episodes=tuple((1, date(2024, 1, 7)) for _ in range(25)),
    )
    match = match_identity(
        _candidate(
            "Solo Leveling S02 Complete 1080p",
            seasons=[2],
            complete=True,
            episodes_total=13,
        ),
        media,
    )
    assert match is not None
    assert match.id_conflict is None


def test_multi_season_pack_with_episodes_is_unchanged() -> None:
    """S01-S03 + 集号的合集仍按整季包处理，不做逐季换算（多季歧义）。"""
    media = MediaIdentity(
        kind="tv",
        year=2024,
        aliases=("Solo Leveling",),
        season_numbers=(1,),
        season_blocks=_SOLO_BLOCKS,
    )
    match = match_identity(
        _candidate("Solo Leveling S01-S03 E01 1080p", seasons=[1, 2, 3], episodes=[1]), media
    )
    assert match is not None
    assert match.pack_seasons == frozenset({1, 2, 3})

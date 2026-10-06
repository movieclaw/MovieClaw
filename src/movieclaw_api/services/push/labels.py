"""推送里季集的写法（docs/design/cloud-push.md §5.1）。

多集一律写成区间，不写「第 1 季 8 集」：那是 8 集，读起来却像第 8 集。

- 连续：``第 1–8 集``；不连续：``第 1–3、7、9 集``；段数太多：``第 1–20、22 集等 23 集``；
- 跨季：``第 1 季全 12 集、第 2 季第 1–3 集``（知道这一季一共几集、又全在时写「全 N 集」）；
- 特别季写「特别篇」；电影的 ``(0, 0)`` 不写。
"""

from __future__ import annotations

Unit = tuple[int, int]

#: 一季里超过这么多段就只写前两段，后面写「等 N 集」
MAX_SEGMENTS = 3


def season_name(season: int) -> str:
    return "特别篇" if season == 0 else f"第 {season} 季"


def _runs(episodes: list[int]) -> list[tuple[int, int]]:
    """有序集号 → 连续段 [(起, 止)]。"""
    runs: list[tuple[int, int]] = []
    for episode in episodes:
        if runs and episode == runs[-1][1] + 1:
            runs[-1] = (runs[-1][0], episode)
        else:
            runs.append((episode, episode))
    return runs


def episodes_text(episodes: list[int] | set[int]) -> str:
    """一季里的集：``第 8 集``、``第 1–8 集``、``第 1–3、7、9 集``、``第 1–20、22 集等 23 集``。"""
    ordered = sorted(set(episodes))
    if not ordered:
        return ""
    parts = [f"{a}–{b}" if b > a else f"{a}" for a, b in _runs(ordered)]
    if len(parts) > MAX_SEGMENTS:
        return f"第 {'、'.join(parts[:2])} 集等 {len(ordered)} 集"
    return f"第 {'、'.join(parts)} 集"


def by_season(units: list[Unit] | set[Unit]) -> dict[int, list[int]]:
    """季 → 有序集号（不含电影的 (0, 0)）。"""
    seasons: dict[int, set[int]] = {}
    for season, episode in units:
        if (season, episode) != (0, 0):
            seasons.setdefault(season, set()).add(episode)
    return {s: sorted(seasons[s]) for s in sorted(seasons)}


def units_text(
    units: list[Unit] | set[Unit],
    *,
    with_season: bool = True,
    totals: dict[int, int] | None = None,
) -> str:
    """一批季集给人看的写法；电影（或空）返回空串。

    ``with_season`` 为假时只有一季的剧不写季号（「第 1–10 集」）；跨季、特别篇总是写。
    ``totals``：季 → 这一季一共几集，这一季全在时写「全 N 集」。
    """
    seasons = by_season(units)
    if not seasons:
        return ""
    show_season = with_season or len(seasons) > 1 or 0 in seasons
    parts = []
    for season, episodes in seasons.items():
        total = (totals or {}).get(season) or 0
        if total and len(episodes) >= total and set(range(1, total + 1)) <= set(episodes):
            body = f"全 {len(episodes)} 集"
        else:
            body = episodes_text(episodes)
        parts.append(f"{season_name(season)}{body}" if show_season else body)
    return "、".join(parts)


def count_text(units: list[Unit] | set[Unit]) -> str:
    """``33 集``（电影不算）。"""
    return f"{sum(len(e) for e in by_season(units).values())} 集"


def unit_text(unit: Unit, *, with_season: bool) -> str:
    """一个单元：``第 8 集`` / ``第 2 季第 8 集`` / ``特别篇第 1 集``；电影为空。"""
    return units_text([unit], with_season=with_season)

"""选优测试：整季包优先于单集（已确认决策），同类按评分，全拒绝返回 None。"""

from __future__ import annotations

from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher import (
    IdentityMatch,
    RuleSetSpec,
    RuleVerdict,
    TorrentCandidate,
    pick_best,
)

_SPEC = RuleSetSpec()


def _entry(
    name: str,
    *,
    is_pack: bool,
    score: int,
    accepted: bool = True,
    seeders: int = 0,
    site_id: str = "test",
):
    candidate = TorrentCandidate(
        site_id=site_id, torrent_id=name, title=name, subtitle="",
        attrs=TorrentAttrs(), seeders=seeders,
    )
    match = IdentityMatch(is_pack=is_pack)
    verdict = RuleVerdict(accepted=accepted, score=score)
    return (candidate, match, verdict)


def test_pack_preferred_over_higher_scored_single() -> None:
    """整季包优先：即使单集评分更高，也选整季包。"""
    single = _entry("single", is_pack=False, score=999)
    pack = _entry("pack", is_pack=True, score=10)
    best = pick_best([single, pack], _SPEC)
    assert best is not None and best[0].torrent_id == "pack"


def test_same_kind_ranked_by_score_then_seeders() -> None:
    low = _entry("low", is_pack=True, score=10)
    high = _entry("high", is_pack=True, score=50)
    assert pick_best([low, high], _SPEC)[0].torrent_id == "high"

    tied_few = _entry("few", is_pack=False, score=50, seeders=3)
    tied_many = _entry("many", is_pack=False, score=50, seeders=30)
    assert pick_best([tied_few, tied_many], _SPEC)[0].torrent_id == "many"


def test_rejected_entries_never_win() -> None:
    rejected = _entry("rejected", is_pack=True, score=999, accepted=False)
    accepted = _entry("accepted", is_pack=False, score=1)
    assert pick_best([rejected, accepted], _SPEC)[0].torrent_id == "accepted"
    assert pick_best([rejected], _SPEC) is None
    assert pick_best([], _SPEC) is None


def test_site_priority_ranks_before_score() -> None:
    """站点白名单顺序先于评分（#806）：原发站的普通种胜过转载站的免费高分种。"""
    spec = RuleSetSpec(sites=["pter", "chdbits"])
    original = _entry("original", is_pack=True, score=108, site_id="pter")
    repost = _entry("repost", is_pack=True, score=160, site_id="chdbits")
    assert pick_best([repost, original], spec)[0].torrent_id == "original"
    # 未配站点时退回评分，行为与改动前一致
    assert pick_best([repost, original], _SPEC)[0].torrent_id == "repost"

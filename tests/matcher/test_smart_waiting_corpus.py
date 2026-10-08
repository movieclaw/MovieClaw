"""真实快照验证：搜索噪声先走身份检查；静态结果不伪装成纵向发布历史。"""

import json
from dataclasses import replace
from datetime import datetime, timedelta
from pathlib import Path
from random import Random

import pytest
from pydantic import TypeAdapter

from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher import MediaIdentity, TorrentCandidate, match_identity
from movieclaw_matcher.smart import SmartPolicy, decide, eligible, quality_vector
from movieclaw_matcher.smart_replay import replay_decision
from movieclaw_matcher.smart_waiting import utc

FIXTURES = Path(__file__).parents[1] / "fixtures/smart_waiting"
# 预期品质来自人工检查样本中的实际档位；目标始终为 4K WEB-DL。
CASES = [
    (0, "幸福伽菜子的快乐杀手生活", 2025, "tv", 2, 1, (4, 3)),
    (1, "Happy Kanakos Killer Life", 2025, "tv", 2, 2, (4, 3)),
    (2, "Cold Hunt", 2026, "tv", 1, 16, (6, 3)),
    (3, "余红旧事", 2026, "tv", 1, 1, (6, 3)),
    (4, "兰香如故", 2026, "tv", 1, 1, (6, 3)),
    (5, "The Boys", 2019, "tv", 1, 1, (6, 3)),
    (6, "The Peripheral", 2022, "tv", 1, 1, (6, 3)),
    (7, "哪吒之魔童闹海", 2025, "movie", 0, 0, (6, 3)),
    (8, "Spider-Man Homecoming", 2017, "movie", 0, 0, (6, 5)),
    (9, "新神榜：杨戬", 2022, "movie", 0, 0, (6, 3)),
]


def load_case(index, title, year, kind, season, episode):
    data = json.loads((FIXTURES / f"search_{index:02}.json").read_text())
    pool = []
    identity = MediaIdentity(kind=kind, year=year, aliases=(title,), season_numbers=(season,))
    for raw in data["items"]:
        candidate = TorrentCandidate(
            site_id=raw["site_id"],
            torrent_id=raw["torrent_id"],
            title=raw["title"],
            subtitle="",
            attrs=TorrentAttrs.model_validate(raw["attrs"] or {}),
            seeders=raw["seeders"],
            size_bytes=raw["size_bytes"],
            publish_time=datetime.fromisoformat(raw["upload_time"]) if raw["upload_time"] else None,
        )
        match = match_identity(candidate, identity)
        if (
            match
            and not match.id_conflict
            and (
                (season, episode) in match.episodes
                or (match.is_pack and season in match.pack_seasons)
            )
        ):
            pool.append(candidate)
    return datetime.fromisoformat(data["as_of"]), pool


@pytest.mark.parametrize("index,title,year,kind,season,episode,expected", CASES)
def test_real_searches_choose_available_best_without_new_wait(
    index, title, year, kind, season, episode, expected
):
    now, pool = load_case(index, title, year, kind, season, episode)
    policy = SmartPolicy(kind=kind, profile_revision=1, wait_seconds=21600)
    assert pool
    result = decide(policy, pool, now=now, first_seen=now)
    assert result.action == "download"
    chosen = next(c for c in pool if f"{c.site_id}/{c.torrent_id}" == result.candidate_key)
    assert quality_vector(chosen.attrs) == expected
    random = Random(34)
    for _ in range(5):
        random.shuffle(pool)
        assert decide(policy, pool, now=now, first_seen=now) == result
    # 每个合格旧资源单独出现，仍不因新订阅启动等待；严格模式不降低分辨率。
    for c in pool:
        if (
            eligible(c, policy)
            and c.publish_time
            and utc(c.publish_time) < now - timedelta(hours=6)
        ):
            assert decide(policy, [c], now=now).action == "download"
        strict = decide(policy.model_copy(update={"strict_resolution": True}), [c], now=now)
        if c.attrs.resolution != "2160p":
            assert strict.action == "no_candidate"


def test_nas_34_original_decision_now_selects_the_same_pack_for_both_old_episodes():
    records = json.loads((FIXTURES / "nas_decisions.json").read_text())
    for record in [r for r in records if r["subscription_id"] == 34]:
        inputs = record["inputs"]
        result = replay_decision(inputs)
        assert result.action == "download" and result.candidate_key == "mteam/1266198"
        assert result.state.anchor.isoformat().startswith("2026-09-")
        assert result.state.first_observed_at.isoformat().startswith("2026-10-07")
        # 明确对照：旧实现忽略发布时间，这个同样的发现时刻会等待 30 分钟。
        candidates = TypeAdapter(list[TorrentCandidate]).validate_python(inputs["candidates"])
        old = decide(
            SmartPolicy.model_validate(inputs["policy"]),
            [replace(c, publish_time=None) for c in candidates],
            now=datetime.fromisoformat(inputs["now"]),
            coverage=inputs["coverage"],
        )
        assert old.action == "wait" and (old.next_at - old.state.anchor).total_seconds() == 1800


def test_fixture_sanitization_and_search_scope():
    for path in FIXTURES.glob("*.json"):
        text = path.read_text()
        for forbidden in (
            "download_url",
            "detail_url",
            "passkey=",
            "192.168.",
            "password",
            "Cookie",
            "Authorization",
        ):
            assert forbidden not in text
        if path.name.startswith("search_"):
            assert (
                json.loads(text)["scope"]
                == "current search snapshot, not complete historical observation"
            )

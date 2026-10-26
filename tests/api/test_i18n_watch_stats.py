"""Statistics translate display fallbacks without changing aggregation or raw names."""

from datetime import timedelta

import pytest

from . import test_playback_activity as activity

client = activity.client


@pytest.mark.asyncio
@pytest.mark.parametrize("named_like_fallback", [False, True])
async def test_statistics_keep_counts_and_reader_independent_client_groups(
    client, named_like_fallback
):
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import PlaybackLog, PlaybackMetric, utcnow

    movie_id, _ = await activity._seed_movie_in_library(
        title="原始作品", tmdb_id=881122, library_name="原始库"
    )
    base = utcnow() - timedelta(days=1)
    raw_client = "未知客户端" if named_like_fallback else "原始客户端"
    async with get_database().session() as session:
        for index, (member, client_name) in enumerate(
            ((0, ""), (-1, raw_client), (999, "RawClient"))
        ):
            at = base + timedelta(minutes=index * 10)
            session.add(
                PlaybackLog(
                    member_id=member,
                    media_item_id=movie_id,
                    kind="movie",
                    title="原始作品",
                    device_id=f"raw-{index}",
                    client=client_name,
                    started_at=at,
                    last_seen_at=at + timedelta(minutes=2),
                    ended_at=at + timedelta(minutes=2),
                    watched_ms=120_000,
                    start_position_ms=0,
                    end_position_ms=120_000,
                )
            )
        session.add_all(
            [PlaybackMetric(member_id=0, tier=tier, watched_ms=120_000) for tier in range(5)]
        )
        await session.commit()
    responses = []
    for language in ("en", "zh-Hans", "en"):
        response = client.get(
            "/api/v1/playback/stats/watch",
            params={"days": 7},
            headers={"Accept-Language": language},
        )
        assert response.status_code == 200, response.text
        responses.append(response.json()["data"])
    en, zh, again = responses
    assert en == again
    assert en["current"] == zh["current"]
    assert en["by_day"] == zh["by_day"]
    assert en["by_hour"] == zh["by_hour"]
    assert [(row["tier"], row["plays"]) for row in en["by_tier"]] == [
        (row["tier"], row["plays"]) for row in zh["by_tier"]
    ]
    assert en["by_tier"][0]["label"] == "Direct play"
    assert zh["by_tier"][0]["label"] == "直连"
    assert {row["member_id"]: row["member_name"] for row in en["by_member"]} == {
        0: "admin",
        -1: "Share guest",
        999: "Member #999",
    }
    assert {row["member_id"]: row["member_name"] for row in zh["by_member"]} == {
        0: "admin",
        -1: "分享访客",
        999: "成员 #999",
    }
    english_clients = {row["client"]: row["plays"] for row in en["by_client"]}
    assert english_clients[raw_client] == (2 if named_like_fallback else 1)
    if named_like_fallback:
        assert "Unknown client" not in english_clients
    else:
        assert english_clients["Unknown client"] == 1
    assert [(row["plays"], row["watched_ms"]) for row in en["by_client"]] == [
        (row["plays"], row["watched_ms"]) for row in zh["by_client"]
    ]
    assert en["top_titles"][0]["media"]["title"] == "原始作品"

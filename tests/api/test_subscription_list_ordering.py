# ruff: noqa: F811
from tests.api.subscription_ordering_fixture import seed_subscription_ordering
from tests.api.test_subscription_routes import client  # noqa: F401

from movieclaw_api.schemas.subscription import SubscriptionView
from movieclaw_db.engine import get_database


def test_api_orders_missing_content_before_pure_upgrades(client):
    async def seed():
        async with get_database().session() as session:
            return await seed_subscription_ordering(session)

    ids = client.portal.call(seed)
    all_rows = client.get("/api/v1/subscriptions").json()["data"]
    for kind in ("movie", "tv"):
        response = client.get("/api/v1/subscriptions", params={"kind": kind})
        assert response.status_code == 200
        rows = response.json()["data"]
        # 同组按最近活动排序；最新的洗版 / 完成活动不能挤到待获取内容前面。
        expected = [
            ids[kind][state]
            for state in ("pipeline", "mixed", "search", "upgrade", "paused", "done")
        ]
        assert [r["id"] for r in rows] == expected
        assert [r["id"] for r in all_rows if r["media"]["kind"] == kind] == expected
        assert rows[3]["progress"]["upgrading"] > 0
        assert rows[-1]["progress"]["upgrading"] == 0
        if kind == "tv":
            assert rows[1]["progress"]["upgrading"] == 1
            assert rows[1]["progress"]["wanted"] == 1
        assert [SubscriptionView.model_validate(row).list_priority for row in rows] == [
            0,
            0,
            0,
            1,
            2,
            3,
        ]

    # 无工单的库存缺口也优先；未选择的季不影响纯洗版，空选择使用最新季。
    upgrade = SubscriptionView.model_validate(
        next(r for r in all_rows if r["id"] == ids["tv"]["upgrade"])
    )
    upgrade.season_collection[0].owned_count = 1
    assert upgrade.list_priority == 0
    upgrade.season_collection[0].owned_count = 2
    upgrade.season_collection.append(
        upgrade.season_collection[0].model_copy(update={"season_number": 2, "owned_count": 0})
    )
    assert upgrade.list_priority == 1
    upgrade.selected_seasons = []
    assert upgrade.list_priority == 0
    upgrade.status = "paused"
    assert upgrade.list_priority == 2

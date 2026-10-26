from __future__ import annotations

from sqlmodel import select

from . import test_subscription_routes as subscriptions

client = subscriptions.client


def test_tracking_activity_is_written_once_and_rendered_for_each_reader(client):
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import SubscriptionActivity

    created = client.post("/api/v1/subscriptions", json={"title_ref": "tmdb:movie:100"})
    assert created.status_code == 200, created.text
    subscription_id = created.json()["data"]["subscription"]["id"]
    path = f"/api/v1/subscriptions/{subscription_id}"
    paused = client.patch(
        f"{path}/tracking-state",
        json={"state": "paused"},
        headers={"Accept-Language": "en"},
    )
    assert paused.status_code == 200, paused.text
    assert paused.json()["message"] == (
        "Paused; release matching and searches will skip this subscription"
    )

    def activity(locale):
        response = client.get(f"{path}/activities", headers={"Accept-Language": locale})
        assert response.status_code == 200, response.text
        return response.json()["data"][0]

    english = activity("en")
    chinese = activity("zh-Hans")
    assert english["id"] == chinese["id"]
    assert english["message_key"] == "activity.subscription.paused"
    assert english["message"] == (
        "Paused: release matching and searches will skip this subscription. Resume at any time."
    )
    assert chinese["message"] == "已暂停：资源匹配与搜索将跳过该订阅，随时可恢复"

    async def stored():
        async with get_database().session() as session:
            row = (
                await session.execute(
                    select(SubscriptionActivity).where(SubscriptionActivity.id == english["id"])
                )
            ).scalar_one()
            return row.message, row.message_key

    assert client.portal.call(stored) == (chinese["message"], english["message_key"])
    resumed = client.patch(f"{path}/tracking-state", json={"state": "active"})
    assert resumed.status_code == 200, resumed.text
    assert activity("en")["message"] == "Tracking resumed"
    assert activity("zh-Hans")["message"] == "已恢复追踪"

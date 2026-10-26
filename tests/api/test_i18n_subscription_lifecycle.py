"""Creation and adjustment histories preserve Chinese and render for each reader."""

import re

from sqlmodel import select

from . import test_subscription_routes as subscriptions
from . import test_subscription_service as services

client = subscriptions.client
db = services.db


def test_new_lifecycle_history_follows_the_reader_and_keeps_the_same_record(client, monkeypatch):
    from movieclaw_api.services import media_discover
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import SubscriptionActivity

    monkeypatch.setattr(media_discover, "get_tmdb_client", subscriptions._fake_tmdb)
    response = client.post(
        "/api/v1/subscriptions",
        json={
            "title_ref": "tmdb:tv:200",
            "selected_seasons": [1],
            "follow_future": True,
            "selection_mode": "rules",
        },
        headers={"Accept-Language": "en"},
    )
    assert response.status_code == 200, response.text
    subscription_id = response.json()["data"]["subscription"]["id"]
    path = f"/api/v1/subscriptions/{subscription_id}"

    def activities(locale):
        result = client.get(path + "/activities", headers={"Accept-Language": locale})
        assert result.status_code == 200, result.text
        return result.json()["data"]

    created = next(row for row in activities("en") if row["type"] == "created")
    assert created["message_key"] == "activity.subscription.created"
    assert not re.search(r"[\u3400-\u9fff]", created["message"].replace("测试剧集", ""))
    original = next(row for row in activities("zh-Hans") if row["id"] == created["id"])
    assert original["message"] == (
        "创建订阅《测试剧集》：勾选第 1 季，自动续订开；"
        "共生成 1 个追踪项——1 集未播出、播出后先等被动匹配"
    )
    changed = client.patch(
        path,
        json={"selected_seasons": [1], "follow_future": False},
        headers={"Accept-Language": "en"},
    )
    assert changed.status_code == 200, changed.text
    adjusted = next(row for row in activities("en") if row["type"] == "adjusted")
    assert adjusted["message_key"] == "activity.subscription.adjusted"
    assert not re.search(r"[\u3400-\u9fff]", adjusted["message"])
    chinese = next(row for row in activities("zh-Hans") if row["id"] == adjusted["id"])
    assert chinese["message"] == (
        "调整订阅：勾选第 1 季，自动续订关；新增 0 个单元，重新纳入 0 个，退出范围 0 个"
        "（下载器任务不会自动删除；退出范围后停止搜索与换源）"
    )

    async def stored():
        async with get_database().session() as session:
            rows = (
                (
                    await session.execute(
                        select(SubscriptionActivity).where(
                            SubscriptionActivity.id.in_([created["id"], adjusted["id"]])
                        )
                    )
                )
                .scalars()
                .all()
            )
            return {row.id: (row.message, row.message_key) for row in rows}

    saved = client.portal.call(stored)
    assert saved[created["id"]] == (original["message"], created["message_key"])
    assert saved[adjusted["id"]] == (chinese["message"], adjusted["message_key"])
    assert activities("en")[0]["message"] == adjusted["message"]


async def test_all_creation_schedule_shapes_keep_the_original_chinese(db, monkeypatch):
    from datetime import UTC, datetime, timedelta

    from movieclaw_api.i18n import use_locale
    from movieclaw_api.i18n.stored import render_value
    from movieclaw_api.services.subscription import core
    from movieclaw_db.models import MediaItem, WantedItem
    from movieclaw_media.models import MediaKind

    from .test_subscription_service import _service

    now = datetime(2026, 10, 24, tzinfo=UTC)
    monkeypatch.setattr(core, "utcnow", lambda: now)
    title = "原始影片"
    item = MediaItem(kind="movie", tmdb_id=999, title=title)

    def row(next_search_at):
        return WantedItem(
            subscription_id=1,
            media_item_id=1,
            season_number=1,
            episode_number=1,
            next_search_at=next_search_at,
        )

    cases = [
        (MediaKind.MOVIE, [], [], False, "创建订阅《原始影片》"),
        (
            MediaKind.MOVIE,
            [row(None)],
            [],
            False,
            "创建订阅《原始影片》：影片尚未定档，定档/上映后自动安排搜索；"
            "期间站点新出的资源仍会被自动匹配",
        ),
        (
            MediaKind.MOVIE,
            [row(now + timedelta(days=1))],
            [],
            False,
            "创建订阅《原始影片》：影片未上映或刚上映，2026-10-25 起开始搜索资源；"
            "期间站点新出的资源仍会被自动匹配",
        ),
        (
            MediaKind.MOVIE,
            [row(now - timedelta(hours=1))],
            [],
            False,
            "创建订阅《原始影片》：已加入搜索队列，等待搜索任务寻找资源",
        ),
        (
            MediaKind.TV,
            [],
            [],
            False,
            "创建订阅《原始影片》：勾选（未勾选任何季），自动续订关；共生成 0 个追踪项——暂无待办集",
        ),
        (
            MediaKind.TV,
            [row(now), row(now + timedelta(days=1)), row(None)],
            [1, 3],
            True,
            "创建订阅《原始影片》：勾选第 1、3 季，自动续订开；共生成 3 个追踪项——"
            "1 集已播出、排入搜索队列；1 集未播出、播出后先等被动匹配；1 集未定档、定档后再安排",
        ),
    ]
    async with db.session() as session:
        service = _service(session)
        for kind, rows, seasons, following, expected in cases:
            snapshots = [value.model_dump() for value in rows]
            message = service._created_reference(item, kind, seasons, following, rows)
            with use_locale("zh-Hans"):
                assert render_value(message) == expected
            with use_locale("en"):
                assert not re.search(r"[\u3400-\u9fff]", render_value(message).replace(title, ""))
            assert [value.model_dump() for value in rows] == snapshots


def test_route_rule_and_episode_floor_references_remain_nested(client, monkeypatch, tmp_path):
    from movieclaw_api.services import media_discover

    monkeypatch.setattr(media_discover, "get_tmdb_client", subscriptions._fake_tmdb)

    def request(method, path, body=None, locale="en"):
        response = getattr(client, method)(
            "/api/v1" + path,
            **({"json": body} if body is not None else {}),
            headers={"Accept-Language": locale},
        )
        assert response.status_code == 200, response.text
        return response.json()["data"]

    default = next(row for row in request("get", "/rule-sets") if row["is_default"])
    custom = request(
        "post",
        "/rule-sets",
        {
            "name": "我的规则",
            "spec": {},
            "match_rules": [{"field": "kind", "op": "any_of", "values": ["tv"]}],
        },
    )
    root = tmp_path / "shows"
    root.mkdir()
    request("post", "/libraries", {"name": "我的剧集", "kind": "tv", "root_paths": [str(root)]})
    created = request(
        "post",
        "/subscriptions",
        {
            "title_ref": "tmdb:tv:200",
            "selection_mode": "rules",
            "selected_seasons": [1],
            "follow_future": True,
        },
    )["subscription"]
    assert created["rule_set_id"] == custom["id"]
    path = f"/subscriptions/{created['id']}"
    event = next(row for row in request("get", path + "/activities") if row["type"] == "created")
    assert event["message_params"]["route"]["message_key"] == "library.routing.defaultLibrary"
    assert event["message_params"]["rule"]["message_key"] == "subscription.ruleRoute.matched"
    assert "我的剧集" in event["message"] and "我的规则" in event["message"]
    text = event["message"]
    for name in ("测试剧集", "我的剧集", "我的规则"):
        text = text.replace(name, "")
    assert not re.search(r"[\u3400-\u9fff]", text)
    request("patch", path, {"rule_set_id": default["id"], "episode_floors": {"1": 3}})
    adjusted = next(
        row for row in request("get", path + "/activities") if row["type"] == "adjusted"
    )
    assert "Default rule set" in adjusted["message"]
    assert not re.search(r"[\u3400-\u9fff]", adjusted["message"])
    chinese = next(
        row
        for row in request("get", path + "/activities", locale="zh-Hans")
        if row["id"] == adjusted["id"]
    )
    assert "，规则组改为「默认规则组」，集数第 1 季按 3 集；新增 2 个单元" in chinese["message"]
    request("patch", path, {"episode_floors": {}})
    chinese = next(
        row
        for row in request("get", path + "/activities", locale="zh-Hans")
        if row["type"] == "adjusted"
    )
    assert "，集数改回以 TMDB 为准；" in chinese["message"]
    english = next(
        row for row in request("get", path + "/activities") if row["id"] == chinese["id"]
    )
    assert "use TMDB counts again" in english["message"]
    assert not re.search(r"[\u3400-\u9fff]", english["message"])

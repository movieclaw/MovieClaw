# ruff: noqa: F811
import json
import sqlite3

import pytest
from tests.api.test_subscription_routes import client  # noqa: F401

from movieclaw_api.schemas.subscription import (
    SubscriptionDetailView,
    SubscriptionView,
    UpgradeRunView,
)


def test_smart_onboarding_uses_real_api_and_separate_profile_versions(client):
    base = "/api/v1/subscriptions"
    assert client.get(f"{base}/smart-profiles/movie").json()["data"]["revision"] == 0
    preferences = {
        "resolution": "2160p",
        "source": "blu-ray",
        "wait_seconds": 86400,
        "allow_upgrade": True,
        "strict_resolution": False,
    }
    saved = client.put(
        f"{base}/smart-profiles/movie", json={"revision": 0, "preferences": preferences}
    )
    assert saved.status_code == 200, saved.text
    created = client.post(
        base,
        json={
            "title_ref": "tmdb:movie:100",
            "selection_mode": "smart",
            "smart_profile_revision": 1,
        },
    )
    assert created.status_code == 200, created.text
    subscription = created.json()["data"]["subscription"]
    assert subscription["selection_mode"] == "smart" and subscription["rule_set_id"] == 0
    assert subscription["smart_policy"]["source"] == "blu-ray"
    detail = client.get(f"{base}/{subscription['id']}")
    assert detail.status_code == 200, detail.text
    assert detail.json()["data"]["smart_policy"] == subscription["smart_policy"]
    assert client.get(f"{base}/smart-profiles/tv").json()["data"]["revision"] == 0
    assert (
        client.put(
            f"{base}/smart-profiles/movie", json={"revision": 0, "preferences": preferences}
        ).status_code
        == 409
    )
    # 旧客户端再次订阅复用同一条记录，不能覆盖已保存模式。
    again = client.post(base, json={"title_ref": "tmdb:movie:100"})
    assert again.status_code == 200, again.text
    assert again.json()["data"]["subscription"]["selection_mode"] == "smart"


def test_smart_api_rejects_ambiguous_mode_and_invalid_wait(client):
    base = "/api/v1/subscriptions"
    assert (
        client.post(
            base,
            json={
                "title_ref": "tmdb:movie:100",
                "selection_mode": "smart",
                "smart_profile_revision": 1,
                "rule_set_id": 1,
            },
        ).status_code
        == 422
    )
    assert (
        client.put(
            f"{base}/smart-profiles/movie",
            json={"revision": 0, "preferences": {"wait_seconds": 3601}},
        ).status_code
        == 400
    )
    result = client.post(
        base,
        json={
            "title_ref": "tmdb:movie:100",
            "selection_mode": "smart",
            "smart_profile_revision": 1,
        },
    )
    assert result.status_code == 400
    legacy = client.post(base, json={"title_ref": "tmdb:movie:100"})
    assert legacy.status_code == 200, legacy.text
    assert legacy.json()["data"]["subscription"]["selection_mode"] == "rules"


def test_member_can_reuse_but_cannot_edit_global_smart_settings(client):
    preferences = {
        "resolution": "1080p",
        "source": "web-dl",
        "wait_seconds": 86400,
        "allow_upgrade": False,
        "strict_resolution": False,
    }
    assert (
        client.put(
            "/api/v1/subscriptions/smart-profiles/movie",
            json={"revision": 0, "preferences": preferences},
        ).status_code
        == 200
    )
    created = client.post(
        "/api/v1/members", json={"username": "smart-member", "password": "member-pass-1"}
    )
    assert created.status_code == 200, created.text
    client.cookies.clear()
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "smart-member", "password": "member-pass-1"}
        ).status_code
        == 200
    )
    assert client.get("/api/v1/subscriptions/smart-profiles/movie").status_code == 200
    assert (
        client.put(
            "/api/v1/subscriptions/smart-profiles/movie",
            json={"revision": 1, "preferences": preferences},
        ).status_code
        == 403
    )
    result = client.post(
        "/api/v1/subscriptions",
        json={
            "title_ref": "tmdb:movie:100",
            "selection_mode": "smart",
            "smart_profile_revision": 1,
        },
    )
    assert result.status_code == 200, result.text
    assert result.json()["data"]["subscription"]["smart_policy"]["resolution"] == "1080p"


def test_smart_runtime_settings_registered_before_first_subscription(client):
    from movieclaw_api.settings import get_descriptor

    assert get_descriptor("subscription.smart") is not None


@pytest.mark.parametrize("kind,legacy_wait", [("movie", 259200), ("tv", 7200)])
def test_week_wait_profiles_validate_and_keep_existing_policy(client, kind, legacy_wait):
    base = "/api/v1/subscriptions"
    profile_url = f"{base}/smart-profiles/{kind}"
    saved = client.put(
        profile_url, json={"revision": 0, "preferences": {"wait_seconds": legacy_wait}}
    )
    assert saved.status_code == 200, saved.text
    payload = {
        "title_ref": "tmdb:movie:100" if kind == "movie" else "tmdb:tv:200",
        "selection_mode": "smart",
        "smart_profile_revision": 1,
    }
    if kind == "tv":
        payload["selected_seasons"] = [1]
    created = client.post(base, json=payload)
    assert created.status_code == 200, created.text
    original = created.json()["data"]["subscription"]
    revision = 1
    for hours in (0, 1, 2, 3, 6, 7, 24, 25, 48, 72, 96, 120, 144, 168):
        result = client.put(
            profile_url,
            json={"revision": revision, "preferences": {"wait_seconds": hours * 3600}},
        )
        assert result.status_code == 200, result.text
        revision += 1
        profile = client.get(profile_url).json()["data"]
        assert profile["revision"] == revision
        assert profile["preferences"]["wait_seconds"] == hours * 3600
    for seconds, status in ((-1, 422), (1800, 400), (3601, 400), (604801, 422)):
        result = client.put(
            profile_url,
            json={"revision": revision, "preferences": {"wait_seconds": seconds}},
        )
        assert result.status_code == status, result.text
        assert client.get(profile_url).json()["data"] == profile
    detail = client.get(f"{base}/{original['id']}").json()["data"]
    assert detail["smart_policy"] == original["smart_policy"]
    assert detail["smart_policy"]["wait_seconds"] == legacy_wait


def test_legacy_rule_id_contract_preserves_smart_policy(client, tmp_path):
    base = "/api/v1/subscriptions"
    assert (
        client.put(
            f"{base}/smart-profiles/tv",
            json={"revision": 0, "preferences": {"allow_upgrade": True}},
        ).status_code
        == 200
    )
    created = client.post(
        base,
        json={
            "title_ref": "tmdb:tv:200",
            "selected_seasons": [1],
            "selection_mode": "smart",
            "smart_profile_revision": 1,
        },
    )
    assert created.status_code == 200, created.text
    original = created.json()["data"]["subscription"]
    url = f"{base}/{original['id']}"
    assert type(original["rule_set_id"]) is int and original["rule_set_id"] == 0

    # 旧客户端回传兼容值：调季、续订和洗版都沿用原偏好，不能写入规则组 0。
    updated = client.patch(url, json={"rule_set_id": 0, "follow_future": True})
    assert updated.status_code == 200, updated.text
    assert updated.json()["data"]["follow_future"] is True
    for payload in ({}, {"rule_set_id": 0}):
        report = client.post(f"{url}/upgrade-runs", json=payload)
        assert report.status_code == 200, report.text
        assert report.json()["data"]["rule_set_id"] == 0
        assert report.json()["data"]["target_label"] == "2160p WEB-DL"

    legacy = client.post(base, json={"title_ref": "tmdb:movie:100"})
    assert legacy.status_code == 200, legacy.text
    rule_sub = legacy.json()["data"]["subscription"]
    rule_id = rule_sub["rule_set_id"]
    assert type(rule_id) is int and rule_id > 0
    # 不能借兼容入口把智能订阅切成传统规则；规则订阅也不能绑定占位值。
    assert client.patch(url, json={"rule_set_id": rule_id}).status_code == 400
    assert client.post(f"{url}/upgrade-runs", json={"rule_set_id": rule_id}).status_code == 400
    rule_url = f"{base}/{rule_sub['id']}"
    assert client.patch(rule_url, json={"rule_set_id": 0}).status_code == 404
    assert client.post(f"{rule_url}/upgrade-runs", json={"rule_set_id": 0}).status_code == 404

    listed = client.get(base).json()["data"]
    smart = next(sub for sub in listed if sub["id"] == original["id"])
    assert smart["rule_set_id"] == 0
    for sub in (smart, client.get(url).json()["data"]):
        assert sub["selection_mode"] == "smart"
        assert sub["smart_policy"] == original["smart_policy"]
    with sqlite3.connect(tmp_path / "subscriptions.db") as db:
        stored = db.execute(
            "SELECT rule_set_id, selection_mode, smart_policy FROM subscription WHERE id = ?",
            (original["id"],),
        ).fetchone()
        assert stored[0] is None and stored[1] == "smart"
        assert json.loads(stored[2]) == original["smart_policy"]

    for model in (SubscriptionView, SubscriptionDetailView, UpgradeRunView):
        schema = model.model_json_schema(mode="validation")
        assert "rule_set_id" in schema["required"]
        assert schema["properties"]["rule_set_id"]["type"] == "integer"

"""Device push labels follow the reader while permission and connection facts stay fixed."""

import pytest

from . import test_cloud_push as cloud

world = cloud.world
client = cloud.client


@pytest.mark.parametrize(
    ("fields", "status"),
    [
        ({"push_problem": "unsupported_build"}, "unsupported_build"),
        ({"push_permission": "denied"}, "permission_denied"),
        ({"push_stream": True}, "ok"),
        ({}, "not_registered"),
        ({"push_token": "ab", "push_topic": "raw-topic", "push_problem": "bad_token"}, "bad_token"),
        ({"push_token": "ab", "push_topic": "raw-topic"}, "no_channel"),
    ],
)
def test_status_translation_does_not_change_device_or_status(fields, status):
    from movieclaw_api.i18n import current_locale
    from movieclaw_api.services.push.me import device_status
    from movieclaw_db.models import LoginDevice

    device = LoginDevice(kind="ios", name="原始设备名", member_id=0, token_hash="fixture", **fields)
    before = device.model_dump()
    labels = []
    for language in ("en", "zh-Hans", "en"):
        token = current_locale.set(language)
        try:
            result = device_status(device, [])
        finally:
            current_locale.reset(token)
        assert result[0] == status
        assert device.model_dump() == before
        labels.append(result[1])
    assert labels[0] == labels[2] != labels[1]
    assert not any("\u3400" <= char <= "\u9fff" for char in labels[0])


def test_device_list_translates_push_reason_at_read_time(client, world):
    cloud._connect(client, world)
    bearer = cloud._app_login(client, cloud._ADMIN, installation="i18n-status", name="原始设备名")
    response = cloud._as_app(
        client,
        bearer,
        "PUT",
        "/api/v1/push/me/registration",
        json={"permission": "authorized", "unsupported_build": True},
    )
    assert response.status_code == 200
    rows = []
    for language in ("en", "zh-Hans", "en"):
        response = client.get("/api/v1/auth/devices", headers={"Accept-Language": language})
        assert response.status_code == 200
        rows.append(next(row for row in response.json()["data"] if row["name"] == "原始设备名"))
    assert {row["id"] for row in rows} == {rows[0]["id"]}
    assert {row["kind"] for row in rows} == {"ios"}
    assert {row["push"]["status"] for row in rows} == {"unsupported_build"}
    assert rows[0]["push"]["status_text"] == rows[2]["push"]["status_text"]
    assert "TestFlight" in rows[0]["push"]["status_text"]
    assert "侧载" in rows[1]["push"]["status_text"]

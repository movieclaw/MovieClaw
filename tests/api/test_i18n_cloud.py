"""Cloud status is rendered for each reader without altering pairing or encrypted storage."""

import copy
import re
from datetime import timedelta

import httpx

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import reference
from movieclaw_api.services.cloud.client import CloudUnreachable
from movieclaw_api.services.cloud.service import Pairing
from movieclaw_api.services.push.relay import network_error_ref
from movieclaw_db.models import utcnow

from . import test_cloud_push as cloud_fixture

client = cloud_fixture.client
world = cloud_fixture.world
_connect = cloud_fixture._connect
_data = cloud_fixture._data
_wait = cloud_fixture._wait


def _read(client, language):
    return _data(client.get("/api/v1/cloud", headers={"Accept-Language": language}))


def test_pairing_references_stay_chinese_while_readers_change(client, world):  # noqa: F811
    _data(client.post("/api/v1/cloud/pairing", json={"instance_name": "用户服务器"}))
    world.cloud.approval = "denied"
    _wait(lambda: (_read(client, "en")["pairing"] or {}).get("status") == "denied")
    from movieclaw_api.services.cloud import get_cloud_service

    pairing = get_cloud_service().pairing
    before = copy.deepcopy(pairing)
    en, zh, again = [_read(client, lang)["pairing"] for lang in ("en", "zh-Hans", "en")]
    assert en == again
    assert en["message"] == "This connection was denied on movieclaw.io"
    assert zh["message"] == pairing.message == "这次连接在 movieclaw.io 上被拒绝了"
    assert en["user_code"] == zh["user_code"]
    assert en["instance_name"] == zh["instance_name"] == "用户服务器"
    assert pairing == before
    assert "message_ref" not in en


def test_health_references_nested_errors_and_storage_do_not_change(client, world):  # noqa: F811
    _connect(client, world)
    from movieclaw_api.services.cloud import get_cloud_service

    service = get_cloud_service()
    setting = client.portal.call(service.load)
    snapshot = setting.model_dump_json()
    service._failures = 1
    failure = CloudUnreachable(message_key="cloud.network.http", params={"status": 503})
    service._last_error, service._last_error_ref = str(failure), failure.message_ref
    en, zh, again = [_read(client, lang) for lang in ("en", "zh-Hans", "en")]
    assert en["health_message"] == again["health_message"]
    assert "HTTP 503" in en["health_message"]
    assert not re.search(r"[\u3400-\u9fff]", en["health_message"])
    assert "最近一次同步失败：MovieClaw Cloud 暂时不可用（HTTP 503）" in zh["health_message"]
    assert client.portal.call(service.load).model_dump_json() == snapshot
    assert service._last_error == str(failure)
    expired = setting.model_copy(update={"token_expires_at": utcnow() - timedelta(seconds=1)})
    with use_locale("en"):
        assert service.health(expired)[0] == "expired"
        assert (
            "(MovieClaw Cloud is temporarily unavailable (HTTP 503))" in service.health(expired)[1]
        )
    with use_locale("zh-Hans"):
        assert "（MovieClaw Cloud 暂时不可用（HTTP 503））" in service.health(expired)[1]


def test_default_unsupported_and_revocation_are_marked_but_upstream_text_is_preserved(
    client, world
):  # noqa: F811
    _connect(client, world)
    from movieclaw_api.services.cloud import get_cloud_service

    service = get_cloud_service()
    for message in ("", "上游自定义原因"):
        world.cloud.renew_reply = (403, {"code": "VERSION_UNSUPPORTED", "message": message})
        _data(client.post("/api/v1/cloud/renew"))
        before = client.portal.call(service.load).model_dump_json()
        english = _read(client, "en")
        chinese = _read(client, "zh-Hans")
        assert english["health"] == chinese["health"] == "unsupported"
        assert english["health_message"] == (
            message
            or "This version is no longer supported by MovieClaw official push. Please update"
        )
        assert chinese["health_message"] == (
            message or "这个版本已不再受 MovieClaw 官方推送支持，请升级"
        )
        assert client.portal.call(service.load).model_dump_json() == before
    world.cloud.renew_reply = (401, {"code": "INSTANCE_REVOKED"})
    _data(client.post("/api/v1/cloud/renew"))
    before = client.portal.call(service.load).model_dump_json()
    assert (
        _read(client, "en")["last_disconnect"]["message"]
        == "This server has been disconnected from the MovieClaw account"
    )
    assert (
        _read(client, "zh-Hans")["last_disconnect"]["message"]
        == "这台服务器已经和 MovieClaw 账号断开"
    )
    assert client.portal.call(service.load).model_dump_json() == before
    assert not client.portal.call(service.load).instance_secret


def test_network_categories_and_pairing_raw_unknown_messages_remain_neutral():
    from movieclaw_api.i18n.stored import render_value

    for error in (
        httpx.ConnectError("secret"),
        httpx.ProxyError("secret"),
        httpx.ReadTimeout("secret"),
        httpx.ReadError("secret"),
    ):
        with use_locale("en"):
            assert not re.search(r"[\u3400-\u9fff]", render_value(network_error_ref(error)))
            assert "secret" not in render_value(network_error_ref(error))
        with use_locale("zh-Hans"):
            assert re.search(r"[\u3400-\u9fff]", render_value(network_error_ref(error)))
    pairing = Pairing("api", "device", "user", "uri", "complete", "qr", utcnow(), 1, "name")
    pairing.set_message(reference("cloud.pairing.expired"))
    assert pairing.message_ref
    pairing.set_message("第三方原文")
    assert pairing.message == "第三方原文" and pairing.message_ref is None
    pairing.set_message(None)
    assert pairing.message is None and pairing.message_ref is None

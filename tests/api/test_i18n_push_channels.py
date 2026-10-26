"""Push management keeps routing/runtime facts neutral and renders diagnostics per reader."""

import copy
import re

import httpx

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import reference, render_value
from movieclaw_api.services.push import channels
from movieclaw_api.services.push.relay import RelayError

from . import test_cloud_push as cloud_fixture

client = cloud_fixture.client
world = cloud_fixture.world
_data = cloud_fixture._data


def _view(connection, language):
    return _data(connection.get("/api/v1/push/channels", headers={"Accept-Language": language}))


def test_official_and_custom_channel_metadata_change_only_for_readers(client, world):
    from sqlalchemy import text

    from movieclaw_db.engine import get_database

    _data(
        client.post(
            "/api/v1/push/relays",
            json={"name": "作者中继", "url": "http://relay.lan", "token": "mcpush_ab12_secret"},
        )
    )

    async def original():
        async with get_database().session() as session:
            return (
                await session.execute(
                    text("SELECT value_json FROM app_setting WHERE namespace='push.channels'")
                )
            ).scalar_one()

    before = client.portal.call(original)
    english, chinese, again = [_view(client, lang) for lang in ("en", "zh-Hans", "en")]
    assert english == again
    assert english["channels"][0]["name"] == "MovieClaw official push"
    assert chinese["channels"][0]["name"] == "MovieClaw 官方推送"
    assert english["channels"][0]["status_text"] == "Not connected to MovieClaw Cloud"
    assert english["channels"][1]["status_text"] == "Working"
    assert chinese["channels"][1]["status_text"] == "正常"
    assert english["channels"][1]["name"] == chinese["channels"][1]["name"] == "作者中继"
    for en, zh in zip(english["channels"], chinese["channels"], strict=True):
        assert {k: v for k, v in en.items() if k not in {"name", "status_text"}} == {
            k: v for k, v in zh.items() if k not in {"name", "status_text"}
        }
    assert client.portal.call(original) == before
    with use_locale("en"):
        neutral = client.portal.call(channels.load_channels)
    assert neutral[0].name == channels.OFFICIAL_NAME
    assert neutral[0].problem == "未连接 MovieClaw Cloud"


def test_probe_errors_warnings_and_nested_runtime_references(client, world, monkeypatch):
    invalid = _data(
        client.post(
            "/api/v1/push/relays/probe",
            json={"url": "ftp://bad"},
            headers={"Accept-Language": "en"},
        )
    )
    assert invalid["error"] == "Relay address must start with http:// or https://"
    response = client.post(
        "/api/v1/push/relays", json={"url": "ftp://bad"}, headers={"Accept-Language": "en"}
    )
    assert response.status_code == 400
    assert response.json()["message"] == invalid["error"]
    remote = world.relays["relay.lan"]
    original = remote.handle

    def wrong_version(request):
        result = original(request)
        document = result.json()
        document["protocol"] = 9
        return httpx.Response(200, json=document)

    monkeypatch.setattr(remote, "handle", wrong_version)
    rejected = _data(
        client.post(
            "/api/v1/push/relays/probe",
            json={"url": "http://relay.lan"},
            headers={"Accept-Language": "en"},
        )
    )
    assert rejected["reachable"]
    assert rejected["error"] == "Relay protocol is version 9; this version supports only 1"
    assert not re.search(r"[\u3400-\u9fff]", " ".join(rejected["warnings"]))
    monkeypatch.setattr(remote, "handle", original)
    view = _data(
        client.post(
            "/api/v1/push/relays",
            json={"name": "Fixture", "url": "http://relay.lan", "token": "mcpush_ab12_secret"},
        )
    )
    channel_id = view["channels"][1]["id"]
    state = channels.runtime(channel_id)
    failure = RelayError(
        message_key="push.relay.network",
        params={"reason": reference("cloud.network.timeout")},
        retryable=True,
        network=True,
    )
    state.record_failure(failure.message, unreachable=True, message_ref=failure.message_ref)
    before = copy.deepcopy(state)
    english, chinese, again = [
        _view(client, lang)["channels"][1] for lang in ("en", "zh-Hans", "en")
    ]
    assert english == again
    assert english["last_error"] == "Relay: Connection timed out"
    assert english["status_text"] == "Last push failed: Relay: Connection timed out"
    assert chinese["last_error"] == state.last_error == "中继连接超时"
    assert state == before
    state.record_failure("上游原文")
    assert state.last_error_ref is None
    assert _view(client, "en")["channels"][1]["last_error"] == "上游原文"
    state.record_success(None)
    assert state.last_error is None and state.last_error_ref is None


def test_relay_errors_preserve_chinese_and_retry_contract_in_english_context():
    with use_locale("en"):
        error = RelayError(
            message_key="push.relay.unauthorized",
            params={"reason": "上游原文"},
            retryable=True,
            code="unauthorized",
        )
        assert error.message == "中继拒绝了凭证：上游原文"
        assert render_value(error.message_ref) == "Relay rejected the credentials: 上游原文"
        assert error.retryable and error.code == "unauthorized" and not error.network
        unknown = RelayError("作者错误", retryable=False)
        assert unknown.message == "作者错误" and unknown.message_ref is None

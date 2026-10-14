import base64
import hashlib
import json
import sqlite3
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from tests.api.test_llm import _FakeProtocol
from tests.api.test_llm import client as client
from tests.llm.unit.test_chatgpt import signed_identity

from movieclaw_api.services import chatgpt_auth
from movieclaw_llm.chatgpt import PLAN_SCOPE
from movieclaw_llm.protocols import PROTOCOLS


@pytest.mark.parametrize(
    "redirect",
    [
        "https://example.invalid/callback",
        "http://localhost:1455/auth/callback",
        "http://127.0.0.1:1455/callback",
        "http://127.0.0.1:bad/auth/callback",
    ],
)
def test_only_exact_loopback_callbacks_are_accepted(client, redirect):
    c, _ = client
    result = c.post("/api/v1/llm/chatgpt/authorize", json={"redirect_uri": redirect})
    assert result.status_code == 400


def test_authorization_code_exchange_and_account_catalog(client, monkeypatch):
    c, _ = client
    monkeypatch.setitem(PROTOCOLS, "openai_chatgpt", _FakeProtocol)
    redirect = "http://127.0.0.1:54321/auth/callback"
    start = c.post("/api/v1/llm/chatgpt/authorize", json={"redirect_uri": redirect})
    assert start.status_code == 200
    flow = start.json()["data"]
    query = parse_qs(urlparse(flow["authorize_url"]).query)
    assert query["client_id"] == ["dynamic_agent_client"]
    assert query["agent_name_hint"] == ["MovieClaw"]
    token, keys = signed_identity(nonce=query["nonce"][0])

    def handle(request):
        if request.url.path.endswith("/oauth/token"):
            form = parse_qs(request.content.decode())
            assert form["redirect_uri"] == [redirect]
            assert form["client_id"] == ["oaiapp_test"]
            challenge = (
                base64.urlsafe_b64encode(hashlib.sha256(form["code_verifier"][0].encode()).digest())
                .decode()
                .rstrip("=")
            )
            assert query["code_challenge"] == [challenge]
            return httpx.Response(
                200,
                json={
                    "access_token": "api-test-access",
                    "refresh_token": "api-test-refresh",
                    "id_token": token,
                    "scope": PLAN_SCOPE,
                    "expires_in": 3600,
                },
            )
        if request.url.path.endswith("jwks.json"):
            return httpx.Response(200, json=keys)
        assert request.headers["authorization"] == "Bearer api-test-access"
        return httpx.Response(
            200,
            json={
                "models": [
                    {"slug": "account-model", "visibility": "list"},
                    {"slug": "hidden-model", "visibility": "hidden"},
                ]
            },
        )

    monkeypatch.setattr(chatgpt_auth, "egress_transport", lambda _: httpx.MockTransport(handle))
    payload = {
        "attempt_id": flow["attempt_id"],
        "state": flow["state"],
        "code": "test-code",
        "client_id": "oaiapp_test",
    }
    wrong = c.post("/api/v1/llm/chatgpt/complete", json={**payload, "state": "wrong"})
    assert wrong.status_code == 400
    result = c.post("/api/v1/llm/chatgpt/complete", json=payload)
    assert result.status_code == 200, result.text
    provider = result.json()["data"]
    assert provider["chatgpt_account"] == "user@example.invalid"
    assert [m["id"] for m in provider["extra_models"]] == ["account-model"]
    assert "api-test-access" not in result.text and "api-test-refresh" not in result.text
    with sqlite3.connect(client[1]) as database:
        stored = database.execute("SELECT api_key FROM llm_provider").fetchone()[0]
    assert stored.startswith("enc::") and "api-test-access" not in stored
    assert c.get("/api/v1/llm/providers").json()["data"][0]["status"] == "active"
    replay = c.post("/api/v1/llm/chatgpt/complete", json=payload)
    assert replay.status_code == 400
    renewed = c.post(
        "/api/v1/llm/chatgpt/authorize",
        json={"redirect_uri": redirect, "provider_id": provider["id"]},
    )
    returning_query = parse_qs(urlparse(renewed.json()["data"]["authorize_url"]).query)
    assert returning_query["client_id"] == ["oaiapp_test"]
    assert returning_query["ext_agent_host_id"] == query["ext_agent_host_id"]
    assert "agent_name_hint" not in returning_query
    assert returning_query["login_hint"] == ["user@example.invalid"]
    assert returning_query["id_token_hint"] == [token]
    mismatch = c.post(
        "/api/v1/llm/chatgpt/complete",
        json={
            "attempt_id": renewed.json()["data"]["attempt_id"],
            "state": renewed.json()["data"]["state"],
            "code": "other-code",
            "client_id": "oaiapp_other",
        },
    )
    assert mismatch.status_code == 400


def test_delete_clears_local_credentials_and_reports_unconfirmed_revocation(client, monkeypatch):
    from unittest.mock import AsyncMock

    from tests.llm.unit.test_chatgpt import credentials

    c, _ = client
    monkeypatch.setitem(PROTOCOLS, "openai_chatgpt", _FakeProtocol)
    revoke = AsyncMock(return_value=False)
    monkeypatch.setattr("movieclaw_api.services.llm_config.revoke_credentials", revoke)
    created = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "ChatGPT delete test",
            "provider_type": "chatgpt",
            "api_key": credentials().model_dump_json(),
            "default_model": "account-model",
            "extra_models": [
                {"id": "account-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    assert created.status_code == 200
    deleted = c.delete(f"/api/v1/llm/providers/{created.json()['data']['id']}")
    assert deleted.status_code == 200 and "远端撤销未确认" in deleted.json()["message"]
    assert c.get("/api/v1/llm/providers").json()["data"] == []
    assert revoke.await_count == 1


def test_chatgpt_tokens_cannot_be_forwarded_to_custom_endpoint(client):
    from tests.llm.unit.test_chatgpt import credentials

    c, _ = client
    result = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "Unsafe",
            "provider_type": "chatgpt",
            "api_key": credentials().model_dump_json(),
            "base_url": "https://example.invalid/v1",
            "default_model": "account-model",
            "extra_models": [
                {"id": "account-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    assert result.status_code == 400


def test_connection_refresh_updates_saved_account_capabilities_without_relogin(client, monkeypatch):
    from tests.llm.unit.test_chatgpt import credentials

    from movieclaw_llm.chatgpt import account_model_catalog
    from movieclaw_llm.models import ProviderInfo

    class AccountProtocol(_FakeProtocol):
        async def test_connection(self):
            catalog = account_model_catalog(
                [
                    {
                        "slug": "gpt-6.1-sol",
                        "visibility": "list",
                        "context_window": 500000,
                        "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}],
                    },
                ]
            )
            return ProviderInfo(models=[m.id for m in catalog], model_catalog=catalog)

    monkeypatch.setitem(PROTOCOLS, "openai_chatgpt", AccountProtocol)
    c, path = client
    result = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "ChatGPT",
            "provider_type": "chatgpt",
            "api_key": credentials().model_dump_json(),
            "default_model": "gpt-6.1-sol",
            "extra_models": [{"id": "gpt-6.1-sol"}],
        },
    )
    assert result.status_code == 200, result.text
    models = c.get("/api/v1/llm/models").json()["data"]
    assert [m["model_id"] for m in models] == ["gpt-6.1-sol"]
    assert models[0]["thinking_levels"] == ["low", "high"]
    with sqlite3.connect(path) as db:
        row = db.execute("select extra_models, api_key from llm_provider").fetchone()
    saved = json.loads(row[0])[0]
    assert saved["context_window"] == 500000
    assert saved["thinking_control"]["levels"] == ["low", "high"]
    assert row[1].startswith("enc::") and "test-access" not in row[1]


def test_probe_never_sends_oauth_bundle_or_uses_proxy(client, monkeypatch):
    from tests.llm.unit.test_chatgpt import credentials

    from movieclaw_api.services import network_config

    c, _ = client
    monkeypatch.setitem(PROTOCOLS, "openai_chatgpt", _FakeProtocol)
    result = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "ChatGPT",
            "provider_type": "chatgpt",
            "api_key": credentials().model_dump_json(),
            "default_model": "account-model",
            "extra_models": [
                {"id": "account-model", "context_window": 8192, "max_output_tokens": 2048}
            ],
        },
    )
    assert result.status_code == 200, result.text

    def forbidden(*args, **kwargs):
        pytest.fail("OAuth network probe must not create any outbound transport")

    monkeypatch.setattr(network_config, "egress_transport", forbidden)
    result = c.post("/api/v1/network/test", json={"service": "llm"})
    assert result.status_code == 400 and "模型接入" in result.text
    assert "test-refresh" not in result.text and "test-access" not in result.text


def test_corrupted_credential_does_not_break_list_and_can_be_removed(client, monkeypatch):
    from unittest.mock import AsyncMock

    from tests.llm.unit.test_chatgpt import credentials

    c, path = client
    monkeypatch.setitem(PROTOCOLS, "openai_chatgpt", _FakeProtocol)
    created = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "ChatGPT",
            "provider_type": "chatgpt",
            "api_key": credentials().model_dump_json(),
            "default_model": "account-model",
            "extra_models": [
                {"id": "account-model", "context_window": 8192, "max_output_tokens": 2048}
            ],
        },
    ).json()["data"]
    with sqlite3.connect(path) as db:
        db.execute(
            "update llm_provider set api_key = 'enc::corrupted' where id = ?", (created["id"],)
        )
    result = c.get("/api/v1/llm/providers")
    assert result.status_code == 200
    item = result.json()["data"][0]
    assert item["chatgpt_account"] is None and not item["usable"] and item["status"] == "failed"
    assert "重新连接" in item["last_error"]
    revoke = AsyncMock()
    monkeypatch.setattr(chatgpt_auth, "revoke_credentials", revoke)
    result = c.delete(f"/api/v1/llm/providers/{created['id']}")
    assert result.status_code == 200 and "远端撤销未确认" in result.json()["message"]
    assert c.get("/api/v1/llm/providers").json()["data"] == []


@pytest.mark.parametrize("name", ["invalid/name", "   "])
def test_authorization_rejects_invalid_route_names_before_oauth(client, name):
    c, _ = client
    result = c.post(
        "/api/v1/llm/chatgpt/authorize",
        json={
            "redirect_uri": "http://127.0.0.1:54321/auth/callback",
            "name": name,
        },
    )
    assert result.status_code == 400 and "名称" in result.text


@pytest.mark.parametrize("failure", ["missing_scope", "different_account", "empty_catalog"])
def test_rejected_grants_keep_specific_error_and_are_revoked(client, monkeypatch, failure):
    from unittest.mock import AsyncMock

    from tests.llm.unit.test_chatgpt import credentials

    c, path = client
    monkeypatch.setitem(PROTOCOLS, "openai_chatgpt", _FakeProtocol)
    created = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "ChatGPT",
            "provider_type": "chatgpt",
            "api_key": credentials().model_dump_json(),
            "default_model": "account-model",
            "extra_models": [
                {"id": "account-model", "context_window": 8192, "max_output_tokens": 2048}
            ],
        },
    ).json()["data"]
    with sqlite3.connect(path) as db:
        before = db.execute("select api_key from llm_provider").fetchone()[0]
    flow = c.post(
        "/api/v1/llm/chatgpt/authorize",
        json={
            "redirect_uri": "http://127.0.0.1:54321/auth/callback",
            "provider_id": created["id"],
        },
    ).json()["data"]
    nonce = parse_qs(urlparse(flow["authorize_url"]).query)["nonce"][0]
    token, keys = signed_identity(
        nonce=nonce, sub="other-account" if failure == "different_account" else "test-subject"
    )

    def handle(request):
        if request.url.path.endswith("/oauth/token"):
            return httpx.Response(
                200,
                json={
                    "access_token": "new-grant-access",
                    "refresh_token": "new-grant-refresh",
                    "id_token": token,
                    "scope": "" if failure == "missing_scope" else PLAN_SCOPE,
                },
            )
        if request.url.path.endswith("jwks.json"):
            return httpx.Response(200, json=keys)
        return httpx.Response(200, json={"models": []})

    monkeypatch.setattr(chatgpt_auth, "egress_transport", lambda _: httpx.MockTransport(handle))
    revoke = AsyncMock(return_value=True)
    monkeypatch.setattr(chatgpt_auth, "revoke_credentials", revoke)
    result = c.post(
        "/api/v1/llm/chatgpt/complete",
        json={
            "attempt_id": flow["attempt_id"],
            "state": flow["state"],
            "code": "test-code",
            "client_id": "oaiapp_test",
        },
    )
    assert result.status_code == 400
    expected = {
        "missing_scope": "允许使用订阅额度",
        "different_account": "不是原来的",
        "empty_catalog": "没有可用模型",
    }
    assert expected[failure] in result.json()["message"]
    assert revoke.await_count == 1
    assert revoke.call_args.args[0].refresh_token == "new-grant-refresh"
    with sqlite3.connect(path) as db:
        assert db.execute("select api_key from llm_provider").fetchone()[0] == before
    assert "new-grant-access" not in result.text and "new-grant-refresh" not in result.text


def test_discovery_persists_refresh_rotation_after_instance_rename(client, monkeypatch):
    from tests.llm.unit.test_chatgpt import credentials

    from movieclaw_db.crypto import get_secret_box
    from movieclaw_llm.chatgpt import ChatGPTCredentials
    from movieclaw_llm.models import ChatResponse
    from movieclaw_llm.protocols import openai_chatgpt

    class AccountProtocol(openai_chatgpt.OpenAIChatGPTProtocol):
        async def chat(self, request, model_id):
            return ChatResponse(content="pong", finish_reason="stop")

    monkeypatch.setitem(PROTOCOLS, "openai_chatgpt", AccountProtocol)
    refresh_calls = []

    def handle(request):
        if request.url.path.endswith("/oauth/token"):
            refresh_calls.append(request)
            return httpx.Response(
                200,
                json={
                    "access_token": "rotated-access",
                    "refresh_token": "rotated-refresh",
                    "expires_in": 3600,
                },
            )
        return httpx.Response(200, json={"models": [{"slug": "gpt-6.1-sol", "visibility": "list"}]})

    monkeypatch.setattr(openai_chatgpt, "egress_transport", lambda _: httpx.MockTransport(handle))
    c, path = client
    created = c.post(
        "/api/v1/llm/providers",
        json={
            "name": "Original",
            "provider_type": "chatgpt",
            "api_key": credentials().model_dump_json(),
            "default_model": "gpt-6.1-sol",
            "extra_models": [{"id": "gpt-6.1-sol"}],
        },
    ).json()["data"]
    with sqlite3.connect(path) as db:
        db.execute(
            "update llm_provider set name = 'Renamed', api_key = ? where id = ?",
            (get_secret_box().encrypt(credentials(expires_at=1).model_dump_json()), created["id"]),
        )
    result = c.post(
        "/api/v1/llm/models/discover",
        json={"provider_type": "chatgpt", "provider_id": created["id"]},
    )
    assert result.status_code == 200, result.text
    assert result.json()["data"] == ["gpt-6.1-sol"]
    assert len(refresh_calls) == 1
    with sqlite3.connect(path) as db:
        record = db.execute("select api_key from llm_provider").fetchone()[0]
    assert (
        ChatGPTCredentials.parse(get_secret_box().decrypt(record)).refresh_token
        == "rotated-refresh"
    )
    result = c.post(
        "/api/v1/llm/models/discover",
        json={"provider_type": "chatgpt", "provider_id": created["id"]},
    )
    assert result.status_code == 200 and len(refresh_calls) == 1

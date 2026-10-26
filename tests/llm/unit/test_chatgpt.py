import asyncio
import base64
import json
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from movieclaw_llm.chatgpt import ISSUER, PLAN_SCOPE, ChatGPTCredentials, verify_id_token
from movieclaw_llm.exceptions import LlmAuthError, LlmServerError
from movieclaw_llm.models import (
    ChatMessage,
    ChatRequest,
    LlmProviderConfig,
    ModelSettings,
    ToolDefinition,
)
from movieclaw_llm.protocols.openai_chatgpt import OpenAIChatGPTProtocol
from movieclaw_llm.providers import get_preset


def test_account_catalog_uses_reported_efforts_for_new_models():
    from movieclaw_llm.chatgpt import account_model_catalog

    catalog = account_model_catalog(
        [
            {
                "slug": "future-model",
                "visibility": "list",
                "context_window": 500000,
                "input_modalities": ["text", "image"],
                "supported_reasoning_levels": [
                    {"effort": "low"},
                    {"effort": "high"},
                    {"effort": "max"},
                    {"effort": "ultra"},
                ],
            },
            {"slug": "hidden", "visibility": "hidden"},
        ]
    )
    assert [m.id for m in catalog] == ["future-model"]
    assert catalog[0].thinking_levels == ["low", "high", "max"]
    assert catalog[0].context_window == 500000 and catalog[0].modalities == ["text", "image"]
    assert not catalog[0].supports_tools and not catalog[0].supports_parallel_tool_calls


@pytest.mark.parametrize("level", ["low", "medium", "high", "xhigh", "max"])
def test_legacy_gpt61_catalog_exposes_menu_and_sends_requested_effort(level):
    from movieclaw_api.services.llm_config import build_model_options, to_domain_config
    from movieclaw_db.models.llm_provider import LlmProvider

    row = LlmProvider(
        id=1,
        name="ChatGPT",
        provider_type="chatgpt",
        api_key="unused",
        default_model="gpt-6.1-sol",
        extra_models=[{"id": "gpt-6.1-sol"}],
    )
    options = build_model_options([row], "gpt-6.1-sol")
    assert len(options) == 1 and options[0].thinking_levels == [
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
    ]
    config = to_domain_config(row, credentials().model_dump_json())
    p = OpenAIChatGPTProtocol(config, get_preset("chatgpt"))
    payload = p._build_payload(
        ChatRequest(
            messages=[ChatMessage(role="user", content="Hello")],
            settings=ModelSettings(thinking_level=level),
        ),
        "gpt-6.1-sol",
        stream=True,
    )
    assert payload["reasoning"] == {"effort": level}
    assert payload["include"] == ["reasoning.encrypted_content"]


def test_explicit_account_efforts_override_preset_without_inventing_off():
    from movieclaw_llm.chatgpt import account_model_catalog, restore_account_model_controls

    catalog = account_model_catalog(
        [
            {
                "slug": "gpt-6-sol",
                "visibility": "list",
                "supported_reasoning_levels": [{"effort": "low"}],
            }
        ]
    )
    assert restore_account_model_controls(catalog)[0].thinking_levels == ["low"]


def credentials(**changes):
    values = dict(
        client_id="oaiapp_test",
        subject="test-subject",
        email="user@example.invalid",
        ext_agent_host_id="urn:uuid:test",
        access_token="test-access",
        refresh_token="test-refresh",
        scopes=[PLAN_SCOPE],
        expires_at=time.time() + 3600,
    )
    values.update(changes)
    return ChatGPTCredentials(**values)


def signed_identity(nonce="test-nonce", **changes):
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = private.public_key().public_numbers()

    def encode(value):
        return base64.urlsafe_b64encode(value).decode().rstrip("=")

    claims = dict(
        iss=ISSUER,
        sub="test-subject",
        aud="oaiapp_test",
        nonce=nonce,
        iat=time.time(),
        exp=time.time() + 3600,
        email="user@example.invalid",
    )
    claims.update(changes)
    header = encode(json.dumps({"alg": "RS256", "kid": "test-key"}).encode())
    payload = encode(json.dumps(claims).encode())
    signature = private.sign(f"{header}.{payload}".encode(), padding.PKCS1v15(), hashes.SHA256())
    key = {
        "kid": "test-key",
        "kty": "RSA",
        "use": "sig",
        "n": encode(numbers.n.to_bytes((numbers.n.bit_length() + 7) // 8, "big")),
        "e": encode(numbers.e.to_bytes(3, "big")),
    }
    return f"{header}.{payload}.{encode(signature)}", {"keys": [key]}


@pytest.mark.parametrize(
    "changes",
    [
        {"aud": "other"},
        {"iss": "https://example.invalid"},
        {"exp": 1},
        {"nonce": "other"},
        {"sub": ""},
    ],
)
def test_identity_rejects_wrong_claims(changes):
    token, keys = signed_identity(**changes)
    with pytest.raises(LlmAuthError):
        verify_id_token(token, keys, "oaiapp_test", "test-nonce")


def test_identity_checks_signature_and_nonce():
    token, keys = signed_identity()
    assert verify_id_token(token, keys, "oaiapp_test", "test-nonce")["sub"] == "test-subject"
    unrelated, _ = signed_identity()
    with pytest.raises(LlmAuthError):
        verify_id_token(unrelated, keys, "oaiapp_test", "test-nonce")


def protocol(record=None):
    return OpenAIChatGPTProtocol(
        LlmProviderConfig(
            name="ChatGPT test",
            provider_type="chatgpt",
            api_key=(record or credentials()).model_dump_json(),
        ),
        get_preset("chatgpt"),
    )


def test_plan_payload_preserves_tools_without_unsupported_parameters():
    p = protocol()
    payload = p._build_payload(
        ChatRequest(
            messages=[
                ChatMessage(role="system", content="Manage media"),
                ChatMessage(role="user", content="Find a film"),
            ],
            tools=[
                ToolDefinition(name="search", description="Search", parameters={"type": "object"}),
                ToolDefinition(name="delete", description="Delete", parameters={"type": "object"}),
            ],
            tool_choice="search",
            settings=ModelSettings(temperature=0.2, max_tokens=100, top_p=0.5),
        ),
        "account-model",
        stream=False,
    )
    assert payload["stream"] is True and payload["store"] is False
    assert payload["input"][0]["role"] == "developer"
    assert payload["tools"][0]["type"] == "namespace"
    assert payload["tools"][0]["tools"][0]["name"] == "search"
    assert payload["tool_choice"] == "required"
    assert [t["name"] for t in payload["tools"][0]["tools"]] == ["search"]
    assert not ({"temperature", "top_p", "max_output_tokens"} & payload.keys())


@pytest.mark.asyncio
async def test_refresh_is_serialized_and_rotating_token_persisted(monkeypatch):
    p = protocol(credentials(expires_at=1))
    p.config.provider_id = 27
    calls = []

    class Store:
        value = credentials(expires_at=1).model_dump_json()
        mutex = asyncio.Lock()

        def lock(self, name):
            assert name == 27
            return self.mutex

        async def load(self, name):
            assert name == 27
            return self.value

        async def save(self, name, previous, updated):
            assert name == 27
            assert self.value == previous
            self.value = updated

    store = Store()
    p.token_store = store

    def handle(request):
        calls.append(request.content.decode())
        return httpx.Response(
            200,
            json={
                "access_token": "new-access",
                "refresh_token": "rotated-refresh",
                "expires_in": 3600,
            },
        )

    monkeypatch.setattr(
        "movieclaw_llm.protocols.openai_chatgpt.egress_transport",
        lambda _: httpx.MockTransport(handle),
    )
    await asyncio.gather(p._authorize(), p._authorize())
    assert len(calls) == 1
    assert "client_id=oaiapp_test" in calls[0] and "refresh_token=test-refresh" in calls[0]
    assert ChatGPTCredentials.parse(store.value).refresh_token == "rotated-refresh"
    assert p._client.api_key == "new-access"
    await p.close()


@pytest.mark.asyncio
async def test_truncated_stream_cannot_be_reported_as_success():
    p = protocol()

    async def events():
        yield SimpleNamespace(type="response.output_text.delta", delta="partial")

    p._client.responses.create = AsyncMock(return_value=events())
    with pytest.raises(LlmServerError, match="未完成"):
        await p.chat(
            ChatRequest(messages=[ChatMessage(role="user", content="Hello")]), "account-model"
        )
    await p.close()


@pytest.mark.asyncio
async def test_non_streaming_call_consumes_completed_stream():
    from tests.llm.unit.test_openai_responses import response_fixture

    p = protocol()

    async def events():
        yield SimpleNamespace(type="response.output_text.delta", delta="Hello")
        yield SimpleNamespace(type="response.completed", response=response_fixture(output=[]))

    p._client.responses.create = AsyncMock(return_value=events())
    response = await p.chat(
        ChatRequest(messages=[ChatMessage(role="user", content="Hello")]), "account-model"
    )
    assert response.content == "Hello" and response.finish_reason == "stop"
    assert p._client.responses.create.call_args.kwargs["stream"] is True
    await p.close()

"""LLM error references survive persistence and are rendered for each reader."""

import copy
import sqlite3

import httpx
import openai
import pytest
from tests.api.test_llm import _PAYLOAD, _FakeProtocol, client  # noqa: F401
from tests.llm.unit.test_openai_chat import make_protocol

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.llm import error_reference
from movieclaw_api.i18n.stored import render_value
from movieclaw_llm import LlmConnectError
from movieclaw_llm.protocols import PROTOCOLS


@pytest.mark.parametrize(
    "status,kind", [(401, "auth"), (429, "rate"), (500, "server"), (400, "request")]
)
def test_sdk_errors_keep_chinese_and_retry_facts_while_readers_change(status, kind):
    protocol = make_protocol()
    response = httpx.Response(
        status,
        request=httpx.Request("POST", "https://fixture.test/v1"),
        headers={"retry-after": "3"},
    )
    error_type = {
        401: openai.AuthenticationError,
        429: openai.RateLimitError,
        500: openai.InternalServerError,
        400: openai.BadRequestError,
    }[status]
    raw = error_type("原始上游 detail /v1/responses", response=response, body=None)
    error = protocol._translate_error(raw)
    snapshot = (str(error), copy.deepcopy(error.params), error.retryable)
    assert error.message_key == f"errors.llm.connection.{kind}"
    for locale in ["en", "zh-Hans", "en"]:
        with use_locale(locale):
            displayed = render_value(error_reference(error))
        assert "原始上游 detail /v1/responses" in displayed
        assert displayed.startswith("[测试实例] ")
        if locale == "zh-Hans":
            assert displayed == str(error)
        else:
            assert {
                "auth": "Authentication failed",
                "rate": "Provider rate limit",
                "server": "temporarily unavailable",
                "request": "Invalid request",
            }[kind] in displayed
            if status == 400:
                assert "Settings > AI" in displayed
        assert (str(error), error.params, error.retryable) == snapshot
    if status == 429:
        assert error.retry_after == 3


def test_failure_reference_is_saved_and_cleared_with_the_original_record(client, monkeypatch):  # noqa: F811
    c, db_file = client

    class Failed(_FakeProtocol):
        async def chat(self, request, model_id):
            raise LlmConnectError(
                "连接模型服务失败，请检查网络与 base_url 配置：Connection refused",
                provider=self.config.name,
                message_key="errors.llm.connection.connect",
                params={"detail": "Connection refused"},
            )

    monkeypatch.setitem(PROTOCOLS, "openai_chat", Failed)
    created = c.post("/api/v1/llm/providers", json=_PAYLOAD)
    assert created.status_code == 200, created.text
    provider_id = created.json()["data"]["id"]

    def stored():
        with sqlite3.connect(db_file) as database:
            return database.execute(
                "SELECT last_error, last_error_ref, api_key, status FROM llm_provider WHERE id=?",
                (provider_id,),
            ).fetchone()

    original = stored()
    assert original[1] and original[2].startswith("enc::")
    for language in ["en", "zh-Hans", "en"]:
        row = c.get("/api/v1/llm/providers", headers={"Accept-Language": language}).json()["data"][
            0
        ]
        assert row["status"] == "failed" and not row["usable"]
        assert row["name"] == _PAYLOAD["name"] and row["default_model"] == _PAYLOAD["default_model"]
        assert (
            row["last_error"] == original[0]
            if language == "zh-Hans"
            else "Could not connect" in row["last_error"]
        )
        assert stored() == original
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _FakeProtocol)
    assert c.post(f"/api/v1/llm/providers/{provider_id}/verify").status_code == 200
    assert stored()[0:2] == (None, "null")
    assert stored()[3] == "ACTIVE"


def test_legacy_and_unknown_errors_are_read_without_rewriting(client):  # noqa: F811
    c, db_file = client
    assert c.post("/api/v1/llm/providers", json=_PAYLOAD).status_code == 200
    raw = "旧供应商自带的说明 / upstream raw"
    with sqlite3.connect(db_file) as db:
        db.execute(
            "UPDATE llm_provider SET status='FAILED', last_error=?, last_error_ref=NULL", (raw,)
        )
    for language in ["en", "zh-Hans"]:
        row = c.get("/api/v1/llm/providers", headers={"Accept-Language": language}).json()["data"][
            0
        ]
        assert row["last_error"] == raw
    with sqlite3.connect(db_file) as db:
        assert db.execute("SELECT last_error, last_error_ref FROM llm_provider").fetchone() == (
            raw,
            None,
        )


def test_preset_names_are_reader_local_and_routing_catalogs_do_not_change(client):  # noqa: F811
    c, _ = client
    rows = [
        c.get("/api/v1/llm/presets", headers={"Accept-Language": locale}).json()["data"]
        for locale in ["en", "zh-Hans", "en"]
    ]
    assert rows[0] == rows[2]
    for english, chinese in zip(rows[0], rows[1], strict=True):
        assert {k: v for k, v in english.items() if k != "display_name"} == {
            k: v for k, v in chinese.items() if k != "display_name"
        }
    assert (
        next(r for r in rows[0] if r["id"] == "openai_compat")["display_name"]
        == "OpenAI-compatible endpoint"
    )
    assert (
        next(r for r in rows[1] if r["id"] == "openai_compat")["display_name"] == "OpenAI 兼容端点"
    )


@pytest.mark.parametrize("provider", [None, "Third-party provider"])
def test_unknown_domain_message_key_keeps_raw_text_for_every_reader(provider):
    error = LlmConnectError(
        "Unknown plugin / 原始上游报错",
        provider=provider,
        message_key="plugin.unknown.error",
        params={"opaque": "Raw value"},
    )
    for locale in ["en", "zh-Hans"]:
        with use_locale(locale):
            assert render_value(error_reference(error)) == str(error)
            assert render_value(error.message_ref) == str(error)

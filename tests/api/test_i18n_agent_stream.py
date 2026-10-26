"""One cached stream and durable error event can be read in both languages."""

import copy

from sqlmodel import select
from tests.api import test_agent as agent
from tests.api import test_agent_sessions as sessions

from movieclaw_api.i18n import use_locale
from movieclaw_api.services import durable_events, llm_config
from movieclaw_api.services.agent_runs import get_agent_run_registry
from movieclaw_api.services.push.core_rules import _agent_finished
from movieclaw_db.engine import get_database
from movieclaw_db.models.domain_event import DomainEvent, EventConsumer
from movieclaw_llm import LlmAuthError, LlmRouter
from movieclaw_llm.models import ChatStreamEvent
from movieclaw_llm.protocols import PROTOCOLS
from movieclaw_llm.protocols.openai_base import StreamAccumulator
from movieclaw_sdk.events import RunFinished

client = sessions.client


def test_sse_replay_and_durable_notification_follow_reader_without_mutation(client, monkeypatch):
    class Failed(agent._StreamProtocol):
        async def chat_stream(self, request, model_id):
            acc = StreamAccumulator(model_id, self.config.name)
            acc.content.append("Partial reply")
            yield ChatStreamEvent(type="text_delta", delta="Partial reply", partial=acc.snapshot())
            yield acc.error_event(
                LlmAuthError(
                    "认证失败，请检查 API Key 是否有效：Vendor raw detail",
                    provider=self.config.name,
                    message_key="errors.llm.connection.auth",
                    params={"detail": "Vendor raw detail"},
                )
            )

    async def subscribe():
        async with get_database().session() as session:
            session.add(
                EventConsumer(
                    consumer_id="i18n-fixture:agent-errors",
                    event_name="agent.run.finished",
                    event_names=["agent.run.finished"],
                )
            )
            await session.commit()
        durable_events.reset_subscribed()

    client.portal.call(subscribe)
    monkeypatch.setattr(
        llm_config, "_runtime_router", LlmRouter(protocol_factory=llm_config.build_server_protocol)
    )
    monkeypatch.setitem(PROTOCOLS, "openai_chat", Failed)
    agent.configure_provider(client)
    response = client.post("/api/v1/sessions", json={"content": "Streaming error fixture"})
    assert response.status_code == 202, response.text
    session_id = response.json()["data"]["session_id"]

    async def cached():
        events, _ = await get_agent_run_registry().get_session_events(
            session_id, 0, timeout_seconds=1
        )
        return [e.event.model_dump() for e in events]

    original = None
    for locale in ["en", "zh-Hans", "en"]:
        stream = client.get(
            f"/api/v1/sessions/{session_id}/events", headers={"Accept-Language": locale}
        )
        assert stream.status_code == 200
        events = agent.parse_sse(stream.text)
        error = next(data for _, kind, data in events if kind == "agent_error")
        assert "error_ref" not in error
        assert "Vendor raw detail" in error["error"]
        assert ("Authentication failed" if locale == "en" else "认证失败") in error["error"]
        assert any(
            kind == "text_delta" and data["delta"] == "Partial reply" for _, kind, data in events
        )
        now = client.portal.call(cached)
        if original is None:
            original = copy.deepcopy(now)
        assert now == original
        assert "认证失败" in now[-1]["error"] and now[-1]["error_ref"]

    sessions._wait_not_running(client, session_id)

    async def stored():
        async with get_database().session() as session:
            rows = (
                (
                    await session.execute(
                        select(DomainEvent).where(DomainEvent.name == "agent.run.finished")
                    )
                )
                .scalars()
                .all()
            )
            return next(row.payload for row in rows if row.payload["session_id"] == session_id)

    payload = client.portal.call(stored)
    original_payload = copy.deepcopy(payload)
    assert payload["error_ref"] and "认证失败" in payload["error"]
    for locale in ["en", "zh-Hans", "en"]:

        async def notification(locale=locale):
            with use_locale(locale):
                return await _agent_finished(None, 0, RunFinished.model_validate(payload))

        content = client.portal.call(notification)
        assert ("Authentication failed" if locale == "en" else "认证失败") in content.body
        assert payload == original_payload == client.portal.call(stored)

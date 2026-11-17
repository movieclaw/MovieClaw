"""进程外订阅插件事件：SDK 接受声明，是否已开放仍由宿主运行时目录把关。"""

from types import SimpleNamespace

import pytest
from pydantic import BaseModel, ConfigDict

from movieclaw_kernel import DURABLE_EVENTS, Event, Mode, contracts
from movieclaw_sdk.events import LIBRARY_FILES_ADDED, EventType, plugin_event
from movieclaw_sdk.runner import RemoteContext


class Result(BaseModel):
    model_config = ConfigDict(frozen=True)
    ok: bool


@pytest.fixture(autouse=True)
def isolated_catalog(monkeypatch):
    monkeypatch.setattr(contracts, "CATALOG", dict(contracts.CATALOG))


@pytest.mark.parametrize("durable", [False, True])
def test_remote_context_declares_a_plugin_event_listener(durable) -> None:
    declarations = []
    runner = SimpleNamespace(declare=lambda kind, item: declarations.append((kind, item)))
    ctx = RemoteContext(runner, "listener", "监听器", None, (DURABLE_EVENTS.name,))
    event = plugin_event("producer.result", Result, title="结果")

    ctx.on(event, lambda payload: None, id="result", priority=3, durable=durable)

    assert declarations == [
        ("listeners", {"event": event.name, "id": "result", "priority": 3, "durable": durable})
    ]
    assert ctx._handlers["result"][0] is event


@pytest.mark.parametrize("inject", [(), (DURABLE_EVENTS.name,)])
def test_remote_plugin_event_keeps_durable_requirements(inject) -> None:
    ctx = RemoteContext(None, "listener", "监听器", None, inject)
    event = plugin_event("producer.result", Result, title="结果")
    with pytest.raises(ValueError, match="稳定 id"):
        ctx.on(event, lambda payload: None, durable=True)
    if not inject:
        with pytest.raises(ValueError, match="DURABLE_EVENTS"):
            ctx.on(event, lambda payload: None, id="result", durable=True)


@pytest.mark.parametrize("name", ["unknown.result", LIBRARY_FILES_ADDED.name])
def test_remote_context_still_rejects_unknown_or_copied_static_events(name) -> None:
    ctx = RemoteContext(None, "listener", "监听器", None, ())
    event = Event(name, Mode.EMIT, payload=Result)
    with pytest.raises(ValueError, match="没有开放给第三方插件"):
        ctx.on(event, lambda payload: None)


def test_plugin_event_type_cannot_replace_a_known_static_contract() -> None:
    ctx = RemoteContext(None, "listener", "监听器", None, ())
    event = EventType(LIBRARY_FILES_ADDED.name, Result, title="伪造", group="插件", owner="plugin")
    with pytest.raises(ValueError, match="没有开放给第三方插件"):
        ctx.on(event, lambda payload: None)

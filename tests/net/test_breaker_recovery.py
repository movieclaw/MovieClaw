"""half-open 探测异常退出后的恢复：不改变失败统计或单探测限制。"""

from __future__ import annotations

import asyncio
import json
import socket
from types import SimpleNamespace

import httpx
import pytest

from movieclaw_net import (
    CircuitOpenError,
    EgressConfig,
    apply_egress_config,
    egress_transport,
    get_breaker,
    reset_all_breakers,
)
from movieclaw_net.egress import current_epoch


@pytest.fixture(autouse=True)
def _clean_state():
    apply_egress_config(EgressConfig())
    reset_all_breakers()
    yield
    apply_egress_config(EgressConfig())
    reset_all_breakers()


@pytest.fixture
def clock(monkeypatch):
    clock = SimpleNamespace(now=100.0)
    # 只替换熔断器的时钟，不冻结 asyncio 的超时/调度时钟。
    monkeypatch.setattr("movieclaw_net.breaker.time", SimpleNamespace(monotonic=lambda: clock.now))
    return clock


def _transport(handler):
    transport = egress_transport("llm")
    transport._inner = httpx.MockTransport(handler)
    transport._inner_epoch = current_epoch()
    return transport


async def _open(client):
    for _ in range(3):
        with pytest.raises(httpx.ConnectError):
            await client.get("https://llm.invalid/v1/models")
    assert get_breaker("llm").is_open
    with pytest.raises(CircuitOpenError):
        await client.get("https://llm.invalid/v1/models")


@pytest.mark.parametrize("outcome", ["cancel", "protocol", "value"])
async def test_aborted_probe_allows_next_probe_without_resetting_state(clock, outcome):
    entered = asyncio.Event()
    release = asyncio.Event()
    calls = 0
    phase = "offline"
    error = (
        httpx.RemoteProtocolError("invalid upstream response")
        if outcome == "protocol"
        else ValueError("transport error")
    )

    async def handler(request):
        nonlocal calls
        calls += 1
        if phase == "offline":
            raise httpx.ConnectError("offline", request=request)
        entered.set()
        await release.wait()
        if phase == "abort":
            raise error
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=_transport(handler)) as client:
        await _open(client)
        assert calls == 3
        breaker = get_breaker("llm")
        opened_at = breaker._opened_at
        clock.now += 60
        phase = "abort"
        probe = asyncio.create_task(client.get("https://llm.invalid/v1/models"))
        try:
            await asyncio.wait_for(entered.wait(), timeout=2)
            # 多个并发竞争者仍快速失败，不能释放正在执行的探测。
            for _ in range(2):
                with pytest.raises(CircuitOpenError):
                    await client.get("https://llm.invalid/v1/models")
            assert calls == 4
            if outcome == "cancel":
                probe.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await probe
            else:
                release.set()
                with pytest.raises(type(error)) as caught:
                    await probe
                assert caught.value is error
        finally:
            probe.cancel()
            await asyncio.gather(probe, return_exceptions=True)

        assert breaker._consecutive_failures == 3
        assert breaker._opened_at == opened_at
        assert not breaker._probing
        # 无需人工 net test，也不必重新等待冷却，即可开始下一次单探测。
        entered.clear()
        release.clear()
        phase = "success"
        probe = asyncio.create_task(client.get("https://llm.invalid/v1/models"))
        try:
            await asyncio.wait_for(entered.wait(), timeout=2)
            with pytest.raises(CircuitOpenError):
                await client.get("https://llm.invalid/v1/models")
            assert calls == 5
            release.set()
            assert (await probe).status_code == 200
        finally:
            probe.cancel()
            await asyncio.gather(probe, return_exceptions=True)
        assert breaker._consecutive_failures == 0
        assert breaker._opened_at is None
        assert (await client.get("https://llm.invalid/v1/models")).status_code == 200


@pytest.mark.parametrize("status", [200, 429, 503])
async def test_http_response_closes_probe(clock, status):
    phase = "offline"

    def handler(request):
        if phase == "offline":
            raise httpx.ConnectError("offline", request=request)
        return httpx.Response(status)

    async with httpx.AsyncClient(transport=_transport(handler)) as client:
        await _open(client)
        phase = "online"
        clock.now += 60
        assert (await client.get("https://llm.invalid/v1/models")).status_code == status
        breaker = get_breaker("llm")
        assert breaker._opened_at is None
        assert breaker._consecutive_failures == 0
        assert not breaker._probing


@pytest.mark.parametrize("error_type", [httpx.ReadTimeout, httpx.ConnectError, httpx.ProxyError])
async def test_network_failure_reopens_probe_for_full_cooldown(clock, error_type):
    phase = "offline"
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        if phase == "offline":
            raise httpx.ConnectError("offline", request=request)
        raise error_type("probe failed", request=request)

    async with httpx.AsyncClient(transport=_transport(handler)) as client:
        await _open(client)
        phase = "probe"
        clock.now += 60
        with pytest.raises(error_type):
            await client.get("https://llm.invalid/v1/models")
        breaker = get_breaker("llm")
        assert breaker._consecutive_failures == 4
        assert breaker._opened_at == clock.now
        assert not breaker._probing
        clock.now += 59
        with pytest.raises(CircuitOpenError) as caught:
            await client.get("https://llm.invalid/v1/models")
        assert caught.value.retry_after == 1
        assert calls == 4
        clock.now += 1
        with pytest.raises(error_type):
            await client.get("https://llm.invalid/v1/models")
        assert calls == 5


async def test_closed_request_error_does_not_release_another_requests_probe(clock):
    entered = asyncio.Event()
    release = asyncio.Event()
    phase = "closed"

    async def handler(request):
        if request.url.path == "/old":
            entered.set()
            await release.wait()
            raise httpx.RemoteProtocolError("old request failed")
        if phase == "offline":
            raise httpx.ConnectError("offline", request=request)
        entered.set()
        await release.wait()
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=_transport(handler)) as client:
        old = asyncio.create_task(client.get("https://llm.invalid/old"))
        probe = None
        try:
            await asyncio.wait_for(entered.wait(), timeout=2)
            phase = "offline"
            await _open(client)
            clock.now += 60
            phase = "probe"
            entered.clear()
            probe = asyncio.create_task(client.get("https://llm.invalid/v1/models"))
            await asyncio.wait_for(entered.wait(), timeout=2)
            # closed 时放行的旧请求在新探测期间取消，不能归还别人的探测槽。
            old.cancel()
            with pytest.raises(asyncio.CancelledError):
                await old
            with pytest.raises(CircuitOpenError):
                await client.get("https://llm.invalid/v1/models")
            release.set()
            assert (await probe).status_code == 200
        finally:
            tasks = [old] + ([probe] if probe is not None else [])
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


@pytest.mark.parametrize("outcome", ["cancel", "protocol"])
async def test_llm_recovers_through_real_http_after_aborted_probe(clock, outcome):
    """真实 SDK → httpx → 出口 → 本地 HTTP；不访问供应商、不人工 reset。"""
    from movieclaw_llm import ChatMessage, ChatRequest, LlmConnectError, LlmProviderConfig
    from movieclaw_llm.protocols.openai_chat import OpenAIChatProtocol
    from movieclaw_llm.providers import get_preset

    entered = asyncio.Event()
    phase = "probe"
    paths = []
    handlers = set()
    payload = json.dumps(
        {
            "id": "local-completion",
            "object": "chat.completion",
            "created": 0,
            "model": "local-model",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": "recovered"},
                    "finish_reason": "stop",
                }
            ],
        }
    ).encode()

    async def serve(reader, writer):
        task = asyncio.current_task()
        handlers.add(task)
        try:
            headers = await reader.readuntil(b"\r\n\r\n")
            paths.append(headers.split(b"\r\n", 1)[0])
            length = next(
                int(line.split(b":", 1)[1])
                for line in headers.split(b"\r\n")
                if line.lower().startswith(b"content-length:")
            )
            body = json.loads(await reader.readexactly(length))
            assert body["model"] == "local-model"
            assert body["messages"] == [{"role": "user", "content": "hello"}]
            if phase == "probe":
                entered.set()
                if outcome == "cancel":
                    await reader.read()  # 客户端取消后关闭连接，不回 HTTP 响应。
                    return
                else:
                    writer.write(b"THIS IS NOT HTTP\r\n\r\n")
                    await writer.drain()
                    return
            writer.write(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                b"Connection: close\r\nContent-Length: "
                + str(len(payload)).encode()
                + b"\r\n\r\n"
                + payload
            )
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()
            handlers.discard(task)

    # 先绑定但不监听：真实连接失败触发 open，随后在同一地址恢复服务。
    with socket.socket() as upstream:
        upstream.bind(("127.0.0.1", 0))
        upstream.setblocking(False)
        config = LlmProviderConfig(
            name="local synthetic LLM",
            provider_type="openai_compat",
            api_key="test-only",
            base_url=f"http://127.0.0.1:{upstream.getsockname()[1]}/v1",
            timeout_seconds=5,
        )
        protocol = OpenAIChatProtocol(config, get_preset("openai_compat"))
        protocol._client.timeout = httpx.Timeout(5.0, connect=0.2)
        request = ChatRequest(messages=[ChatMessage(role="user", content="hello")])
        probe = None
        try:
            for _ in range(3):
                with pytest.raises(LlmConnectError):
                    await protocol.chat(request, "local-model")
            with pytest.raises(LlmConnectError) as caught:
                await protocol.chat(request, "local-model")
            assert isinstance(caught.value.__cause__.__cause__, CircuitOpenError)
            clock.now += 60
            async with await asyncio.start_server(serve, sock=upstream):
                if outcome == "cancel":
                    probe = asyncio.create_task(protocol.chat(request, "local-model"))
                    await asyncio.wait_for(entered.wait(), timeout=2)
                    probe.cancel()
                    with pytest.raises(asyncio.CancelledError):
                        await probe
                else:
                    with pytest.raises(LlmConnectError) as caught:
                        await protocol.chat(request, "local-model")
                    assert isinstance(caught.value.__cause__.__cause__, httpx.RemoteProtocolError)
                phase = "online"
                clock.now += 3 * 3600  # 时间流逝不能修复遗留的 _probing=True。
                # 对应作者 curl 正常的观察：绕过熔断直连同一端点确实正常。
                async with httpx.AsyncClient(trust_env=False) as direct:
                    healthy = await direct.post(
                        f"{config.base_url}/chat/completions",
                        json={
                            "model": "local-model",
                            "messages": [{"role": "user", "content": "hello"}],
                        },
                    )
                assert healthy.status_code == 200
                response = await protocol.chat(request, "local-model")
                assert response.content == "recovered"
                assert len(paths) == 3
                assert all(path == b"POST /v1/chat/completions HTTP/1.1" for path in paths)
                assert get_breaker("llm")._opened_at is None
        finally:
            if probe is not None:
                probe.cancel()
                await asyncio.gather(probe, return_exceptions=True)
            await protocol.close()
            for task in list(handlers):
                task.cancel()
            await asyncio.gather(*handlers, return_exceptions=True)

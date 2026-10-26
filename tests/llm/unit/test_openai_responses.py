"""openai_responses 协议：请求转换、原生条目回放、响应/流式解析（全部 mock）。"""

import httpx
import openai
from openai.types.responses import Response, ResponseStreamEvent
from pydantic import TypeAdapter

from movieclaw_llm import (
    ChatMessage,
    ChatRequest,
    ImagePart,
    LlmProviderConfig,
    LlmRouter,
    LlmServerError,
    ModelInfo,
    ModelSettings,
    NativeOutput,
    TextPart,
    ThinkingControl,
    ThinkingPart,
    ToolCall,
    ToolDefinition,
)
from movieclaw_llm.protocols.openai_chat import OpenAIChatProtocol
from movieclaw_llm.protocols.openai_responses import OpenAIResponsesProtocol
from movieclaw_llm.providers import get_preset

TOOL = ToolDefinition(
    name="search",
    description="搜索资源",
    parameters={"type": "object", "properties": {"q": {"type": "string"}}},
)


def make_protocol(
    provider_type: str = "openai", extra_models: list[ModelInfo] | None = None
) -> OpenAIResponsesProtocol:
    config = LlmProviderConfig(
        name="测试实例",
        provider_type=provider_type,
        api_key="sk-test",
        base_url="http://relay.local/v1" if provider_type == "openai_compat" else None,
        extra_models=extra_models or [],
    )
    return OpenAIResponsesProtocol(config, get_preset(provider_type))


def build(p: OpenAIResponsesProtocol, request: ChatRequest, model_id="gpt-5.6-luna") -> dict:
    return p._build_payload(request, model_id, stream=False)


# -- 请求转换 ---------------------------------------------------------------


def test_issue_768_tools_with_explicit_effort_go_into_reasoning_object():
    """issue #768 的场景：带工具 + 高档位。effort 落 reasoning.effort，不再有顶层
    reasoning_effort（Chat Completions 上正是这个组合被拒）。"""
    payload = build(
        make_protocol(),
        ChatRequest(
            messages=[ChatMessage(role="user", content="帮我找沙丘")],
            tools=[TOOL],
            settings=ModelSettings(thinking_level="high"),
        ),
    )
    assert payload["reasoning"] == {"effort": "high"}
    assert "reasoning_effort" not in payload
    assert "reasoning_effort" not in payload.get("extra_body", {})
    assert payload["tools"] == [
        {
            "type": "function",
            "name": "search",
            "description": "搜索资源",
            "parameters": TOOL.parameters,
            # Responses 默认 strict=true，我们的 Schema 不满足严格模式，必须显式关掉
            "strict": False,
        }
    ]
    assert payload["store"] is False
    assert payload["include"] == ["reasoning.encrypted_content"]


def test_off_level_encodes_effort_none():
    payload = build(
        make_protocol(),
        ChatRequest(
            messages=[ChatMessage(role="user", content="q")],
            settings=ModelSettings(thinking_level="off"),
        ),
    )
    assert payload["reasoning"] == {"effort": "none"}


def test_astra_off_falls_back_without_sending_unsupported_none():
    payload = build(
        make_protocol(),
        ChatRequest(messages=[], settings=ModelSettings(thinking_level="off")),
        "gpt-6-astra",
    )
    assert "reasoning" not in payload
    assert payload["include"] == ["reasoning.encrypted_content"]


def test_deepseek_borrowed_model_uses_responses_off_encoding():
    flash = next(m for m in get_preset("deepseek").models if m.id == "deepseek-flash")
    payload = build(
        make_protocol("openai_compat", [flash]),
        ChatRequest(messages=[], settings=ModelSettings(thinking_level="off")),
        flash.id,
    )
    assert payload["reasoning"] == {"effort": "none"}
    assert "extra_body" not in payload


def test_current_reasoning_removes_sampling_unless_explicitly_off():
    request = ChatRequest(
        messages=[], settings=ModelSettings(temperature=0.5, top_p=0.9, thinking_level="high")
    )
    protocol = make_protocol()
    payload = build(protocol, request, "gpt-6-luna")
    assert "temperature" not in payload
    assert "top_p" not in payload
    request.settings.thinking_level = "off"
    payload = build(protocol, request, "gpt-6-luna")
    assert payload["temperature"] == 0.5
    assert payload["top_p"] == 0.9


def test_level_outside_menu_falls_back_to_default():
    """Luna 不支持 minimal：回落默认，不伪造该档位。"""
    payload = build(
        make_protocol(),
        ChatRequest(
            messages=[ChatMessage(role="user", content="q")],
            settings=ModelSettings(thinking_level="minimal"),
        ),
    )
    assert "reasoning" not in payload


def test_non_reasoning_model_does_not_request_encrypted_content():
    """非推理模型请求 encrypted_content 会被拒：没有 effort 声明就不带 include。"""
    p = make_protocol("openai_compat", [ModelInfo(id="qwen-plus")])
    payload = build(p, ChatRequest(messages=[ChatMessage(role="user", content="q")]), "qwen-plus")
    assert "include" not in payload
    assert "reasoning" not in payload


def test_budget_dialect_is_merged_top_level():
    """非 effort 方言（如 enable_thinking）交给端点自己认，原样并入顶层。"""
    model = ModelInfo(
        id="qwen3", max_thinking_tokens=1000, thinking_control=ThinkingControl(kind="budget")
    )
    p = make_protocol("openai_compat", [model])
    payload = build(
        p,
        ChatRequest(
            messages=[ChatMessage(role="user", content="q")],
            settings=ModelSettings(thinking_level="low"),
        ),
        "qwen3",
    )
    assert payload["extra_body"] == {"enable_thinking": True, "thinking_budget": 250}
    assert "reasoning" not in payload


def test_conversation_items():
    payload = build(
        make_protocol(),
        ChatRequest(
            messages=[
                ChatMessage(role="system", content="你是助手"),
                ChatMessage(
                    role="user",
                    content=[
                        TextPart(text="识别海报"),
                        ImagePart(data="QUJD", media_type="image/png"),
                    ],
                ),
                ChatMessage(
                    role="assistant",
                    content=[ThinkingPart(text="想想"), TextPart(text="我查一下")],
                    tool_calls=[ToolCall(id="call_1", name="search", raw_arguments='{"q":"沙丘"}')],
                ),
                ChatMessage(role="tool", content="找到 3 条", tool_call_id="call_1", name="search"),
            ]
        ),
    )
    assert payload["input"] == [
        {"role": "system", "content": "你是助手"},
        {
            "role": "user",
            "content": [
                {"type": "input_text", "text": "识别海报"},
                {"type": "input_image", "image_url": "data:image/png;base64,QUJD"},
            ],
        },
        {"role": "assistant", "content": "我查一下"},
        {
            "type": "function_call",
            "call_id": "call_1",
            "name": "search",
            "arguments": '{"q":"沙丘"}',
        },
        {"type": "function_call_output", "call_id": "call_1", "output": "找到 3 条"},
    ]


def test_settings_mapping_and_unsupported_params_dropped(caplog):
    with caplog.at_level("INFO"):
        payload = build(
            make_protocol(),
            ChatRequest(
                messages=[ChatMessage(role="user", content="q")],
                tool_choice="search",
                settings=ModelSettings(
                    max_tokens=512,
                    temperature=0.3,
                    stop=["\n"],
                    seed=7,
                    response_format="json_object",
                    extra_body={"service_tier": "flex"},
                ),
            ),
        )
    assert payload["max_output_tokens"] == 512
    tiny = build(
        make_protocol(),
        ChatRequest(
            messages=[ChatMessage(role="user", content="ping")],
            settings=ModelSettings(max_tokens=1),
        ),
    )
    assert tiny["max_output_tokens"] == 16  # 连接测试的 max_tokens=1 抬到线协议下限
    assert payload["temperature"] == 0.3
    assert payload["tool_choice"] == {"type": "function", "name": "search"}
    assert payload["text"] == {"format": {"type": "json_object"}}
    assert payload["extra_body"] == {"service_tier": "flex"}
    assert "stop" not in payload and "seed" not in payload
    assert any("stop" in r.message and "seed" in r.message for r in caplog.records)


# -- 原生条目回放 -----------------------------------------------------------

NATIVE_ITEMS = [
    {
        "id": "rs_1",
        "type": "reasoning",
        "summary": [],
        "encrypted_content": "gAAA密文",
        "status": "completed",
    },
    {
        "id": "fc_1",
        "type": "function_call",
        "call_id": "call_1",
        "name": "search",
        "arguments": '{"q":"沙丘"}',
        "status": "completed",
    },
]


def assistant_with_native(provider="测试实例", model="gpt-5.6-luna") -> ChatMessage:
    return ChatMessage(
        role="assistant",
        content="",
        tool_calls=[ToolCall(id="call_1", name="search", raw_arguments='{"q":"沙丘"}')],
        native_output=NativeOutput(provider=provider, model=model, items=NATIVE_ITEMS),
    )


def test_native_items_replayed_verbatim_without_ids_for_same_model():
    """同实例同模型：推理密文原样回放；store=false 下 id 是悬空引用，必须剥掉。"""
    payload = build(make_protocol(), ChatRequest(messages=[assistant_with_native()]))
    assert payload["input"] == [
        {"type": "reasoning", "summary": [], "encrypted_content": "gAAA密文"},
        {
            "type": "function_call",
            "call_id": "call_1",
            "name": "search",
            "arguments": '{"q":"沙丘"}',
        },
    ]


def test_native_items_not_replayed_across_models_or_instances():
    """密文绑定账号与模型：换模型 / 换实例都按普通历史重建，不带推理条目。"""
    expected = [
        {
            "type": "function_call",
            "call_id": "call_1",
            "name": "search",
            "arguments": '{"q":"沙丘"}',
        }
    ]
    other_model = build(
        make_protocol(), ChatRequest(messages=[assistant_with_native()]), "gpt-5.6-sol"
    )
    assert other_model["input"] == expected
    other_instance = build(
        make_protocol(), ChatRequest(messages=[assistant_with_native(provider="别家")])
    )
    assert other_instance["input"] == expected


def test_chat_protocol_ignores_native_output():
    """切回 Chat Completions 的实例：原生快照不进线协议。"""
    config = LlmProviderConfig(name="测试实例", provider_type="openai", api_key="sk")
    chat = OpenAIChatProtocol(config, get_preset("openai"))
    payload = chat._build_payload(
        ChatRequest(messages=[assistant_with_native()]), "gpt-5.6-luna", stream=False
    )
    assert "native_output" not in str(payload) and "gAAA" not in str(payload)


def test_native_output_survives_message_roundtrip():
    """转录落盘是 ChatMessage 的 JSON：快照随之持久化，续聊时还能回放。"""
    message = assistant_with_native()
    restored = ChatMessage.model_validate_json(message.model_dump_json(exclude_none=True))
    assert restored.native_output == message.native_output


# -- 非流式解析 -------------------------------------------------------------


def response_fixture(**overrides) -> Response:
    data = {
        "id": "resp_1",
        "object": "response",
        "created_at": 1,
        "model": "gpt-5.6-luna",
        "parallel_tool_calls": True,
        "tool_choice": "auto",
        "tools": [],
        "status": "completed",
        "output": [
            {
                "id": "rs_1",
                "type": "reasoning",
                "summary": [{"type": "summary_text", "text": "先搜索"}],
                "encrypted_content": "gAAA密文",
            },
            {
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": "我查一下", "annotations": []}],
            },
            {
                "id": "fc_1",
                "type": "function_call",
                "call_id": "call_1",
                "name": "search",
                "arguments": '{"q":"沙丘"}',
                "status": "completed",
            },
        ],
        "usage": {
            "input_tokens": 10,
            "input_tokens_details": {"cached_tokens": 4, "cache_write_tokens": 0},
            "output_tokens": 6,
            "output_tokens_details": {"reasoning_tokens": 3},
            "total_tokens": 16,
        },
    }
    return Response.model_validate(data | overrides)


class FakeResponses:
    def __init__(self, result):
        self._result = result
        self.calls: list[dict] = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self._result, Exception):
            raise self._result
        if callable(self._result):
            return self._result()
        return self._result


class FakeClient:
    def __init__(self, result):
        self.responses = FakeResponses(result)

    async def close(self):
        pass


async def test_chat_parses_output_items_usage_and_native_snapshot():
    p = make_protocol()
    p._client = FakeClient(response_fixture())
    resp = await p.chat(
        ChatRequest(messages=[ChatMessage(role="user", content="q")]), "gpt-5.6-luna"
    )
    assert resp.content == "我查一下"
    assert resp.thinking == "先搜索"
    assert resp.finish_reason == "tool_calls"
    assert resp.tool_calls[0].id == "call_1"
    assert resp.tool_calls[0].arguments == {"q": "沙丘"}
    assert (resp.usage.prompt_tokens, resp.usage.completion_tokens) == (10, 6)
    assert resp.usage.cache_read_tokens == 4
    assert resp.native_output.provider == "测试实例"
    assert [i["type"] for i in resp.native_output.items] == [
        "reasoning",
        "message",
        "function_call",
    ]
    # to_message 把快照带进历史，下一步请求即可回放
    replay = build(p, ChatRequest(messages=[resp.to_message()]))["input"]
    assert replay[0] == {
        "type": "reasoning",
        "summary": [{"type": "summary_text", "text": "先搜索"}],
        "encrypted_content": "gAAA密文",
    }


async def test_chat_without_reasoning_items_keeps_no_snapshot():
    p = make_protocol()
    fixture = response_fixture()
    fixture.output = fixture.output[1:2]
    p._client = FakeClient(fixture)
    resp = await p.chat(
        ChatRequest(messages=[ChatMessage(role="user", content="q")]), "gpt-5.6-luna"
    )
    assert resp.finish_reason == "stop"
    assert resp.native_output is None


async def test_chat_incomplete_maps_to_length():
    p = make_protocol()
    p._client = FakeClient(
        response_fixture(status="incomplete", incomplete_details={"reason": "max_output_tokens"})
    )
    resp = await p.chat(
        ChatRequest(messages=[ChatMessage(role="user", content="q")]), "gpt-5.6-luna"
    )
    assert resp.finish_reason == "length"


async def test_chat_failed_status_raises_server_error():
    p = make_protocol()
    p._client = FakeClient(
        response_fixture(status="failed", error={"code": "server_error", "message": "上游炸了"})
    )
    try:
        await p.chat(ChatRequest(messages=[ChatMessage(role="user", content="q")]), "gpt-5.6-luna")
    except LlmServerError as exc:
        assert "上游炸了" in str(exc) and "测试实例" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("failed 状态应抛 LlmServerError")


# -- 流式 -------------------------------------------------------------------

_EVENT = TypeAdapter(ResponseStreamEvent)


def ev(seq: int, payload: dict):
    return _EVENT.validate_python(payload | {"sequence_number": seq})


def stream_events():
    fixture = response_fixture()
    yield ev(
        0,
        {
            "type": "response.created",
            "response": fixture.model_dump() | {"status": "in_progress", "output": []},
        },
    )
    yield ev(
        1,
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {"id": "rs_1", "type": "reasoning", "summary": []},
        },
    )
    yield ev(
        2,
        {
            "type": "response.reasoning_summary_text.delta",
            "item_id": "rs_1",
            "output_index": 0,
            "summary_index": 0,
            "delta": "先",
        },
    )
    yield ev(
        3,
        {
            "type": "response.reasoning_summary_text.delta",
            "item_id": "rs_1",
            "output_index": 0,
            "summary_index": 0,
            "delta": "搜索",
        },
    )
    yield ev(
        4,
        {
            "type": "response.reasoning_summary_text.delta",
            "item_id": "rs_1",
            "output_index": 0,
            "summary_index": 1,
            "delta": "再回答",
        },
    )
    yield ev(
        5,
        {
            "type": "response.output_text.delta",
            "item_id": "msg_1",
            "output_index": 1,
            "content_index": 0,
            "delta": "我查",
            "logprobs": [],
        },
    )
    yield ev(
        6,
        {
            "type": "response.output_text.delta",
            "item_id": "msg_1",
            "output_index": 1,
            "content_index": 0,
            "delta": "一下",
            "logprobs": [],
        },
    )
    yield ev(
        7,
        {
            "type": "response.output_item.added",
            "output_index": 2,
            "item": {
                "id": "fc_1",
                "type": "function_call",
                "call_id": "call_1",
                "name": "search",
                "arguments": "",
            },
        },
    )
    yield ev(
        8,
        {
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_1",
            "output_index": 2,
            "delta": '{"q"',
        },
    )
    yield ev(
        9,
        {
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_1",
            "output_index": 2,
            "delta": ':"沙丘"}',
        },
    )
    yield ev(
        10,
        {
            "type": "response.output_item.done",
            "output_index": 2,
            "item": fixture.output[2].model_dump(),
        },
    )
    yield ev(11, {"type": "response.completed", "response": fixture.model_dump()})


async def collect(p, gen_factory, model_id="gpt-5.6-luna"):
    async def agen():
        for item in gen_factory():
            yield item

    p._client = FakeClient(agen)
    return [
        e
        async for e in p.chat_stream(
            ChatRequest(messages=[ChatMessage(role="user", content="q")], tools=[TOOL]), model_id
        )
    ]


async def test_stream_event_sequence_and_final_partial():
    p = make_protocol()
    events = await collect(p, stream_events)
    assert [e.type for e in events] == [
        "start",
        "thinking_delta",
        "thinking_delta",
        "thinking_delta",
        "text_delta",
        "text_delta",
        "toolcall_start",
        "toolcall_delta",
        "toolcall_delta",
        "toolcall_end",
        "done",
    ]
    final = events[-1].partial
    assert final.thinking == "先搜索\n\n再回答"  # 换摘要段补空行
    assert final.content == "我查一下"
    assert final.finish_reason == "tool_calls"
    assert final.tool_calls[0].id == "call_1"
    assert final.tool_calls[0].arguments == {"q": "沙丘"}
    assert final.usage.total_tokens == 16
    assert final.native_output is not None
    assert final.native_output.items[0]["encrypted_content"] == "gAAA密文"
    deltas = [e for e in events if e.type == "toolcall_delta"]
    assert all(e.tool_call.id == "call_1" and e.tool_call.name == "search" for e in deltas)
    # 请求本身：流式 + 推理密文
    sent = p._client.responses.calls[0]
    assert sent["stream"] is True and sent["include"] == ["reasoning.encrypted_content"]


async def test_stream_tool_call_without_argument_deltas():
    """个别中转不推参数增量、只在 output_item.done 给全量：照样拿到完整调用。"""
    fixture = response_fixture()

    def events():
        yield ev(
            0,
            {
                "type": "response.output_item.done",
                "output_index": 2,
                "item": fixture.output[2].model_dump(),
            },
        )
        yield ev(1, {"type": "response.completed", "response": fixture.model_dump()})

    out = await collect(make_protocol(), events)
    assert [e.type for e in out] == ["start", "toolcall_start", "toolcall_end", "done"]
    assert out[-1].partial.tool_calls[0].arguments == {"q": "沙丘"}


async def test_stream_failed_and_error_events_end_with_error():
    fixture = response_fixture(
        status="failed", error={"code": "server_error", "message": "上游炸了"}
    )

    def failed():
        yield ev(
            0,
            {
                "type": "response.output_text.delta",
                "item_id": "m",
                "output_index": 0,
                "content_index": 0,
                "delta": "部分",
                "logprobs": [],
            },
        )
        yield ev(1, {"type": "response.failed", "response": fixture.model_dump()})

    out = await collect(make_protocol(), failed)
    assert out[-1].type == "error"
    assert out[-1].partial.content == "部分"
    assert "上游炸了" in out[-1].partial.error

    def errored():
        yield ev(0, {"type": "error", "code": "rate_limit", "message": "太快了", "param": None})

    out = await collect(make_protocol(), errored)
    assert out[-1].type == "error" and "太快了" in out[-1].partial.error


async def test_stream_connection_drop_preserves_partial():
    def broken():
        yield ev(
            0,
            {
                "type": "response.output_text.delta",
                "item_id": "m",
                "output_index": 0,
                "content_index": 0,
                "delta": "部分",
                "logprobs": [],
            },
        )
        raise openai.APIConnectionError(request=httpx.Request("POST", "http://x"))

    out = await collect(make_protocol(), broken)
    assert out[-1].type == "error"
    assert out[-1].partial.content == "部分"
    assert "连接模型服务失败" in out[-1].partial.error


async def test_stream_request_error_is_translated():
    request = httpx.Request("POST", "http://x")
    bad = openai.BadRequestError(
        "Unsupported value", response=httpx.Response(400, request=request), body=None
    )
    p = make_protocol()
    p._client = FakeClient(bad)
    out = [
        e
        async for e in p.chat_stream(
            ChatRequest(messages=[ChatMessage(role="user", content="q")]), "gpt-5.6-luna"
        )
    ]
    assert [e.type for e in out] == ["error"]
    assert "请求参数错误" in out[0].partial.error


# -- 路由选协议 -------------------------------------------------------------


def test_router_picks_protocol_from_preset_default_or_instance_override():
    router = LlmRouter(
        [
            LlmProviderConfig(name="官方", provider_type="openai", api_key="sk-a"),
            LlmProviderConfig(
                name="中转",
                provider_type="openai",
                api_key="sk-b",
                base_url="http://relay/v1",
                api_protocol="openai_chat",
            ),
            LlmProviderConfig(
                name="兼容",
                provider_type="openai_compat",
                api_key="sk-c",
                base_url="http://c/v1",
                api_protocol="openai_responses",
            ),
            LlmProviderConfig(
                name="兼容默认",
                provider_type="openai_compat",
                api_key="sk-d",
                base_url="http://d/v1",
            ),
        ]
    )
    clients = {p.name: router._client_for(p) for p in router._providers}
    assert isinstance(clients["官方"], OpenAIResponsesProtocol)
    assert type(clients["中转"]) is OpenAIChatProtocol
    assert isinstance(clients["兼容"], OpenAIResponsesProtocol)
    assert type(clients["兼容默认"]) is OpenAIChatProtocol


def test_chat_completions_rejection_points_to_protocol_switch():
    """issue #768 原始报错：上游让改用 /v1/responses → 错误里附上去哪切换协议。"""
    request = httpx.Request("POST", "http://x")
    exc = openai.BadRequestError(
        "Function tools with reasoning_effort are not supported for gpt-5.6-luna in "
        "/v1/chat/completions. To use function tools, use /v1/responses or set "
        "reasoning_effort to 'none'.",
        response=httpx.Response(400, request=request),
        body=None,
    )
    config = LlmProviderConfig(name="测试实例", provider_type="openai", api_key="sk")
    err = OpenAIChatProtocol(config, get_preset("openai"))._translate_error(exc)
    assert "API 协议切换为 Responses API" in str(err)

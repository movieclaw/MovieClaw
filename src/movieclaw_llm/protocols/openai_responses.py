"""OpenAI Responses API 协议实现（POST /v1/responses）。

为什么需要它：GPT-5.6 等推理模型在 Chat Completions 上不允许「函数工具 +
非 none 的 reasoning_effort」同时出现（issue #768），Agent 每轮都带工具，
等于思考档位全部失效；OpenAI 给的出路就是 Responses API。

与 openai_chat 的线协议差异（本层负责吸收）：

- 消息是「条目」序列：普通消息 / function_call / function_call_output 平级，
  工具结果靠 call_id 关联（ToolCall.id 存的就是 call_id）；
- 工具声明扁平化，且**默认 strict=true**——我们的 JSON Schema 不满足严格
  模式的约束（全字段必填、禁额外字段），必须显式关掉；
- 思考强度在 reasoning.effort；max_tokens 叫 max_output_tokens；
  stop / seed / presence_penalty / frequency_penalty 没有对应参数，丢弃；
- 无状态：store=false，不在 OpenAI 侧留存对话。推理模型多步工具调用时
  需要拿回上一步的推理条目才能接着想，所以请求 reasoning.encrypted_content，
  把整段 response.output 存进 NativeOutput，同实例同模型时原样回放。

推理摘要（reasoning.summary）**不主动请求**：OpenAI 要求组织完成实名验证
才能生成摘要，未验证的账号会直接 400。端点自己返回的摘要/推理文本照常
当思考内容展示。
"""

from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from typing import Any

from movieclaw_llm.exceptions import LlmServerError
from movieclaw_llm.models import (
    ChatMessage,
    ChatRequest,
    ChatResponse,
    ChatStreamEvent,
    FinishReason,
    ImagePart,
    NativeOutput,
    TextPart,
    TokenUsage,
    ToolCall,
)
from movieclaw_llm.protocols.openai_base import (
    OpenAIProtocolBase,
    StreamAccumulator,
    _warn_harmony_residue_in_content,
)
from movieclaw_llm.thinking import thinking_body_fragment

logger = logging.getLogger(__name__)

#: Responses API 没有对应参数的采样设置：发出去只会 400，丢弃并记日志
_UNSUPPORTED_SETTINGS = ("stop", "seed", "presence_penalty", "frequency_penalty")

#: max_output_tokens 的下限（OpenAI 线协议约束）
_MIN_OUTPUT_TOKENS = 16

#: incomplete_details.reason → 统一结束原因
_INCOMPLETE_REASON_MAP: dict[str, FinishReason] = {
    "max_output_tokens": "length",
    "content_filter": "content_filter",
}

#: 回放原生条目时剥掉的字段：store=false 时条目不在服务端留存，带着 id
#: 回传会被当成引用去查而报「Item not found」；status 是输出侧状态，不是输入
_REPLAY_DROP_KEYS = ("id", "status")


class OpenAIResponsesProtocol(OpenAIProtocolBase):
    require_completed = False
    # -- 请求转换 -----------------------------------------------------------

    def _is_reasoning_model(self, model_id: str) -> bool:
        """effort 制思考控制 = OpenAI 式推理模型，才有推理条目可回放。

        非推理模型请求 encrypted_content 会被上游拒绝，所以按声明 fail-closed。
        """
        info = self._model_info(model_id)
        control = info.thinking_control if info else None
        return control is not None and control.kind == "effort"

    @staticmethod
    def _convert_user_content(message: ChatMessage) -> str | list[dict]:
        """用户内容块 → Responses 输入内容。纯文本压成字符串（兼容端点最稳）。"""
        if isinstance(message.content, str):
            return message.content
        parts: list[dict] = []
        has_image = False
        for part in message.content:
            if isinstance(part, TextPart):
                parts.append({"type": "input_text", "text": part.text})
            elif isinstance(part, ImagePart):
                if not part.url and not part.data:
                    # 与 openai_chat 同款 fail-safe：未水合的引用块降级为占位文本
                    logger.warning(
                        "图片内容块未水合（attachment_id=%s），已降级为占位文本；"
                        "这是程序缺陷，请检查发请求前的水合逻辑",
                        part.attachment_id,
                    )
                    parts.append({"type": "input_text", "text": "[图片未能加载，已略过]"})
                    continue
                has_image = True
                url = part.url or f"data:{part.media_type};base64,{part.data}"
                parts.append({"type": "input_image", "image_url": url})
            # ThinkingPart：思考内容不作为输入发回，静默丢弃
        if not has_image:
            return "".join(p["text"] for p in parts)
        return parts

    def _replayable(self, message: ChatMessage, model_id: str) -> list[dict] | None:
        """同实例同模型产出的原生条目才回放；其余情况返回 None 按普通历史重建。"""
        native = message.native_output
        if native is None or not native.items:
            return None
        if native.provider != self.config.name or native.model != model_id:
            return None
        return [
            {k: v for k, v in item.items() if k not in _REPLAY_DROP_KEYS} for item in native.items
        ]

    def _convert_message(self, message: ChatMessage, model_id: str) -> list[dict]:
        if message.role == "tool":
            return [
                {
                    "type": "function_call_output",
                    "call_id": message.tool_call_id,
                    "output": message.text(),
                }
            ]
        if message.role == "assistant":
            replay = self._replayable(message, model_id)
            if replay is not None:
                return replay
            items: list[dict] = []
            text = message.text()
            if text:
                items.append({"role": "assistant", "content": text})
            for tc in message.tool_calls or []:
                items.append(
                    {
                        "type": "function_call",
                        "call_id": tc.id,
                        "name": tc.name,
                        "arguments": tc.raw_arguments or json.dumps(tc.arguments),
                    }
                )
            return items
        if message.role == "system":
            # 留在 input 里而不是并进 instructions：保持消息原有顺序
            return [{"role": "system", "content": message.text()}]
        return [{"role": "user", "content": self._convert_user_content(message)}]

    def _build_payload(self, request: ChatRequest, model_id: str, *, stream: bool) -> dict:
        input_items: list[dict] = []
        for message in request.messages:
            input_items.extend(self._convert_message(message, model_id))
        payload: dict[str, Any] = {"model": model_id, "input": input_items, "store": False}
        if request.tools:
            payload["tools"] = [
                {
                    "type": "function",
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters,
                    "strict": False,
                }
                for t in request.tools
            ]
        if request.tool_choice:
            if request.tool_choice in ("auto", "none", "required"):
                payload["tool_choice"] = request.tool_choice
            else:
                payload["tool_choice"] = {"type": "function", "name": request.tool_choice}
        s = request.settings
        if s.temperature is not None:
            payload["temperature"] = s.temperature
        if s.top_p is not None:
            payload["top_p"] = s.top_p
        if s.max_tokens is not None:
            # Responses API 拒收小于 16 的值（连接测试发的是 max_tokens=1）
            payload["max_output_tokens"] = max(s.max_tokens, _MIN_OUTPUT_TOKENS)
        dropped = [key for key in _UNSUPPORTED_SETTINGS if getattr(s, key) is not None]
        if dropped:
            logger.info("Responses API 不支持参数 %s，本次请求已忽略", "、".join(dropped))
        if s.response_format == "json_object":
            payload["text"] = {"format": {"type": "json_object"}}

        # 思考档位：effort 制的 reasoning_effort 改写为 reasoning.effort；
        # 其他方言（budget / toggle）原样并入请求体顶层，交给端点自己认
        extra = thinking_body_fragment(s.thinking_level, self._model_info(model_id), model_id)
        model = self._model_info(model_id)
        if (
            model
            and model.thinking_control
            and model.thinking_control.kind == "effort"
            and model.thinking_control.supports_off
            and s.thinking_level == "off"
        ):
            # effort 模型的 Responses 关闭编码统一为 reasoning.effort=none；
            # 不能把 DeepSeek Chat 的 thinking.type=disabled 带到这里。
            extra = {"reasoning_effort": "none"}
        effort = extra.pop("reasoning_effort", None)
        if effort is not None:
            payload["reasoning"] = {"effort": effort}
        if model and (
            model.fixed_sampling or (model.sampling_requires_no_reasoning and effort != "none")
        ):
            payload.pop("temperature", None)
            payload.pop("top_p", None)
        if self._is_reasoning_model(model_id):
            payload["include"] = ["reasoning.encrypted_content"]
        extra = {**extra, **(s.extra_body or {})}  # 用户显式 extra_body 优先
        if extra:
            payload["extra_body"] = extra
        if stream:
            payload["stream"] = True
        return payload

    # -- 响应转换 -----------------------------------------------------------

    @staticmethod
    def _parse_usage(usage: Any) -> TokenUsage:
        if usage is None:
            return TokenUsage()
        details = getattr(usage, "input_tokens_details", None)
        cached = (getattr(details, "cached_tokens", None) or 0) if details is not None else 0
        return TokenUsage(
            prompt_tokens=usage.input_tokens or 0,
            completion_tokens=usage.output_tokens or 0,
            total_tokens=usage.total_tokens or 0,
            cache_read_tokens=cached,
        )

    @staticmethod
    def _reasoning_text(item: Any) -> str:
        """推理条目里可展示的文本：摘要（OpenAI）或推理原文（开源模型端点）。"""
        texts = [p.text for p in getattr(item, "summary", None) or [] if getattr(p, "text", "")]
        texts += [p.text for p in getattr(item, "content", None) or [] if getattr(p, "text", "")]
        return "\n\n".join(texts)

    @staticmethod
    def _message_text(item: Any) -> str:
        """输出消息的正文；拒答（refusal）也当正文给用户看，免得静默空响应。"""
        out: list[str] = []
        for part in getattr(item, "content", None) or []:
            kind = getattr(part, "type", "")
            if kind == "output_text":
                out.append(part.text or "")
            elif kind == "refusal":
                out.append(part.refusal or "")
        return "".join(out)

    def _native_output(self, items: list[Any], model_id: str) -> NativeOutput | None:
        """含推理条目时才留快照——没有推理可续接时按普通历史重建是等价的。"""
        if not any(getattr(item, "type", "") == "reasoning" for item in items):
            return None
        return NativeOutput(
            provider=self.config.name,
            model=model_id,
            items=[item.model_dump(mode="json", exclude_none=True) for item in items],
        )

    @staticmethod
    def _finish_reason(response: Any, has_tool_calls: bool) -> FinishReason:
        if getattr(response, "status", None) == "incomplete":
            details = getattr(response, "incomplete_details", None)
            reason = getattr(details, "reason", None) or ""
            return _INCOMPLETE_REASON_MAP.get(reason, "length")
        return "tool_calls" if has_tool_calls else "stop"

    @staticmethod
    def _failure_message(response: Any) -> str:
        error = getattr(response, "error", None)
        message = getattr(error, "message", None) if error is not None else None
        return message or "模型服务返回失败状态，原因未知"

    def _parse_response(self, response: Any, model_id: str) -> ChatResponse:
        if getattr(response, "status", None) == "failed":
            raise LlmServerError(
                f"模型服务返回失败：{self._failure_message(response)}", provider=self.config.name
            )
        content: list[str] = []
        thinking: list[str] = []
        tool_calls: list[ToolCall] = []
        for item in response.output or []:
            kind = getattr(item, "type", "")
            if kind == "message":
                content.append(self._message_text(item))
            elif kind == "reasoning":
                text = self._reasoning_text(item)
                if text:
                    thinking.append(text)
            elif kind == "function_call":
                tool_calls.append(
                    self._parse_tool_call(item.call_id, item.name, item.arguments or "")
                )
        text = "".join(content) or None
        _warn_harmony_residue_in_content(text)
        return ChatResponse(
            content=text,
            thinking="\n\n".join(thinking) or None,
            tool_calls=tool_calls or None,
            finish_reason=self._finish_reason(response, bool(tool_calls)),
            usage=self._parse_usage(response.usage),
            model=getattr(response, "model", None) or model_id,
            provider=self.config.name,
            native_output=self._native_output(response.output or [], model_id),
        )

    # -- 对外接口 -----------------------------------------------------------

    async def chat(self, request: ChatRequest, model_id: str) -> ChatResponse:
        payload = self._build_payload(request, model_id, stream=False)
        try:
            response = await self._client.responses.create(**payload)
        except Exception as exc:  # noqa: BLE001 - 统一翻译为 LlmError 体系
            raise self._translate_error(exc) from exc
        return self._parse_response(response, model_id)

    async def chat_stream(
        self, request: ChatRequest, model_id: str
    ) -> AsyncIterator[ChatStreamEvent]:
        payload = self._build_payload(request, model_id, stream=True)
        acc = StreamAccumulator(model_id, self.config.name)
        try:
            stream = await self._client.responses.create(**payload)
        except Exception as exc:  # noqa: BLE001
            err = self._translate_error(exc)
            yield acc.error_event(str(err))
            return

        yield ChatStreamEvent(type="start", partial=acc.snapshot())
        #: 已完成的输出条目（output_index → 条目），终态事件缺 output 时兜底
        done_items: dict[int, Any] = {}
        final_response: Any = None
        #: 上一段思考文本所在的 (output_index, summary_index)，换段时补空行
        thinking_key: tuple[int, int] | None = None
        try:
            async for event in stream:
                kind = getattr(event, "type", "")
                if kind == "response.output_text.delta" or kind == "response.refusal.delta":
                    if event.delta:
                        acc.content.append(event.delta)
                        yield ChatStreamEvent(
                            type="text_delta", delta=event.delta, partial=acc.snapshot()
                        )
                elif kind in (
                    "response.reasoning_summary_text.delta",
                    "response.reasoning_text.delta",
                ):
                    if not event.delta:
                        continue
                    # 摘要按 summary_index 分段，推理原文按 content_index 分段
                    part = getattr(event, "summary_index", None)
                    if part is None:
                        part = getattr(event, "content_index", 0)
                    key = (event.output_index, part)
                    delta = event.delta
                    if thinking_key is not None and key != thinking_key:
                        delta = "\n\n" + delta
                    thinking_key = key
                    acc.thinking.append(delta)
                    yield ChatStreamEvent(
                        type="thinking_delta", delta=delta, partial=acc.snapshot()
                    )
                elif kind == "response.output_item.added":
                    item = event.item
                    if getattr(item, "type", "") == "function_call":
                        acc.start_tool(event.output_index, item.call_id, item.name)
                        yield ChatStreamEvent(
                            type="toolcall_start",
                            tool_call=acc.tool_snapshot(event.output_index),
                            partial=acc.snapshot(),
                        )
                elif kind == "response.function_call_arguments.delta":
                    if not event.delta:
                        continue
                    acc.start_tool(event.output_index)  # 防御：端点漏发 output_item.added
                    acc.append_tool_arguments(event.output_index, event.delta)
                    yield ChatStreamEvent(
                        type="toolcall_delta",
                        delta=event.delta,
                        tool_call=acc.tool_snapshot(event.output_index),
                        partial=acc.snapshot(),
                    )
                elif kind == "response.output_item.done":
                    item = event.item
                    done_items[event.output_index] = item
                    if getattr(item, "type", "") == "function_call":
                        started = acc.start_tool(event.output_index, item.call_id, item.name)
                        if started:
                            yield ChatStreamEvent(
                                type="toolcall_start",
                                tool_call=acc.tool_snapshot(event.output_index),
                                partial=acc.snapshot(),
                            )
                        # 收尾给的完整参数为准：个别端点只发这一份、不推增量
                        if item.arguments or not acc.has_tool_arguments(event.output_index):
                            acc.replace_tool_arguments(event.output_index, item.arguments or "")
                elif kind in ("response.completed", "response.incomplete"):
                    final_response = event.response
                elif kind == "response.failed":
                    message = self._failure_message(event.response)
                    err = LlmServerError(f"模型服务返回失败：{message}", provider=self.config.name)
                    yield acc.error_event(str(err))
                    return
                elif kind == "error":
                    message = getattr(event, "message", None) or "未知错误"
                    err = LlmServerError(f"模型服务报错：{message}", provider=self.config.name)
                    yield acc.error_event(str(err))
                    return
        except Exception as exc:  # noqa: BLE001 - 流中断以 error 事件收尾，保留 partial
            err = self._translate_error(exc)
            logger.warning("流式调用中断：%s", err)
            yield acc.error_event(str(err))
            return

        if self.require_completed and (
            final_response is None or getattr(final_response, "status", "") != "completed"
        ):
            yield acc.error_event("ChatGPT 响应未完成，请重试（可能已达到订阅额度）")
            return
        _warn_harmony_residue_in_content("".join(acc.content))
        for index in acc.tool_order:
            tc = acc.finalize_tool(index, self._parse_tool_call)
            yield ChatStreamEvent(type="toolcall_end", tool_call=tc, partial=acc.snapshot())
        output = list(getattr(final_response, "output", None) or []) or [
            done_items[i] for i in sorted(done_items)
        ]
        acc.native_output = self._native_output(output, model_id)
        if final_response is not None:
            acc.usage = self._parse_usage(final_response.usage)
            acc.finish_reason = self._finish_reason(final_response, bool(acc.tool_order))
        else:
            acc.finish_reason = "tool_calls" if acc.tool_order else "stop"
        yield ChatStreamEvent(type="done", partial=acc.snapshot())

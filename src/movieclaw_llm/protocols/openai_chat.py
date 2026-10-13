"""OpenAI Chat Completions 协议实现。

一份实现覆盖所有 OpenAI 兼容端点：OpenAI 官方、阿里云百炼
compatible-mode、自建 vLLM/Ollama 等，差异由预设的 compat 声明吸收
（当前主要是思考内容字段名 thinking_field）。

职责边界：本层只做「统一模型 ↔ OpenAI 线协议」的双向转换和错误翻译，
不做路由、不做重试策略（重试决策依据 LlmError.retryable 由上层把握）。
"""

from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from typing import Any

from movieclaw_llm.exceptions import LlmRequestError
from movieclaw_llm.models import (
    ChatMessage,
    ChatRequest,
    ChatResponse,
    ChatStreamEvent,
    FinishReason,
    ImagePart,
    TextPart,
    ThinkingPart,
    TokenUsage,
)
from movieclaw_llm.protocols.openai_base import (
    OpenAIProtocolBase,
    StreamAccumulator,
    _sdk,
    _warn_harmony_residue_in_content,
)
from movieclaw_llm.thinking import thinking_body_fragment

logger = logging.getLogger(__name__)


def sdk_default_user_agent() -> str:
    """openai SDK 自带的 User-Agent（用户不覆盖时实际发送的值）。

    按 SDK 内部公式（BaseClient.user_agent：``{类名}/Python {版本}``）拼出，
    而不是写死字符串——升级 SDK 后设置页展示的默认值自动跟着变。
    供设置页作为 User-Agent 输入框的占位提示，帮用户排查网关按 UA 放行的场景。
    """
    openai = _sdk()
    return f"{openai.AsyncOpenAI.__name__}/Python {openai.__version__}"

# OpenAI 的 finish_reason → 统一枚举；未知值按 stop 兜底
_FINISH_REASON_MAP: dict[str, FinishReason] = {
    "stop": "stop",
    "tool_calls": "tool_calls",
    "length": "length",
    "content_filter": "content_filter",
}

class OpenAIChatProtocol(OpenAIProtocolBase):
    # -- 请求转换 -----------------------------------------------------------

    def _convert_content(self, message: ChatMessage) -> str | list[dict] | None:
        """内容块 → OpenAI 格式。纯文本尽量压成字符串（兼容端点最稳）。"""
        if isinstance(message.content, str):
            return message.content
        parts: list[dict] = []
        has_image = False
        for part in message.content:
            if isinstance(part, TextPart):
                parts.append({"type": "text", "text": part.text})
            elif isinstance(part, ImagePart):
                if not part.url and not part.data:
                    # 未水合的引用块（只有 attachment_id）：上游水合层漏了它。
                    # fail-safe：降级为占位文本——宁可丢一张图，也不把内部
                    # 引用漏给供应商（发出去必然 4xx，还暴露内部标识）。
                    logger.warning(
                        "图片内容块未水合（attachment_id=%s），已降级为占位文本；"
                        "这是程序缺陷，请检查发请求前的水合逻辑",
                        part.attachment_id,
                    )
                    parts.append({"type": "text", "text": "[图片未能加载，已略过]"})
                    continue
                has_image = True
                url = part.url or f"data:{part.media_type};base64,{part.data}"
                parts.append({"type": "image_url", "image_url": {"url": url}})
            # ThinkingPart：思考内容不作为输入发回，静默丢弃
        if not has_image:
            return "".join(p["text"] for p in parts)
        return parts

    def _convert_message(self, message: ChatMessage) -> dict:
        out: dict[str, Any] = {"role": message.role}
        if message.role == "tool":
            # tool 结果消息：OpenAI 要求纯字符串 content + tool_call_id
            out["content"] = message.text()
            out["tool_call_id"] = message.tool_call_id
            return out
        if message.role == "assistant":
            # assistant 历史消息：正文压成纯文本；tool_calls 用 raw_arguments 保真回传
            text = message.text()
            out["content"] = text or None
            if self.preset.compat.preserve_thinking and self.preset.compat.thinking_field:
                thinking = "".join(
                    part.text for part in message.content if isinstance(part, ThinkingPart)
                ) if isinstance(message.content, list) else ""
                if thinking:
                    out[self.preset.compat.thinking_field] = thinking
            if message.tool_calls:
                out["tool_calls"] = [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.name,
                            "arguments": tc.raw_arguments or json.dumps(tc.arguments),
                        },
                    }
                    for tc in message.tool_calls
                ]
            return out
        out["content"] = self._convert_content(message)
        return out

    def _build_payload(self, request: ChatRequest, model_id: str, *, stream: bool) -> dict:
        model = self._model_info(model_id)
        if request.tools and model and model.requires_responses_for_tools:
            raise LlmRequestError(
                f"模型「{model_id}」的工具调用需要 Responses API，"
                "请在模型接入的高级设置中切换 API 协议",
                provider=self.config.name,
            )
        payload: dict[str, Any] = {
            "model": model_id,
            "messages": [self._convert_message(m) for m in request.messages],
        }
        if request.tools:
            payload["tools"] = [
                {
                    "type": "function",
                    "function": {
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.parameters,
                    },
                }
                for t in request.tools
            ]
        if request.tool_choice:
            if request.tool_choice in ("auto", "none", "required"):
                payload["tool_choice"] = request.tool_choice
            else:
                # 直接写工具名 = 强制调用该工具
                payload["tool_choice"] = {
                    "type": "function",
                    "function": {"name": request.tool_choice},
                }
        s = request.settings
        for key in (
            "temperature",
            "top_p",
            "max_tokens",
            "stop",
            "presence_penalty",
            "frequency_penalty",
            "seed",
        ):
            value = getattr(s, key)
            if value is not None:
                target = model.max_tokens_parameter if key == "max_tokens" and model else key
                payload[target] = value
        if s.response_format == "json_object":
            payload["response_format"] = {"type": "json_object"}
        # 思考档位翻译（reasoning_effort / enable_thinking+thinking_budget /
        # thinking.type）落在 extra_body 通道——openai SDK 会把它并入请求体
        # 顶层，正是各家兼容端点期望的位置。用户显式 extra_body 同名键优先
        # （逃生舱语义）。
        extra = {
            **thinking_body_fragment(s.thinking_level, model, model_id),
            **(s.extra_body or {}),
        }
        if request.tools and model and model.chat_tools_require_no_reasoning:
            if extra.get("reasoning_effort") not in (None, "none"):
                raise LlmRequestError(
                    f"模型「{model_id}」在 Chat Completions 中调用工具必须关闭推理；"
                    "如需推理，请切换 Responses API",
                    provider=self.config.name,
                )
            extra["reasoning_effort"] = "none"
        if (
            model
            and model.sampling_requires_no_reasoning
            and extra.get("reasoning_effort") != "none"
        ):
            payload.pop("temperature", None)
            payload.pop("top_p", None)
        if model and model.fixed_sampling:
            payload.pop("temperature", None)
            payload.pop("top_p", None)
        if extra:
            payload["extra_body"] = extra
        if stream:
            payload["stream"] = True
            if self.preset.compat.supports_stream_usage:
                payload["stream_options"] = {"include_usage": True}
        return payload

    # -- 响应转换 -----------------------------------------------------------

    def _read_thinking(self, obj: Any) -> str | None:
        """按 compat 声明的字段名提取思考内容（如 reasoning_content）。"""
        field = self.preset.compat.thinking_field
        if not field:
            return None
        value = getattr(obj, field, None)
        return value if isinstance(value, str) and value else None

    @staticmethod
    def _parse_usage(usage: Any) -> TokenUsage:
        if usage is None:
            return TokenUsage()
        cached = 0
        details = getattr(usage, "prompt_tokens_details", None)
        if details is not None:
            cached = getattr(details, "cached_tokens", None) or 0
        return TokenUsage(
            prompt_tokens=usage.prompt_tokens or 0,
            completion_tokens=usage.completion_tokens or 0,
            total_tokens=usage.total_tokens or 0,
            cache_read_tokens=cached,
        )

    def _parse_response(self, completion: Any, model_id: str) -> ChatResponse:
        choice = completion.choices[0]
        msg = choice.message
        tool_calls = None
        if msg.tool_calls:
            tool_calls = [
                self._parse_tool_call(tc.id, tc.function.name, tc.function.arguments or "")
                for tc in msg.tool_calls
            ]
        _warn_harmony_residue_in_content(msg.content)
        return ChatResponse(
            content=msg.content,
            thinking=self._read_thinking(msg),
            tool_calls=tool_calls,
            finish_reason=_FINISH_REASON_MAP.get(choice.finish_reason or "", "stop"),
            usage=self._parse_usage(completion.usage),
            model=getattr(completion, "model", None) or model_id,
            provider=self.config.name,
        )

    # -- 对外接口 -----------------------------------------------------------

    async def chat(self, request: ChatRequest, model_id: str) -> ChatResponse:
        payload = self._build_payload(request, model_id, stream=False)
        try:
            completion = await self._client.chat.completions.create(**payload)
        except Exception as exc:  # noqa: BLE001 - 统一翻译为 LlmError 体系
            raise self._translate_error(exc) from exc
        return self._parse_response(completion, model_id)

    async def chat_stream(
        self, request: ChatRequest, model_id: str
    ) -> AsyncIterator[ChatStreamEvent]:
        payload = self._build_payload(request, model_id, stream=True)
        acc = StreamAccumulator(model_id, self.config.name)
        try:
            stream = await self._client.chat.completions.create(**payload)
        except Exception as exc:  # noqa: BLE001
            err = self._translate_error(exc)
            yield acc.error_event(str(err))
            return

        yield ChatStreamEvent(type="start", partial=acc.snapshot())
        try:
            async for chunk in stream:
                if chunk.usage is not None:
                    acc.usage = self._parse_usage(chunk.usage)
                if not chunk.choices:
                    continue
                choice = chunk.choices[0]
                delta = choice.delta
                if delta is not None:
                    thinking = self._read_thinking(delta)
                    if thinking:
                        acc.thinking.append(thinking)
                        yield ChatStreamEvent(
                            type="thinking_delta", delta=thinking, partial=acc.snapshot()
                        )
                    if delta.content:
                        acc.content.append(delta.content)
                        yield ChatStreamEvent(
                            type="text_delta", delta=delta.content, partial=acc.snapshot()
                        )
                    for frag in delta.tool_calls or []:
                        started, event_delta = acc.feed_tool_fragment(frag)
                        if started:
                            yield ChatStreamEvent(
                                type="toolcall_start",
                                tool_call=acc.tool_snapshot(frag.index),
                                partial=acc.snapshot(),
                            )
                        if event_delta:
                            # delta 也带 tool_call 快照：并行工具调用交错流式时，
                            # 消费方（agent 事件层）靠它把增量归属到正确的调用
                            yield ChatStreamEvent(
                                type="toolcall_delta",
                                delta=event_delta,
                                tool_call=acc.tool_snapshot(frag.index),
                                partial=acc.snapshot(),
                            )
                if choice.finish_reason:
                    acc.finish_reason = _FINISH_REASON_MAP.get(choice.finish_reason, "stop")
        except Exception as exc:  # noqa: BLE001 - 流中断以 error 事件收尾，保留 partial
            err = self._translate_error(exc)
            logger.warning("流式调用中断：%s", err)
            yield acc.error_event(str(err))
            return

        # 收尾：工具参数完整了，逐个解析并发 toolcall_end
        _warn_harmony_residue_in_content("".join(acc.content))
        for index in acc.tool_order:
            tc = acc.finalize_tool(index, self._parse_tool_call)
            yield ChatStreamEvent(type="toolcall_end", tool_call=tc, partial=acc.snapshot())
        if acc.finish_reason is None:
            acc.finish_reason = "tool_calls" if acc.tool_order else "stop"
        yield ChatStreamEvent(type="done", partial=acc.snapshot())

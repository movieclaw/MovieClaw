"""订阅授权专用 Responses 通路；保留 API Key 通路的原有行为。"""

from __future__ import annotations

import asyncio
import time
from collections.abc import AsyncIterator
from typing import Protocol

import httpx

from movieclaw_llm.chatgpt import (
    RESOURCE,
    ChatGPTCredentials,
    account_model_catalog,
    refresh_credentials,
)
from movieclaw_llm.exceptions import LlmAuthError, LlmServerError
from movieclaw_llm.models import ChatRequest, ChatResponse, ChatStreamEvent, ProviderInfo
from movieclaw_llm.protocols.openai_responses import OpenAIResponsesProtocol
from movieclaw_net import egress_transport


class ChatGPTTokenStore(Protocol):
    async def load(self, provider_id: int) -> str: ...
    async def save(self, provider_id: int, previous: str, updated: str) -> None: ...
    def lock(self, provider_id: int) -> asyncio.Lock: ...


class OpenAIChatGPTProtocol(OpenAIResponsesProtocol):
    require_completed = True

    def __init__(self, config, preset) -> None:
        self._credentials = ChatGPTCredentials.parse(config.api_key)
        self.token_store: ChatGPTTokenStore | None = None
        self._refresh_lock = asyncio.Lock()
        super().__init__(
            config.model_copy(
                update={
                    "api_key": self._credentials.access_token,
                    "base_url": RESOURCE,
                }
            ),
            preset,
        )

    async def _authorize(self) -> None:
        provider_id = self.config.provider_id
        lock = self.token_store.lock(provider_id) if self.token_store else self._refresh_lock
        async with lock:
            previous = (
                await self.token_store.load(provider_id)
                if self.token_store
                else self._credentials.model_dump_json()
            )
            credentials = ChatGPTCredentials.parse(previous)
            if credentials.expires_at <= time.time() + 60:
                async with httpx.AsyncClient(
                    transport=egress_transport("llm"),
                    timeout=30,
                ) as client:
                    credentials = await refresh_credentials(client, credentials)
                if self.token_store:
                    await self.token_store.save(
                        provider_id,
                        previous,
                        credentials.model_dump_json(),
                    )
            self._credentials = credentials
            self._client.api_key = credentials.access_token

    def _build_payload(self, request, model_id, *, stream):
        payload = super()._build_payload(request, model_id, stream=True)
        # SIWC 预览的参数范围比 API Key 通路窄；不把 SDK 通用参数透传进去。
        for key in ("temperature", "top_p", "max_output_tokens", "extra_body"):
            payload.pop(key, None)
        for item in payload["input"]:
            if item.get("role") == "system":
                item["role"] = "developer"
        if payload.get("tools"):
            payload["tools"] = [
                {
                    "type": "namespace",
                    "name": "movieclaw",
                    "description": "MovieClaw media management tools",
                    "tools": payload["tools"],
                }
            ]
        if isinstance(payload.get("tool_choice"), dict):
            # A forced function choice has no namespace field in the public API.
            # Offer only that function and require a call, preserving the namespace.
            name = payload["tool_choice"]["name"]
            payload["tools"][0]["tools"] = [
                tool for tool in payload["tools"][0]["tools"] if tool["name"] == name
            ]
            if not payload["tools"][0]["tools"]:
                raise LlmServerError(f"找不到指定的工具：{name}")
            payload["tool_choice"] = "required"
        return payload

    def _convert_message(self, message, model_id):
        items = super()._convert_message(message, model_id)
        for item in items:
            if item.get("type") == "function_call":
                item["namespace"] = "movieclaw"
        return items

    async def chat_stream(
        self, request: ChatRequest, model_id: str
    ) -> AsyncIterator[ChatStreamEvent]:
        try:
            await self._authorize()
        except LlmAuthError as exc:
            yield ChatStreamEvent(
                type="error",
                partial=ChatResponse(
                    model=model_id,
                    provider=self.config.name,
                    finish_reason="error",
                    error=str(exc),
                ),
            )
            return
        async for event in super().chat_stream(request, model_id):
            yield event

    async def chat(self, request: ChatRequest, model_id: str) -> ChatResponse:
        async for event in self.chat_stream(request, model_id):
            if event.type == "error":
                raise LlmServerError(event.partial.error or "ChatGPT 请求失败")
            if event.type == "done":
                return event.partial
        raise LlmServerError("ChatGPT 响应未完成，请重试")

    async def test_connection(self) -> ProviderInfo:
        await self._authorize()
        async with httpx.AsyncClient(transport=egress_transport("llm"), timeout=30) as client:
            response = await client.get(
                RESOURCE + "/models",
                headers={
                    "Authorization": "Bearer " + self._credentials.access_token,
                },
            )
            if response.status_code != 200:
                raise LlmAuthError("无法读取 ChatGPT 账号的模型清单，请重新连接")
            data = response.json()
            catalog = account_model_catalog(data.get("models", []))
            return ProviderInfo(
                models=[m.id for m in catalog],
                model_catalog=catalog,
            )

"""订阅授权专用 Responses 通路；保留 API Key 通路的原有行为。"""

from __future__ import annotations

import asyncio
import time
from collections.abc import AsyncIterator
from typing import Protocol

import httpx

from movieclaw_llm.chatgpt import RESOURCE, ChatGPTCredentials, refresh_credentials
from movieclaw_llm.exceptions import LlmAuthError, LlmServerError
from movieclaw_llm.models import ChatRequest, ChatResponse, ChatStreamEvent, ProviderInfo
from movieclaw_llm.protocols.openai_responses import OpenAIResponsesProtocol
from movieclaw_net import egress_transport


class ChatGPTTokenStore(Protocol):
    async def load(self, name: str) -> str: ...
    async def save(self, name: str, previous: str, updated: str) -> None: ...
    def lock(self, name: str) -> asyncio.Lock: ...


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
        lock = self.token_store.lock(self.config.name) if self.token_store else self._refresh_lock
        async with lock:
            previous = (
                await self.token_store.load(self.config.name)
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
                        self.config.name,
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
            payload["tool_choice"]["namespace"] = "movieclaw"
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
            return ProviderInfo(
                models=[
                    row["slug"]
                    for row in data.get("models", [])
                    if row.get("visibility") == "list" and row.get("slug")
                ]
            )

"""OpenAI 系协议的公共底座：SDK 客户端构建、模型声明查找、工具参数解析、
错误翻译、连接测试。

openai_chat（Chat Completions）与 openai_responses（Responses API）是同一个
SDK 客户端上的两套线协议，鉴权、出口、错误体系完全一致，只有请求/响应的
形态不同——共性收在这里，各自只写线协议转换。
"""

from __future__ import annotations

import contextlib
import json
import logging
from typing import TYPE_CHECKING, Any

import httpx

from movieclaw_llm.base import BaseLlmProtocol
from movieclaw_llm.exceptions import (
    LlmAuthError,
    LlmConnectError,
    LlmContentFilterError,
    LlmError,
    LlmRateLimitError,
    LlmRequestError,
    LlmServerError,
)
from movieclaw_llm.models import (
    ChatResponse,
    ChatStreamEvent,
    FinishReason,
    LlmProviderConfig,
    ModelInfo,
    NativeOutput,
    ProviderInfo,
    ProviderPreset,
    TokenUsage,
    ToolCall,
)
from movieclaw_llm.tools import HARMONY_RESIDUE_HINT, has_harmony_residue
from movieclaw_net import egress_transport

if TYPE_CHECKING:  # 仅供类型检查，运行期不导入
    import openai as openai_sdk

logger = logging.getLogger(__name__)


def _sdk() -> openai_sdk:
    """按需导入 openai SDK。

    **刻意不在模块顶部导入**：这个包一旦被 import，就要打开 800 个文件、
    花掉小半秒——而它只在用户真的调用大模型时才用得上。本模块却在启动路径上
    （协议注册表 → LLM 路由 → Agent → API 路由），顶部导入等于让每次启动都替
    「可能整轮都不会用到的功能」付这笔冷启动磁盘 IO。家用 NAS 的机械盘上，
    几百个小文件的随机读就是实打实的秒级。

    SDK 本体由 Python 的模块缓存持有，第二次起是一次字典查找。
    """
    import openai

    return openai


def _warn_harmony_residue_in_content(content: str | None) -> None:
    """正文里泄漏 Harmony 标记（如整段思考被当正文返回）时告警，引导用户修后端。"""
    if has_harmony_residue(content):
        logger.warning("模型返回的正文含 Harmony 格式残留。%s", HARMONY_RESIDUE_HINT)


# 上游明确要求改用 Responses API 时（如 GPT-5.6 带工具调思考强度），告诉用户去哪切
_RESPONSES_REQUIRED_HINT = (
    "。该模型要求使用 Responses API：请在「设置 → AI」编辑这个供应商，"
    "到高级设置里把 API 协议切换为 Responses API"
)

# 百炼等国内端点内容审查拦截的错误码/关键词
_CONTENT_FILTER_CODES = {"data_inspection_failed", "content_filter"}


class OpenAIProtocolBase(BaseLlmProtocol):
    def __init__(self, config: LlmProviderConfig, preset: ProviderPreset) -> None:
        super().__init__(config, preset)
        kwargs: dict[str, Any] = {"api_key": config.api_key}
        base_url = config.base_url or preset.base_url
        if base_url:
            kwargs["base_url"] = base_url
        if config.timeout_seconds is not None:
            kwargs["timeout"] = config.timeout_seconds
        if config.user_agent:
            # default_headers 在 SDK 内部是最后一层合并，能盖掉 SDK 自带的
            # 「AsyncOpenAI/Python x.y.z」；留空则完全不干预，保持 SDK 默认。
            kwargs["default_headers"] = {"User-Agent": config.user_agent}
        # 统一出口：底层 httpx 客户端注入服务标签 llm 的出口 transport，
        # 用户可在「设置 → 网络」让 LLM 请求走代理（OpenAI 官方等被墙端点）。
        # 超时仍由 AsyncOpenAI 的 timeout 参数按请求控制，这里不重复设置。
        kwargs["http_client"] = httpx.AsyncClient(transport=egress_transport("llm"))
        self._client = _sdk().AsyncOpenAI(**kwargs)

    def _model_info(self, model_id: str) -> ModelInfo | None:
        """按 id 查模型声明：用户补录（extra_models）优先于预设目录。

        与 LlmRouter._catalog 同一合并口径；思考档位翻译靠它拿
        thinking_control / max_thinking_tokens。目录外模型返回 None——
        fail-closed，档位不落请求。
        """
        for model in self.config.extra_models:
            if model.id == model_id:
                return model
        for model in self.preset.models:
            if model.id == model_id:
                return model
        return None

    @staticmethod
    def _parse_tool_call(tc_id: str, name: str, raw_arguments: str) -> ToolCall:
        """尽力解析工具参数 JSON；失败不抛异常，交给上层回喂模型纠错。"""
        arguments: dict = {}
        parse_error: str | None = None
        if raw_arguments:
            try:
                parsed = json.loads(raw_arguments)
                if isinstance(parsed, dict):
                    arguments = parsed
                else:
                    parse_error = f"工具参数应为 JSON 对象，实际是 {type(parsed).__name__}"
            except json.JSONDecodeError as exc:
                parse_error = f"工具参数不是合法 JSON：{exc}"
        return ToolCall(
            id=tc_id,
            name=name,
            arguments=arguments,
            raw_arguments=raw_arguments,
            parse_error=parse_error,
        )

    def _translate_error(self, exc: Exception) -> LlmError:
        name = self.config.name
        if isinstance(exc, LlmError):
            return exc
        openai = _sdk()
        if isinstance(exc, openai.AuthenticationError | openai.PermissionDeniedError):
            return LlmAuthError(f"认证失败，请检查 API Key 是否有效：{exc}", provider=name)
        if isinstance(exc, openai.RateLimitError):
            retry_after = None
            headers = getattr(exc.response, "headers", None)
            if headers is not None:
                raw = headers.get("retry-after")
                if raw is not None:
                    with contextlib.suppress(ValueError):
                        retry_after = float(raw)
            return LlmRateLimitError(
                f"触发供应商限流，请稍后重试：{exc}", provider=name, retry_after=retry_after
            )
        if isinstance(exc, openai.APITimeoutError | openai.APIConnectionError):
            return LlmConnectError(
                f"连接模型服务失败，请检查网络与 base_url 配置：{exc}", provider=name
            )
        if isinstance(exc, openai.BadRequestError):
            code = getattr(exc, "code", None)
            if code in _CONTENT_FILTER_CODES:
                return LlmContentFilterError(f"内容被供应商合规审查拦截：{exc}", provider=name)
            hint = _RESPONSES_REQUIRED_HINT if "/v1/responses" in str(exc) else ""
            return LlmRequestError(f"请求参数错误：{exc}{hint}", provider=name)
        if isinstance(exc, openai.APIStatusError):
            if exc.status_code >= 500:
                return LlmServerError(
                    f"模型服务暂时出错（HTTP {exc.status_code}）：{exc}", provider=name
                )
            return LlmRequestError(
                f"模型服务返回错误（HTTP {exc.status_code}）：{exc}", provider=name
            )
        return LlmConnectError(f"调用模型服务时发生未知错误：{exc}", provider=name)

    async def test_connection(self) -> ProviderInfo:
        try:
            page = await self._client.models.list()
        except Exception as exc:  # noqa: BLE001
            raise self._translate_error(exc) from exc
        return ProviderInfo(models=[m.id for m in page.data])

    async def close(self) -> None:
        await self._client.close()


class StreamAccumulator:
    """流式增量的累积器：随时可产出完整的 ChatResponse 快照（partial）。"""

    def __init__(self, model_id: str, provider: str) -> None:
        self.model_id = model_id
        self.provider = provider
        self.content: list[str] = []
        self.thinking: list[str] = []
        self.usage = TokenUsage()
        self.finish_reason: FinishReason | None = None
        # index → 累积中的工具调用（id/name 首个分片给出，arguments 逐片拼接）
        self._tools: dict[int, dict] = {}
        self.tool_order: list[int] = []
        self._finalized: dict[int, ToolCall] = {}
        self.native_output: NativeOutput | None = None

    def start_tool(self, index: int, tc_id: str = "", name: str = "") -> bool:
        """登记一个工具调用槽位（首次出现时），返回是否为新调用。"""
        started = index not in self._tools
        if started:
            self._tools[index] = {"id": "", "name": "", "arguments": []}
            self.tool_order.append(index)
        slot = self._tools[index]
        if tc_id:
            slot["id"] = tc_id
        if name:
            slot["name"] = name
        return started

    def append_tool_arguments(self, index: int, delta: str) -> None:
        self._tools[index]["arguments"].append(delta)

    def replace_tool_arguments(self, index: int, arguments: str) -> None:
        """以上游给出的完整参数为准（个别端点不推参数增量，只在收尾给全量）。"""
        self._tools[index]["arguments"] = [arguments]

    def has_tool_arguments(self, index: int) -> bool:
        return bool(self._tools[index]["arguments"])

    def feed_tool_fragment(self, frag: Any) -> tuple[bool, str | None]:
        """吸收一个 Chat Completions 的 tool_call 分片，返回 (是否新调用开始, 参数增量)。"""
        fn = frag.function
        started = self.start_tool(frag.index, frag.id or "", (fn.name or "") if fn else "")
        delta = None
        if fn is not None and fn.arguments:
            self.append_tool_arguments(frag.index, fn.arguments)
            delta = fn.arguments
        return started, delta

    def tool_snapshot(self, index: int) -> ToolCall:
        slot = self._tools[index]
        return ToolCall(id=slot["id"], name=slot["name"], raw_arguments="".join(slot["arguments"]))

    def finalize_tool(self, index: int, parser: Any) -> ToolCall:
        slot = self._tools[index]
        tc = parser(slot["id"], slot["name"], "".join(slot["arguments"]))
        self._finalized[index] = tc
        return tc

    def snapshot(self, error: str | None = None) -> ChatResponse:
        tool_calls = [
            self._finalized.get(i) or self.tool_snapshot(i) for i in self.tool_order
        ] or None
        return ChatResponse(
            content="".join(self.content) or None,
            thinking="".join(self.thinking) or None,
            tool_calls=tool_calls,
            finish_reason=self.finish_reason,
            usage=self.usage,
            model=self.model_id,
            provider=self.provider,
            error=error,
            native_output=self.native_output,
        )

    def error_event(self, message: str) -> ChatStreamEvent:
        self.finish_reason = "error"
        return ChatStreamEvent(type="error", partial=self.snapshot(error=message))

"""协议实现注册：协议 id → 实现类。新增协议（如 anthropic）时在此登记。"""

from movieclaw_llm.base import BaseLlmProtocol
from movieclaw_llm.exceptions import LlmRoutingError
from movieclaw_llm.models import LlmProviderConfig, ProviderPreset
from movieclaw_llm.protocols.openai_chat import OpenAIChatProtocol
from movieclaw_llm.protocols.openai_responses import OpenAIResponsesProtocol

PROTOCOLS: dict[str, type[BaseLlmProtocol]] = {
    "openai_chat": OpenAIChatProtocol,
    "openai_responses": OpenAIResponsesProtocol,
}


def build_protocol(config: LlmProviderConfig, preset: ProviderPreset) -> BaseLlmProtocol:
    """按实例构建协议客户端：实例显式选了协议就用它，否则跟随预设默认。

    路由调用与连接测试都走这里——两处各自取协议会出现「测试通过、实际调用
    走的却是另一套协议」的分叉。
    """
    protocol_id = config.api_protocol or preset.protocol
    protocol_cls = PROTOCOLS.get(protocol_id)
    if protocol_cls is None:
        raise LlmRoutingError(f"供应商实例「{config.name}」引用了未实现的协议「{protocol_id}」")
    return protocol_cls(config, preset)


__all__ = ["PROTOCOLS", "OpenAIChatProtocol", "OpenAIResponsesProtocol", "build_protocol"]

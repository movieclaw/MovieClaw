"""网页搜索配置的读写、连通性测试，以及运行时供应商装配。

密钥明文只留在配置模型和供应商对象里。日志记供应商 id 和末四位，不记密钥本身。
"""

from __future__ import annotations

import logging

import httpx

from movieclaw_agent.tools.web_search import make_web_search_tool
from movieclaw_agent.web_search import (
    WebSearchError,
    get_provider,
    provider_catalog,
    provider_ids,
)
from movieclaw_agent.web_search.types import SearchProvider
from movieclaw_api.exceptions import BadRequestException, UpstreamUnreachableException
from movieclaw_api.settings.store import get_setting_store
from movieclaw_api.settings.web_search import WebSearchSetting
from movieclaw_net import egress_transport

logger = logging.getLogger("movieclaw_api.web_search")

_TEST_QUERY = "Inception 2010"
_HINT_MIN = 8


def mask_key(api_key: str) -> str:
    """末四位。太短的密钥不展示，避免短密钥几乎等于明文。"""
    if len(api_key) < _HINT_MIN:
        return ""
    return api_key[-4:]


def status_view(setting: WebSearchSetting) -> dict:
    return {
        "provider": setting.provider or None,
        "configured": setting.configured,
        "key_hint": mask_key(setting.api_key) if setting.configured else "",
        "providers": provider_catalog(),
    }


def search_transport(*, probe: bool) -> httpx.AsyncBaseTransport:
    """业务搜索走熔断；设置页的测试必须真的发出去，所以绕过熔断。"""
    return egress_transport("web_search", use_breaker=not probe)


def build_provider(provider_id: str, api_key: str, *, probe: bool = False) -> SearchProvider:
    cls = get_provider(provider_id)
    return cls(api_key, transport=search_transport(probe=probe))


async def get_status() -> dict:
    return status_view(await get_setting_store().get(WebSearchSetting))


async def save_web_search(*, provider: str, api_key: str | None) -> dict:
    provider_id = provider.strip().lower()
    if provider_id not in provider_ids():
        raise BadRequestException("不支持的搜索供应商")
    current = await get_setting_store().get(WebSearchSetting)
    key = (api_key or "").strip()
    if not key:
        if current.provider == provider_id and current.api_key:
            key = current.api_key
        else:
            raise BadRequestException("请填写 API Key；更换供应商时需要新的密钥")
    saved = WebSearchSetting(provider=provider_id, api_key=key)
    await get_setting_store().set(saved)
    logger.info("已保存网页搜索配置 provider=%s hint=%s", provider_id, mask_key(key) or "（过短）")
    return status_view(saved)


async def clear_web_search() -> dict:
    cleared = WebSearchSetting()
    await get_setting_store().set(cleared)
    logger.info("已清除网页搜索配置")
    return status_view(cleared)


async def load_web_search_provider() -> SearchProvider | None:
    """没配供应商或没配密钥时返回 None，调用方据此不注册工具。"""
    setting = await get_setting_store().get(WebSearchSetting)
    if not setting.configured:
        return None
    return build_provider(setting.provider, setting.api_key)


async def test_web_search(*, provider: str | None, api_key: str | None) -> dict:
    """用一把密钥做一次最小搜索。不保存。失败不覆盖已经保存的配置。"""
    current = await get_setting_store().get(WebSearchSetting)
    provider_id = (provider or current.provider or "").strip().lower()
    if not provider_id:
        raise BadRequestException("请先选择搜索供应商")
    if provider_id not in provider_ids():
        raise BadRequestException("不支持的搜索供应商")
    key = (api_key or "").strip()
    if not key:
        if current.provider == provider_id and current.api_key:
            key = current.api_key
        else:
            raise BadRequestException("请先粘贴 API Key")
    searcher = build_provider(provider_id, key, probe=True)
    try:
        hits = await searcher.search(_TEST_QUERY, max_results=1, include_content=False)
    except WebSearchError as exc:
        if exc.kind == "network":
            raise UpstreamUnreachableException(
                str(exc),
                service="web_search",
                hint="到「设置 → 网络」为「网页搜索」打开代理后再试",
            ) from None
        raise BadRequestException(str(exc)) from None
    title = hits[0].title if hits else ""
    message = "连接成功" if not title else f"连接成功，示例结果：{title}"
    logger.info("网页搜索测试通过 provider=%s", provider_id)
    return {"ok": True, "message": message, "sample_title": title or None}


def attach_web_search_tool(tools: list, provider: SearchProvider | None) -> list:
    if provider is None:
        return tools
    return [*tools, make_web_search_tool(provider)]

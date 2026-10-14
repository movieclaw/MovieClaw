"""web_search：智能体查询公开网页。

只有用户在「设置 → AI 设定」接好供应商时，装配方才会把本工具放进工具集。
没配置时工厂根本不会被调用，模型看不到这个工具。

结果是给模型读的紧凑文本，不是给前端渲染的结构。失败用 ValueError，
runner 会把说明回喂模型且不中断对话。
"""

from __future__ import annotations

import asyncio
import logging
import time

from movieclaw_agent.toolkit import AgentTool
from movieclaw_agent.web_search import SearchProvider, WebSearchError
from movieclaw_agent.web_search.http import redact
from movieclaw_llm import ToolDefinition

logger = logging.getLogger("movieclaw_agent.web_search")

TOOL_NAME = "web_search"
_DEFAULT_RESULTS = 5
_MAX_RESULTS = 8
_MAX_QUERY = 400
#: 全进程至少间隔这么久再发出下一次搜索，避免一次对话打满供应商配额。
MIN_INTERVAL_SECONDS = 1.0

_DESCRIPTION = "搜索网络以获取最新信息。返回可选的摘要回答和来源 URL 列表。"

_lock = asyncio.Lock()
_last_call = 0.0


async def _pace() -> None:
    global _last_call
    async with _lock:
        wait = MIN_INTERVAL_SECONDS - (time.monotonic() - _last_call)
        if wait > 0:
            await asyncio.sleep(wait)
        _last_call = time.monotonic()


def format_hits(
    query: str,
    hits: list,
    *,
    include_content: bool,
    supports_content: bool,
) -> str:
    if not hits:
        text = f"没有找到与「{query}」相关的网页。可以换更具体的关键词再搜一次。"
    else:
        lines = [
            f"互联网搜索「{query}」（{len(hits)} 条）。摘要来自网页，引用时请带上标题和链接。"
        ]
        for index, hit in enumerate(hits, 1):
            lines.append(f"{index}. {hit.title or '（无标题）'}")
            lines.append(f"   {hit.url}")
            if hit.date:
                lines.append(f"   日期：{hit.date}")
            if hit.snippet:
                lines.append(f"   {hit.snippet}")
            if hit.content:
                lines.append(f"   正文摘录：{hit.content}")
        text = "\n".join(lines)
    if include_content and not supports_content:
        text += "\n（这次只有摘要，没有网页正文。）"
    return text


def make_web_search_tool(provider: SearchProvider) -> AgentTool:
    async def handler(args: dict) -> str:
        query = str(args.get("query") or "").strip()
        if not query:
            raise ValueError("query 不能为空。请写出要查的内容，必要时带上关键词或搜索运算符。")
        if len(query) > _MAX_QUERY:
            raise ValueError(f"query 过长（最多 {_MAX_QUERY} 字）。请收成一个明确问题再搜。")
        max_results = _clamp_results(args.get("max_results"))
        include_content = bool(args.get("include_content"))
        await _pace()
        started = time.monotonic()
        try:
            hits = await provider.search(
                query, max_results=max_results, include_content=include_content
            )
        except WebSearchError as exc:
            message = redact(str(exc), provider.api_key)
            logger.warning("web_search provider=%s failed: %s", provider.id, message)
            raise ValueError(message) from None
        hits = hits[:max_results]
        logger.info(
            "web_search provider=%s results=%d elapsed_ms=%d query=%s",
            provider.id,
            len(hits),
            int((time.monotonic() - started) * 1000),
            redact(query[:80], provider.api_key),
        )
        return format_hits(
            query,
            hits,
            include_content=include_content,
            supports_content=provider.supports_content,
        )

    return AgentTool(
        definition=ToolDefinition(
            name=TOOL_NAME,
            description=_DESCRIPTION,
            parameters={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": (
                            "要查找的内容。可以包含 site:example.com、filetype:pdf、"
                            "intitle:词、-排除词，或引号中的精确短语"
                        ),
                    },
                    "max_results": {
                        "type": "number",
                        "description": (
                            f"最多返回多少条。默认 {_DEFAULT_RESULTS}，范围 1 到 {_MAX_RESULTS}"
                        ),
                    },
                    "include_content": {
                        "type": "boolean",
                        "description": "是否附上正文摘录。默认否；摘要不够时再打开",
                    },
                },
                "required": ["query"],
            },
        ),
        handler=handler,
    )


def _clamp_results(value: object) -> int:
    if value is None:
        return _DEFAULT_RESULTS
    try:
        count = int(value)
    except (TypeError, ValueError):
        return _DEFAULT_RESULTS
    return min(max(count, 1), _MAX_RESULTS)

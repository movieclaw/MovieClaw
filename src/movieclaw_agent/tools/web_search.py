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

_DESCRIPTION = (
    "在公开互联网上搜索电影和剧集的事实。用来查上映或播出日期、演职员、奖项、"
    "影评口碑、官方新闻和片单，以及 TMDB、豆瓣或本地媒体库里没有、或不新鲜的信息。\n"
    "不要用它查用户自己的媒体库、订阅、下载任务或本机配置（用 mclaw），"
    "也不要拿它代替 discover / search 浏览已经在库里的片子，"
    "更不要下载文件或访问需要登录的页面。\n"
    "一次只查一个问题。query 写作品原名或常用译名，并带上要查的事实，"
    '例如「沙丘2 上映日期 主演」或 "Dune Part Two cast reviews"。'
    "默认最多 5 条，只含标题、链接和短摘要；摘要不够再把 include_content 设为 true"
    "（Brave 没有正文，仍只有摘要）。引用时带上标题和链接，并说明这是网页上的信息。"
)

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
    provider_id: str,
    hits: list,
    *,
    include_content: bool,
    supports_content: bool,
) -> str:
    if not hits:
        text = f"没有找到与「{query}」相关的公开网页。可以换更具体的原名、年份或英文名再搜一次。"
    else:
        lines = [
            f"互联网搜索「{query}」（{provider_id}，{len(hits)} 条）。"
            "摘要来自网页，引用时请带上标题和链接。"
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
        text += "\n（当前供应商只提供摘要，没有网页正文。）"
    return text


def make_web_search_tool(provider: SearchProvider) -> AgentTool:
    async def handler(args: dict) -> str:
        query = str(args.get("query") or "").strip()
        if not query:
            raise ValueError(
                "query 不能为空。请写出要查的作品名和具体事实，例如「沙丘2 上映日期」。"
            )
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
            provider.id,
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
                        "description": "一个明确问题。用作品原名或常用译名，加上要查的事实",
                    },
                    "max_results": {
                        "type": "number",
                        "description": f"返回条数，1 到 {_MAX_RESULTS}，默认 {_DEFAULT_RESULTS}",
                    },
                    "include_content": {
                        "type": "boolean",
                        "description": "是否附上网页正文摘录。默认否；摘要不够回答时再打开",
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

"""搜索请求的超时、一次重试，以及给模型看的失败说明。

密钥只出现在请求头里。失败文案是固定中文或经过打码的上游短句，
不把异常原样抛出去——httpx 的异常文本有时会带上 URL。
"""

from __future__ import annotations

import asyncio
from typing import Any

import httpx

from movieclaw_net.breaker import CircuitOpenError

TIMEOUT = httpx.Timeout(12.0, connect=5.0)
#: 超时、连接失败、429、5xx 只再试一次（熔断打开时不试）。测试里把它改成 0，避免用例空等。
RETRY_DELAY_SECONDS = 0.5
_RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})

_AUTH = (
    "搜索 API Key 无效或没有权限。请到「设置 → AI 设定 → 搜索能力接入」核对密钥，"
    "不要用同一把 Key 反复重试。"
)
_RATE = "搜索服务触发了速率或配额限制。请稍后再试，不要立刻用相同条件重搜。"
_TIMEOUT = (
    "搜索服务超时（12 秒内没有响应）。请稍后再试；若服务器在国内，"
    "请到「设置 → 网络」为「网页搜索」打开代理。"
)
_CONNECT = (
    "无法连接搜索服务。请检查网络；若服务器在国内，"
    "请到「设置 → 网络」为「网页搜索」打开代理后再试。"
)
_BREAKER = (
    "搜索服务近期连续连不上，已暂停请求一小会儿，稍后会自动恢复。"
    "若一直如此，请到「设置 → 网络」对「网页搜索」做连通性测试。"
)


class WebSearchError(Exception):
    """给模型和设置页看的失败。``kind`` 供设置页区分「线路不通」和「Key 不对」。"""

    def __init__(self, message: str, *, kind: str = "upstream") -> None:
        super().__init__(message)
        self.kind = kind


def redact(text: str, secret: str) -> str:
    """从一段文本里去掉密钥。空密钥不动，避免把所有空串都替换掉。"""
    if not secret or not text or secret not in text:
        return text
    return text.replace(secret, "***")


def clip_text(text: str, limit: int) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 1].rstrip() + "…"


def normalize_date(value: object) -> str | None:
    """收成 ``YYYY-MM-DD``；认不出日期格式时保留短原文，没有则 None。"""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if len(text) >= 10 and text[4] == "-" and text[7] == "-":
        return text[:10]
    return text[:40]


def _detail(response: httpx.Response, secret: str) -> str:
    try:
        payload = response.json()
    except ValueError:
        return redact(" ".join(response.text.split())[:180], secret)
    if not isinstance(payload, dict):
        return ""
    for key in ("error", "message", "detail"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return redact(" ".join(value.split())[:180], secret)
        if isinstance(value, dict):
            inner = value.get("error") or value.get("message")
            if isinstance(inner, str) and inner.strip():
                return redact(" ".join(inner.split())[:180], secret)
    return ""


def _status_error(response: httpx.Response, secret: str) -> WebSearchError:
    if response.status_code in (401, 403):
        return WebSearchError(_AUTH, kind="auth")
    if response.status_code == 429:
        return WebSearchError(_RATE, kind="rate")
    detail = _detail(response, secret)
    message = f"搜索服务返回 HTTP {response.status_code}。"
    if detail:
        message = f"{message}{detail}"
    return WebSearchError(message)


async def request_json(
    client: httpx.AsyncClient,
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    secret: str,
    json: dict[str, Any] | None = None,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """发一次搜索请求。超时、连接失败和 429/5xx 间隔 ``RETRY_DELAY_SECONDS`` 再试一次。"""
    last_network: WebSearchError | None = None
    for attempt in range(2):
        try:
            response = await client.request(method, url, headers=headers, json=json, params=params)
        except CircuitOpenError:
            # 熔断期间再试也是立刻失败，直接说明是暂停中
            raise WebSearchError(_BREAKER, kind="network") from None
        except httpx.TimeoutException:
            last_network = WebSearchError(_TIMEOUT, kind="network")
        except httpx.HTTPError:
            last_network = WebSearchError(_CONNECT, kind="network")
        else:
            if response.status_code in _RETRY_STATUSES and attempt == 0:
                await asyncio.sleep(RETRY_DELAY_SECONDS)
                continue
            if response.status_code >= 400:
                raise _status_error(response, secret)
            try:
                data = response.json()
            except ValueError:
                raise WebSearchError("搜索服务返回了无法解析的内容。") from None
            if not isinstance(data, dict):
                raise WebSearchError("搜索服务返回了无法解析的内容。")
            return data
        if attempt == 0:
            await asyncio.sleep(RETRY_DELAY_SECONDS)
            continue
    assert last_network is not None
    raise last_network

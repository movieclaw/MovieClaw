"""云端协议客户端（docs/design/cloud-protocol.md）：只管发请求、解析响应。

连接的状态机、续签的节奏、失败的处理都在 ``services/cloud/service.py``。

出口走出网代理的 ``movieclaw_cloud`` 标签；不用熔断器——续签自己有退避，配对轮询
本来就按间隔来，熔断只会让「连不上」的判断变得不可预测。

``device_code``、``instance_secret``、``access_token`` 都不写日志。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import httpx

from movieclaw_api import __version__
from movieclaw_api.services.push.relay import describe_network_error
from movieclaw_api.settings.cloud import CloudDiscovery
from movieclaw_db.models import utcnow
from movieclaw_net.egress import egress_transport

logger = logging.getLogger("movieclaw_api.cloud.client")

EGRESS_SERVICE = "movieclaw_cloud"
DEVICE_CODE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"
_TIMEOUT = httpx.Timeout(15.0, connect=8.0)


class CloudUnreachable(Exception):
    """云端连不上，或者返回了 5xx / 看不懂的响应：可以稍后重试。"""


@dataclass
class CloudReply:
    """一次请求的结果：HTTP 状态码 + 解析后的 JSON（解析不了为空字典）。"""

    status: int
    body: dict[str, Any]

    @property
    def code(self) -> str:
        """MovieClaw 结构的 ``code``，或 RFC 6749 结构的 ``error``。"""
        return str(self.body.get("code") or self.body.get("error") or "")

    @property
    def message(self) -> str:
        return str(self.body.get("message") or self.body.get("error_description") or "").strip()


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=egress_transport(EGRESS_SERVICE, use_breaker=False),
        timeout=_TIMEOUT,
        headers={"User-Agent": f"MovieClaw/{__version__}", "Accept": "application/json"},
        follow_redirects=False,
        # 是否走代理只由「设置 → 网络」的 movieclaw_cloud 标签决定，不隐式吃环境变量
        trust_env=False,
    )


async def _request(method: str, url: str, **kwargs: Any) -> CloudReply:
    try:
        async with _client() as client:
            response = await client.request(method, url, **kwargs)
    except httpx.HTTPError as exc:
        raise CloudUnreachable(f"MovieClaw Cloud{describe_network_error(exc)}") from exc
    if response.status_code >= 500:
        raise CloudUnreachable(f"MovieClaw Cloud 暂时不可用（HTTP {response.status_code}）")
    try:
        body = response.json()
    except ValueError:
        body = {}
    return CloudReply(response.status_code, body if isinstance(body, dict) else {})


def _strip(url: str) -> str:
    return url.strip().rstrip("/")


async def fetch_discovery(cloud_url: str) -> CloudDiscovery:
    """拉发现文档。格式不对也按连不上处理（调用方会退回缓存）。"""
    reply = await _request("GET", f"{_strip(cloud_url)}/.well-known/movieclaw-cloud")
    if reply.status != 200 or not reply.body.get("api"):
        raise CloudUnreachable(f"MovieClaw Cloud 的发现文档不可用（HTTP {reply.status}）")
    endpoints = [
        e for e in reply.body.get("push_endpoints") or [] if isinstance(e, dict) and e.get("url")
    ]
    endpoints.sort(key=lambda e: e.get("priority") if isinstance(e.get("priority"), int) else 99)
    return CloudDiscovery(
        api=_strip(str(reply.body["api"])),
        push_endpoints=[_strip(str(e["url"])) for e in endpoints],
        min_instance_version=str(reply.body.get("min_instance_version") or ""),
        fetched_at=utcnow(),
    )


async def request_device_code(api: str, *, instance_name: str) -> CloudReply:
    """申请配对码（RFC 8628 §3.1）。"""
    return await _request(
        "POST",
        f"{_strip(api)}/v1/instance/device-code",
        data={"instance_name": instance_name, "instance_version": __version__, "scope": "push"},
    )


async def poll_token(api: str, *, device_code: str) -> CloudReply:
    """轮询认领结果（RFC 8628 §3.4）。"""
    return await _request(
        "POST",
        f"{_strip(api)}/v1/instance/token",
        data={"grant_type": DEVICE_CODE_GRANT, "device_code": device_code},
    )


async def renew(api: str, *, instance_secret: str, report: dict) -> CloudReply:
    """续签并上报。"""
    return await _request(
        "POST",
        f"{_strip(api)}/v1/instance/renew",
        json={"report": report},
        headers={"Authorization": f"Bearer {instance_secret}"},
    )


async def unbind(api: str, *, instance_secret: str) -> CloudReply:
    """在实例这边解绑。"""
    return await _request(
        "POST",
        f"{_strip(api)}/v1/instance/unbind",
        headers={"Authorization": f"Bearer {instance_secret}"},
    )

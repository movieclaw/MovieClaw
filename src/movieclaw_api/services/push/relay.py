"""推送中继协议客户端（MovieClaw-Push 的 docs/protocol.md）。

只做两件事：``GET /v1/info`` 读中继能力，``POST /v1/push`` 批量推送。选哪个中继、
失败了换谁、结果怎么处理，都在 ``services/push/dispatcher.py``。

出口：官方中继和公网上的自建中继走出网代理的 ``movieclaw_push`` 标签；局域网里的
自建中继总是直连（代理多半到不了内网地址）。不用熔断器——每个中继各自的失败由
分发器按通道记录、切换，一个通道连不上不该把别的通道一起熔断。
"""

from __future__ import annotations

import ipaddress
import logging
from dataclasses import dataclass, field
from urllib.parse import urlsplit

import httpx

from movieclaw_api import __version__
from movieclaw_api.i18n.stored import reference, stored_fields
from movieclaw_api.settings.cloud import RelayInfo
from movieclaw_db.models import utcnow
from movieclaw_net.egress import EgressScope, egress_transport

logger = logging.getLogger("movieclaw_api.push.relay")

EGRESS_SERVICE = "movieclaw_push"
_TIMEOUT = httpx.Timeout(15.0, connect=8.0)
#: 推送要等中继把整批交给苹果才答复（中继等苹果最多 30 秒）：等得比它短，苹果一慢
#: 实例就先超时，换地址重发，已经送达的通知再响一遍、额度也扣两次
_PUSH_TIMEOUT = httpx.Timeout(60.0, connect=8.0)
_LAN_SUFFIXES = (".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain")


class RelayError(Exception):
    """中继这次请求整体失败。``retryable`` 为真时换下一个地址 / 通道或稍后重试。

    ``network`` 为真表示根本没连上（没收到任何 HTTP 答复）。
    """

    def __init__(
        self,
        message: str = "",
        *,
        retryable: bool,
        code: str = "",
        network: bool = False,
        message_key: str | None = None,
        params: dict | None = None,
    ) -> None:
        self.message_key = message_key
        self.params = params or {}
        self.message_ref = reference(message_key, **self.params) if message_key else None
        if message_key:
            message = stored_fields(message_key, **self.params)["message"]
        super().__init__(message)
        self.message = message
        self.retryable = retryable
        self.code = code
        self.network = network


class RelayValidationError(ValueError):
    def __init__(self, message_key: str) -> None:
        self.message_key = message_key
        self.params = {}
        self.message_ref = reference(message_key)
        super().__init__(stored_fields(message_key)["message"])


@dataclass
class PushResponse:
    """``POST /v1/push`` 的结果：和请求的消息一一对应。"""

    results: list[dict] = field(default_factory=list)
    quota: dict | None = None


def normalize_url(url: str) -> str:
    """去掉首尾空白和末尾的 ``/``；只接受 http / https。"""
    value = url.strip().rstrip("/")
    parts = urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise RelayValidationError("push.relay.scheme")
    if parts.query or parts.fragment:
        raise RelayValidationError("push.relay.query")
    return value


def is_lan_url(url: str) -> bool:
    """地址是不是在局域网里：私有 / 本机地址、单段主机名、.local 这类内网域名。"""
    host = (urlsplit(url).hostname or "").lower()
    if not host:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return host == "localhost" or "." not in host or host.endswith(_LAN_SUFFIXES)
    return address.is_private or address.is_loopback or address.is_link_local


def _scope(url: str, *, lan_direct: bool) -> EgressScope:
    return EgressScope.LAN if lan_direct and is_lan_url(url) else EgressScope.WAN


def _client(url: str, *, lan_direct: bool, timeout: httpx.Timeout = _TIMEOUT) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=egress_transport(
            EGRESS_SERVICE, scope=_scope(url, lan_direct=lan_direct), use_breaker=False
        ),
        timeout=timeout,
        headers={"User-Agent": f"MovieClaw/{__version__}"},
        follow_redirects=False,
        # 是否走代理只由「设置 → 网络」的 movieclaw_push 标签决定，不隐式吃环境变量
        trust_env=False,
    )


def network_error_ref(exc: httpx.HTTPError) -> dict:
    """Keep the network category available to each reader without translating exceptions."""
    if isinstance(exc, httpx.TimeoutException):
        return reference("cloud.network.timeout")
    if isinstance(exc, httpx.ConnectError):
        return reference("cloud.network.connect")
    if isinstance(exc, httpx.ProxyError):
        return reference("cloud.network.proxy")
    return reference("cloud.network.unknown")


def _error_message(response: httpx.Response) -> str:
    try:
        body = response.json()
    except ValueError:
        return f"HTTP {response.status_code}"
    if isinstance(body, dict) and body.get("message"):
        return str(body["message"])
    return f"HTTP {response.status_code}"


def parse_info(body: object) -> RelayInfo:
    """把 ``/v1/info`` 的响应收成快照；结构不对抛 ValueError。"""
    if not isinstance(body, dict) or not isinstance(body.get("protocol"), int):
        raise RelayValidationError("push.relay.invalidInfo")
    auth = body.get("auth") if isinstance(body.get("auth"), dict) else {}
    types = body.get("types") if isinstance(body.get("types"), dict) else {}
    limits = body.get("limits") if isinstance(body.get("limits"), dict) else {}
    return RelayInfo(
        protocol=body["protocol"],
        software=str(body.get("software") or ""),
        aud=str(body.get("aud") or ""),
        topics=[str(t) for t in body.get("topics") or [] if isinstance(t, str)],
        environments=[str(e) for e in body.get("environments") or [] if isinstance(e, str)],
        types=sorted(str(t) for t in types),
        auth_mode=str(auth.get("mode") or ""),
        max_batch=int(body.get("max_batch") or 100),
        limits={k: int(v) for k, v in limits.items() if isinstance(v, int)},
        fetched_at=utcnow(),
    )


async def fetch_info(url: str, *, lan_direct: bool = True) -> RelayInfo:
    """读中继的能力声明。连不上、不是中继都抛 ``RelayError``。"""
    info, _ = await check_info(url, bearer=None, lan_direct=lan_direct)
    return info


async def check_info(
    url: str, *, bearer: str | None, lan_direct: bool = True
) -> tuple[RelayInfo, dict | None]:
    """带上凭证读 ``/v1/info``（协议 §4.1）：除了能力声明，凭证有效时还有剩余额度。

    官方中继把带有效凭证的请求记作这台服务器的一次连接，续签前的例行检查用它。
    凭证无效不会让请求失败，只是没有 ``quota``。
    """
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    try:
        async with _client(url, lan_direct=lan_direct) as client:
            response = await client.get(f"{url}/v1/info", headers=headers)
    except httpx.HTTPError as exc:
        raise RelayError(
            message_key="push.relay.network",
            params={"reason": network_error_ref(exc)},
            retryable=True,
            network=True,
        ) from exc
    if response.status_code != 200:
        raise RelayError(
            message_key="push.relay.response",
            params={"reason": _error_message(response)},
            retryable=response.status_code >= 500,
        )
    try:
        body = response.json()
        info = parse_info(body)
    except ValueError as exc:
        raise RelayError(
            str(exc), retryable=False, message_key=getattr(exc, "message_key", None)
        ) from exc
    quota = body.get("quota") if isinstance(body.get("quota"), dict) else None
    return info, quota


async def push(
    url: str, messages: list[dict], *, bearer: str | None, lan_direct: bool = True
) -> PushResponse:
    """批量推送（一次最多 100 条）。整批失败抛 ``RelayError``，单条结果在返回值里。"""
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    try:
        async with _client(url, lan_direct=lan_direct, timeout=_PUSH_TIMEOUT) as client:
            response = await client.post(
                f"{url}/v1/push", json={"messages": messages}, headers=headers
            )
    except httpx.HTTPError as exc:
        raise RelayError(
            message_key="push.relay.network",
            params={"reason": network_error_ref(exc)},
            retryable=True,
            network=True,
        ) from exc
    status = response.status_code
    if status == 200:
        try:
            body = response.json()
        except ValueError as exc:
            raise RelayError(message_key="push.relay.notJson", retryable=True) from exc
        results = body.get("results") if isinstance(body, dict) else None
        if not isinstance(results, list) or len(results) != len(messages):
            raise RelayError(message_key="push.relay.mismatch", retryable=True)
        quota = body.get("quota") if isinstance(body.get("quota"), dict) else None
        return PushResponse(
            results=[r if isinstance(r, dict) else {} for r in results], quota=quota
        )
    message = _error_message(response)
    if status == 401:
        raise RelayError(
            message_key="push.relay.unauthorized",
            params={"reason": message},
            retryable=True,
            code="unauthorized",
        )
    if status == 403:
        raise RelayError(
            message_key="push.relay.forbidden",
            params={"reason": message},
            retryable=True,
            code="forbidden",
        )
    if status >= 500 or status == 429:
        raise RelayError(
            message_key="push.relay.unavailable", params={"reason": message}, retryable=True
        )
    raise RelayError(message_key="push.relay.rejected", params={"reason": message}, retryable=False)

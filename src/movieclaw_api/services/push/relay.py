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
        self, message: str, *, retryable: bool, code: str = "", network: bool = False
    ) -> None:
        super().__init__(message)
        self.message = message
        self.retryable = retryable
        self.code = code
        self.network = network


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
        raise ValueError("中继地址要以 http:// 或 https:// 开头")
    if parts.query or parts.fragment:
        raise ValueError("中继地址不能带 ? 或 # 后面的部分")
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


def describe_network_error(exc: httpx.HTTPError) -> str:
    """把网络异常说成人话（给设置页看，不露异常类名）。"""
    if isinstance(exc, httpx.TimeoutException):
        return "连接超时"
    if isinstance(exc, httpx.ConnectError):
        return "连不上，检查地址、端口和网络"
    if isinstance(exc, httpx.ProxyError):
        return "代理连不上，检查「设置 → 网络」里的代理"
    return "网络出错"


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
        raise ValueError("不是 MovieClaw 推送中继（/v1/info 的格式不对）")
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
            f"中继{describe_network_error(exc)}", retryable=True, network=True
        ) from exc
    if response.status_code != 200:
        raise RelayError(
            f"中继返回 {_error_message(response)}",
            retryable=response.status_code >= 500,
        )
    try:
        body = response.json()
        info = parse_info(body)
    except ValueError as exc:
        raise RelayError(str(exc), retryable=False) from exc
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
            f"中继{describe_network_error(exc)}", retryable=True, network=True
        ) from exc
    status = response.status_code
    if status == 200:
        try:
            body = response.json()
        except ValueError as exc:
            raise RelayError("中继的响应不是 JSON", retryable=True) from exc
        results = body.get("results") if isinstance(body, dict) else None
        if not isinstance(results, list) or len(results) != len(messages):
            raise RelayError("中继的响应和请求对不上", retryable=True)
        quota = body.get("quota") if isinstance(body.get("quota"), dict) else None
        return PushResponse(
            results=[r if isinstance(r, dict) else {} for r in results], quota=quota
        )
    message = _error_message(response)
    if status == 401:
        raise RelayError(f"中继拒绝了凭证：{message}", retryable=True, code="unauthorized")
    if status == 403:
        raise RelayError(f"中继拒绝推送：{message}", retryable=True, code="forbidden")
    if status >= 500 or status == 429:
        raise RelayError(f"中继暂时不可用：{message}", retryable=True)
    raise RelayError(f"中继拒绝了请求：{message}", retryable=False)

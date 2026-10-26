"""局域网自动发现（UDP 7359，协议见 docs/design/lan-discovery.md）。

同一个端口应答两种询问：

- ``who is MovieClawServer?``——MovieClaw 自家协议，各端 App 用。应答带实例号、
  服务器版本和**一组**候选地址；不受「Jellyfin 兼容」开关影响。
- ``who is JellyfinServer?``——Jellyfin 兼容（设计文档 jellyfin-compat.md 3.1），
  给 Infuse 等 Jellyfin 客户端用，只应答一个地址；兼容开关关掉时不应答（否则
  它们发现了也连不上）。

两种询问都大小写不敏感、按包含关系匹配，单播回源。候选地址按可信度排序：

1. ``published_server_url`` 显式配置（高级项，无界面入口）；
2. UDP connect() 探测出的出口 IP——不在 Docker 内部网段时（host 网络/裸机）；
3. 最近有人用局域网 IP 访问本服务时浏览器地址栏里的那个地址（见下）；
4. 「设置 → 网络 → 外部访问地址」（``app.server.external_url``，可能是公网域名）；
5. 以上都没有：Jellyfin 应答仍回探测出的容器内网 IP 并写告警（宁可给个可能错的
   地址让用户看到问题，也不无声失败；与 Jellyfin 的"取不到就沉默"不同，属有意
   偏离）。自家应答不带它：App 会用应答报文的来源 IP 自己拼。

第 3 项解决 Docker 桥接部署：容器里拿不到宿主的局域网 IP，更不知道宿主把 3000
映射成了哪个端口，但用户在浏览器里打开过 ``http://192.168.1.10:3300``，请求头
Host 里就是这一串。中间件对每个请求看一眼 Host（只认私有网段 IPv4 字面量），
记下最近用过的几个，变了才落库。
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import socket

from pydantic import Field

from movieclaw_api import __version__
from movieclaw_api.settings import AppServerSetting, get_setting_store
from movieclaw_api.settings.base import SettingSchema, register_setting
from movieclaw_api.settings.schemas import get_jellyfin_compat

logger = logging.getLogger("movieclaw_api.lan_discovery")

DISCOVERY_PORT = 7359
_MOVIECLAW_QUERY = "who is movieclawserver?"
_JELLYFIN_QUERY = "who is jellyfinserver?"
#: 自家应答的类型标记与协议版本：客户端靠 type 区分自家应答与 Jellyfin 应答
PROTOCOL_TYPE = "movieclaw.discovery"
PROTOCOL_VERSION = 1
#: 记住的局域网访问地址个数（多网段、换过端口时都能留一份）
_MAX_ORIGINS = 4

_DOCKER_BRIDGE = ipaddress.ip_network("172.16.0.0/12")
_RFC1918 = (
    ipaddress.ip_network("10.0.0.0/8"),
    _DOCKER_BRIDGE,
    ipaddress.ip_network("192.168.0.0/16"),
)

_protocol_transport: asyncio.DatagramTransport | None = None


# ---------------------------------------------------------------------------
# 局域网访问地址：从 HTTP 请求的 Host 学
# ---------------------------------------------------------------------------


@register_setting(namespace="discovery.lan_origins", title="局域网访问地址（自动发现用）")
class LanOriginsSetting(SettingSchema):
    """最近有人用局域网 IP 访问本服务时的地址，新的在前。运行时状态，不是用户配置。"""

    origins: list[str] = Field(default_factory=list, description="如 http://192.168.1.10:3300")


def origin_from_host(
    host: str, forwarded_host: str | None, forwarded_proto: str | None
) -> str | None:
    """请求头 → 局域网访问地址；Host 不是私有网段 IPv4 字面量（域名、回环、公网）返回 None。

    协议：容器里的 nginx 只有 http；外层若还有一层反代且没改 Host（X-Forwarded-Host
    与 Host 相同），才沿用它给的 X-Forwarded-Proto。
    """
    name, _, port_text = host.strip().partition(":")
    try:
        ip = ipaddress.ip_address(name)
    except ValueError:
        return None
    if ip.version != 4 or not any(ip in net for net in _RFC1918):
        return None
    port: int | None = None
    if port_text:
        if not port_text.isdigit() or not 0 < int(port_text) < 65536:
            return None
        port = int(port_text)
    scheme = "http"
    if forwarded_proto == "https" and (forwarded_host is None or forwarded_host == host):
        scheme = "https"
    if port is None or port == (443 if scheme == "https" else 80):
        return f"{scheme}://{ip}"
    return f"{scheme}://{ip}:{port}"


class _LanOrigins:
    def __init__(self) -> None:
        self._origins: list[str] = []
        self._loaded = False
        self._last_host: bytes | None = None
        self._tasks: set[asyncio.Task] = set()

    def observe(
        self, host: bytes, forwarded_host: bytes | None, forwarded_proto: bytes | None
    ) -> None:
        """中间件对每个请求调一次：同一个 Host 连续出现时什么都不做。"""
        if host == self._last_host:
            return
        self._last_host = host
        origin = origin_from_host(
            host.decode("latin-1"),
            forwarded_host.decode("latin-1") if forwarded_host is not None else None,
            forwarded_proto.decode("latin-1") if forwarded_proto is not None else None,
        )
        if origin is None or self._origins[:1] == [origin]:
            return
        known = origin in self._origins
        self._origins = [origin, *(o for o in self._origins if o != origin)][:_MAX_ORIGINS]
        # 只是调整先后不落库：两个地址来回切换时不写库
        if not known:
            self._spawn(self._sync())

    async def get(self) -> list[str]:
        if not self._loaded:
            await self._sync()
        return list(self._origins)

    async def _sync(self) -> None:
        """与库里的合并（内存里的新在前），有变化才写。"""
        try:
            store = get_setting_store()
            stored = await store.get(LanOriginsSetting)
            merged = list(dict.fromkeys([*self._origins, *stored.origins]))[:_MAX_ORIGINS]
            self._origins = merged
            self._loaded = True
            if merged != stored.origins:
                await store.set(LanOriginsSetting(origins=merged))
        except Exception:
            logger.debug("局域网访问地址读写失败", exc_info=True)

    def _spawn(self, coro) -> None:
        try:
            task = asyncio.get_running_loop().create_task(coro)
        except RuntimeError:
            coro.close()
            return
        # 事件循环只持任务弱引用，不自持会被 GC 掉
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)


lan_origins = _LanOrigins()


# ---------------------------------------------------------------------------
# 应答地址
# ---------------------------------------------------------------------------


def _probe_outbound_ip(client_ip: str) -> str | None:
    """UDP connect（不发包）读内核路由面向该客户端的出口地址。"""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect((client_ip, 9))
            return s.getsockname()[0]
    except OSError:
        return None


def _looks_like_docker_bridge(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return addr in _DOCKER_BRIDGE


async def _candidate_addresses(
    client_ip: str, http_port: int, published_server_url: str
) -> tuple[list[str], str | None]:
    """按模块文档的顺序列出候选地址（去重），外加探测出的容器内网地址（不是 Docker 桥接时为 None）。

    探测失败（路由不到发询问的一方）时返回空列表：应答也发不回去。
    """
    addresses: list[str] = []

    def add(raw: str) -> None:
        value = raw.strip().rstrip("/")
        if value and value not in addresses:
            addresses.append(value)

    if published_server_url:
        add(published_server_url)
    ip = _probe_outbound_ip(client_ip)
    if ip is None:
        logger.warning("自动发现：无法确定面向 %s 的本机地址，跳过应答", client_ip)
        return addresses, None
    bridge = _looks_like_docker_bridge(ip)
    if not bridge:
        add(f"http://{ip}:{http_port}")
    for origin in await lan_origins.get():
        add(origin)
    add((await get_setting_store().get(AppServerSetting)).external_url)
    return addresses, (f"http://{ip}:{http_port}" if bridge else None)


def _warn_bridge_only(ip_address: str) -> None:
    logger.warning(
        "自动发现探测到的地址 %s 疑似 Docker 内部网段，播放器可能无法连接。"
        "请在浏览器里用局域网地址打开一次 MovieClaw（会自动记住），"
        "或在「设置 → 网络 → 外部访问地址」填写局域网内可访问的地址"
        "（如 http://192.168.1.10:3000），或改用 host 网络模式部署",
        ip_address,
    )


async def _resolve_address(client_ip: str, http_port: int, published_server_url: str) -> str | None:
    """Jellyfin 应答用的单个地址；None = 无法确定，跳过应答。"""
    addresses, bridge_address = await _candidate_addresses(
        client_ip, http_port, published_server_url
    )
    if addresses:
        return addresses[0]
    if bridge_address is not None:
        _warn_bridge_only(bridge_address)
    return bridge_address


async def movieclaw_reply(client_ip: str, http_port: int) -> dict | None:
    """自家协议的应答；None = 路由不到发询问的一方，跳过应答。"""
    setting = await get_jellyfin_compat()
    addresses, bridge_address = await _candidate_addresses(
        client_ip, http_port, setting.published_server_url
    )
    if not addresses and bridge_address is None:
        return None
    if not addresses:
        _warn_bridge_only(bridge_address or "")
    return {
        "type": PROTOCOL_TYPE,
        "version": PROTOCOL_VERSION,
        "instance_id": setting.server_id,
        "name": setting.server_name,
        "server_version": __version__,
        "addresses": addresses,
        "endpoints": await _endpoints(addresses),
    }


async def _endpoints(addresses: list[str]) -> list[dict[str, str]]:
    """``addresses`` 加上访问地址簿，标上内网 / 外网（server-addresses.md §3.2）。"""
    from movieclaw_api.services.server_addresses import address_book, normalize_url, url_kind

    try:
        book = await address_book.list()
    except Exception:
        logger.debug("自动发现：读访问地址失败", exc_info=True)
        book = []
    kinds = {view.url: view.kind for view in book}
    result: dict[str, str] = {}
    for raw in [*addresses, *(view.url for view in book)]:
        try:
            url = normalize_url(raw)
        except ValueError:
            continue
        result.setdefault(url, kinds.get(url) or url_kind(url))
    return [{"url": url, "kind": kind} for url, kind in result.items()]


async def jellyfin_reply(client_ip: str, http_port: int) -> dict | None:
    """Jellyfin 兼容应答；兼容开关关闭或地址无法确定时 None。"""
    setting = await get_jellyfin_compat()
    if not setting.enabled:
        return None
    address = await _resolve_address(client_ip, http_port, setting.published_server_url)
    if address is None:
        return None
    return {
        "Address": address,
        "Id": setting.server_id,
        "Name": setting.server_name,
        # 对齐真 Jellyfin：该字段不省略（UDP 响应不走 null 省略约定）
        "EndpointAddress": None,
    }


# ---------------------------------------------------------------------------
# UDP 监听
# ---------------------------------------------------------------------------


class _DiscoveryProtocol(asyncio.DatagramProtocol):
    def __init__(self, http_port: int) -> None:
        self._http_port = http_port
        # 事件循环只持任务弱引用，不自持会被 GC 掉在飞的应答
        self._tasks: set[asyncio.Task] = set()

    def connection_made(self, transport) -> None:  # type: ignore[override]
        self._transport = transport

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:  # type: ignore[override]
        text = data[:512].decode("utf-8", errors="replace").lower()
        if _MOVIECLAW_QUERY in text:
            build = movieclaw_reply
        elif _JELLYFIN_QUERY in text:
            build = jellyfin_reply
        else:
            return
        task = asyncio.get_running_loop().create_task(self._respond(build, addr))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _respond(self, build, addr: tuple[str, int]) -> None:
        try:
            payload = await build(addr[0], self._http_port)
            if payload is None:
                return
            self._transport.sendto(json.dumps(payload, ensure_ascii=False).encode("utf-8"), addr)
            logger.debug("已应答自动发现请求：%s ← %s", addr[0], payload)
        except Exception:
            logger.exception("自动发现应答失败")


async def start_discovery(http_port: int) -> None:
    """绑定 UDP 7359 开始监听。端口被占/无权限时告警并跳过（发现是锦上添花）。"""
    global _protocol_transport
    loop = asyncio.get_running_loop()
    try:
        transport, _ = await loop.create_datagram_endpoint(
            lambda: _DiscoveryProtocol(http_port),
            local_addr=("0.0.0.0", DISCOVERY_PORT),
        )
        _protocol_transport = transport
        logger.info("局域网自动发现已监听 UDP %d", DISCOVERY_PORT)
    except OSError as exc:
        logger.warning(
            "无法监听 UDP %d（%s），局域网自动发现不可用；手动填地址不受影响",
            DISCOVERY_PORT,
            exc,
        )


def stop_discovery() -> None:
    global _protocol_transport
    if _protocol_transport is not None:
        _protocol_transport.close()
        _protocol_transport = None

"""这台服务器的访问地址簿（docs/design/server-addresses.md §3）。

App 拿到这份地址簿后自己判断在家走内网、出门走外网，用户不用选。地址来源：

- **学到的**：管理员已登录、成功的请求进的是哪个入口（``X-Forwarded-Host`` 优先于
  ``Host``，协议按 ``X-Forwarded-Proto``）就记下哪个。只学管理员的：``Host`` /
  ``X-Forwarded-Host`` 是请求方自己能写的，学到的地址又会发给全家的 App 去连——成员或匿名请求
  塞进来一个转发中继，主机签名也拦不住（中继把探测原样转给真服务器就能拿到合法签名）。
  30 天没人用过的自动淘汰。局域网发现记下的地址（匿名请求也会学）不进地址簿。
- **配置的**：「外部访问地址」与 ``published_server_url``。
- **手动的**：管理员在「设置 → 网络 → 访问地址」里加的。类型可以改：家里 DNS 把域名解析到
  内网时，这个域名其实是内网地址，只看名字判断不出来。不过期。

内网 / 外网只看地址本身（``host_kind``）：私网、环回、链路本地 IP，内网后缀域名，单段主机名
算内网；其余（含 Tailscale 的 100.64/10）算外网。手动加的地址以手动选的类型为准。
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import time
from datetime import UTC, datetime
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, Field

from movieclaw_api.settings import AppServerSetting, get_setting_store
from movieclaw_api.settings.base import SettingSchema, register_setting

logger = logging.getLogger("movieclaw_api.server_addresses")

Kind = Literal["lan", "wan"]
Source = Literal["learned", "configured", "manual"]

#: 鉴权依赖认出登录主体后在 ASGI scope 里打的标记：中间件只从已登录的请求里学地址
AUTHENTICATED_SCOPE_KEY = "movieclaw.authenticated"

#: 学到的地址多久没人用就淘汰
LEARNED_TTL_S = 30 * 86400
#: 学到的地址「最近使用」多久落一次库：每个请求都写库没有意义，界面上只显示到「几小时前」
_TOUCH_PERSIST_S = 6 * 3600
#: 最多记几个学到的地址（换过端口、换过域名时都能留一份）
_MAX_LEARNED = 16

_LAN_SUFFIXES = (".local", ".lan", ".home.arpa", ".internal", ".localdomain")
_SHARED_ADDRESS_SPACE = ipaddress.ip_network("100.64.0.0/10")


def host_kind(host: str) -> Kind:
    """主机名（不带端口）是内网还是外网。"""
    name = host.strip().strip("[]").lower().rstrip(".")
    try:
        ip = ipaddress.ip_address(name)
    except ValueError:
        if not name or "." not in name or name.endswith(_LAN_SUFFIXES):
            return "lan"
        return "wan"
    if ip.version == 4 and ip in _SHARED_ADDRESS_SPACE:
        return "wan"
    return "lan" if ip.is_private or ip.is_loopback or ip.is_link_local else "wan"


def split_host(netloc: str) -> str:
    """``Host`` 头 → 主机名：去掉端口，IPv6 字面量去掉方括号。"""
    text = netloc.strip()
    if text.startswith("["):
        return text[1:].partition("]")[0]
    if text.count(":") > 1:  # 不带方括号的 IPv6
        return text
    return text.partition(":")[0]


def normalize_url(raw: str) -> str:
    """规范成 ``协议://主机[:端口]``：只接受 http / https，去掉路径和默认端口。

    不合法抛 ``ValueError``（消息直接给用户看）。"""
    value = raw.strip()
    parts = urlsplit(value)
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("地址要以 http:// 或 https:// 开头")
    if parts.username or parts.password:
        raise ValueError("地址里不能带用户名和密码")
    try:
        port = parts.port
    except ValueError as exc:
        raise ValueError("端口不正确") from exc
    host = parts.hostname.lower()
    if ":" in host:
        host = f"[{host}]"
    if port is None or port == (443 if scheme == "https" else 80):
        return f"{scheme}://{host}"
    return f"{scheme}://{host}:{port}"


def url_kind(url: str) -> Kind:
    return host_kind(urlsplit(url).hostname or "")


class AddressRecord(BaseModel):
    url: str
    kind: Kind
    source: Literal["learned", "manual"]
    #: 最近一次有人经它访问（epoch 秒）；手动加了还没人用过时为 None
    last_seen: int | None = None


@register_setting(namespace="app.server.addresses", title="访问地址（各端 App 自动选用）")
class ServerAddressesSetting(SettingSchema):
    """学到的与手动加的访问地址。配置的那两项（外部访问地址等）不在这里，读的时候现合并。"""

    records: list[AddressRecord] = Field(default_factory=list)


class AddressView(BaseModel):
    url: str
    kind: Kind
    source: Source
    last_seen: datetime | None = None


class _AddressBook:
    def __init__(self) -> None:
        self._records: dict[str, AddressRecord] = {}
        #: 每条地址最近一次落库时记的 last_seen（判断要不要再写）
        self._persisted_seen: dict[str, int] = {}
        #: 手动指定了类型的主机名 → 类型（判内外网时每个请求查一次，只读内存）
        self._manual_hosts: dict[str, Kind] = {}
        self._loaded = False
        self._lock = asyncio.Lock()
        #: 最近看到的入口（Host 字节串, 协议字节串）→ 时间：一分钟内再来不做任何事
        self._recent: dict[tuple[bytes, bytes], int] = {}
        self._tasks: set[asyncio.Task] = set()

    # ------------------------------------------------------------------ 读写

    async def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        async with self._lock:
            if self._loaded:
                return
            stored = await get_setting_store().get(ServerAddressesSetting)
            for record in stored.records:
                self._records.setdefault(record.url, record)
                if record.last_seen is not None:
                    self._persisted_seen[record.url] = record.last_seen
            self._reindex()
            self._loaded = True

    def _reindex(self) -> None:
        self._manual_hosts = {
            (urlsplit(r.url).hostname or ""): r.kind
            for r in self._records.values()
            if r.source == "manual"
        }

    async def _persist(self) -> None:
        records = sorted(self._records.values(), key=lambda r: r.url)
        await get_setting_store().set(ServerAddressesSetting(records=records))
        self._persisted_seen = {r.url: r.last_seen for r in records if r.last_seen is not None}

    def _spawn(self, coro) -> None:
        try:
            task = asyncio.get_running_loop().create_task(coro)
        except RuntimeError:
            coro.close()
            return
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    # ------------------------------------------------------------------ 学习

    def observe(
        self, host: bytes, forwarded_host: bytes | None, forwarded_proto: bytes | None
    ) -> None:
        """一次管理员已登录、成功的请求进的入口。同一个入口一分钟内再来只查一次字典（两个入口交替也一样）。"""
        now = int(time.time())
        key = (forwarded_host or host, forwarded_proto or b"http")
        seen = self._recent.get(key)
        if seen is not None and now - seen < 60:
            return
        if len(self._recent) >= 64:
            self._recent.clear()
        self._recent[key] = now
        netloc = key[0].decode("latin-1").split(",")[0].strip()
        proto = key[1].decode("latin-1").split(",")[0].strip().lower()
        try:
            url = normalize_url(f"{proto if proto in ('http', 'https') else 'http'}://{netloc}")
        except ValueError:
            return
        hostname = urlsplit(url).hostname or ""
        if host_kind(hostname) == "lan" and not _is_lan_ipv4(hostname):
            # 内网只学私网 IPv4 字面量：单段主机名、.local 一类常是容器名或 nginx 自己
            # （与局域网发现同口径）
            return
        self._spawn(self._learn(url, now))

    async def _learn(self, url: str, now: int) -> None:
        try:
            await self._ensure_loaded()
            record = self._records.get(url)
            if record is None:
                learned = [r for r in self._records.values() if r.source == "learned"]
                if len(learned) >= _MAX_LEARNED:
                    oldest = min(learned, key=lambda r: r.last_seen or 0)
                    del self._records[oldest.url]
                self._records[url] = AddressRecord(
                    url=url, kind=url_kind(url), source="learned", last_seen=now
                )
            else:
                record.last_seen = now
                persisted = self._persisted_seen.get(url)
                if persisted is not None and now - persisted < _TOUCH_PERSIST_S:
                    return
            await self._persist()
        except Exception:
            logger.debug("访问地址记录失败", exc_info=True)

    # ------------------------------------------------------------------ 查询

    def manual_kind(self, hostname: str) -> Kind | None:
        """管理员给这个主机名手动指定的类型；没指定为 None。

        只读内存：还没从库里读过时先返回 None，并在后台读一次（启动后最初几个请求可能没用上
        手动指定的类型）。"""
        if not self._loaded and not self._tasks:
            self._spawn(self.preload())
        return self._manual_hosts.get(hostname.strip().strip("[]").lower())

    async def preload(self) -> None:
        try:
            await self._ensure_loaded()
        except Exception:
            logger.debug("访问地址读取失败", exc_info=True)

    async def list(self) -> list[AddressView]:
        """手动的 > 配置的 > 学到的（同一地址只列一次），内网在前，各自按最近使用排。"""
        await self._ensure_loaded()
        now = int(time.time())
        views: dict[str, AddressView] = {}
        for record in self._records.values():
            if record.source == "manual":
                views[record.url] = AddressView(
                    url=record.url,
                    kind=record.kind,
                    source="manual",
                    last_seen=_dt(record.last_seen),
                )
        for configured in await _configured_urls():
            if configured not in views:
                seen = self._records.get(configured)
                views[configured] = AddressView(
                    url=configured,
                    kind=url_kind(configured),
                    source="configured",
                    last_seen=_dt(seen.last_seen if seen else None),
                )
        for record in self._records.values():
            if record.source != "learned" or record.url in views:
                continue
            if record.last_seen is None or now - record.last_seen > LEARNED_TTL_S:
                continue
            views[record.url] = AddressView(
                url=record.url, kind=record.kind, source="learned", last_seen=_dt(record.last_seen)
            )
        return sorted(
            views.values(),
            key=lambda v: (v.kind != "lan", -(v.last_seen.timestamp() if v.last_seen else 0)),
        )

    # ------------------------------------------------------------------ 管理

    async def add_manual(self, raw: str, kind: Kind | None) -> AddressView:
        url = normalize_url(raw)
        await self._ensure_loaded()
        previous = self._records.get(url)
        self._records[url] = AddressRecord(
            url=url,
            kind=kind or url_kind(url),
            source="manual",
            last_seen=previous.last_seen if previous else None,
        )
        self._reindex()
        await self._persist()
        record = self._records[url]
        return AddressView(
            url=url, kind=record.kind, source="manual", last_seen=_dt(record.last_seen)
        )

    async def remove(self, raw: str) -> bool:
        """删掉学到的或手动加的地址。学到的地址之后再有人用会重新出现。"""
        url = normalize_url(raw)
        await self._ensure_loaded()
        if self._records.pop(url, None) is None:
            return False
        self._reindex()
        self._recent.clear()
        await self._persist()
        return True

    def reset_state(self) -> None:
        self.__init__()


def _dt(epoch: int | None) -> datetime | None:
    return datetime.fromtimestamp(epoch, UTC) if epoch is not None else None


def _is_lan_ipv4(hostname: str) -> bool:
    try:
        ip = ipaddress.ip_address(hostname)
    except ValueError:
        return False
    return ip.version == 4 and ip.is_private and not ip.is_loopback and not ip.is_unspecified


async def _configured_urls() -> list[str]:
    from movieclaw_api.settings.schemas import get_jellyfin_compat

    urls: list[str] = []
    for raw in (
        (await get_setting_store().get(AppServerSetting)).external_url,
        (await get_jellyfin_compat()).published_server_url,
    ):
        try:
            url = normalize_url(raw)
        except ValueError:
            continue
        if url not in urls:
            urls.append(url)
    return urls


def lan_subnets(addresses: list[AddressView]) -> list[str]:
    """内网 IPv4 地址所在的 /24：客户端不发请求就能判断「我是不是在这个网段」。"""
    subnets: list[str] = []
    for view in addresses:
        if view.kind != "lan":
            continue
        try:
            ip = ipaddress.ip_address(urlsplit(view.url).hostname or "")
        except ValueError:
            continue
        if ip.version != 4 or ip.is_loopback:
            continue
        net = str(ipaddress.ip_network(f"{ip}/24", strict=False))
        if net not in subnets:
            subnets.append(net)
    return subnets


address_book = _AddressBook()


__all__ = [
    "AUTHENTICATED_SCOPE_KEY",
    "AddressView",
    "Kind",
    "ServerAddressesSetting",
    "address_book",
    "host_kind",
    "lan_subnets",
    "normalize_url",
    "split_host",
    "url_kind",
]

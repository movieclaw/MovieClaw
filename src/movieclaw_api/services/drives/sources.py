"""只在网盘上的库文件怎么读字节（docs/design/cloud-storage.md §7）。

- **直链**：按（账号、文件、UA）缓存插件给的时长（最长一小时），同一把钥匙并发只取一次；删除、移动、
  洗版时主动作废。服务器自己读（转发、转码、抽字幕、读索引）用 ``SERVER_USER_AGENT`` 取链；
  给播放器 302 时用播放器的 UA。
- **云端路径登记**：只在网盘上的文件（``local_bytes`` 为假、副本已核验）按台账路径登记在内存里。
  ``movieclaw_playback.streaming`` 的读字节入口（``media_input`` / ``open_strm_range``）据此把路径
  换成直链——转码、字幕、关键帧、字体这些同步读取不用各自认识网盘。同步读取多在工作线程里，
  缓存里没有就回到事件循环取一次；在事件循环上调用时只用缓存（调用方先 ``prefetch``）。
- **同时播放数**：按账号限制「同时有几路在读」（``read_slots``）。一路播放 = 一台设备的一次播放，
  它发出的几条并发 Range 请求共用一个名额；一段时间没有请求就让出。服务器自己的读取（转码会话、
  抽字幕）同样占名额，播放优先。
- **取流方式**：家里转发 / 直连网盘 / 自动（§7.2）。
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Literal

from sqlalchemy import select

from movieclaw_api.services.drives import gateway
from movieclaw_api.services.drives.registry import backends
from movieclaw_api.services.network_side import Side
from movieclaw_db.engine import get_database
from movieclaw_db.models.library_file import LibraryFile
from movieclaw_db.models.library_file_replica import REPLICA_VERIFIED, LibraryFileReplica
from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository
from movieclaw_playback.streaming import StrmLink
from movieclaw_sdk import drives as dv

logger = logging.getLogger("movieclaw_api.drives")

#: 服务器自己读网盘时用的 UA（转发、转码、抽字幕）。按 UA 签发直链的网盘，用它取的链只能它自己用
SERVER_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 MovieClaw"
)
#: 直链缓存的上限（秒）：插件说能用更久也只缓存这么久
LINK_TTL_CAP_S = 3600.0
#: 提前这么久当作过期（拖进度时别拿到一条马上失效的链）
LINK_EARLY_S = 30.0
_LINK_CACHE_MAX = 512

#: 一路播放多久没有请求就让出名额（秒）：播放器缓冲满了会停一阵再续拉
PLAY_SLOT_IDLE_S = 45.0
#: 外网直连的那一处多久没取新链就算离开（秒）
DIRECT_IDLE_S = 600.0

StreamMode = Literal["auto", "relay", "direct"]


class SlotsFull(Exception):
    """账号的同时播放数用完了。``message`` 直接给用户看。"""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


@dataclass(frozen=True, slots=True)
class CloudFile:
    file_id: int
    account_id: int
    remote_id: str
    size_bytes: int | None
    #: 台账记的修改时间（纳秒）：缓存指纹用，本地 stat 不到
    mtime_ns: int | None = None


# ---------------------------------------------------------------------- 直链


@dataclass(slots=True)
class _CachedLink:
    url: str
    expires_at: float


_links: dict[tuple[int, str, str], _CachedLink] = {}
_inflight: dict[tuple[int, str, str], asyncio.Future[str]] = {}


async def direct_url(
    account_id: int,
    remote_id: str,
    user_agent: str,
    *,
    priority: gateway.Priority = gateway.Priority.PLAYBACK,
) -> str:
    """一个网盘文件的直链（缓存、并发合并）。失败抛 ``DriveError`` 的子类。"""
    key = (account_id, remote_id, user_agent)
    now = time.monotonic()
    cached = _links.get(key)
    if cached is not None and cached.expires_at > now:
        return cached.url
    pending = _inflight.get(key)
    if pending is not None:
        return await asyncio.shield(pending)
    future: asyncio.Future[str] = asyncio.get_running_loop().create_future()
    _inflight[key] = future
    try:
        link: dv.DirectLink = await gateway.call(
            account_id,
            "direct_link",
            priority=priority,
            remote_id=remote_id,
            user_agent=user_agent,
        )
        ttl = max(0.0, min(link.expires_in, LINK_TTL_CAP_S) - LINK_EARLY_S)
        if ttl > 0:
            if len(_links) >= _LINK_CACHE_MAX:
                _links.pop(next(iter(_links)))
            _links[key] = _CachedLink(link.url, time.monotonic() + ttl)
        future.set_result(link.url)
        return link.url
    except BaseException as exc:
        future.set_exception(exc)
        # 没人等这个 future 时别让 asyncio 报「异常没被取走」
        future.exception()
        raise
    finally:
        _inflight.pop(key, None)


def forget_links(account_id: int, remote_id: str | None = None) -> None:
    """删除、移动、洗版、换账号后：这些直链不能再用。"""
    stale = [k for k in _links if k[0] == account_id and remote_id in (None, k[1])]
    for key in stale:
        _links.pop(key, None)


def _cached_url(account_id: int, remote_id: str, user_agent: str) -> str | None:
    cached = _links.get((account_id, remote_id, user_agent))
    if cached is not None and cached.expires_at > time.monotonic():
        return cached.url
    return None


# ---------------------------------------------------------------------- 云端路径登记


_paths: dict[str, CloudFile] = {}
_loop: asyncio.AbstractEventLoop | None = None


def cloud_file(file_path: str) -> CloudFile | None:
    return _paths.get(file_path)


async def load_registry() -> int:
    """启动时：把只在网盘上、副本已核验的文件登记进来。返回登记了几个。"""
    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(
                    LibraryFile.id,
                    LibraryFile.file_path,
                    LibraryFile.size_bytes,
                    LibraryFile.file_mtime_ns,
                    LibraryFileReplica,
                )
                .join(LibraryFileReplica, LibraryFileReplica.library_file_id == LibraryFile.id)
                .where(
                    LibraryFile.local_bytes.is_(False),  # type: ignore[attr-defined]
                    LibraryFileReplica.state == REPLICA_VERIFIED,
                )
            )
        ).all()
    _paths.clear()
    for file_id, path, size, mtime_ns, replica in rows:
        _paths[path] = CloudFile(
            file_id, replica.account_id, replica.remote_id, replica.size_bytes or size, mtime_ns
        )
    return len(_paths)


async def refresh_file(file_id: int) -> CloudFile | None:
    """一个文件的字节位置变了（释放了本地、纳管、副本丢失、本地回来了）：重新登记它。"""
    async with get_database().session() as session:
        file = await session.get(LibraryFile, file_id)
        replica = (
            await session.execute(
                select(LibraryFileReplica).where(LibraryFileReplica.library_file_id == file_id)
            )
        ).scalar_one_or_none()
    for path in [p for p, item in _paths.items() if item.file_id == file_id]:
        _paths.pop(path, None)
    if file is None or file.local_bytes or replica is None or replica.state != REPLICA_VERIFIED:
        return None
    item = CloudFile(
        file_id,
        replica.account_id,
        replica.remote_id,
        replica.size_bytes or file.size_bytes,
        file.file_mtime_ns,
    )
    _paths[file.file_path] = item
    return item


def server_link(item: CloudFile, url: str) -> StrmLink:
    """服务器自己读用的直链：请求时带上取链时的 UA（按 UA 签发的直链换了 UA 就不认）。"""
    return StrmLink(url=url, headers={"User-Agent": SERVER_USER_AGENT})


async def prefetch(
    file_path: str, *, priority: gateway.Priority = gateway.Priority.PLAYBACK
) -> StrmLink | None:
    """在事件循环上先把服务器读用的直链取好（之后同步读取直接命中缓存）。不是网盘文件返回 None。"""
    item = _paths.get(file_path)
    if item is None:
        return None
    url = await direct_url(item.account_id, item.remote_id, SERVER_USER_AGENT, priority=priority)
    return server_link(item, url)


def resolve(file_path: str) -> StrmLink | None:
    """同步读取入口用：网盘文件的服务器直链；取不到返回 None（按读失败处理）。"""
    item = _paths.get(file_path)
    if item is None:
        return None
    url = _cached_url(item.account_id, item.remote_id, SERVER_USER_AGENT)
    if url is not None:
        return server_link(item, url)
    loop = _loop
    if loop is None or loop.is_closed():
        return None
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        # 工作线程：回到事件循环取一次链
        try:
            future = asyncio.run_coroutine_threadsafe(prefetch(file_path), loop)
            return future.result(timeout=30)
        except Exception as exc:  # noqa: BLE001 -- 取不到链按读失败处理，原因记日志
            logger.warning("取网盘直链失败（%s）：%s", file_path, exc)
            return None
    # 在事件循环上同步调用：不能阻塞等自己，只用缓存（调用方应先 prefetch）
    logger.warning("网盘直链不在缓存里，且在事件循环上同步读取：%s", file_path)
    return None


def _stamp(file_path: str) -> tuple[int, int] | None:
    item = _paths.get(file_path)
    if item is None or item.size_bytes is None:
        return None
    return item.size_bytes, item.mtime_ns or 0


def bind() -> None:
    """把登记表接到播放层的读字节入口（插件内核启动时）。"""
    from movieclaw_playback import streaming

    global _loop
    _loop = asyncio.get_running_loop()
    streaming.bind_cloud(lambda path: path in _paths, resolve, _stamp)


def unbind() -> None:
    from movieclaw_playback import streaming

    global _loop
    streaming.bind_cloud(None, None)
    _loop = None


def reset_state() -> None:
    """测试换库时用。"""
    _paths.clear()
    _links.clear()
    _inflight.clear()
    _slots.clear()
    _limits.clear()
    _direct_clients.clear()


# ---------------------------------------------------------------------- 同时播放数


@dataclass(slots=True)
class _AccountSlots:
    #: 持有者 → 最近一次用的时间（monotonic）；播放按空闲让出，服务器读取用完就还
    holders: dict[str, float] = field(default_factory=dict)
    pinned: set[str] = field(default_factory=set)


_slots: dict[int, _AccountSlots] = {}


@dataclass(frozen=True, slots=True)
class _AccountView:
    expires_at: float
    slots: int
    status: str
    name: str
    backend: str


_limits: dict[int, _AccountView] = {}
_LIMITS_TTL_S = 15.0


async def _account_view(account_id: int) -> _AccountView:
    """账号的同时播放数、状态、名字、网盘类型。

    按账号缓存 15 秒：每条 Range 请求都要问，别次次查库。
    """
    cached = _limits.get(account_id)
    now = time.monotonic()
    if cached is not None and cached.expires_at > now:
        return cached
    async with get_database().session() as session:
        row = await DriveAccountRepository(session).get(account_id)
    if row is None:
        raise dv.NotFound("网盘账号不存在")
    _qps, _budget, slots = gateway.effective(row, backends().get(row.backend))
    view = _AccountView(now + _LIMITS_TTL_S, slots, row.status, row.name, row.backend)
    _limits[account_id] = view
    return view


def forget_limits(account_id: int) -> None:
    _limits.pop(account_id, None)


async def take_slot(account_id: int, holder: str, *, pinned: bool = False) -> None:
    """占一个名额（同一持有者重复占只刷新时间）。满了抛 ``SlotsFull``。

    ``pinned`` 的持有者（转码会话、抽字幕）不会因空闲被让出，用完调 ``release_slot``。
    """
    view = await _account_view(account_id)
    limit, name = view.slots, view.name
    slots = _slots.setdefault(account_id, _AccountSlots())
    now = time.monotonic()
    for key, last in list(slots.holders.items()):
        if key not in slots.pinned and now - last > PLAY_SLOT_IDLE_S:
            del slots.holders[key]
    if holder not in slots.holders and len(slots.holders) >= limit:
        raise SlotsFull(
            f"网盘「{name}」同时播放数已满（{limit}），稍后再试，或在「设置 → 网盘」里调整"
        )
    slots.holders[holder] = now
    if pinned:
        slots.pinned.add(holder)


def release_slot(account_id: int, holder: str) -> None:
    slots = _slots.get(account_id)
    if slots is None:
        return
    slots.holders.pop(holder, None)
    slots.pinned.discard(holder)


# ---------------------------------------------------------------------- 取流方式


_direct_clients: dict[int, tuple[str, float]] = {}


def choose_direct(
    *,
    mode: StreamMode,
    account_id: int,
    side: Side,
    place: str,
    relay_fallback: bool,
    force_relay: bool,
    original_link: bool,
) -> bool:
    """这次取流要不要 302 到网盘直链（cloud-storage.md §7.2）。不直连就由家里转发。

    ``side`` 是请求方在家还是在外面（server-addresses.md §5），``place`` 是在外面的哪一处：
    按设备算。
    不按公网地址算——走 CDN / VPS 中转时转发链里离我们最近的公网地址是中转节点，所有在外面的设备
    看起来是同一处；同一个咖啡馆的两台设备按两处算，第二台转发，是安全的那一边。

    - 家里的设备、点了「改走转发」的（App 直连失败后带 ``relay=1`` 重来）、插件说直链不是原画
      的：转发；
    - 「总是转发」：转发；「总是直连」：在外面或认不准都直连（用户明确选的）；
    - 「自动」：只有声明能在直连失败时改走转发的客户端（自家 App），确定在外面，且这个账号此刻
      没有别处在外面直连，才直连——任何时刻最多「家里 + 一处在外」两个地址访问网盘，第三方播放器
      永远不直连。认不准时无从保证「只有一处」，转发。
    """
    if force_relay or not original_link or side == "home":
        return False
    if mode == "relay":
        return False
    if mode == "auto":
        if not relay_fallback or side != "outside":
            return False
        holder = _direct_clients.get(account_id)
        now = time.monotonic()
        if holder is not None and holder[0] != place and now - holder[1] < DIRECT_IDLE_S:
            return False
    _direct_clients[account_id] = (place, time.monotonic())
    return True


def declares_fallback(headers: Mapping[str, str], query: Mapping[str, str]) -> bool:
    """客户端声明「直连网盘失败会带 ``relay=1`` 改走转发」。

    请求头 ``X-MovieClaw-Relay-Fallback: 1``，或查询参数 ``fallback=1``（播放引擎自己发请求、带不了
    自定义请求头时用）。
    """
    return headers.get("x-movieclaw-relay-fallback") == "1" or query.get("fallback") == "1"


async def stream_mode() -> StreamMode:
    """设置 → 播放里「在外面播放网盘上的片子」的选择。"""
    from movieclaw_api.settings import get_setting_store
    from movieclaw_api.settings.playback import PlaybackPolicySetting

    policy = await get_setting_store().get(PlaybackPolicySetting)
    return policy.cloud_stream_mode


@dataclass(frozen=True, slots=True)
class CloudStream:
    """一次取流怎么走：``direct_url`` 不为空就 302 过去，否则按 ``relay`` 由家里转发。"""

    direct_url: str | None
    relay: StrmLink | None


async def stream_target(
    file_path: str,
    *,
    holder: str,
    user_agent: str | None,
    side: Side = "unknown",
    place: str = "",
    relay_fallback: bool = False,
    force_relay: bool = False,
    allow_direct: bool = True,
) -> CloudStream:
    """只在网盘上的文件这次取流怎么走（cloud-storage.md §7.2、§7.3）。

    ``holder`` 是这路播放的标识（同一台设备同一个文件的几条 Range 请求共用一个名额）。``side`` /
    ``place`` 见 ``choose_direct``；不许直连（``allow_direct=False``）时不用给。
    直连网盘不经过家里，不占名额。失败抛 ``SlotsFull`` / ``BackendUnavailable`` / ``DriveError``。
    """
    from movieclaw_api.services.drives.registry import BackendUnavailable

    item = _paths.get(file_path)
    if item is None:
        raise dv.NotFound("这个文件只在网盘上，但网盘副本现在不可用")
    view = await _account_view(item.account_id)
    backend = backends().get(view.backend)
    if backend is None:
        raise BackendUnavailable(f"没有安装能连接「{view.backend}」网盘的存储插件")
    if allow_direct and choose_direct(
        mode=await stream_mode(),
        account_id=item.account_id,
        side=side,
        place=place,
        relay_fallback=relay_fallback,
        force_relay=force_relay,
        original_link=backend.capabilities.original_link,
    ):
        url = await direct_url(item.account_id, item.remote_id, user_agent or SERVER_USER_AGENT)
        return CloudStream(direct_url=url, relay=None)
    await take_slot(item.account_id, holder)
    url = await direct_url(item.account_id, item.remote_id, SERVER_USER_AGENT)
    return CloudStream(direct_url=None, relay=server_link(item, url))


def stream_error(exc: Exception) -> str:
    """取流失败给用户看的一句话。"""
    from movieclaw_api.services.drives.registry import BackendUnavailable

    if isinstance(exc, SlotsFull):
        return exc.message
    if isinstance(exc, BackendUnavailable):
        return str(exc)
    if isinstance(exc, dv.AuthExpired):
        return f"网盘需要重新登录：{exc.message}"
    if isinstance(exc, dv.DriveError):
        return f"网盘取不到这个文件：{exc.message}"
    return f"网盘取流失败：{exc}"

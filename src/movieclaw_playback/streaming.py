"""取流领域服务：本地文件 Range 直连与 strm 网盘直链解析。

- 本地文件：交给 Starlette FileResponse（原生 Range/206/If-Range/HEAD），
  Content-Type 按容器查表；
- strm 占位文件：读第一个非空、非 ``#`` 开头的行，**只接受
  http/https/rtsp/rtp 绝对 URI**——File 协议/相对路径必须拒绝，否则 strm
  就成了任意本地文件读取漏洞（对齐 Jellyfin ProbeProvider.FetchShortcutInfo
  与 BaseItem.cs:1191-1194 的安全语义）。播放走 302 重定向，不做反向代理
  （零网盘流量，docs/design/jellyfin-compat.md 6.4）。
"""

from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import Awaitable, Callable, Sequence
from pathlib import Path
from secrets import token_hex
from typing import TypeVar
from urllib.parse import urlsplit

import anyio
from starlette.datastructures import MutableHeaders
from starlette.responses import FileResponse
from starlette.types import Message, Receive, Scope, Send

from movieclaw_playback.mp4_sample_entry import (
    BytePatch,
    apply_byte_patches,
    hev1_to_hvc1_patches,
)

logger = logging.getLogger("movieclaw_playback.streaming")

STRM_EXT = ".strm"

_ALLOWED_STRM_SCHEMES = {"http", "https", "rtsp", "rtp"}

# 一个播放器设备在停止播放后，可能仍保留若干 HTTP Range 连接。它们不一定马上
# 触发 TCP disconnect，不能只靠 Request.is_disconnected() 才停止读盘。
_active_stream_stops: dict[str, set[asyncio.Event]] = {}

_T = TypeVar("_T")

# 容器 → MIME（对齐 Jellyfin MimeTypes.cs 的常用子集；未知视频容器兜底 video/{ext}）
_CONTAINER_MIME = {
    "mkv": "video/x-matroska",
    "mp4": "video/mp4",
    "m4v": "video/x-m4v",
    "ts": "video/mp2t",
    "m2ts": "video/mp2t",
    "avi": "video/x-msvideo",
    "mov": "video/quicktime",
    "webm": "video/webm",
    "wmv": "video/x-ms-wmv",
    "flv": "video/x-flv",
    "mpg": "video/mpeg",
    "mpeg": "video/mpeg",
    "iso": "application/x-iso9660-image",
}


def register_device_stream(device_id: str) -> asyncio.Event:
    """登记设备的一条本地取流，并返回会话停止时置位的取消信号。"""
    stopped = asyncio.Event()
    _active_stream_stops.setdefault(device_id, set()).add(stopped)
    return stopped


def unregister_device_stream(device_id: str, stopped: asyncio.Event) -> None:
    """回收已结束取流的取消信号，避免设备长期播放后积累无用引用。"""
    streams = _active_stream_stops.get(device_id)
    if streams is None:
        return
    streams.discard(stopped)
    if not streams:
        _active_stream_stops.pop(device_id, None)


def stop_device_streams(device_id: str) -> int:
    """停止一个播放器设备仍在读取的全部本地流，返回受影响的连接数。"""
    streams = tuple(_active_stream_stops.get(device_id, ()))
    for stopped in streams:
        stopped.set()
    if streams:
        logger.info("播放器会话已停止，已取消 %d 条仍在读取的视频流", len(streams))
    return len(streams)


class ClientDisconnected(Exception):
    """等待期间客户端断开了连接（见 :func:`await_unless_disconnected`）。"""


async def _wait_disconnect(receive: Receive) -> None:
    """一直等到 ``http.disconnect``。GET 的请求体消费完后 receive 会挂起到连接断开。"""
    while True:
        message = await receive()
        if message["type"] == "http.disconnect":
            return
        # 防御：某些测试桩会重复返回空的 http.request，让出事件循环避免空转
        await asyncio.sleep(0)


async def await_unless_disconnected(receive: Receive, awaitable: Awaitable[_T]) -> _T:
    """等 ``awaitable`` 的同时盯着客户端：客户端先断开就取消它，抛 :class:`ClientDisconnected`。

    为什么要它（docs/design/transcode-latency.md §4.1）：转码会话的分片请求可能要等好几秒，
    客户端等不及会自己掐掉——AVPlayer 跳转时取消在途请求、一个分片等满约 4 秒就放弃重发。
    uvicorn 并不会因为连接断开就取消应用协程，于是没人要的旧请求一直挂在「在等的分片」表里，
    直到 30 秒超时；转码重启判定把它当成客户端还要的分片，回拖时它会挡住真正的目标、或者
    在宽限期满后把转码拽回过时的位置。这里起一个后台 receive 盯断开，断开即取消等待，
    等待方的 ``finally`` 随之注销挂号。

    返回前一定收掉后台 receive：之后的响应对象（``DisconnectAwareFileResponse``）还要自己
    receive，ASGI 的 receive 同一时刻只能有一个等待者。
    """
    task = asyncio.ensure_future(awaitable)
    watcher = asyncio.ensure_future(_wait_disconnect(receive))
    try:
        await asyncio.wait({task, watcher}, return_when=asyncio.FIRST_COMPLETED)
        if task.done():
            return task.result()
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        raise ClientDisconnected
    finally:
        if not task.done():
            # 外层自己被取消（服务端关机等）：别把等待留在后台
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        if not watcher.done():
            watcher.cancel()
        await asyncio.gather(watcher, return_exceptions=True)


class DisconnectAwareFileResponse(FileResponse):
    """客户端断开或播放器上报停止后立即停止读盘的 ``FileResponse``。

    Uvicorn 检测到 TCP 连接断开后会静默丢弃后续 ASGI ``send`` 消息；而
    Starlette 原生 ``FileResponse`` 不读取 ``receive``，仍会把整个 Range
    循环从磁盘读完。对数十 GB 的机械盘媒体文件，这会表现为客户端已经退出、
    服务端却持续高 CPU 和读盘（播放器每次 seek 留下的旧 Range 连接都会把
    文件读到底）。

    断连检测的实现要点（2026-08 NAS 现场事故的教训）：

    - **不要每块调用** ``Request.is_disconnected()``：Starlette 1.x 的实现是
      "预取消的 CancelScope + await receive()"，在 ``BaseHTTPMiddleware``
      包裹下永远在中间件内部的检查点处被取消、**恒返回 False**，而且每块两次
      取消舞的 CPU 开销比读盘发包本身还高。
    - 改为响应开始时起**一个**后台任务 ``await receive()``，收到
      ``http.disconnect`` 就置位 ``_disconnected``；发送循环里只做
      ``Event.is_set()`` 的同步检查，每块开销趋近于零。
    - 块大小提到 1 MiB（Starlette 默认 64 KiB）：每块都要经过 ASGI send、
      中间件转发和 uvicorn 写缓冲，块数少 16 倍就是 CPU 少 16 倍。

    该类沿用 Starlette 的 Range 头和分段规则，并且**一律发送
    ``Content-Length``**（2026-08-22 NAS 现场事故的教训）：

    - 早期版本为了能在"播放器上报停止、TCP 仍连着"时用一个空的结束帧收尾，
      非 HEAD 请求一律剥掉 ``Content-Length``、让服务器改用 chunked。真
      Jellyfin 不是这么干的，而 Infuse / VidHub / Apple TV 这类基于
      AVFoundation 的播放器拿不到响应长度就无法预估缓冲，表现为**不停地开一个
      小 Range、读一点、掐断、再开一个**：现场实测 40 秒内打进来 89 个 Range
      请求（约 2 次/秒），每个响应在客户端断开前已经从磁盘读了 23–60 MB，
      合计约 2.2 GB——比整个 1.67 GB 的剧集文件还多。磁盘被打满后，同一时刻的
      媒体库列表和封面请求全部超时，客户端表现为"连不上、库里空空的"。
    - 因此长度头必须留着。代价是提前停止时**无法再合法地收尾**（body 短于
      已声明的长度是协议错误），只能停止发送、由服务器关闭连接：

      * TCP 已断连：uvicorn 本就丢弃后续 send，直接返回即静默结束；
      * 播放器上报 Stopped 而 TCP 仍在：uvicorn 会记一条
        "ASGI callable returned without completing response." 并关闭连接——
        关掉这条已被放弃的连接正是我们要的结果，为了让部署者看懂，停止读盘时
        先用中文说明原因。

    断开时最多多读一个已在途的块。
    """

    chunk_size = 1024 * 1024

    def __init__(
        self,
        path: str | Path,
        *,
        session_stopped: asyncio.Event | None = None,
        on_close: Callable[[], None] | None = None,
        byte_sink: Callable[[int], None] | None = None,
        byte_patches: tuple[BytePatch, ...] = (),
        probe=None,
        **kwargs,
    ) -> None:
        super().__init__(path, **kwargs)
        self._session_stopped = session_stopped
        self._on_close = on_close
        # 每发出一块调用一次的字节计量回调（活动页「观看」视角的速率来源）；
        # 必须是同步且近零开销的，不能拖慢发送循环
        self._byte_sink = byte_sink
        # 流经时原地替换的字节（目前只有 HEVC MP4 的 hev1 → hvc1 标签，见
        # mp4_sample_entry）。长度不变，Content-Length / Range 语义都不受影响；
        # 磁盘上的文件一个字节都不动
        self._byte_patches = byte_patches
        # 播放体验打点的取流计时（docs/design/playback-qoe.md §5.3）：读出第一块时调
        # ``first_chunk()``，结束时调 ``finish(字节数, disconnected=…)``；两者都只改内存，近零开销
        self._probe = probe
        #: 这条响应是否没发完就停了（客户端断开 / 播放器上报停止）。不能拿 ``_disconnected`` 判：
        #: 响应正常发完后服务器也会给一条 http.disconnect，每个请求都会被误记成「中途断开」
        self._stopped_early = False
        self._disconnected = asyncio.Event()
        self._bytes_read = 0
        self._stop_logged = False

    def _should_stop_reading(self) -> bool:
        """同步、零开销的停止判断；每块调用一次。"""
        if self._session_stopped is not None and self._session_stopped.is_set():
            reason = "播放器已上报停止"
            # TCP 还连着，这条响应会短于已声明的 Content-Length：服务器接下来
            # 会打印一条英文的 "returned without completing response" 并关闭
            # 连接，那是预期行为而不是故障，先在这里讲清楚
            detail = "，将关闭这条已被放弃的连接"
        elif self._disconnected.is_set():
            reason = "客户端已断开"
            detail = ""
        else:
            return False
        self._stopped_early = True
        if not self._stop_logged:
            self._stop_logged = True
            logger.info(
                "%s视频流，停止继续读取（本响应已读取 %d 字节）%s",
                reason,
                self._bytes_read,
                detail,
            )
        return True

    async def _watch_disconnect(self, receive: Receive) -> None:
        """后台等待客户端断开。

        请求体（GET/HEAD 为空）消费完后，ASGI 服务器的 ``receive`` 会一直挂起
        直到连接断开才返回 ``http.disconnect``；BaseHTTPMiddleware 的包装同样
        会把这条消息透传下来（Starlette 自己的 StreamingResponse 也靠这条路径
        监听断连）。
        """
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                self._disconnected.set()
                return
            # 防御：某些测试桩/服务器会重复返回空的 http.request，让出事件循环
            # 避免空转
            await asyncio.sleep(0)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        """无论正常结束、客户端断开还是会话取消，都回收设备流登记与监听任务。"""
        # pathsend 会把文件路径交给 ASGI 服务器，之后应用层既不能观察 Stopped，
        # 也无法中止服务器的持续读盘。视频流必须由本响应逐块读取和检查。
        extensions = scope.get("extensions")
        if extensions and "http.response.pathsend" in extensions:
            scope = {
                **scope,
                "extensions": {
                    key: value
                    for key, value in extensions.items()
                    if key != "http.response.pathsend"
                },
            }
        watcher = asyncio.ensure_future(self._watch_disconnect(receive))
        try:
            await super().__call__(scope, receive, send)
        finally:
            watcher.cancel()
            if self._probe is not None:
                self._probe.finish(self._bytes_read, disconnected=self._stopped_early)
            if self._on_close is not None:
                self._on_close()

    async def _send_span(self, file, send: Send, start: int, end: int | None) -> None:
        """把文件 ``[start, end)`` 区间逐块发出，中途停止则直接返回。

        ``end`` 为 None 表示读到文件末尾（无 Range 的整文件响应）。
        提前停止时不补结束帧：Content-Length 已经发出去了，补一个短 body
        是协议错误，交给服务器关闭连接即可。
        """
        await file.seek(start)
        more_body = True
        while more_body:
            if self._should_stop_reading():
                return
            size = self.chunk_size if end is None else min(self.chunk_size, end - start)
            chunk = await file.read(size)
            if self._probe is not None:
                self._probe.first_chunk()
            self._bytes_read += len(chunk)
            if self._byte_sink is not None:
                self._byte_sink(len(chunk))
            if self._byte_patches:
                chunk = apply_byte_patches(chunk, start, self._byte_patches)
            start += len(chunk)
            more_body = len(chunk) == self.chunk_size and (end is None or start < end)
            await send({"type": "http.response.body", "body": chunk, "more_body": more_body})

    async def _handle_simple(
        self, send: Send, send_header_only: bool, _send_pathsend: bool
    ) -> None:
        await send(
            {
                "type": "http.response.start",
                "status": self.status_code,
                "headers": self.raw_headers,
            }
        )
        if send_header_only:
            await send({"type": "http.response.body", "body": b"", "more_body": False})
            return
        if self._should_stop_reading():
            return
        async with await anyio.open_file(self.path, mode="rb") as file:
            await self._send_span(file, send, 0, None)

    async def _handle_single_range(
        self, send: Send, start: int, end: int, file_size: int, send_header_only: bool
    ) -> None:
        headers = MutableHeaders(raw=list(self.raw_headers))
        headers["content-range"] = f"bytes {start}-{end - 1}/{file_size}"
        headers["content-length"] = str(end - start)
        await send(
            {
                "type": "http.response.start",
                "status": 206,
                "headers": headers.raw,
            }
        )
        if send_header_only:
            await send({"type": "http.response.body", "body": b"", "more_body": False})
            return
        if self._should_stop_reading():
            return
        async with await anyio.open_file(self.path, mode="rb") as file:
            await self._send_span(file, send, start, end)

    async def _handle_multiple_ranges(
        self,
        send: Send,
        ranges: list[tuple[int, int]],
        file_size: int,
        send_header_only: bool,
    ) -> None:
        boundary = token_hex(13)
        content_length, header_generator = self.generate_multipart(
            ranges, boundary, file_size, self.headers["content-type"]
        )
        headers = MutableHeaders(raw=list(self.raw_headers))
        headers["content-type"] = f"multipart/byteranges; boundary={boundary}"
        headers["content-length"] = str(content_length)
        await send(
            {
                "type": "http.response.start",
                "status": 206,
                "headers": headers.raw,
            }
        )
        if send_header_only:
            await send({"type": "http.response.body", "body": b"", "more_body": False})
            return
        if self._should_stop_reading():
            return
        async with await anyio.open_file(self.path, mode="rb") as file:
            for start, end in ranges:
                if self._should_stop_reading():
                    return
                await send(
                    {
                        "type": "http.response.body",
                        "body": header_generator(start, end),
                        "more_body": True,
                    }
                )
                await file.seek(start)
                while start < end:
                    if self._should_stop_reading():
                        return
                    chunk = await file.read(min(self.chunk_size, end - start))
                    if self._probe is not None:
                        self._probe.first_chunk()
                    self._bytes_read += len(chunk)
                    if self._byte_sink is not None:
                        self._byte_sink(len(chunk))
                    if self._byte_patches:
                        chunk = apply_byte_patches(chunk, start, self._byte_patches)
                    start += len(chunk)
                    await send({"type": "http.response.body", "body": chunk, "more_body": True})
                await send({"type": "http.response.body", "body": b"\r\n", "more_body": True})
            await send(
                {
                    "type": "http.response.body",
                    "body": f"--{boundary}--".encode("latin-1"),
                    "more_body": False,
                }
            )


#: 只有这些容器的 HEVC 才有 hev1/hvc1 之分（MKV 没有样本条目类型码）
_ISOBMFF_CONTAINERS = {"mp4", "m4v", "mov"}


async def direct_play_byte_patches(
    path: str | Path, container: str | None, video_codec: str | None
) -> tuple[BytePatch, ...]:
    """档 0 直出要带的字节补丁：HEVC MP4 的 ``hev1`` → ``hvc1``（issue #430）。

    WebKit 只认 hvc1，而 WEB-DL 的 MP4 大多打 hev1；改的只是 stsd 里 4 字节
    类型码，对其它播放器也都合法。非 HEVC / 非 ISO BMFF 直接返回空，不开文件。
    首次要读盒子头（moov 在文件尾时几次 seek），放线程池里做；之后按
    (路径, mtime, 大小) 命中缓存。
    """
    if (container or "").lower() not in _ISOBMFF_CONTAINERS:
        return ()
    if (video_codec or "").lower() != "hevc":
        return ()
    return await asyncio.to_thread(hev1_to_hvc1_patches, path)


class FileWindowResponse(DisconnectAwareFileResponse):
    """把文件里的几段首尾相接当成一个独立文件供出：长度、Range 都按拼接后的偏移算。

    光盘镜像里的剪辑没有自己的文件，远程 Worker 按段取源时由它从镜像上读这一段
    （iso_source.py）；剪辑在镜像里断成多截时（双层盘换层、交错存放）按顺序拼起来。
    读盘、断连、计量与父类完全相同，只是每截区间平移到它在镜像里的位置。
    """

    def __init__(self, path: str | Path, *, windows: Sequence[tuple[int, int]], **kwargs) -> None:
        real = os.stat(path)
        length = sum(end - start for start, end in windows)
        window = os.stat_result(
            (
                real.st_mode,
                real.st_ino,
                real.st_dev,
                real.st_nlink,
                real.st_uid,
                real.st_gid,
                length,
                int(real.st_atime),
                int(real.st_mtime),
                int(real.st_ctime),
            )
        )
        super().__init__(path, stat_result=window, **kwargs)
        self._windows = tuple(windows)
        self._length = length

    async def _send_span(self, file, send: Send, start: int, end: int | None) -> None:
        pieces = slice_windows(self._windows, start, self._length if end is None else end)
        if not pieces:
            await send({"type": "http.response.body", "body": b"", "more_body": False})
            return

        async def hold_open(message: Message) -> None:
            # 前几截读完不能收尾：父类每截末尾发 more_body=False，这里改成还有下文
            await send({**message, "more_body": True})

        for i, (a, b) in enumerate(pieces):
            await super()._send_span(file, send if i == len(pieces) - 1 else hold_open, a, b)
            if self._should_stop_reading():
                return


def slice_windows(
    windows: Sequence[tuple[int, int]], start: int, end: int
) -> list[tuple[int, int]]:
    """几截首尾相接的区间里的 ``[start, end)`` → 落在原文件上的各截 ``(起, 止)``。

    在原文件上恰好相邻的截合并成一截。
    """
    out: list[tuple[int, int]] = []
    offset = 0
    for a, b in windows:
        lo, hi = max(start, offset), min(end, offset + b - a)
        if lo < hi:
            piece = (a + lo - offset, a + hi - offset)
            if out and out[-1][1] == piece[0]:
                out[-1] = (out[-1][0], piece[1])
            else:
                out.append(piece)
        offset += b - a
        if offset >= end:
            break
    return out


def container_mime_type(container: str | None) -> str:
    """按容器名取 Content-Type；未知容器给 video/{ext} 兜底。"""
    if not container:
        return "application/octet-stream"
    ext = container.lower().lstrip(".")
    return _CONTAINER_MIME.get(ext, f"video/{ext}")


def is_strm(file_path: str) -> bool:
    return file_path.lower().endswith(STRM_EXT)


def resolve_strm_url(file_path: str | Path) -> str | None:
    """读 strm 文件内容解析出远程播放地址；不合法返回 None。

    取第一个非空且不以 ``#`` 开头的行；仅接受白名单 scheme 的绝对 URI。
    每次播放现读文件——strm 内容可能是带时效签名的直链，不缓存。
    """
    try:
        text = Path(file_path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        logger.warning("strm 文件读取失败：%s", file_path)
        return None
    for line in text.splitlines():
        candidate = line.strip()
        if not candidate or candidate.startswith("#"):
            continue
        scheme = urlsplit(candidate).scheme.lower()
        if scheme in _ALLOWED_STRM_SCHEMES:
            return candidate
        logger.warning(
            "strm 内容不是允许的远程地址（仅接受 http/https/rtsp/rtp），已拒绝：%s",
            file_path,
        )
        return None
    return None

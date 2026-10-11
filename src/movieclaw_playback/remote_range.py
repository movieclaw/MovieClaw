"""按 HTTP Range 读远端文件的只读文件对象（网盘直链的容器索引用）。

容器索引的读取器（``keyframes._matroska_cues``）只做「读文件头、跳到 Cues 读一整块」
这类少量小读，换成 Range 请求就是三四个请求、几十 KB 到几 MB——不必为一份索引把整片
拉下来。每次 ``read`` 发一个请求，至少取 ``min_fetch`` 字节并留着最近一块，连续的小读
（头部解析）落在同一块里。

服务端不认 Range（回 200 整个文件）时直接报错，绝不顺着把整片读下来。

请求走进程内共享的连接池（keep-alive）：按索引抽字幕要发上千个小请求，网盘 CDN 多是
https，每个请求都重新握手的话光 TLS 就要一两百毫秒。
"""

from __future__ import annotations

import threading
from types import TracebackType

import httpx

#: 每次请求至少取这么多：Matroska 头部的 SeekHead、Tracks、Info 都在开头几十 KB 里
_MIN_FETCH = 64 * 1024


class RemoteRangeFile:
    """只读、可 seek 的远端文件。``size`` 在第一次读之后可用（来自 Content-Range）。"""

    def __init__(self, url: str, *, timeout: float = 15.0, min_fetch: int = _MIN_FETCH) -> None:
        self._url = url
        self._timeout = timeout
        self._min_fetch = min_fetch
        self._pos = 0
        self._block_start = 0
        self._block = b""
        self.size: int | None = None

    def __enter__(self) -> RemoteRangeFile:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()

    def close(self) -> None:
        self._block = b""

    def tell(self) -> int:
        return self._pos

    def seek(self, offset: int, whence: int = 0) -> int:
        if whence == 0:
            self._pos = offset
        elif whence == 1:
            self._pos += offset
        else:
            if self.size is None:
                self._fetch(0, 1)
            assert self.size is not None
            self._pos = self.size + offset
        return self._pos

    def read(self, n: int) -> bytes:
        if n <= 0:
            return b""
        start, end = self._pos, self._pos + n
        block_end = self._block_start + len(self._block)
        if not (self._block_start <= start and end <= block_end):
            self._fetch(start, max(n, self._min_fetch))
        offset = start - self._block_start
        data = self._block[offset : offset + n]
        self._pos += len(data)
        return data

    def pread(self, length: int, offset: int) -> bytes:
        """独立地读 ``[offset, offset + length)``，不动读写位置、不碰块缓存——可多线程并发调用
        （MP4 关键帧样本抽检）。"""
        return self._request(offset, length)

    def _fetch(self, start: int, length: int) -> None:
        if self.size is not None and start >= self.size:
            self._block_start, self._block = start, b""
            return
        self._block = self._request(start, length)
        self._block_start = start

    def _request(self, start: int, length: int) -> bytes:
        headers = {"Range": f"bytes={start}-{start + length - 1}"}
        try:
            with _client().stream("GET", self._url, headers=headers, timeout=self._timeout) as r:
                if r.status_code != 206:
                    raise OSError(f"远端不支持按区间读取（HTTP {r.status_code}）")
                total = (r.headers.get("Content-Range") or "").rpartition("/")[2]
                if total.isdigit():
                    self.size = int(total)
                # 网盘直链常是「签名地址 302 到 CDN」：后续的读直接打最终地址，不再每次绕一圈
                self._url = str(r.url)
                return r.read()[:length]
        except httpx.HTTPError as exc:
            raise OSError(f"远端读取失败：{exc}") from exc


_CLIENT: httpx.Client | None = None
_CLIENT_LOCK = threading.Lock()


def _client() -> httpx.Client:
    """进程内共享的连接池（线程安全）。跟随跳转；代理按环境变量（与 ffmpeg 一致）。"""
    global _CLIENT
    with _CLIENT_LOCK:
        if _CLIENT is None:
            _CLIENT = httpx.Client(
                follow_redirects=True,
                limits=httpx.Limits(max_connections=16, max_keepalive_connections=16),
            )
        return _CLIENT

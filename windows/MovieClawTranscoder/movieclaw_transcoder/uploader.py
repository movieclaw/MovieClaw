"""产物回传：把切好的 init 与片段送回 NAS（docs/design/transcode-latency.md §5）。

渐进式回传与 macOS 转码器同一套做法：``init.mp4`` 整个传；每个片段（0.5 秒）作为它所属分片的
第 ``part`` 块按序传（``?part=N``），NAS 原子地追加进 ``.segNNNNN.m4s.partial``，播放器不必等
一整段（4 秒）转完；下一段的第一个片段到了（或 ffmpeg 正常收尾），这一段补一个收尾块
（``final=1``，可以是空的），NAS 把它改名成正式分片。

某一块传不上去（重试用尽、NAS 回 409 说中间缺了一块）：这一段不再分块，等它转完把内存里攒着的
整段一次传上去——与整段落盘的老路完全一样，NAS 那边的半截随之作废。所以内存里同时只攒一段
（几 MB）。所有上传串行在一个线程里，块的先后不会乱；到 NAS 的连接常驻（keep-alive）：分片
按秒级节奏产出，逐个新建连接会让每次上传都重做 TCP 与 TLS 握手，而这些往返恰好落在起播和
seek 这些最怕延迟的时刻。
"""

from __future__ import annotations

import http.client
import queue
import threading
import time
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass

from .segmenter import FragmentOutput, FragmentSegmenter

#: 这些状态值得重试：NAS 暂时忙、反向代理抖了一下、请求被中途取消
RETRYABLE_STATUS = frozenset({408, 425, 429, 499, 500, 502, 503, 504})
#: 一个请求最多尝试几次；两次之间的退避（秒）。总共约 7.5 秒，能熬过一次 Wi-Fi 重连
MAX_ATTEMPTS = 5
RETRY_DELAYS = (0.5, 1.0, 2.0, 4.0)
REQUEST_TIMEOUT_S = 30.0


@dataclass(frozen=True)
class UploadResult:
    status: int
    attempts: int
    message: str | None = None

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


def split_artifact_url(url: str) -> tuple[str, str] | None:
    """ffmpeg 输出参数里的 NAS 产物地址 → (产物目录地址, query)；不是产物地址返回 None。

    形如 ``https://nas/api/v1/transcode-worker/sessions/<id>/artifacts/stream.mp4?token=…``：
    目录地址去掉末尾的文件名；query 里是只对这一轮任务有效的签名令牌，每次上传原样带上。
    """
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or "/artifacts/" not in parts.path:
        return None
    directory = parts.path[: parts.path.index("/artifacts/") + len("/artifacts")]
    base = urllib.parse.urlunsplit((parts.scheme, parts.netloc, directory, "", ""))
    return base, parts.query


class ArtifactClient:
    """到 NAS 产物端点的一条常驻连接，带重试。只在上传线程里用。"""

    def __init__(
        self,
        base_url: str,
        query: str,
        *,
        cancelled: Callable[[], bool] = lambda: False,
        log: Callable[[str], None] = lambda _message: None,
    ) -> None:
        parts = urllib.parse.urlsplit(base_url)
        self._tls = parts.scheme == "https"
        self._host = parts.hostname or ""
        self._port = parts.port
        self._prefix = parts.path.rstrip("/")
        self._query = query
        self._cancelled = cancelled
        self._log = log
        self._connection: http.client.HTTPConnection | None = None

    def put(
        self, name: str, body: bytes, *, part: int | None = None, final: bool = False
    ) -> UploadResult:
        items = [self._query] if self._query else []
        if part is not None:
            items.append(f"part={part}")
            if final:
                items.append("final=1")
        path = f"{self._prefix}/{urllib.parse.quote(name)}"
        if items:
            path += "?" + "&".join(items)
        headers = {
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(body)),
            "Cache-Control": "no-store",
        }
        status, reason = 0, ""
        for attempt in range(1, MAX_ATTEMPTS + 1):
            if self._cancelled():
                return UploadResult(499, attempt, "上传已取消")
            try:
                connection = self._connect()
                connection.request("PUT", path, body=body, headers=headers)
                response = connection.getresponse()
                response.read()
                status = response.status
                reason = f"NAS 返回 HTTP {status}"
                if response.will_close:
                    self._drop()
            except (OSError, http.client.HTTPException) as exc:
                self._drop()
                status, reason = 502, f"连接 NAS 失败：{exc}"
            if 200 <= status < 300:
                if attempt > 1:
                    self._log(f"产物上传重试成功：{name} 第 {attempt} 次")
                return UploadResult(status, attempt)
            if status not in RETRYABLE_STATUS or attempt == MAX_ATTEMPTS:
                return UploadResult(status, attempt, reason)
            self._log(f"产物上传将重试：{name} 第 {attempt}/{MAX_ATTEMPTS} 次失败（{reason}）")
            time.sleep(RETRY_DELAYS[min(attempt, len(RETRY_DELAYS)) - 1])
        return UploadResult(status, MAX_ATTEMPTS, reason)

    def close(self) -> None:
        self._drop()

    def _connect(self) -> http.client.HTTPConnection:
        if self._connection is None:
            factory = http.client.HTTPSConnection if self._tls else http.client.HTTPConnection
            self._connection = factory(self._host, self._port, timeout=REQUEST_TIMEOUT_S)
        return self._connection

    def _drop(self) -> None:
        if self._connection is not None:
            try:
                self._connection.close()
            finally:
                self._connection = None


class _End:
    """队列里的收尾标记：ffmpeg 正常结束，最后一段补收尾块。"""


@dataclass
class _Segment:
    index: int
    name: str
    next_part: int = 0
    buffer: bytes = b""
    #: 分块传不上去了，转完整段重传
    fallback: bool = False


class ProgressiveUploader:
    """喂进 ffmpeg 写出的字节，切段后按序回传 NAS。``feed`` 在读线程里调，上传在自己的线程里。"""

    def __init__(
        self,
        client: ArtifactClient,
        *,
        segment_seconds: float,
        start_segment: int | None,
        on_abandoned: Callable[[str, int, str], None],
        on_uploaded: Callable[[str], None] = lambda _name: None,
        log: Callable[[str], None] = lambda _message: None,
    ) -> None:
        self._client = client
        self._segmenter = FragmentSegmenter(segment_seconds, start_segment)
        self._on_abandoned = on_abandoned
        #: 回传里程碑（init 传上去、每个分片的第一块传上去）：任务层拿它记起播分段计时
        self._on_uploaded = on_uploaded
        self._log = log
        self._queue: queue.Queue[FragmentOutput | _End | None] = queue.Queue()
        self._cancelled = threading.Event()
        self._thread = threading.Thread(target=self._run, name="artifact-upload", daemon=True)
        self._current: _Segment | None = None

    def start(self) -> None:
        self._thread.start()

    def feed(self, data: bytes) -> str | None:
        """喂进新增字节；格式坏到切不了段时返回原因。"""
        for output in self._segmenter.append(data):
            self._queue.put(output)
        return self._segmenter.failure

    def finish(self, timeout: float = 30.0) -> bool:
        """ffmpeg 正常收尾：最后一段补收尾块，等全部传完。``timeout`` 内没传完返回 False。"""
        self._queue.put(_End())
        self._queue.put(None)
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def cancel(self) -> None:
        """连接断了或任务被叫停：不再上传，也不补收尾块。"""
        self._cancelled.set()
        self._queue.put(None)
        self._client.close()

    # -- 上传线程 -------------------------------------------------------------

    def _run(self) -> None:
        while True:
            item = self._queue.get()
            if item is None or self._cancelled.is_set():
                return
            if isinstance(item, _End):
                if self._current is not None:
                    self._complete(self._current)
                    self._current = None
            elif item.kind == "init":
                self._whole("init.mp4", item.data)
            else:
                self._fragment(item)

    def _fragment(self, output: FragmentOutput) -> None:
        index = output.segment
        assert index is not None
        current = self._current
        if output.starts_segment or current is None or current.index != index:
            if current is not None:
                self._complete(current)
            current = self._current = _Segment(index, f"seg{index:05d}.m4s")
        current.buffer += output.data
        if current.fallback or self._cancelled.is_set():
            return
        result = self._client.put(current.name, output.data, part=current.next_part)
        if result.ok:
            if current.next_part == 0:
                self._on_uploaded(current.name)
            current.next_part += 1
            return
        if not self._cancelled.is_set():
            current.fallback = True
            self._log(
                f"分片分块回传失败，转完后整段重传：{current.name} "
                f"part={current.next_part} status={result.status}"
            )

    def _complete(self, segment: _Segment) -> None:
        """一段转完了：补收尾块；分块那条路走不通就整段重传。"""
        if self._cancelled.is_set():
            return
        if not segment.fallback:
            result = self._client.put(segment.name, b"", part=segment.next_part, final=True)
            if result.ok or self._cancelled.is_set():
                return
        self._whole(segment.name, segment.buffer)

    def _whole(self, name: str, data: bytes) -> None:
        result = self._client.put(name, data)
        if result.ok:
            if name == "init.mp4":
                self._on_uploaded(name)
        elif not self._cancelled.is_set():
            # 重试用尽：交给任务层上报 job.artifact_failed，NAS 按补片台账从这一片重启
            self._on_abandoned(name, result.status, result.message or f"HTTP {result.status}")

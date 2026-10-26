"""播放体验打点：一次播放一条记录（docs/design/playback-qoe.md）。

**为什么要有它**：播放体验的北极星是「无打扰播放率」——一次播放从点下到离开，有没有让用户
等太久、被打断、拿到打了折扣的规格、或者被猜错了音轨字幕。原来的 ``playback_metric`` 只在
播放正常结束时由网页整行上报一份快照，失败的、出画前就退出的、闪退的播放一条都没有，
恰好漏掉了最糟的那一批；起播从请求算起、跳转耗时不上报，「快」也量不准。

这里把一次播放拆成两步落库，**按播放编号（attempt_id）合并**：

1. **开始**（:func:`begin_attempt`）：App 在用户点下时生成编号，随会话请求带上。服务端
   **先回响应、再在后台**建一条 ``status=started`` 的行，记下服务端视角的事实（档位、决策
   原因、转码计划、服务端各段耗时）。写库绝不放在起播路径上——之前「取流接口占满数据库连接池、
   全站卡 30 秒」的事故就出在这条路径上。断线重连、换画质会再开会话，同一个编号只追加会话摘要。
2. **收尾**（:func:`finish_attempt`）：App 离开这次播放时上报完整记录（所有结局都报）。服务端
   合并进同一行，并在这里统一判定派生值：跳转分位、非自愿中断次数、可避免的规格损失、北极星。
   规则只放在服务端一处，App 只报原始事实——规则改了不用改 App，历史记录也能重算。

App 没报结束的行（闪退、被系统杀掉、断网）不会丢：开始后 6 小时仍是 ``started`` 的行由
:func:`sweep_unreported` 标成「未收尾」；App 下次启动补报时照样能合并回来。

**取流统计只在内存里累计**（:class:`ServeTally`）：原文件直出、原盘目录直推的每个 Range
请求按令牌里的播放编号归集请求数、字节、首字节耗时、慢请求与中途断开；转码会话结束时把
自己的摘要交过来。收尾时一次性写进记录，**从不逐请求写库**。

遥测只落本地，绝不外发（硬边界 3）。
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Any

from sqlalchemy import DateTime, bindparam, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import source_text
from movieclaw_db.models import LibraryFile, PlaybackMetric
from movieclaw_db.models.base import utcnow

logger = logging.getLogger(__name__)

#: 本文口径的版本号；旧的网页整行上报是 1。统计只比较同口径的记录
METRIC_VERSION = 2

STATUS_STARTED = "started"
STATUS_FINISHED = "finished"
STATUS_UNREPORTED = "unreported"
STATUS_ABNORMAL = "abnormal"

#: 结局：看完 / 中途退出 / 出画前退出 / 失败 / 异常退出（闪退或被系统杀掉）
OUTCOMES = frozenset({"watched", "exited", "exit_before_start", "failed", "abnormal_exit"})

#: 开始后多久还没收尾就算「未收尾」
UNREPORTED_AFTER = timedelta(hours=6)

# —— 北极星的「打扰」线（playback-qoe.md §1.1）——
STARTUP_DISTURB_MS = 2000
SEEK_DISTURB_MS = 1500
REBUFFER_DISTURB_MS = 500
FREEZE_DISTURB_MS = 1000

#: 首字节超过这个毫秒数的取流请求进「慢请求清单」
SLOW_REQUEST_MS = 1000

# —— 上报的上限：超限截断并记一行警告，不拒收 ——
_MAX_MS = 24 * 3600 * 1000
_MAX_COUNT = 100_000
_MAX_LIST = {"seeks": 50, "interruptions": 50, "switches": 50, "behaviors": 50, "timeline": 200}
_MAX_DETAIL_BYTES = 256 * 1024
_MAX_LOG_TAIL = 32 * 1024
_MAX_TEXT = 64


# ---------------------------------------------------------------------------
# 取流统计（内存）
# ---------------------------------------------------------------------------


@dataclass
class ServeTally:
    """一次播放在服务端取流侧的累计。只在内存里，收尾时一次性写进记录。"""

    requests: int = 0
    bytes: int = 0
    disconnects: int = 0
    #: 每个请求从进来到第一块数据读出的毫秒数（上限 2 万个，够一部三小时 UHD 的 8 MB 分块）
    first_byte_ms: list[int] = field(default_factory=list)
    #: 慢请求清单：(距第一个请求的秒数, 首字节毫秒, 总毫秒, 字节)，最多 20 条
    slow: list[tuple[float, int, int, int]] = field(default_factory=list)
    #: 转码会话结束时交来的摘要（最多 10 个）
    transcode: list[dict[str, Any]] = field(default_factory=list)
    first_seen: float = field(default_factory=time.monotonic)
    last_seen: float = field(default_factory=time.monotonic)

    def summary(self) -> dict[str, Any]:
        ordered = sorted(self.first_byte_ms)
        return {
            "requests": self.requests,
            "bytes": self.bytes,
            "disconnects": self.disconnects,
            "first_byte_p50_ms": percentile(ordered, 0.50),
            "first_byte_p90_ms": percentile(ordered, 0.90),
            "first_byte_max_ms": ordered[-1] if ordered else None,
            "slow": [
                {"at_s": round(at, 1), "first_byte_ms": fb, "total_ms": total, "bytes": size}
                for at, fb, total, size in self.slow
            ],
            "transcode": list(self.transcode),
        }


_serve: dict[str, ServeTally] = {}
_MAX_FIRST_BYTE_SAMPLES = 20_000
_MAX_SLOW = 20
_MAX_TRANSCODE = 10
#: 一次播放的取流统计闲置多久就丢弃（App 没报结束、也没有新请求）
_SERVE_IDLE_S = 3600.0


def _tally(attempt_id: str) -> ServeTally:
    tally = _serve.get(attempt_id)
    if tally is None:
        tally = _serve[attempt_id] = ServeTally()
    tally.last_seen = time.monotonic()
    return tally


class ServeProbe:
    """一个取流请求的计时器：请求进来时建，读出第一块时 :meth:`first_chunk`，结束时 :meth:`finish`。

    由 ``DisconnectAwareFileResponse`` 在发送循环里调用，必须同步、近零开销。
    """

    __slots__ = ("_attempt_id", "_started", "_first_byte_ms")

    def __init__(self, attempt_id: str) -> None:
        self._attempt_id = attempt_id
        self._started = time.perf_counter()
        self._first_byte_ms: int | None = None

    def first_chunk(self) -> None:
        if self._first_byte_ms is None:
            self._first_byte_ms = int((time.perf_counter() - self._started) * 1000)

    def finish(self, bytes_sent: int, *, disconnected: bool) -> None:
        total_ms = int((time.perf_counter() - self._started) * 1000)
        tally = _tally(self._attempt_id)
        tally.requests += 1
        tally.bytes += bytes_sent
        if disconnected:
            tally.disconnects += 1
        if self._first_byte_ms is not None:
            if len(tally.first_byte_ms) < _MAX_FIRST_BYTE_SAMPLES:
                tally.first_byte_ms.append(self._first_byte_ms)
            if self._first_byte_ms >= SLOW_REQUEST_MS and len(tally.slow) < _MAX_SLOW:
                at = time.monotonic() - tally.first_seen
                tally.slow.append((at, self._first_byte_ms, total_ms, bytes_sent))


def serve_probe(attempt_id: str | None) -> ServeProbe | None:
    """令牌里带了播放编号才计时；旧令牌、网页、Jellyfin 客户端不计。"""
    return ServeProbe(attempt_id) if attempt_id else None


def note_transcode_session(attempt_id: str | None, summary: dict[str, Any]) -> None:
    """转码会话结束时把自己的摘要交给这次播放（首片、分片等待、超时、重启、错误）。"""
    if not attempt_id:
        return
    tally = _tally(attempt_id)
    if len(tally.transcode) < _MAX_TRANSCODE:
        tally.transcode.append(summary)


def take_serve_stats(attempt_id: str) -> dict[str, Any] | None:
    """取走一次播放的取流统计（收尾时调用一次）。没有请求过就返回 None。"""
    tally = _serve.pop(attempt_id, None)
    return tally.summary() if tally is not None else None


def sweep_serve_stats(now: float | None = None) -> int:
    """丢弃闲置太久的取流统计（App 没报结束，也不会再有请求）。返回丢弃的条数。"""
    now = time.monotonic() if now is None else now
    stale = [key for key, tally in _serve.items() if now - tally.last_seen > _SERVE_IDLE_S]
    for key in stale:
        _serve.pop(key, None)
    return len(stale)


# ---------------------------------------------------------------------------
# 判定规则（只放服务端一处）
# ---------------------------------------------------------------------------

#: 老格式容器：多半走软件解码通路
_LEGACY_CONTAINERS = frozenset({"avi", "wmv", "rmvb", "rm", "mpg", "mpeg", "flv", "vob"})

# 片源类型的展示名：需要翻译的给消息键，规格名本身（DVD/HDR/4K…）原样
SOURCE_CLASS_LABELS = {
    "uhd_bluray": "player.qoe.source.uhdBluray",
    "bluray": "player.qoe.source.bluray",
    "dvd": "DVD",
    "legacy": "player.qoe.source.legacy",
    "dolby_vision": "player.qoe.source.dolbyVision",
    "hdr": "HDR",
    "4k": "4K",
    "1080p": "1080p",
    "720p": "720p",
    "sd": "player.qoe.source.sd",
    "unknown": "player.qoe.source.unknown",
}


def _label(labels: dict[str, str], key: str, render=t) -> str:
    """码 → 展示名（按请求语言）；不认识的码原样给。"""
    label = labels.get(key, key)
    return render(label) if label.startswith("player.qoe.") else label


def source_class(file: LibraryFile | None) -> str:
    """片源类型（分组用）：原盘 / DVD 先分，其次老格式，再按 HDR 与分辨率。"""
    if file is None:
        return "unknown"
    container = (file.container or "").lower()
    resolution = (file.resolution or "").lower()
    uhd = resolution.startswith("2160")
    if container == "dvd":
        return "dvd"
    if container in {"bluray", "iso"}:
        if uhd:
            return "uhd_bluray"
        # ISO 可能是 DVD 镜像：台账分辨率低于 720p 的按 DVD 算
        if container == "iso" and resolution in {"480p", "576p", "540p", "536p"}:
            return "dvd"
        return "bluray"
    if container in _LEGACY_CONTAINERS:
        return "legacy"
    hdr = (file.hdr or "").lower()
    if "dolby" in hdr:
        return "dolby_vision"
    if hdr:
        return "hdr"
    if uhd:
        return "4k"
    if resolution.startswith("1080"):
        return "1080p"
    if resolution.startswith("720"):
        return "720p"
    return "sd" if resolution else "unknown"


#: 真正「听得出无损」的音频输出；蓝牙本身就是有损传输
_LOSSLESS_ROUTES = frozenset({"wired", "hdmi", "airplay"})
#: 本身就无损的输出编码
_LOSSLESS_CODECS = frozenset({"flac", "alac", "pcm", "lpcm", "truehd", "mlp"})


def avoidable_losses(delivery: dict[str, Any] | None) -> list[str] | None:
    """规格损失规则表（playback-qoe.md §5.6）：以当前设备 + 当前音频输出能呈现的最好效果为准。

    返回可避免的损失列表；没有规格快照返回 None（不参与统计）。设备本来就做不到的（如 iPhone
    解不了杜比视界 P7 的完整增强层）、输出听不出差别的（经蓝牙输出时无损转有损）、用户主动限画质
    的，都不算。
    """
    if not delivery:
        return None
    losses: list[str] = []
    user_capped = bool(delivery.get("user_capped"))
    route = delivery.get("route") or ""
    if route == "server_transcode" and not user_capped:
        losses.append("server_transcode")

    video = delivery.get("video") or {}
    display_hdr = (delivery.get("output") or {}).get("display_hdr")
    source_format = (video.get("source_format") or "").lower()
    output_format = (video.get("output_format") or "").lower()
    if display_hdr and not user_capped and source_format and output_format:
        if source_format != "sdr" and output_format == "sdr":
            losses.append("hdr_lost")
        elif source_format == "dolbyvision" and output_format != "dolbyvision":
            losses.append("dolby_vision_lost")

    audio = delivery.get("audio") or {}
    audio_route = (delivery.get("output") or {}).get("audio_route") or ""
    if audio.get("delivery") in {"muted", "dropped"}:
        losses.append("audio_dropped")
    output_codec = (audio.get("output_codec") or "").lower()
    if (
        audio.get("source_lossless")
        and audio_route in _LOSSLESS_ROUTES
        and output_codec
        and output_codec not in _LOSSLESS_CODECS
    ):
        losses.append("lossless_lost")
    # 源是 E-AC-3 全景声（JOC）时原样送出做得到；TrueHD 全景声在 iOS 上没有透传路径，算设备上限
    source_codec = (audio.get("source_codec") or "").lower()
    if (
        audio.get("source_atmos")
        and audio.get("atmos_kept") is False
        and source_codec in {"eac3", "ec-3"}
    ):
        losses.append("atmos_lost")

    subtitle = delivery.get("subtitle") or {}
    if subtitle.get("mode") == "burned" and not user_capped:
        losses.append("subtitle_burned")
    return losses


def interruption_count(interruptions: list[dict[str, Any]]) -> int:
    """按北极星口径数非自愿中断：卡顿 ≥ 0.5 秒、冻帧 ≥ 1 秒、报错、闪退。

    断线重连本身用户看不见（缓冲撑住了），撑不住时会表现为卡顿，所以不单独计。
    """
    count = 0
    for item in interruptions:
        kind = item.get("kind")
        ms = _int(item.get("ms")) or 0
        if (
            (kind == "rebuffer" and ms >= REBUFFER_DISTURB_MS)
            or (kind == "freeze" and ms >= FREEZE_DISTURB_MS)
            or kind in {"error", "crash"}
        ):
            count += 1
    return count


def disturb_reasons(row: PlaybackMetric, *, longest_seek_wait_ms: int = 0) -> list[str]:
    """这次播放打扰了用户的原因；空列表 = 无打扰（playback-qoe.md §1.1）。

    ``longest_seek_wait_ms`` 是用户在任何一次跳转上等过的最长时间，**不只算落地的**：等了 10 秒
    还没出画、用户放弃又跳了一次（被取代）、或者干脆退出（离开时还没落地），都是最糟的跳转体验，
    只看落地的会漏掉它们。"""
    reasons: list[str] = []
    if row.outcome in {"failed", "exit_before_start"}:
        reasons.append("no_picture" if row.outcome == "exit_before_start" else "failed")
    elif row.outcome == "abnormal_exit":
        reasons.append("abnormal_exit")
    if row.first_frame_ms is not None and row.first_frame_ms > STARTUP_DISTURB_MS:
        reasons.append("startup_slow")
    seek_max = max(row.seek_in_max_ms or 0, row.seek_out_max_ms or 0, longest_seek_wait_ms)
    if seek_max > SEEK_DISTURB_MS:
        reasons.append("seek_slow")
    if row.interrupt_count > 0:
        reasons.append("interrupted")
    if row.avoidable_loss:
        reasons.append("avoidable_loss")
    if row.misguess_count > 0:
        reasons.append("misguess")
    return reasons


REASON_LABELS = {
    "no_picture": "player.qoe.reason.noPicture",
    "failed": "player.qoe.reason.failed",
    "abnormal_exit": "player.qoe.reason.abnormalExit",
    "startup_slow": "player.qoe.reason.startupSlow",
    "seek_slow": "player.qoe.reason.seekSlow",
    "interrupted": "player.qoe.reason.interrupted",
    "avoidable_loss": "player.qoe.reason.avoidableLoss",
    "misguess": "player.qoe.reason.misguess",
}
NETWORK_LABELS = {
    "home": "player.qoe.network.home",
    "away": "player.qoe.network.away",
    "unknown": "player.qoe.network.unknown",
}


# ---------------------------------------------------------------------------
# 开始与收尾
# ---------------------------------------------------------------------------


async def begin_attempt(
    session: AsyncSession,
    *,
    attempt_id: str,
    member_id: int,
    file: LibraryFile | None,
    tier: int,
    client: str,
    server: dict[str, Any],
) -> None:
    """服务端视角的「已开始」：会话接口响应之后在后台调用。

    同一个编号再来（断线重连、原位重开、换画质都会再开会话）只追加会话摘要、更新档位，
    不覆盖 App 已经报过的内容。App 的收尾先到（极少见：后台任务排队时 App 已经离开）也照样合并。
    """
    row = await _row(session, attempt_id)
    if row is None:
        row = PlaybackMetric(
            attempt_id=attempt_id,
            member_id=member_id,
            library_file_id=file.id if file is not None else None,
            media_item_id=file.media_item_id if file is not None else None,
            season_number=file.season_number if file is not None else None,
            episode_number=file.episode_number if file is not None else None,
            tier=tier,
            client=client,
            status=STATUS_STARTED,
            metric_version=METRIC_VERSION,
            source_class=source_class(file),
            detail={"server": {"sessions": [server]}},
        )
        session.add(row)
    else:
        detail = dict(row.detail or {})
        server_block = dict(detail.get("server") or {})
        sessions = list(server_block.get("sessions") or [])
        if len(sessions) < _MAX_TRANSCODE:
            sessions.append(server)
        server_block["sessions"] = sessions
        detail["server"] = server_block
        row.detail = detail
        if row.status == STATUS_STARTED:
            row.tier = tier
        row.updated_at = utcnow()
    await session.commit()


@dataclass
class FinishReport:
    """App 收尾时报上来的一次播放（字段含义见 ``PlaybackMetricPayload``）。"""

    attempt_id: str
    outcome: str
    tier: int
    library_file_id: int | None = None
    media_item_id: int | None = None
    season_number: int | None = None
    episode_number: int | None = None
    degraded_from: int | None = None
    engine: str = ""
    hw_backend: str = ""
    origin: str = ""
    client: str = ""
    lab_scenario: str = ""
    route: str = ""
    network_class: str = ""
    interface: str = ""
    app_version: str = ""
    first_frame_ms: int | None = None
    playing_ms: int | None = None
    user_wait_ms: int = 0
    rebuffer_ms: int = 0
    rebuffer_count: int = 0
    seek_count: int = 0
    dropped_frames: int | None = None
    total_frames: int | None = None
    watched_ms: int = 0
    error_kind: str = ""
    error_category: str = ""
    error_stage: str = ""
    detail: dict[str, Any] = field(default_factory=dict)
    log_tail: str = ""


async def finish_attempt(
    session: AsyncSession, *, member_id: int, report: FinishReport
) -> PlaybackMetric:
    """App 的收尾：合并进同一行，判定派生值，写一行摘要日志。"""
    report = _sanitize(report)
    row = await _row(session, report.attempt_id)
    if row is None:
        # 服务端的「已开始」还没写（后台任务排队中），或这次播放在协商阶段就失败了、根本没开成会话
        row = PlaybackMetric(
            attempt_id=report.attempt_id,
            member_id=member_id,
            tier=report.tier,
            metric_version=METRIC_VERSION,
        )
        session.add(row)
    file = (
        await session.get(LibraryFile, report.library_file_id) if report.library_file_id else None
    )

    for name in (
        "outcome", "degraded_from", "engine", "hw_backend", "origin", "lab_scenario", "route",
        "network_class", "interface", "app_version", "first_frame_ms", "playing_ms",
        "user_wait_ms", "rebuffer_ms", "rebuffer_count", "seek_count", "dropped_frames",
        "total_frames", "watched_ms", "error_kind", "error_category", "error_stage",
    ):
        setattr(row, name, getattr(report, name))
    row.client = report.client or row.client
    if report.tier >= 0 or row.tier is None:
        row.tier = report.tier
    for name in ("library_file_id", "media_item_id", "season_number", "episode_number"):
        value = getattr(report, name)
        if value is not None:
            setattr(row, name, value)
    if file is not None or not row.source_class:
        row.source_class = source_class(file)
    row.metric_version = METRIC_VERSION
    row.status = STATUS_ABNORMAL if report.outcome == "abnormal_exit" else STATUS_FINISHED
    row.ended_at = utcnow()
    row.updated_at = row.ended_at
    row.log_tail = report.log_tail

    # 明细：App 报的原样合并；服务端自己的块（会话摘要、取流统计）保留
    detail = dict(report.detail)
    previous = dict(row.detail or {})
    server_block = dict(previous.get("server") or {})
    serve = take_serve_stats(report.attempt_id)
    if serve is not None:
        server_block["serve"] = serve
    if server_block:
        detail["server"] = server_block

    seeks = [s for s in detail.get("seeks") or [] if isinstance(s, dict)]
    _apply_seek_stats(row, seeks)
    interruptions = [i for i in detail.get("interruptions") or [] if isinstance(i, dict)]
    row.freeze_count = sum(1 for i in interruptions if i.get("kind") == "freeze")
    row.freeze_ms = sum(_int(i.get("ms")) or 0 for i in interruptions if i.get("kind") == "freeze")
    row.reconnect_count = sum(1 for i in interruptions if i.get("kind") == "reconnect")
    row.reconnect_ms = sum(
        _int(i.get("ms")) or 0 for i in interruptions if i.get("kind") == "reconnect"
    )
    row.interrupt_count = interruption_count(interruptions)
    behaviors = [b for b in detail.get("behaviors") or [] if isinstance(b, dict)]
    row.misguess_count = sum(1 for b in behaviors if b.get("misguess"))
    losses = avoidable_losses(detail.get("delivery"))
    row.avoidable_loss = None if losses is None else bool(losses)
    waited = [
        _int(s.get("ms")) or 0
        for s in seeks
        if s.get("outcome") in {"landed", "superseded", "abandoned", "failed", "timeout"}
    ]
    reasons = disturb_reasons(row, longest_seek_wait_ms=max(waited, default=0))
    row.undisturbed = not reasons
    detail["judgement"] = {"losses": losses, "reasons": reasons}
    row.detail = detail
    await session.commit()
    await session.refresh(row)
    logger.info("%s", _summary_line(row, reasons, losses))
    return row


async def sweep_unreported(session: AsyncSession) -> int:
    """开始后 6 小时仍没收尾的记录标成「未收尾」。App 之后补报照样能合并回来。"""
    cutoff = utcnow() - UNREPORTED_AFTER
    result = await session.execute(
        update(PlaybackMetric)
        .where(PlaybackMetric.status == STATUS_STARTED, PlaybackMetric.created_at < cutoff)
        .values(status=STATUS_UNREPORTED, updated_at=utcnow())
    )
    await session.commit()
    return result.rowcount or 0


async def purge_expired(session: AsyncSession, *, days: int) -> int:
    """按时间清理：保留最近 ``days`` 天。"""
    cutoff = utcnow() - timedelta(days=max(1, days))
    result = await session.execute(
        PlaybackMetric.__table__.delete().where(PlaybackMetric.created_at < cutoff)
    )
    await session.commit()
    return result.rowcount or 0


async def get_attempt(session: AsyncSession, attempt_id: str) -> PlaybackMetric | None:
    return await _row(session, attempt_id)


# ---------------------------------------------------------------------------
# 统计
# ---------------------------------------------------------------------------

#: 分组维度 → 列
GROUP_COLUMNS = {
    "source_class": PlaybackMetric.source_class,
    "network_class": PlaybackMetric.network_class,
    "route": PlaybackMetric.route,
    "app_version": PlaybackMetric.app_version,
    "client": PlaybackMetric.client,
    "interface": PlaybackMetric.interface,
}
#: 样本少于这个数的分组不算分位数，直接列明细
MIN_SAMPLES = 30


async def qoe_stats(
    session: AsyncSession,
    *,
    days: int,
    group_by: str | None,
    include_lab: bool,
    worst: int = 20,
) -> dict[str, Any]:
    """一段时间内的播放体验统计（playback-qoe.md §5.5）。只看口径 2 的记录。"""
    since = utcnow() - timedelta(days=max(1, days))
    conditions = [
        PlaybackMetric.metric_version >= METRIC_VERSION,
        PlaybackMetric.created_at >= since,
    ]
    if not include_lab:
        conditions.append(PlaybackMetric.lab_scenario == "")
    rows = list(
        (await session.execute(select(*_COMPACT_COLUMNS).where(*conditions))).mappings()
    )
    seek_rows = await _seek_samples(session, since=since, include_lab=include_lab)
    reason_counts = await _reason_counts(session, since=since, include_lab=include_lab)

    group_column = group_by if group_by in GROUP_COLUMNS else None
    groups: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        key = str(row[group_column]) if group_column else "all"
        groups.setdefault(key or "unknown", []).append(dict(row))
    seeks_by_attempt: dict[str, list[tuple[int, bool]]] = {}
    for attempt_id, ms, buffered in seek_samples_iter(seek_rows):
        seeks_by_attempt.setdefault(attempt_id, []).append((ms, buffered))

    overall = _group_stats(rows=[dict(r) for r in rows], seeks=seeks_by_attempt)
    grouped = [
        {"key": key, "label": _group_label(group_column, key),
         **_group_stats(rows=members, seeks=seeks_by_attempt)}
        for key, members in sorted(groups.items(), key=lambda item: -len(item[1]))
    ] if group_column else []
    worst_rows = sorted(
        (dict(r) for r in rows if r["undisturbed"] is False),
        key=_severity,
        reverse=True,
    )[: max(0, worst)]
    return {
        "days": days,
        "since": since.isoformat(),
        "include_lab": include_lab,
        "group_by": group_column,
        "overall": overall,
        "groups": grouped,
        "reasons": [
            {"reason": reason, "label": _label(REASON_LABELS, reason), "count": count}
            for reason, count in sorted(reason_counts.items(), key=lambda item: -item[1])
        ],
        "worst": [_compact(r) for r in worst_rows],
    }


_COMPACT_COLUMNS = (
    PlaybackMetric.attempt_id,
    PlaybackMetric.created_at,
    PlaybackMetric.status,
    PlaybackMetric.outcome,
    PlaybackMetric.client,
    PlaybackMetric.origin,
    PlaybackMetric.lab_scenario,
    PlaybackMetric.media_item_id,
    PlaybackMetric.season_number,
    PlaybackMetric.episode_number,
    PlaybackMetric.library_file_id,
    PlaybackMetric.tier,
    PlaybackMetric.degraded_from,
    PlaybackMetric.source_class,
    PlaybackMetric.route,
    PlaybackMetric.network_class,
    PlaybackMetric.interface,
    PlaybackMetric.app_version,
    PlaybackMetric.first_frame_ms,
    PlaybackMetric.playing_ms,
    PlaybackMetric.seek_in_max_ms,
    PlaybackMetric.seek_out_max_ms,
    PlaybackMetric.interrupt_count,
    PlaybackMetric.rebuffer_ms,
    PlaybackMetric.freeze_ms,
    PlaybackMetric.watched_ms,
    PlaybackMetric.error_kind,
    PlaybackMetric.avoidable_loss,
    PlaybackMetric.misguess_count,
    PlaybackMetric.undisturbed,
)


def _group_stats(
    *, rows: list[dict[str, Any]], seeks: dict[str, list[tuple[int, bool]]]
) -> dict[str, Any]:
    attempts = len(rows)
    reported = [r for r in rows if r["status"] in {STATUS_FINISHED, STATUS_ABNORMAL}]
    judged = [r for r in reported if r["undisturbed"] is not None]
    small = attempts < MIN_SAMPLES
    first_frames = sorted(r["first_frame_ms"] for r in reported if r["first_frame_ms"] is not None)
    samples = [pair for r in reported for pair in seeks.get(r["attempt_id"] or "", [])]
    in_buffer = sorted(ms for ms, buffered in samples if buffered)
    out_buffer = sorted(ms for ms, buffered in samples if not buffered)
    watched_ms = sum(r["watched_ms"] or 0 for r in reported)
    interrupts = sum(r["interrupt_count"] or 0 for r in reported)
    loss_judged = [r for r in reported if r["avoidable_loss"] is not None]

    def pct(values: list[int]) -> dict[str, int | None] | None:
        if small or not values:
            return None
        return {
            "p50": percentile(values, 0.50),
            "p90": percentile(values, 0.90),
            "p99": percentile(values, 0.99),
            "count": len(values),
        }

    def ratio(numerator: int, denominator: int) -> float | None:
        return round(numerator / denominator, 4) if denominator and not small else None

    return {
        "attempts": attempts,
        "reported": len(reported),
        "unreported": sum(1 for r in rows if r["status"] == STATUS_UNREPORTED),
        "in_progress": sum(1 for r in rows if r["status"] == STATUS_STARTED),
        "small_sample": small,
        # 北极星
        "undisturbed_rate": ratio(sum(1 for r in judged if r["undisturbed"]), len(judged)),
        # 快
        "first_frame_ms": pct(first_frames),
        "seek_in_buffer_ms": pct(in_buffer),
        "seek_out_buffer_ms": pct(out_buffer),
        # 稳
        "interrupts_per_hour": (
            round(interrupts / (watched_ms / 3_600_000), 3) if watched_ms and not small else None
        ),
        "failure_rate": ratio(sum(1 for r in reported if r["outcome"] == "failed"), len(reported)),
        "exit_before_start_rate": ratio(
            sum(1 for r in reported if r["outcome"] == "exit_before_start"), len(reported)
        ),
        "abnormal_exit_rate": ratio(
            sum(1 for r in reported if r["outcome"] == "abnormal_exit"), len(reported)
        ),
        # 对
        "avoidable_loss_rate": ratio(
            sum(1 for r in loss_judged if r["avoidable_loss"]), len(loss_judged)
        ),
        "misguess_rate": ratio(sum(1 for r in reported if r["misguess_count"]), len(reported)),
        # 样本太少时直接列明细，不编分位数
        "samples": [_compact(r) for r in rows] if small else None,
    }


def _json_where(since, include_lab: bool):
    """两条 json_each 原生查询共用的条件（与 :func:`qoe_stats` 的 ORM 条件一致）。"""
    where = "metric_version >= :version AND created_at >= :since"
    if not include_lab:
        where += " AND lab_scenario = ''"
    params = {"version": METRIC_VERSION, "since": since}
    return where, params


async def _seek_samples(
    session: AsyncSession, *, since, include_lab: bool
) -> list[tuple[str, int, int]]:
    """所有落地跳转的 (编号, 毫秒, 是否缓冲内)。

    用 SQLite 的 json_each 在 C 层展开，不把整份明细读进 Python。"""
    where, params = _json_where(since, include_lab)
    statement = text(
        "SELECT playback_metric.attempt_id, json_extract(seek.value, '$.ms'), "
        "json_extract(seek.value, '$.buffered') "
        "FROM playback_metric, json_each(playback_metric.detail, '$.seeks') AS seek "
        f"WHERE {where} AND json_extract(seek.value, '$.outcome') = 'landed'"
    ).bindparams(bindparam("since", type_=DateTime()))
    return [tuple(r) for r in (await session.execute(statement, params)).all()]


def seek_samples_iter(rows: list[tuple[str, Any, Any]]):
    for attempt_id, ms, buffered in rows:
        value = _int(ms)
        if attempt_id and value is not None:
            yield attempt_id, value, bool(buffered)


async def _reason_counts(session: AsyncSession, *, since, include_lab: bool) -> dict[str, int]:
    """打扰原因的帕累托：按原因数播放次数。"""
    where, params = _json_where(since, include_lab)
    statement = text(
        "SELECT reason.value, COUNT(*) FROM playback_metric, "
        "json_each(playback_metric.detail, '$.judgement.reasons') AS reason "
        f"WHERE {where} GROUP BY reason.value"
    ).bindparams(bindparam("since", type_=DateTime()))
    return {str(k): int(v) for k, v in (await session.execute(statement, params)).all()}


def _compact(row: dict[str, Any]) -> dict[str, Any]:
    created = row.get("created_at")
    return {
        "attempt_id": row.get("attempt_id"),
        "created_at": created.isoformat() if created is not None else None,
        "status": row.get("status"),
        "outcome": row.get("outcome"),
        "client": row.get("client"),
        "media_item_id": row.get("media_item_id"),
        "season_number": row.get("season_number"),
        "episode_number": row.get("episode_number"),
        "library_file_id": row.get("library_file_id"),
        "tier": row.get("tier"),
        "source_class": row.get("source_class"),
        "route": row.get("route"),
        "network_class": row.get("network_class"),
        "first_frame_ms": row.get("first_frame_ms"),
        "seek_max_ms": max(row.get("seek_in_max_ms") or 0, row.get("seek_out_max_ms") or 0) or None,
        "interrupt_count": row.get("interrupt_count"),
        "error_kind": row.get("error_kind") or None,
        "avoidable_loss": row.get("avoidable_loss"),
        "misguess_count": row.get("misguess_count"),
        "undisturbed": row.get("undisturbed"),
    }


def _severity(row: dict[str, Any]) -> tuple[int, int]:
    """最差的排前面：失败 / 异常退出 / 出画前退出 > 中断 > 其余；同级按最长的等待。"""
    grave = 3 if row.get("outcome") in {"failed", "abnormal_exit", "exit_before_start"} else 0
    grave += 2 if (row.get("interrupt_count") or 0) > 0 else 0
    waited = max(
        row.get("first_frame_ms") or 0,
        row.get("seek_in_max_ms") or 0,
        row.get("seek_out_max_ms") or 0,
    )
    return grave, waited


def _group_label(column: str | None, key: str) -> str:
    if column == "source_class":
        return _label(SOURCE_CLASS_LABELS, key)
    if column == "network_class":
        return _label(NETWORK_LABELS, key)
    return key


# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------


async def _row(session: AsyncSession, attempt_id: str) -> PlaybackMetric | None:
    return (
        await session.execute(select(PlaybackMetric).where(PlaybackMetric.attempt_id == attempt_id))
    ).scalar_one_or_none()


def _apply_seek_stats(row: PlaybackMetric, seeks: list[dict[str, Any]]) -> None:
    landed = [s for s in seeks if s.get("outcome") == "landed" and _int(s.get("ms")) is not None]
    inside = sorted(_int(s["ms"]) for s in landed if s.get("buffered"))
    outside = sorted(_int(s["ms"]) for s in landed if not s.get("buffered"))
    row.seek_in_count = len(inside)
    row.seek_in_p90_ms = percentile(inside, 0.90)
    row.seek_in_max_ms = inside[-1] if inside else None
    row.seek_out_count = len(outside)
    row.seek_out_p90_ms = percentile(outside, 0.90)
    row.seek_out_max_ms = outside[-1] if outside else None


def _sanitize(report: FinishReport) -> FinishReport:
    """上报校验：数值夹到上下界、枚举不认识的清空、列表与明细有大小上限。超限截断并警告，不拒收。"""
    trimmed: list[str] = []
    if report.outcome not in OUTCOMES:
        # i18n-ignore: QoE summary log line
        trimmed.append(f"结局 {report.outcome!r}")
        report.outcome = "exited"
    for name in ("first_frame_ms", "playing_ms", "user_wait_ms", "rebuffer_ms", "watched_ms"):
        value = getattr(report, name)
        if value is not None:
            setattr(report, name, max(0, min(_MAX_MS, int(value))))
    for name in ("rebuffer_count", "seek_count", "dropped_frames", "total_frames"):
        value = getattr(report, name)
        if value is not None:
            setattr(report, name, max(0, min(_MAX_COUNT * 1000, int(value))))
    for name in (
        "engine", "hw_backend", "origin", "client", "lab_scenario", "route", "network_class",
        "interface", "app_version", "error_kind", "error_category", "error_stage",
    ):
        setattr(report, name, (getattr(report, name) or "")[:_MAX_TEXT])
    detail = dict(report.detail) if isinstance(report.detail, dict) else {}
    for key, limit in _MAX_LIST.items():
        items = detail.get(key)
        if isinstance(items, list) and len(items) > limit:
            # i18n-ignore: QoE summary log line
            trimmed.append(f"{key} {len(items)} 条")
            detail[key] = items[:limit]
    if len(json.dumps(detail, ensure_ascii=False, default=str)) > _MAX_DETAIL_BYTES:
        # i18n-ignore: QoE summary log line
        trimmed.append("明细超过 256 KB，丢掉时间线")
        detail.pop("timeline", None)
    report.detail = detail
    if len(report.log_tail) > _MAX_LOG_TAIL:
        # i18n-ignore: QoE summary log line
        trimmed.append("日志尾巴超过 32 KB")
        report.log_tail = report.log_tail[-_MAX_LOG_TAIL:]
    if trimmed:
        logger.warning(
            "播放记录上报超出上限已截断（attempt=%s）：%s", report.attempt_id, "；".join(trimmed)
        )
    return report


def _summary_line(row: PlaybackMetric, reasons: list[str], losses: list[str] | None) -> str:
    """收尾时的一行摘要：用户说「刚才那次不对劲」时，按编号在日志里一搜就是这一行。"""
    outcome = {
        # i18n-ignore: QoE summary log line
        "watched": "看完", "exited": "中途退出", "exit_before_start": "出画前退出",
        # i18n-ignore: QoE summary log line
        "failed": "失败", "abnormal_exit": "异常退出",
    # i18n-ignore: QoE summary log line
    }.get(row.outcome, row.outcome or "未知")
    seeks = row.seek_in_count + row.seek_out_count
    source = _label(SOURCE_CLASS_LABELS, row.source_class or "-", source_text)
    parts = [
        # i18n-ignore: QoE summary log line
        f"播放记录 attempt={row.attempt_id} 结局={outcome}",
        # i18n-ignore: QoE summary log line
        f"档 {row.tier} {row.route or row.engine or '-'} {source}",
        # i18n-ignore: QoE summary log line
        f"首帧 {row.first_frame_ms} 毫秒" if row.first_frame_ms is not None else "未出画",
        (
            # i18n-ignore: QoE summary log line
            f"跳转 {seeks} 次（缓冲内最长 {row.seek_in_max_ms or 0}、"
            # i18n-ignore: QoE summary log line
            f"缓冲外最长 {row.seek_out_max_ms or 0} 毫秒）"
            if seeks
            # i18n-ignore: QoE summary log line
            else "无跳转"
        ),
        # i18n-ignore: QoE summary log line
        f"中断 {row.interrupt_count} 次（卡顿 {row.rebuffer_count} 次 {row.rebuffer_ms} 毫秒、"
        # i18n-ignore: QoE summary log line
        f"冻帧 {row.freeze_count} 次）",
        # i18n-ignore: QoE summary log line
        f"规格损失 {'、'.join(losses)}" if losses else "规格无损",
        # i18n-ignore: QoE summary log line
        f"猜错 {row.misguess_count} 次" if row.misguess_count else "未猜错",
        # i18n-ignore: QoE summary log line
        f"观看 {row.watched_ms // 1000} 秒",
        # i18n-ignore: QoE summary log line
        "无打扰"
        if not reasons
        # i18n-ignore: QoE summary log line
        else "打扰：" + "、".join(_label(REASON_LABELS, r, source_text) for r in reasons),
    ]
    if row.error_kind:
        category, stage = row.error_category or "-", row.error_stage or "-"
        # i18n-ignore: QoE summary log line
        parts.append(f"错误 {row.error_kind}（{category}，{stage}）")
    if row.lab_scenario:
        # i18n-ignore: QoE summary log line
        parts.append(f"实验室 {row.lab_scenario}")
    return " · ".join(parts)


def _int(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def percentile(ordered: list[int], q: float) -> int | None:
    """已排序序列的分位数（最近秩法）。空序列返回 None，不编数字。"""
    if not ordered:
        return None
    index = min(len(ordered) - 1, max(0, round(q * (len(ordered) - 1))))
    return ordered[index]


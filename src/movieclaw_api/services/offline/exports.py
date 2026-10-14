"""离线下载的转码导出（docs/design/offline-download.md §5.3）。

App 选了 1080p / 720p / 480p 下载时，服务器把整片转成一个分片化 MP4，手机**边转边下**：
下载请求一到就从文件开头发起，跟着 ffmpeg 的输出往后发，转完发完才正常结束。这样「睡前
点下一整季、锁屏放着」也能下完——先转完再下的话，转完时 App 多半在后台，发不起下载。

形态与片段预切同一路数：进程内单路队列干活，状态落在每个导出自己的目录里
（``<根>/<导出号>/meta.json``），服务重启后没转完的重新排队、换一个代号从头转（已转过的
分片多半还在转码缓存里，不必真重转）。

**转码走播放的会话层**：导出就是一个「只下载、不看」的 VOD 会话，按顺序要分片、拿到就接到
文件后面。挑执行者（本机硬件 → 在线的 Mac 转码器 → 软件）、远程派单、补片重启都与播放同一套，
NAS 没有显卡时整片交给转码器做。

- **导出号** = 文件身份（id、大小、修改时间）+ 档位 + 音轨 + 导出格式版本的指纹：
  全家下同一集同一档只转一次；片源换了（洗版）指纹跟着变。
- **代号**：每转一次加一。ETag 用「导出号 + 代号」，下载中途服务端重转（重启、缓存被清）
  时客户端带旧 ETag 续传，If-Range 对不上，整份重下，不会把两次转码的字节拼在一起。
- **并发**：全局一次一路；播放优先——播放要名额而名额被导出占着时，导出的会话被停掉
  （session.py ``_evict_export_*``），等名额空出来从下一个缺的分片接着转。本机转时降优先级。
- **回收**：客户端下完调 DELETE；没人取的，最后一次访问 72 小时后回收。
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import secrets
import shutil
import time
from collections import deque
from collections.abc import Callable
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Any

from starlette.responses import Response
from starlette.types import Receive, Scope, Send

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.playback import plan as playback_plan
from movieclaw_api.services.playback.ffmpeg_args import (
    BITRATE_LADDER,
    HEVC_BITRATE_LADDER,
    HW_BACKENDS,
    INIT_NAME,
    SEGMENT_SECONDS,
    segment_type,
)
from movieclaw_api.services.playback.hwprobe import available_backends, available_local_backends
from movieclaw_api.services.playback.limits import (
    MAX_REMUX_CONCURRENCY,
    auto_quota_bytes,
    auto_transcode_concurrency,
)
from movieclaw_api.services.playback.remote_config import effective_remote_transcode_config
from movieclaw_api.services.playback.remote_worker import (
    remote_worker_available,
    remote_worker_busy,
    remote_workers_have_encoder,
)
from movieclaw_api.services.playback.session import (
    DiskQuotaError,
    SessionLimitError,
    SessionStartError,
    TranscodeSession,
    get_session_manager,
)
from movieclaw_api.services.playback.track_context import track_contexts
from movieclaw_api.settings import PlaybackPolicySetting
from movieclaw_api.settings.store import get_setting_store
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile
from movieclaw_playback.decide import PlaybackPlan, PlaybackTier, plan_capped_transcode
from movieclaw_playback.hls_vod import SegmentPlan, compute_uniform_plan
from movieclaw_playback.profile import media_profile_from_file

logger = logging.getLogger(__name__)

#: 档位 → 目标高度（码率按实时转码的阶梯，ffmpeg_args.BITRATE_LADDER）
PROFILES: dict[str, int] = {"1080p": 1080, "720p": 720, "480p": 480}
#: 导出参数一变（容器、片段时长、音频档位），已转的产物就不能再当同一份用
EXPORT_FORMAT_VERSION = 1
#: 转码档的音轨：手机上一条立体声 AAC 足够，多声道只是白占空间
AUDIO_BPS = 256_000
RETENTION_S = 72 * 3600
#: 名额被播放占着、转码器暂时不在时多久再看一次
_CAPACITY_POLL_S = 5.0
#: 导出会话不属于任何成员：「同一成员同一文件开新会话」「设备结束播放」都碰不到它
EXPORT_MEMBER_ID = -1
#: 连续这么多轮会话一个分片都没推进就判失败（被播放挤掉的轮次不算）
_MAX_STALLED_ROUNDS = 3
#: 会话还活着、某一段却这么久都没转出来：换一轮会话再试
_SEGMENT_STALL_S = 300.0
#: 每接上这么多段把进度写一次 meta.json
_PROGRESS_SAVE_EVERY = 10
#: 边转边下：读到文件尾、转码还在跑时多久再看一次
_TAIL_POLL_S = 0.25
_CHUNK = 1024 * 1024

STATUS_QUEUED = "queued"
STATUS_RUNNING = "running"
STATUS_DONE = "done"
STATUS_FAILED = "failed"


class ExportStreamAborted(RuntimeError):
    """边转边发中途作废（转码失败 / 重转换了代号）：抛出去让服务器掐断连接、不发结束块。"""


class ExportUnavailable(Exception):
    """这个文件出不了这一档（原盘、HDR 没有硬件、软件转码没开……），文案面向用户。"""


@dataclass
class ExportState:
    export_id: str
    file_id: int
    profile: str
    audio_track: str | None
    status: str
    generation: int
    expected_bytes: int
    final_bytes: int | None = None
    error: str | None = None
    created_at: float = 0.0
    last_access_at: float = 0.0
    #: 每转一次换一个随机串：产物被回收后重建、代号从头数时，ETag 也不会与上一次撞上
    #: （否则客户端拿旧 ETag 续传，会把两次转码的字节拼在一起）
    nonce: str = ""
    #: 旧版（NAS 直接起 ffmpeg）留下的进程号；现在转码归会话层管，只为读得回旧 meta.json
    pid: int | None = None
    #: 已接进文件的分片数 / 总分片数（进度）
    done_segments: int = 0
    total_segments: int = 0
    #: 这一代由谁转、出什么编码（活动页显示用）：转码器名 / 「NAS 显卡」/「NAS 软件」，hevc / h264
    executor: str | None = None
    codec: str | None = None
    #: 还要这份导出的设备（下完调 DELETE 时只摘掉自己，最后一个摘掉才删）
    claims: list[str] = field(default_factory=list)

    @property
    def etag(self) -> str:
        return f'"exp-{self.export_id}-{self.generation}-{self.nonce}"'


def exports_root() -> Path:
    return Path(get_settings().offline_exports_dir)


def video_bps(profile: str, *, hevc: bool = False) -> int:
    ladder = (HEVC_BITRATE_LADDER if hevc else BITRATE_LADDER)[PROFILES[profile]]
    return int(float(ladder[:-1]) * 1_000_000)


#: 实际平均视频码率 ÷ 码率上限（离线导出的预计大小用）。2026-10-14 标定：16 部真片（低码率 4K 网剧、
#: 4K 原盘与杜比视界、1080p 网络版与蓝光压制、动画、情景剧）各取两段 60 秒，按导出同款命令转三档，
#: 222 组。VideoToolbox（只给上限、编码器自己定码率）中位 0.55，按它估的预计 ÷ 实际中位 1.01～1.06、
#: 八成以上落在 ±25% 内（偏差主要来自画面复杂度，暗场 / 动画能低到上限的一成多，与源码率无关）；
#: 软件 libx264（CRF + 上限）中位 0.83、全部在 ±25% 内。其它显卡没法实测，按软件的系数估（偏保守）。
VIDEOTOOLBOX_RATE_FACTOR = 0.55
OTHER_RATE_FACTOR = 0.83


def estimate_bytes(
    profile: str,
    duration_s: float | None,
    *,
    hevc: bool | None = None,
    videotoolbox: bool | None = None,
) -> int:
    """预计大小（界面上写「≈」）：视频码率上限 × 实测系数 + 音轨码率，乘片长；容器开销约 2%。
    ``hevc`` / ``videotoolbox`` 为 None 时按现在最可能的执行者猜。"""
    if not duration_s or duration_s <= 0:
        return 0
    if hevc is None:
        hevc = likely_hevc()
    if videotoolbox is None:
        videotoolbox = hevc or likely_videotoolbox()
    factor = VIDEOTOOLBOX_RATE_FACTOR if videotoolbox else OTHER_RATE_FACTOR
    return int((video_bps(profile, hevc=hevc) * factor + AUDIO_BPS) * duration_s / 8 * 1.02)


def likely_hevc() -> bool:
    """现在开转多半出 HEVC：在线的转码器都带 HEVC 编码器（NAS 本机是 Mac 时同理）。"""
    return "videotoolbox" in available_local_backends() or remote_workers_have_encoder(
        "hevc_videotoolbox"
    )


def likely_videotoolbox() -> bool:
    """现在开转多半由 VideoToolbox 编码：NAS 本机没有别的显卡、而有转码器在线（或本机就是 Mac）。"""
    local = available_local_backends()
    if local:
        return local[0] == "videotoolbox"
    return remote_worker_available("videotoolbox", strict=False) or remote_worker_busy(
        "videotoolbox"
    )


def export_fingerprint(file: LibraryFile, profile: str, audio_track: str | None) -> str:
    mtime = None
    with contextlib.suppress(OSError):
        mtime = int(os.stat(file.file_path).st_mtime)
    raw = json.dumps(
        [file.id, file.size_bytes, mtime, profile, audio_track or "", EXPORT_FORMAT_VERSION]
    )
    return hashlib.sha256(raw.encode()).hexdigest()[:24]


async def _media_and_policy(file: LibraryFile, audio_track: str | None):
    async with get_database().session() as session:
        contexts = await track_contexts(session, [file])
    media = media_profile_from_file(
        file, context=contexts.get(file.id or 0), preferred_audio=audio_track
    )
    return media, await playback_plan.load_policy()


def _capped(media, policy, profile: str, audio_track: str | None) -> PlaybackPlan:
    plan = plan_capped_transcode(
        media,
        policy,
        preferred_audio=audio_track,
        max_height=PROFILES[profile],
        segment_container="mp4",
        audio_codecs=frozenset({"aac"}),
        max_audio_channels=2,
    )
    if not isinstance(plan, PlaybackPlan):
        raise ExportUnavailable(plan.reason)
    return plan


async def build_plan(file: LibraryFile, profile: str, audio_track: str | None) -> PlaybackPlan:
    """这一档能不能出（清单列档位、建导出时当场回答用）：与 Jellyfin 协议「播放器要求限码率」
    同一个规划函数。硬件算上在线的转码器（播放怎么算这里就怎么算）；真正由谁转在开转时
    才定（``_execution``）。"""
    if profile not in PROFILES:
        raise ExportUnavailable(f"不支持的档位：{profile}")
    if file.is_disc():
        raise ExportUnavailable("原盘暂不支持下载到设备")
    media, policy = await _media_and_policy(file, audio_track)
    return _offerable(media, policy, profile, audio_track)


def _offerable(media, policy, profile: str, audio_track: str | None) -> PlaybackPlan:
    """这一档能不能提供（单个文件的 ``build_plan`` 与选档表单的批量判断同一条规则）"""
    if policy.hardware_busy:
        # 转码器在线、只是名额被播放占满：导出会排队等它，这一档照样提供
        policy = replace(policy, hardware_available=True, hardware_busy=False)
    plan = _capped(media, policy, profile, audio_track)
    if plan.tier is PlaybackTier.HARDWARE_TRANSCODE:
        return plan
    if not policy.software_transcode_enabled:
        raise ExportUnavailable("没有可用的硬件转码，且软件转码未开启")
    return plan


async def available_profiles(files: list[LibraryFile]) -> dict[int, set[str]]:
    """一批文件各自能提供的档位（选档表单批量估大小）：轨道上下文与播放策略整批只取一次"""
    candidates = [f for f in files if f.id is not None and not f.is_disc()]
    if not candidates:
        return {}
    async with get_database().session() as session:
        contexts = await track_contexts(session, candidates)
    policy = await playback_plan.load_policy()
    result: dict[int, set[str]] = {}
    for file in candidates:
        media = media_profile_from_file(file, context=contexts.get(file.id or 0))
        offered: set[str] = set()
        for profile in PROFILES:
            try:
                _offerable(media, policy, profile, None)
            except ExportUnavailable:
                continue
            offered.add(profile)
        result[file.id or 0] = offered
    return result


@dataclass(frozen=True)
class _Execution:
    """这一轮导出会话由谁来转。"""

    plan: PlaybackPlan
    hw_backend: str | None
    remote: bool


async def _execution(
    file: LibraryFile, profile: str, audio_track: str | None
) -> _Execution | None:
    """现在能不能开转、由谁转；None = 还得等（名额被播放占着、转码器暂时不在）。

    选后端与播放同一个函数（``select_execution_backend``）：本机硬件 → 在线的转码器。
    转码器在线但名额被播放占满时等它，不退到 NAS 软件转码——它几分钟内就会空出来，
    比 NAS 软转快一个数量级。HDR 没有硬件可用时也等（与播放同一条底线：不让 CPU 做
    4K 色调映射）；软件转码没开时同理等硬件回来——建导出时（``build_plan``）硬件是在的。"""
    media, policy = await _media_and_policy(file, audio_track)
    # 先按「有硬件」规划：硬件这会儿不在（转码器掉线、名额满）是等的理由，不是判失败的理由
    plan = _capped(
        media, replace(policy, hardware_available=True, hardware_busy=False), profile, audio_track
    )
    local = await asyncio.to_thread(available_local_backends)
    if plan.tier is PlaybackTier.HARDWARE_TRANSCODE:
        backends = await asyncio.to_thread(available_backends)
        backend, remote = playback_plan.select_execution_backend(
            plan,
            available=backends,
            local_backends=local,
            remote_video_available=remote_worker_available(
                "videotoolbox", segment_type(plan), strict=True
            ),
        )
        if backend is not None:
            if not remote and not _local_slot_free(hardware=True):
                return None
            if _hevc_capable(backend, remote=remote):
                plan = replace(plan, video=replace(plan.video, codec="hevc"))
            return _Execution(plan, backend, remote)
        if (
            remote_worker_busy("videotoolbox")
            or plan.video.tone_map
            or not policy.software_transcode_enabled
        ):
            return None
        plan = _capped(media, replace(policy, hardware_available=False), profile, audio_track)
    if not _local_slot_free(hardware=bool(local)):
        return None
    return _Execution(plan, None, False)


def _hevc_capable(backend: str, *, remote: bool) -> bool:
    """这个执行者能出 HEVC：同画质体积小三分之一（ffmpeg_args.HEVC_BITRATE_LADDER），手机全系硬解。
    目前只有 VideoToolbox（Mac 转码器）；NAS 的软件与其它显卡仍出 H.264（libx265 在 NAS 的
    CPU 上太慢）。"""
    encoder = HW_BACKENDS[backend].hevc_encoder if backend in HW_BACKENDS else None
    if encoder is None:
        return False
    return remote_workers_have_encoder(encoder, backend) if remote else True


def _local_slot_free(*, hardware: bool) -> bool:
    return get_session_manager().active_transcodes() < auto_transcode_concurrency(
        hardware=hardware
    )


class ExportManager:
    def __init__(self, root: Path | None = None) -> None:
        self._root = root
        self._states: dict[str, ExportState] = {}
        self._loaded = False
        self._queue: deque[str] = deque()
        self._wake = asyncio.Event()
        self._worker: asyncio.Task | None = None
        #: 正在驱动的播放会话
        self._session_id: str | None = None
        #: 排队循环正在处理的导出（可能还在等名额，状态仍是排队）
        self._current_id: str | None = None
        #: 这一轮会话从哪一段、什么时候开始（monotonic），算转码倍速用
        self._round_start: tuple[int, float] | None = None
        #: 正在被下载的导出（导出号 → 连接数）：回收时跳过
        self._readers: dict[str, int] = {}

    @property
    def root(self) -> Path:
        return self._root or exports_root()

    def _dir(self, export_id: str) -> Path:
        return self.root / export_id

    def output_path(self, state: ExportState) -> Path:
        return self._dir(state.export_id) / f"{state.generation}.mp4"

    # ---- 状态落盘 ----

    def _save(self, state: ExportState) -> None:
        folder = self._dir(state.export_id)
        folder.mkdir(parents=True, exist_ok=True)
        tmp = folder / "meta.json.tmp"
        tmp.write_text(json.dumps(asdict(state)), encoding="utf-8")
        tmp.replace(folder / "meta.json")

    def _load(self) -> None:
        """第一次用到时读回全部导出；没转完的（服务重启打断的）重新排队。"""
        if self._loaded:
            return
        self._loaded = True
        if not self.root.is_dir():
            return
        for folder in self.root.iterdir():
            meta = folder / "meta.json"
            try:
                state = ExportState(**json.loads(meta.read_text(encoding="utf-8")))
            except (OSError, ValueError, TypeError):
                shutil.rmtree(folder, ignore_errors=True)
                continue
            if state.status in (STATUS_QUEUED, STATUS_RUNNING):
                # 上次没正常收尾（崩溃、被杀）：重新排队（残留的 ffmpeg 由会话层的启动清理收拾）
                state.status = STATUS_QUEUED
                state.pid = None
                self._save(state)
                self._queue.append(state.export_id)
            self._states[state.export_id] = state
        if self._queue:
            self._ensure_worker()

    # ---- 对外 ----

    def get(self, export_id: str) -> ExportState | None:
        self._load()
        return self._states.get(export_id)

    async def ensure(
        self,
        file: LibraryFile,
        profile: str,
        audio_track: str | None,
        *,
        duration_s: float | None,
        claimant: str | None = None,
    ) -> ExportState:
        """建或复用一个导出（幂等）。失败过的再要一次就重转。``claimant`` 是要它的设备。"""
        self._load()
        await build_plan(file, profile, audio_track)  # 出不了这一档当场告诉客户端
        export_id = export_fingerprint(file, profile, audio_track)
        now = time.time()
        state = self._states.get(export_id)
        stale = (
            state is not None
            and state.status == STATUS_DONE
            and not self.output_path(state).exists()
        )  # 产物被清掉了（缓存管理清空）：重转
        if state is None or stale or state.status == STATUS_FAILED:
            state = ExportState(
                export_id=export_id,
                file_id=int(file.id or 0),
                profile=profile,
                audio_track=audio_track,
                status=STATUS_QUEUED,
                generation=(state.generation if state else 0),
                expected_bytes=estimate_bytes(profile, duration_s),
                created_at=now,
                claims=state.claims if state else [],
            )
            self._states[export_id] = state
            self._queue.append(export_id)
        if claimant and claimant not in state.claims:
            state.claims.append(claimant)
        state.last_access_at = now
        self._save(state)
        self._ensure_worker()
        self._wake.set()
        self.collect_garbage()
        return state

    def touch(self, state: ExportState) -> None:
        if self._states.get(state.export_id) is not state:
            return  # 这期间已被回收：不再写回一份孤儿 meta.json
        state.last_access_at = time.time()
        self._save(state)

    def claim(self, export_id: str, claimant: str) -> None:
        state = self.get(export_id)
        if state is not None and claimant not in state.claims:
            state.claims.append(claimant)
            self._save(state)

    def release(self, export_id: str, claimant: str | None = None) -> None:
        """某台设备下完了：摘掉它；没有别的设备还要、没人在下、也不在转，才当场删。"""
        state = self.get(export_id)
        if state is None:
            return
        if claimant in state.claims:
            state.claims.remove(claimant)
            self._save(state)
        if state.status in (STATUS_QUEUED, STATUS_RUNNING) or state.claims:
            return
        if self._readers.get(export_id):
            # 还有连接在读：留给过期回收
            return
        self._drop(export_id)

    def queue_position(self, export_id: str) -> int | None:
        try:
            return list(self._queue).index(export_id)
        except ValueError:
            return None

    def waiting(self, export_id: str) -> tuple[str, int]:
        """排队中的导出在等什么：（"transcoder" 轮到了、在等转码名额空出来 / 转码器回来，0）
        或（"queue" 排在别的导出后面，前面还有几个——含正在转的那个）。"""
        if export_id == self._current_id:
            return "transcoder", 0
        position = self.queue_position(export_id) or 0
        return "queue", position + (1 if self._current_id is not None else 0)

    def collect_garbage(self) -> None:
        cutoff = time.time() - RETENTION_S
        for export_id, state in list(self._states.items()):
            if state.status in (STATUS_QUEUED, STATUS_RUNNING) or self._readers.get(export_id):
                continue
            if state.last_access_at < cutoff:
                self._drop(export_id)

    def _drop(self, export_id: str) -> None:
        self._states.pop(export_id, None)
        shutil.rmtree(self._dir(export_id), ignore_errors=True)

    def reader_enter(self, export_id: str) -> None:
        self._readers[export_id] = self._readers.get(export_id, 0) + 1

    def reader_leave(self, export_id: str) -> None:
        left = self._readers.get(export_id, 0) - 1
        if left > 0:
            self._readers[export_id] = left
        else:
            self._readers.pop(export_id, None)

    def activity_line(self, export_id: str) -> tuple[str, int | None] | None:
        """活动页「正在下载」这一行的转码信息，和据已转比例推算的最终大小（推不出为 None）。

        例：「转码 720p HEVC · macmini · 5.2 倍速 · 已转 24%」「720p HEVC 转码版」。"""
        state = self.get(export_id)
        if state is None:
            return None
        spec = f"{state.profile} {(state.codec or 'h264').upper()}"
        if state.status == STATUS_DONE:
            return f"{spec} 转码版", state.final_bytes
        if state.status == STATUS_QUEUED:
            return f"转码 {spec} · 排队中", None
        if state.status == STATUS_FAILED:
            return f"转码 {spec} · 失败", None
        parts = [f"转码 {spec}"]
        if state.executor:
            parts.append(state.executor)
        if self._running_export_id() == export_id and self._round_start is not None:
            start_index, started = self._round_start
            elapsed = time.monotonic() - started
            if elapsed >= 5 and state.done_segments > start_index:
                speed = (state.done_segments - start_index) * SEGMENT_SECONDS / elapsed
                parts.append(f"{speed:.1f} 倍速")
        projected = None
        if state.total_segments:
            fraction = state.done_segments / state.total_segments
            parts.append(f"已转 {int(fraction * 100)}%")
            if fraction > 0.02:
                with contextlib.suppress(OSError):
                    projected = int(self.output_path(state).stat().st_size / fraction)
        return " · ".join(parts), projected

    def _running_export_id(self) -> str | None:
        if self._session_id is None:
            return None
        live = get_session_manager().get(self._session_id)
        return live.export_id if live is not None else None

    # ---- 转码 ----

    def _ensure_worker(self) -> None:
        if self._worker is None or self._worker.done():
            self._worker = asyncio.create_task(self._run(), name="offline-exports")

    async def _run(self) -> None:
        while True:
            if not self._queue:
                self._wake.clear()
                try:
                    await asyncio.wait_for(self._wake.wait(), timeout=600)
                except TimeoutError:
                    self.collect_garbage()
                    if not self._queue:
                        return
                continue
            export_id = self._queue.popleft()
            state = self._states.get(export_id)
            if state is None or state.status != STATUS_QUEUED:
                continue
            self._current_id = export_id
            try:
                await self._transcode(state)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 —— 一份导出出错不能拖垮队列
                if not isinstance(exc, ExportUnavailable):
                    logger.exception("离线导出失败：%s", export_id)
                state.status = STATUS_FAILED
                state.error = str(exc) or exc.__class__.__name__
                self._save(state)
                logger.warning("离线导出失败：%s：%s", export_id, state.error)
            finally:
                self._current_id = None

    def _new_generation(self, state: ExportState) -> Path:
        """换代号从头写：旧代号的产物删掉，正在读旧产物的连接会发现代号变了而断开。"""
        old = self.output_path(state) if state.generation else None
        state.generation += 1
        state.nonce = secrets.token_hex(4)
        state.status = STATUS_RUNNING
        state.error = None
        state.final_bytes = None
        state.done_segments = 0
        out = self.output_path(state)
        out.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(OSError):
            out.unlink()
        out.touch()
        self._save(state)
        if old is not None:
            with contextlib.suppress(OSError):
                old.unlink()
        return out

    async def _wait_execution(self, file: LibraryFile, state: ExportState) -> _Execution:
        while True:
            execution = await _execution(file, state.profile, state.audio_track)
            if execution is not None:
                return execution
            await asyncio.sleep(_CAPACITY_POLL_S)

    async def _transcode(self, state: ExportState) -> None:
        """一个「只下载、不看」的播放会话按顺序要分片，NAS 把 init + 分片接成一个 MP4。

        挑执行者、远程转码器派单、补片与断点重启全部走播放的会话层；VOD 分片时间戳是文件
        绝对时间，同一编码器重转的 init 逐字节相同，所以中途换会话（被播放挤掉、转码器断线、
        服务端重启）从下一个缺的分片接着转就行。换了编码器 init 对不上，整份重来。
        """
        async with get_database().session() as session:
            file = await session.get(LibraryFile, state.file_id)
        if file is None:
            raise ExportUnavailable("文件已不在媒体库里")
        if not file.duration_seconds:
            raise ExportUnavailable("片长未知，没法转码导出")
        segments = compute_uniform_plan(float(file.duration_seconds), target_s=SEGMENT_SECONDS)
        sessions = get_session_manager()
        cache = (await get_setting_store().get(PlaybackPolicySetting)).transcode_cache_enabled
        out: Path | None = None
        init: bytes | None = None
        index = 0
        stalled = 0
        started = time.monotonic()
        while index < segments.count:
            execution = await self._wait_execution(file, state)
            if out is None:
                # 真开转了才进「转码中」：等名额 / 等转码器回来时仍是排队，内容接口回 503 让手机
                # 稍后再来，而不是挂一条没有字节的长连接
                out = self._new_generation(state)
            try:
                live = await sessions.start(
                    execution.plan,
                    source_path=file.file_path,
                    member_id=EXPORT_MEMBER_ID,
                    start_ms=int(segments.boundaries[index] * 1000),
                    segment_plan=segments,
                    hw_backend=execution.hw_backend,
                    max_transcode=auto_transcode_concurrency(hardware=bool(execution.hw_backend)),
                    max_remux=MAX_REMUX_CONCURRENCY,
                    quota_bytes=auto_quota_bytes(sessions.cache_root),
                    use_remote=execution.remote,
                    remote_base_url=(
                        effective_remote_transcode_config().base_url if execution.remote else ""
                    ),
                    display_name=f"离线下载 · {Path(file.file_path).name}",
                    device_id=f"offline-export:{state.export_id}",
                    cache=cache,
                    export_id=state.export_id,
                )
            except (SessionLimitError, SessionStartError, DiskQuotaError) as exc:
                stalled += 1
                if stalled >= _MAX_STALLED_ROUNDS:
                    raise ExportUnavailable(f"转码起不来：{exc}") from exc
                logger.info("离线导出 %s 开转码会话失败，稍后重试：%s", state.export_id, exc)
                await asyncio.sleep(_CAPACITY_POLL_S)
                continue
            self._session_id = live.id
            self._round_start = (index, time.monotonic())
            state.codec = execution.plan.video.codec
            state.executor = live.remote_worker_id or (
                "NAS 显卡" if execution.hw_backend else "NAS 软件"
            )
            expected = estimate_bytes(
                state.profile,
                float(file.duration_seconds),
                hevc=execution.plan.video.codec == "hevc",
                videotoolbox=execution.hw_backend == "videotoolbox",
            )
            if expected != state.expected_bytes:
                state.expected_bytes = expected
                self._save(state)
            before = index
            logger.info(
                "离线导出 %s 从第 %d/%d 段开转（%s）",
                state.export_id,
                index,
                segments.count,
                "转码器" if execution.remote else (execution.hw_backend or "软件"),
            )
            try:
                index, init = await self._drain(live, segments, index, out, init, state)
            except _InitMismatch:
                # 换了编码器（不同的转码器 / 退到本机），init 对不上：整份从头，且不再认领
                # 混了两种编码器的缓存
                logger.warning("离线导出 %s 换了编码器，整份从头转", state.export_id)
                out, init, index, cache = self._new_generation(state), None, 0, False
                continue
            finally:
                self._session_id = None
                self._round_start = None
                await sessions.stop(live.id, reason="离线导出这一轮结束")
            if live.preempted:
                continue  # 被播放挤掉：不算没进展，等名额空出来接着转
            if index > before:
                stalled = 0
                continue
            stalled += 1
            if stalled >= _MAX_STALLED_ROUNDS:
                raise ExportUnavailable(live.error or "转码一直没有进展")
            await asyncio.sleep(_CAPACITY_POLL_S)
        assert out is not None
        state.status = STATUS_DONE
        state.final_bytes = out.stat().st_size
        self._save(state)
        logger.info(
            "离线导出完成：%s，%d MB，用时 %d 秒",
            state.export_id,
            state.final_bytes // (1024 * 1024),
            time.monotonic() - started,
        )

    async def _drain(
        self,
        live: TranscodeSession,
        segments: SegmentPlan,
        index: int,
        out: Path,
        init: bytes | None,
        state: ExportState,
    ) -> tuple[int, bytes | None]:
        """跟着会话把分片按顺序接到 ``out`` 后面，返回（下一个要的分片号, init）。"""
        sessions = get_session_manager()
        idle_since = time.monotonic()
        while index < segments.count:
            live.touch()
            path = await sessions.ensure_segment(live, index)
            if path is None:
                if live.state in ("failed", "stopped"):
                    return index, init
                if index in live.unreachable_segments:
                    if index >= segments.count - 2 and index > 0:
                        # 源比台账短一截（片尾）：转出来的就是全部
                        logger.info(
                            "离线导出 %s 片尾第 %d 段产不出来，按源实际长度收尾",
                            state.export_id,
                            index,
                        )
                        return segments.count, init
                    live.error = f"第 {index} 段转不出来"
                    return index, init
                if time.monotonic() - idle_since > _SEGMENT_STALL_S:
                    live.error = f"第 {index} 段等了 {_SEGMENT_STALL_S:.0f} 秒还没转出来"
                    return index, init
                continue  # 30 秒没等到但会话还活着（远程首片、慢机）：接着等
            assert isinstance(path, Path)
            head = await asyncio.to_thread((live.directory / INIT_NAME).read_bytes)
            if init is None:
                init = head
                await asyncio.to_thread(_append, out, [head])
            elif head != init:
                raise _InitMismatch
            await asyncio.to_thread(_append, out, [path.read_bytes()])
            index += 1
            idle_since = time.monotonic()
            state.done_segments = index
            state.total_segments = segments.count
            if index % _PROGRESS_SAVE_EVERY == 0:
                self._save(state)  # 进度落盘（排查与重启后看得见做到哪了）
        return index, init

    async def shutdown(self) -> None:
        """后端退出：停掉排队循环；导出会话由播放会话管理器一并收拾。"""
        if self._worker is not None:
            self._worker.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._worker


class _InitMismatch(Exception):
    """新一轮会话的 init 与已经写进文件的不同：换了编码器，后面的分片接不上。"""


def _append(out: Path, chunks: list[bytes]) -> None:
    with out.open("ab") as handle:
        for chunk in chunks:
            handle.write(chunk)


_manager: ExportManager | None = None


def get_export_manager() -> ExportManager:
    global _manager
    if _manager is None:
        _manager = ExportManager()
    return _manager


def reset_export_manager(root: Path | None = None) -> ExportManager:
    """测试用：换一个根目录重建（不碰正在跑的旧实例）。"""
    global _manager
    _manager = ExportManager(root)
    return _manager


class ExportTailResponse(Response):
    """正在转的导出：200 分块传输，从头发、跟着文件增长往后发。

    只有转码成功结束且全部发完才正常收尾；转码失败、换了代号就掐断连接（不发结束块），
    客户端一定报错，不会把半个文件当成完成。客户端断开由后台 ``receive`` 发现
    （见 docs/design 里 is_disconnected 的教训：轮询它在中间件下恒为假）。
    """

    media_type = "video/mp4"

    def __init__(
        self, manager: ExportManager, state: ExportState, on_close: Callable[[], None] | None = None
    ) -> None:
        self.on_close = on_close
        self.manager = manager
        self.export_id = state.export_id
        self.generation = state.generation
        self.path = manager.output_path(state)
        super().__init__(
            status_code=200,
            headers={
                "etag": state.etag,
                "accept-ranges": "bytes",
                "cache-control": "no-store",
                # 预计大小（客户端画进度用；最终大小以实际为准）
                "x-expected-length": str(state.expected_bytes),
            },
        )
        # Response 默认会写 content-length: 0
        self.raw_headers = [(k, v) for k, v in self.raw_headers if k != b"content-length"]

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        disconnected = asyncio.Event()

        async def watch() -> None:
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    disconnected.set()
                    return

        watcher = asyncio.create_task(watch())
        self.manager.reader_enter(self.export_id)
        try:
            await send({"type": "http.response.start", "status": 200, "headers": self.raw_headers})
            if scope.get("method", "GET").upper() == "HEAD":
                await send({"type": "http.response.body", "body": b"", "more_body": False})
                return
            await self._stream(send, disconnected)
        finally:
            watcher.cancel()
            self.manager.reader_leave(self.export_id)
            if self.on_close is not None:
                self.on_close()

    async def _stream(self, send: Send, disconnected: asyncio.Event) -> None:
        sent = 0
        handle = None
        try:
            while not disconnected.is_set():
                if handle is None:
                    try:
                        handle = await asyncio.to_thread(open, self.path, "rb")
                    except FileNotFoundError:
                        handle = None
                if handle is not None:
                    chunk = await asyncio.to_thread(handle.read, _CHUNK)
                    if chunk:
                        sent += len(chunk)
                        await send({"type": "http.response.body", "body": chunk, "more_body": True})
                        continue
                state = self.manager.get(self.export_id)
                if state is None or state.generation != self.generation:
                    raise ExportStreamAborted(f"离线导出 {self.export_id} 重转了，掐断旧连接")
                if state.status == STATUS_FAILED:
                    raise ExportStreamAborted(f"离线导出 {self.export_id} 转码失败，掐断连接")
                if state.status == STATUS_DONE and handle is not None:
                    if state.final_bytes is not None and sent >= state.final_bytes:
                        await send({"type": "http.response.body", "body": b"", "more_body": False})
                        return
                    if state.final_bytes is not None and sent < state.final_bytes:
                        # 转完了却读不满（文件被替换、截断）：不能当完成，也不空转
                        raise ExportStreamAborted(f"离线导出 {self.export_id} 产物不完整")
                await asyncio.sleep(_TAIL_POLL_S)
        finally:
            if handle is not None:
                handle.close()


def state_view_fields(manager: ExportManager, state: ExportState) -> dict[str, Any]:
    return {
        "export_id": state.export_id,
        "status": state.status,
        "etag": state.etag,
        "expected_bytes": state.expected_bytes,
        "final_bytes": state.final_bytes,
        "error": state.error,
        "queue_position": manager.queue_position(state.export_id),
    }

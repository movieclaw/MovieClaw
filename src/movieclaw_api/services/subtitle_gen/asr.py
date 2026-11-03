"""本地语音识别：文件没有任何可用字幕时，从音轨识别台词（docs/design/subtitle-asr.md）。

这一层只管四件事：本机能不能识别（能力探测，进程内探测一次）、给一个文件选音轨并
判定台词语言（规划，纯计算）、跑识别子进程（``asr_worker``，主进程不加载模型），
以及把识别结果断成字幕条（纯函数）。选源、任务编排与翻译衔接在 ``tasks``。

模型是 SenseVoice-Small 官方 2024-07-17 int8（sherpa-onnx 导出）。同系列的
2025-09-09 版是粤语微调版，日语、韩语实测全坏，不能换用（§6）。
"""

from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import json
import logging
import os
import re
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from movieclaw_api.core.config import get_settings
from movieclaw_api.i18n.stored import stored_fields
from movieclaw_api.services.subtitle_gen import process, validate
from movieclaw_api.services.subtitle_gen.extract import SubEvent

logger = logging.getLogger("movieclaw_api.subtitle_gen")

#: Job 输入里固化的模型标识：换模型时改它，旧任务不会悄悄用新模型续跑
MODEL_ID = "sensevoice-small-2024-07-17"
#: SenseVoice 能识别的台词语言 → 识别结果的语言码（ISO 639-2/B，外挂文件名与选源共用）
LANGUAGE_TOKENS = {"zh": "chi", "yue": "chi", "en": "eng", "ja": "jpn", "ko": "kor"}
#: 各种语言写法 → SenseVoice 语言。音轨标签是 ISO 639-2，元数据是 TMDB 两字码（cn = 粤语）
_LANGUAGE_ALIASES = {
    "zh": "zh", "chi": "zh", "zho": "zh", "cmn": "zh", "chs": "zh", "cht": "zh",
    "yue": "yue", "cn": "yue",
    "en": "en", "eng": "en",
    "ja": "ja", "jpn": "ja",
    "ko": "ko", "kor": "ko",
}
_UNKNOWN_LANGUAGES = frozenset({"", "und", "unk", "unknown", "mis", "mul", "zxx", "none", "xx"})
# i18n-ignore: commentary track titles parsed from media metadata
_COMMENTARY = re.compile(r"commentary|评论|導評|导评|解说|解說", re.IGNORECASE)
#: 中置声道所在的声道布局（ffmpeg 写法）；布局缺失时 6/8 声道按 5.1/7.1 处理
_CENTER_LAYOUTS = ("5.1", "6.1", "7.1")
#: 预检的预计时长：有 AVX2 时约 8 倍实时（V1500B 2 线程实测 7.9 倍）；
#: 没有 AVX2 的老 CPU 没测过，先按 3 倍
_SPEED_AVX2 = 8.0
_SPEED_BASELINE = 3.0
#: 不在暂停却这么久没有任何输出：子进程卡死，结束它并报错
_STALL_SECONDS = 600.0
_PLAYBACK_POLL_SECONDS = 1.0
#: 识别参数（也是断点身份的一部分：参数变了，旧断点的切段就对不上了）
_PAD_SECONDS = 0.3
_MAX_SPEECH_SECONDS = 20.0
#: 断点多久强制落盘一次：断电最多丢这么久的识别
_CHECKPOINT_SYNC_SECONDS = 10.0
_WORKER = Path(__file__).with_name("asr_worker.py")


# ---------------------------------------------------------------------------
# 能力探测（部署环境的属性：进程内探测一次，预检只查表）
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Capability:
    available: bool
    #: 不可用的原因：runtime（没装 sherpa-onnx）/ model（模型文件不全）
    missing: str | None
    model_dir: Path
    avx2: bool

    @property
    def speed(self) -> float:
        return _SPEED_AVX2 if self.avx2 else _SPEED_BASELINE


_CAPABILITY: Capability | None = None
_CAPABILITY_LOCK = threading.Lock()


def model_files(model_dir: Path) -> dict[str, Path]:
    return {
        "model": model_dir / "model.int8.onnx",
        "tokens": model_dir / "tokens.txt",
        "vad": model_dir / "silero_vad.onnx",
    }


def _has_avx2() -> bool:
    """Linux 看 /proc/cpuinfo；其他平台（Mac、Windows 开发机）按支持处理。"""
    try:
        with open("/proc/cpuinfo", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("flags"):
                    return " avx2" in line
    except OSError:
        return True
    return True


def _probe() -> Capability:
    model_dir = Path(get_settings().asr_model_dir)
    avx2 = _has_avx2()
    # 只找包不导入：真正加载留给子进程，主进程不为可能整轮用不到的功能付冷启动
    if importlib.util.find_spec("sherpa_onnx") is None:
        return Capability(False, "runtime", model_dir, avx2)
    if not all(path.is_file() for path in model_files(model_dir).values()):
        return Capability(False, "model", model_dir, avx2)
    return Capability(True, None, model_dir, avx2)


def capability() -> Capability:
    global _CAPABILITY
    if _CAPABILITY is None:
        with _CAPABILITY_LOCK:
            if _CAPABILITY is None:
                _CAPABILITY = _probe()
                if _CAPABILITY.available:
                    logger.info(
                        "本地语音识别自检通过（%s，%s），没有字幕的文件可从音轨识别台词",
                        MODEL_ID,
                        "AVX2" if _CAPABILITY.avx2 else "无 AVX2",
                    )
                else:
                    logger.info(
                        "当前环境不能做本地语音识别（缺%s：%s），没有字幕的文件无法从音轨识别",
                        "sherpa-onnx" if _CAPABILITY.missing == "runtime" else "模型文件",
                        _CAPABILITY.model_dir,
                    )
    return _CAPABILITY


def warm_capability() -> None:
    """（阻塞，调用方放线程池）启动时预热，让首次预检直接命中缓存。"""
    capability()


def reset_capability_cache() -> None:
    """测试用：丢掉探测结论，下次重新探测。"""
    global _CAPABILITY
    with _CAPABILITY_LOCK:
        _CAPABILITY = None


# ---------------------------------------------------------------------------
# 规划：选哪条音轨、台词是什么语言（纯计算，预检秒回）
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class AudioPlan:
    index: int  # 同类型序号：ffmpeg 的 0:a:<index>
    language: str | None  # SenseVoice 语言；None = 未知，任务里自动判断
    raw_language: str | None  # 不支持的语言原样带回，给提示文案用
    refusal: str | None  # 不能识别的原因码：asr_language / asr_remote / asr_unavailable
    center_channel: bool
    codec: str | None
    layout: str | None
    channels: int | None

    @property
    def language_token(self) -> str | None:
        """识别结果的语言码（chi / eng / jpn / kor）；台词语言未知时为 None。"""
        return LANGUAGE_TOKENS.get(self.language) if self.language else None


def normalize_language(raw: str | None) -> tuple[str | None, str | None]:
    """任意语言写法 → (SenseVoice 语言, 不支持时的原始写法)。两者都为 None = 未知。"""
    value = str(raw or "").strip().lower()
    if value in _UNKNOWN_LANGUAGES:
        return None, None
    if value in _LANGUAGE_ALIASES:
        return _LANGUAGE_ALIASES[value], None
    return None, value


def choose_track(streams: list[dict], original_language: str | None) -> int:
    """原语言优先；排除评论音轨与 ffmpeg 解不了的轨（如 Audio Vivid）；都不行用第一条。"""
    usable = [
        index
        for index, stream in enumerate(streams)
        if stream.get("codec") and not _COMMENTARY.search(str(stream.get("title") or ""))
    ]
    original, _ = normalize_language(original_language)
    if original is not None:
        for index in usable:
            if normalize_language(streams[index].get("language"))[0] == original:
                return index
    return usable[0] if usable else 0


def wants_center(stream: dict) -> bool:
    layout = str(stream.get("channel_layout") or "")
    if layout:
        return layout.startswith(_CENTER_LAYOUTS)
    return stream.get("channels") in (6, 7, 8)


def plan_audio(
    file_path: str,
    audio_streams: list[dict] | None,
    original_language: str | None,
    *,
    remote: bool,
) -> AudioPlan | None:
    """给文件规划一次识别；没有任何音轨时返回 None。"""
    streams = audio_streams or []
    if not streams:
        return None
    index = choose_track(streams, original_language)
    stream = streams[index]
    # 音轨自己的语言标签最可信（国语配音轨的标签就是 chi）；没有标签再看影片原语言
    language, raw = normalize_language(stream.get("language"))
    if language is None and raw is None:
        language, raw = normalize_language(original_language)
    if remote:
        refusal = "asr_remote"
    elif raw is not None:
        refusal = "asr_language"
    elif not capability().available:
        refusal = "asr_unavailable"
    else:
        refusal = None
    return AudioPlan(
        index=index,
        language=language,
        raw_language=raw,
        refusal=refusal,
        center_channel=wants_center(stream),
        codec=str(stream.get("codec") or "") or None,
        layout=str(stream.get("channel_layout") or "") or None,
        channels=stream.get("channels"),
    )


def estimate_minutes(duration_seconds: int | None) -> int:
    """预检里的预计识别时长（分钟，至少 1）：按片长 ÷ 本机速度系数粗估。"""
    if not duration_seconds:
        return 1
    return max(1, round(duration_seconds / capability().speed / 60))


def worker_threads() -> int:
    """2 线程已有约 8 倍实时、只占约 2 个核；再多收益很小（8 线程反而更慢）。"""
    return 2 if (os.cpu_count() or 2) >= 4 else 1


# ---------------------------------------------------------------------------
# 识别子进程
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Segment:
    start_ms: int
    end_ms: int
    text: str
    #: (token 原文, 绝对起点毫秒)
    tokens: tuple[tuple[str, int], ...] = ()


@dataclass
class Transcript:
    segments: list[Segment] = field(default_factory=list)
    language: str | None = None
    speech_seconds: float = 0.0


class TranscribeError(Exception):
    """识别没完成；保留可按读者语言渲染的原因引用。"""

    def __init__(self, message: dict) -> None:
        self.reference = message
        super().__init__(message["message"])


def _playback_busy() -> bool:
    """本机在为播放转码（软件转码要吃满所有核）：识别要让路。与片头识别同一口径。"""
    from movieclaw_api.services.library import skip_segments

    return skip_segments.playback_load() == skip_segments.TRANSCODING


def _segment(event: dict) -> Segment:
    start = int(event["start_ms"])
    pairs = zip(event.get("tokens") or [], event.get("timestamps") or [], strict=False)
    tokens = tuple((str(token), start + int(float(offset) * 1000)) for token, offset in pairs)
    return Segment(start, int(event["end_ms"]), str(event.get("text") or ""), tokens)


async def transcribe(
    wav: Path,
    language: str | None,
    *,
    on_progress: Callable[[float], None],
    on_paused: Callable[[bool], None],
    checkpoint: Checkpoint | None = None,
    playback_busy: Callable[[], bool] = _playback_busy,
) -> Transcript:
    """跑识别子进程到结束；被取消时子进程连同进程组秒级结束。

    ``on_progress`` 收到已识别到的音频秒数，``on_paused`` 在因转码暂停 / 继续时各调一次。
    给了 ``checkpoint`` 就边识别边记断点，并从断点里已识别完的位置接着识别（重启、
    崩溃、断电后不从头再来）；断点里锁定过的语言优先于 ``language``。
    """
    files = model_files(capability().model_dir)
    transcript = Transcript()
    start = 0.0
    if checkpoint is not None:
        transcript.segments = [_segment(event) for event in checkpoint.segments]
        transcript.language = checkpoint.language
        language = checkpoint.language or language
        start = checkpoint.position
    params = {
        "model": str(files["model"]),
        "tokens": str(files["tokens"]),
        "vad": str(files["vad"]),
        "wav": str(wav),
        "language": language,
        "threads": worker_threads(),
        "pad": _PAD_SECONDS,
        "max_speech": _MAX_SPEECH_SECONDS,
        "start": start,
        "parent": os.getpid(),
    }
    argv = [sys.executable, "-I", str(_WORKER)]
    if checkpoint is not None:
        await asyncio.to_thread(checkpoint.open)
    try:
        async with process.spawn(argv, stdin=json.dumps(params).encode() + b"\n") as proc:
            follower = asyncio.create_task(_follow_playback(proc, on_paused, playback_busy))
            try:
                await _read_events(proc, transcript, on_progress, checkpoint)
            finally:
                follower.cancel()
            returncode = await proc.wait()
            if returncode != 0:
                raise TranscribeError(
                    stored_fields(
                        "library.subtitleJob.asrFailed",
                        reason=proc.stderr_tail() or f"exit {returncode}",
                    )
                )
    except OSError as exc:
        raise TranscribeError(
            stored_fields("library.subtitleJob.asrFailed", reason=str(exc))
        ) from exc
    finally:
        if checkpoint is not None:
            await asyncio.to_thread(checkpoint.close)
    return transcript


async def _read_events(
    proc: process.Spawned,
    transcript: Transcript,
    on_progress: Callable[[float], None],
    checkpoint: Checkpoint | None = None,
) -> None:
    idle = 0.0
    while True:
        try:
            line = await asyncio.wait_for(proc.readline(), timeout=30)
        except TimeoutError:
            # 暂停期间没有输出是正常的；不在暂停却长时间没动静就是卡死了
            idle = 0.0 if proc.paused else idle + 30
            if idle >= _STALL_SECONDS:
                minutes = int(_STALL_SECONDS / 60)
                raise TranscribeError(
                    stored_fields("library.subtitleJob.asrStalled", minutes=minutes)
                ) from None
            continue
        if not line:
            return
        idle = 0.0
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "segment":
            transcript.segments.append(_segment(event))
            if checkpoint is not None and checkpoint.append(event):
                await asyncio.to_thread(checkpoint.sync)
        elif kind == "language":
            transcript.language = event.get("language") or transcript.language
            if checkpoint is not None and transcript.language:
                checkpoint.append({"type": "language", "language": transcript.language})
        elif kind == "progress":
            on_progress(float(event.get("position") or 0))
        elif kind == "done":
            transcript.language = event.get("language") or transcript.language
            transcript.speech_seconds = float(event.get("speech_seconds") or 0)


async def _follow_playback(
    proc: process.Spawned, on_paused: Callable[[bool], None], busy: Callable[[], bool]
) -> None:
    while True:
        try:
            loaded = busy()
        except Exception:  # noqa: BLE001 -- 观测失败不该连累识别
            loaded = False
        if loaded and not proc.paused:
            proc.pause()
            if proc.paused:
                logger.info("本机正在为播放转码，语音识别暂停")
                on_paused(True)
        elif not loaded and proc.paused:
            proc.resume()
            logger.info("播放转码结束，语音识别继续")
            on_paused(False)
        await asyncio.sleep(_PLAYBACK_POLL_SECONDS)


# ---------------------------------------------------------------------------
# 识别断点（§4.5）
# ---------------------------------------------------------------------------


class Checkpoint:
    """识别断点（JSON Lines）：首行是身份，之后是锁定的语言与逐段结果，与子进程事件同形。

    主进程边收边追加，约每 10 秒 fsync 一次；重启、崩溃或断电后，身份相同（同一视频
    文件、音轨、声道取法、台词语言、模型与切段参数）就从最后一段的终点接着识别。
    最后一行可能只写了一半，读的时候丢掉；身份不符整份作废。
    """

    def __init__(self, path: Path, identity: dict) -> None:
        self.path = path
        self.identity = {
            **identity,
            "model": MODEL_ID,
            "pad": _PAD_SECONDS,
            "max_speech": _MAX_SPEECH_SECONDS,
        }
        self.created_ns = 0
        self.language: str | None = None
        self.segments: list[dict] = []
        self._fh = None
        self._synced_at = 0.0

    @classmethod
    def load(cls, path: Path, identity: dict, *, stale_created_ns: int | None = None) -> Checkpoint:
        """读断点的有效部分；``stale_created_ns`` 是要作废的那份断点（重新识别时）。"""
        checkpoint = cls(path, identity)
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            return checkpoint
        records: list[dict] = []
        for line in lines:
            try:
                records.append(json.loads(line))
            except ValueError:
                break  # 断电时写了一半的尾行
        if not records or records[0].get("identity") != checkpoint.identity:
            return checkpoint
        created_ns = int(records[0].get("created_ns") or 0)
        if stale_created_ns is not None and created_ns == stale_created_ns:
            return checkpoint
        checkpoint.created_ns = created_ns
        for record in records[1:]:
            if record.get("type") == "language" and record.get("language"):
                checkpoint.language = str(record["language"])
            elif record.get("type") == "segment" and "start_ms" in record:
                checkpoint.segments.append(record)
        return checkpoint

    @property
    def position(self) -> float:
        """已经识别完的位置（秒）：最后一段的终点；续跑从这里开始。"""
        return self.segments[-1]["end_ms"] / 1000 if self.segments else 0.0

    def open(self) -> None:
        """（阻塞）把有效部分原子重写一遍（顺手去掉写了一半的尾行），再接着追加。

        断点只为省时间：写不了（盘满、只读）就不记，识别照常进行。
        """
        if not self.created_ns:
            self.created_ns = time.time_ns()
        head = {"identity": self.identity, "created_ns": self.created_ns}
        records = [head]
        if self.language:
            records.append({"type": "language", "language": self.language})
        records.extend(self.segments)
        tmp = self.path.with_name(self.path.name + ".part")
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in records)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self.path)
            self._fh = open(self.path, "a", encoding="utf-8")  # noqa: SIM115 -- 识别期间一直追加
        except OSError:
            logger.warning("识别断点写不了，这次识别不记断点：%s", self.path, exc_info=True)
            self._fh = None
        self._synced_at = time.monotonic()

    def append(self, record: dict) -> bool:
        """追加一条（只进页缓存）；返回是否该落盘了——落盘阻塞，由调用方放线程池做。"""
        if record.get("type") == "language":
            self.language = record.get("language")
        else:
            self.segments.append(record)
        if self._fh is None:
            return False
        try:
            self._fh.write(json.dumps(record, ensure_ascii=False) + "\n")
            self._fh.flush()
        except OSError:
            logger.warning("识别断点写入失败，之后不再记断点：%s", self.path, exc_info=True)
            self._close_quietly()
            return False
        return time.monotonic() - self._synced_at >= _CHECKPOINT_SYNC_SECONDS

    def sync(self) -> None:
        """（阻塞）把已追加的部分落盘。"""
        self._synced_at = time.monotonic()
        fh = self._fh
        if fh is not None:
            with contextlib.suppress(OSError, ValueError):
                os.fsync(fh.fileno())

    def close(self) -> None:
        """（阻塞）落盘并关闭；断点文件留着，识别外挂写好之后再由调用方删除。"""
        if self._fh is None:
            return
        with contextlib.suppress(OSError):
            self._fh.flush()
            os.fsync(self._fh.fileno())
        self._close_quietly()

    def discard(self) -> None:
        self._close_quietly()
        with contextlib.suppress(OSError):
            self.path.unlink(missing_ok=True)

    def _close_quietly(self) -> None:
        fh, self._fh = self._fh, None
        if fh is not None:
            with contextlib.suppress(OSError):
                fh.close()


# ---------------------------------------------------------------------------
# 断句：识别结果 → 字幕条（纯函数，§4.3）
# ---------------------------------------------------------------------------

_HARD_BREAKS = frozenset("。！？!?…")
_SOFT_BREAKS = frozenset("，、,;；：:")
_CJK_LANGUAGES = frozenset({"chi", "jpn", "kor"})
_MAX_CUE_MS = 7000
#: token 只有起点：两个 token 起点相隔 ≥0.6 秒（≈ 0.3 秒停顿 + 一个字的时长）算停顿
_PAUSE_SPLIT_MS = 600
_LEAD_MS = 100
_MIN_GAP_MS = 80
_MIN_CUE_MS = 800
_MAX_REPEAT = 2
_SPEECH = re.compile(r"\w", re.UNICODE)


def _ends_sentence(token: str) -> bool:
    text = token.strip()
    if not text:
        return False
    if text[-1] in _HARD_BREAKS:
        return True
    # 英文句号：「Mr.」这类缩写会被多切一刀，代价只是多一条字幕
    return text[-1] == "." and not text[:-1].replace(".", "").isdigit()


def _collapse_repeats(tokens: list[tuple[str, int]]) -> list[tuple[str, int]]:
    """同一 token 连续出现 3 次以上只留 2 次（CTC 偶发的复读，不是台词本身）。"""
    out: list[tuple[str, int]] = []
    repeat = 0
    for token, at in tokens:
        if out and token.strip() and token == out[-1][0]:
            repeat += 1
            if repeat >= _MAX_REPEAT:
                continue
        else:
            repeat = 0
        out.append((token, at))
    return out


def _join(tokens: list[tuple[str, int]], cjk: bool) -> str:
    if cjk:
        return "".join(token.strip() for token, _ in tokens)
    # SenseVoice 的英文 token 自带前导空格表示词界，原样拼接即可
    return "".join(token for token, _ in tokens).strip()


def _visible_len(text: str, cjk: bool) -> int:
    return len(text.replace(" ", "")) if cjk else len(text)


def _split(
    tokens: list[tuple[str, int]], segment_end: int, cjk: bool, limit: int
) -> list[tuple[int, int, str]]:
    """一段识别结果断成若干条：句末必切；超长或超时就在最近的逗号或停顿处切。

    每条的终点：同段后面还有条目时到下一条起点为止（台词是连着的）；本段最后一条
    到段尾（VAD 段尾已补过 0.3 秒余量，正好是说完后的停留）。
    """
    pieces: list[tuple[int, int, str]] = []
    current: list[tuple[str, int]] = []
    cut = -1  # 可以切在 current[cut] 之后

    def flush(upto: int) -> None:
        nonlocal current, cut
        group, current = current[: upto + 1], current[upto + 1 :]
        end = current[0][1] if current else segment_end
        pieces.append((group[0][1], end, _join(group, cjk)))
        cut = -1
        for i, (token, _at) in enumerate(current):
            stripped = token.strip()
            if stripped and stripped[-1] in _SOFT_BREAKS:
                cut = i

    for token, at in tokens:
        if current and at - current[-1][1] >= _PAUSE_SPLIT_MS:
            cut = len(current) - 1
        current.append((token, at))
        stripped = token.strip()
        if _ends_sentence(token):
            flush(len(current) - 1)
            continue
        if stripped and stripped[-1] in _SOFT_BREAKS:
            cut = len(current) - 1
        too_long = _visible_len(_join(current, cjk), cjk) > limit
        too_slow = at - current[0][1] > _MAX_CUE_MS
        if (too_long or too_slow) and len(current) > 1:
            flush(cut if 0 <= cut < len(current) - 1 else len(current) - 2)
    if current:
        flush(len(current) - 1)
    # 下一条起点就是这一条的终点，最后一条终点不早于本段最后一个 token
    return [(start, max(end, start + 1), text) for start, end, text in pieces]


def build_cues(segments: list[Segment], language: str) -> list[SubEvent]:
    """识别结果 → 字幕条（``language`` 是识别结果语言码 chi / eng / jpn / kor）。

    规则见 docs/design/subtitle-asr.md §4.3：句末标点必切；逗号、顿号与停顿作候选
    切点；单条 ≤7 秒、≤ 两行字数；起点提前 0.1 秒，终点到下一条之前或段尾（段尾
    含 0.3 秒余量），条间留 80 ms，单条尽量不短于 0.8 秒。
    """
    cjk = language in _CJK_LANGUAGES
    limit = validate.line_limit(language) * 2
    cues: list[tuple[int, int, str]] = []
    for segment in segments:
        tokens = _collapse_repeats(list(segment.tokens)) or [(segment.text, segment.start_ms)]
        for start, end, text in _split(tokens, segment.end_ms, cjk, limit):
            text = text.strip().lstrip("，、,;；：:。.!！?？ ")
            if _SPEECH.search(text):
                cues.append((start, end, text))
    events: list[SubEvent] = []
    for i, (start, end, text) in enumerate(cues):
        begin = max(start - _LEAD_MS, events[-1][1] + _MIN_GAP_MS if events else 0)
        limit_end = cues[i + 1][0] - _LEAD_MS - _MIN_GAP_MS if i + 1 < len(cues) else None
        finish = end if limit_end is None else min(end, limit_end)
        wanted = begin + _MIN_CUE_MS
        if finish < wanted:
            finish = wanted if limit_end is None else max(finish, min(wanted, limit_end))
        events.append((begin, max(finish, begin + 1), text))
    return events

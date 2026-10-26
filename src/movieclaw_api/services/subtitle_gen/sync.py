"""L1 同步度检测：以音轨为真相源的抽样质量门（subtitle-ai-translate.md §5.2）。

参考字幕若与影片不同步，翻译再好也是全片错位——检测发生在烧 LLM 钱
之前。抽样即可（首/中/尾各 ~2 分钟），不扫全片。

VAD 两级：优先 silero-vad ONNX（模型在 data/models/silero-vad/ 时启用，
走 onnxruntime + 模型 Release 分发的既有惯例）；模型缺失/加载失败降级
**能量法**（帧 RMS 阈值，精度有限但零依赖、确定性可测）。任何一级不可用
（如无 ffmpeg/strm 无本体）返回 None=无法检测，调用方按"未知"处理而非
"不同步"。
"""

from __future__ import annotations

import asyncio
import functools
import logging
import os
import shutil
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from movieclaw_api.services.subtitle_gen import process
from movieclaw_api.services.subtitle_gen.extract import SubEvent

logger = logging.getLogger("movieclaw_api.subtitle_gen")

SAMPLE_RATE = 16_000
_WINDOW_SECONDS = 120  # 每个抽样窗时长
_FFMPEG_TIMEOUT = 60.0
#: 事件命中率低于该值判"疑似不同步"（§5.2 阈值；能量法噪声大，宽松取值）
SYNC_THRESHOLD = 0.55


@functools.cache
def _ffmpeg() -> str | None:
    return shutil.which("ffmpeg")


def audio_index(streams: list[dict] | None) -> int:
    """抽样用哪条音轨（同类型序号），``streams`` 是台账的 ``audio_streams``。

    默认第一条；第一条 ffmpeg 解不了（华语 WEB-DL 的 Audio Vivid，探测不出 codec）时，
    换同语言（或语言未知）的第一条解得了的轨。换不了维持第一条，抽样失败按未知处理。
    """
    if not streams or streams[0].get("codec"):
        return 0
    language = streams[0].get("language")
    for index, stream in enumerate(streams[1:], 1):
        other = stream.get("language")
        if stream.get("codec") and (language in (None, "und") or other in (None, "und", language)):
            return index
    return 0


async def extract_pcm(
    video: Path, start_s: float, duration_s: float, audio: int = 0
) -> np.ndarray | None:
    """抽一段 16k 单声道 PCM（``audio`` 是音轨序号）；失败返回 None（无音轨/坏文件/超时）。

    ffmpeg 起在独立进程组里：停止任务时随之结束，不必等它把这一段解码完。
    """
    ffmpeg = _ffmpeg()
    if ffmpeg is None:
        return None
    try:
        result = await process.run(
            [
                ffmpeg, "-nostdin", "-v", "error",
                "-ss", str(start_s), "-t", str(duration_s),
                "-i", str(video),
                "-map", f"0:a:{audio}", "-ac", "1", "-ar", str(SAMPLE_RATE),
                "-f", "s16le", "-",
            ],
            timeout=_FFMPEG_TIMEOUT,
        )
    except process.ProcessTimeout:
        logger.warning("同步检测的音频抽样超时：%s @%ss", video, start_s)
        return None
    except OSError as exc:
        logger.warning("同步检测的音频抽样无法启动 ffmpeg：%s（%s）", video, exc)
        return None
    if result.returncode != 0 or len(result.stdout) < SAMPLE_RATE:  # 至少 0.5 秒
        return None
    return np.frombuffer(result.stdout, dtype=np.int16).astype(np.float32) / 32768.0


# ---------------------------------------------------------------------------
# VAD：silero 优先，能量法兜底
# ---------------------------------------------------------------------------


def _silero_model_path() -> Path:
    return Path(os.environ.get("MOVIECLAW_VAD_DIR", "data/models/silero-vad")) / (
        "silero_vad.onnx"
    )


@functools.cache
def _silero_session():
    """silero-vad ONNX 会话；模型缺失/加载失败返回 None（降级能量法）。"""
    path = _silero_model_path()
    if not path.is_file():
        return None
    try:
        import onnxruntime

        return onnxruntime.InferenceSession(
            str(path), providers=["CPUExecutionProvider"]
        )
    except Exception as exc:  # noqa: BLE001 -- 模型/运行时问题一律降级
        logger.warning("silero-vad 模型加载失败，同步检测降级为能量法：%s", exc)
        return None


def _speech_mask_silero(pcm: np.ndarray) -> np.ndarray | None:
    """silero v5 逐 512 采样帧推理 → 每帧是否语音；失败返回 None。"""
    session = _silero_session()
    if session is None:
        return None
    try:
        frame = 512
        n = len(pcm) // frame
        state = np.zeros((2, 1, 128), dtype=np.float32)
        sr = np.array(SAMPLE_RATE, dtype=np.int64)
        probs = np.empty(n, dtype=np.float32)
        for i in range(n):
            chunk = pcm[i * frame : (i + 1) * frame].reshape(1, -1)
            out, state = session.run(
                None, {"input": chunk, "state": state, "sr": sr}
            )[:2]
            probs[i] = float(out.reshape(-1)[0])
        return probs > 0.5
    except Exception as exc:  # noqa: BLE001 -- 推理形状不符等一律降级
        logger.warning("silero-vad 推理失败，同步检测降级为能量法：%s", exc)
        return None


def _speech_mask_energy(pcm: np.ndarray, frame: int = 512) -> np.ndarray:
    """能量法 VAD：帧 RMS 高于自适应阈值即语音（精度有限的确定性兜底）。"""
    n = len(pcm) // frame
    if n == 0:
        return np.zeros(0, dtype=bool)
    frames = pcm[: n * frame].reshape(n, frame)
    rms = np.sqrt((frames**2).mean(axis=1))
    # 阈值 = 底噪（20 分位）与峰值间的折中；全静音段不误报
    floor = np.percentile(rms, 20)
    threshold = max(floor * 3.0, 0.01)
    return rms > threshold


def speech_intervals(pcm: np.ndarray) -> list[tuple[int, int]]:
    """PCM → 语音区间毫秒表（silero 优先，能量法兜底；合并 300ms 内的间隙）。"""
    mask = _speech_mask_silero(pcm)
    if mask is None:
        mask = _speech_mask_energy(pcm)
    frame_ms = 512 * 1000 / SAMPLE_RATE
    intervals: list[tuple[int, int]] = []
    start: int | None = None
    for i, hit in enumerate(mask):
        if hit and start is None:
            start = int(i * frame_ms)
        elif not hit and start is not None:
            intervals.append((start, int(i * frame_ms)))
            start = None
    if start is not None:
        intervals.append((start, int(len(mask) * frame_ms)))
    # 合并近邻（说话间的自然停顿不该断开区间）
    merged: list[tuple[int, int]] = []
    for s, e in intervals:
        if merged and s - merged[-1][1] <= 300:
            merged[-1] = (merged[-1][0], e)
        else:
            merged.append((s, e))
    return merged


def event_hit_rate(
    speech: list[tuple[int, int]], events: list[tuple[int, int]]
) -> float | None:
    """字幕事件与语音区间的命中率：有任一重叠即命中；无事件返回 None。"""
    if not events:
        return None
    hits = 0
    for es, ee in events:
        for ss, se in speech:
            if es < se and ss < ee:
                hits += 1
                break
    return hits / len(events)


async def sample_sync_score(
    video_path: Path, events: list[SubEvent], runtime_seconds: int | None, audio: int = 0
) -> float | None:
    """抽样同步度（0..1）；None=无法检测（无 ffmpeg/无音轨/事件太少）。

    首/中/尾三窗各 2 分钟，逐窗算事件命中率后取平均；窗内事件不足 5 条
    的窗跳过（片头片尾常无对白，不该拉低分数）。
    """
    if _ffmpeg() is None:
        logger.info("系统中未找到 ffmpeg，跳过字幕同步度检测（结果按未知处理）")
        return None
    runtime = runtime_seconds or (max(e[1] for e in events) // 1000 if events else 0)
    if runtime < _WINDOW_SECONDS * 2 or len(events) < 20:
        return None  # 短片/事件太少，抽样无统计意义
    starts = [
        runtime * 0.1,
        runtime * 0.5 - _WINDOW_SECONDS / 2,
        runtime * 0.9 - _WINDOW_SECONDS,
    ]
    scores: list[float] = []
    for start_s in starts:
        start_ms, end_ms = int(start_s * 1000), int((start_s + _WINDOW_SECONDS) * 1000)
        window_events = [
            (max(0, s - start_ms), e - start_ms)
            for s, e, _ in events
            if s < end_ms and e > start_ms
        ]
        if len(window_events) < 5:
            continue
        pcm = await extract_pcm(video_path, start_s, float(_WINDOW_SECONDS), audio)
        if pcm is None:
            return None  # 音频抽不出来：整个检测按未知处理
        # VAD（尤其 silero 逐帧推理）放线程池：事件循环同时在服务所有请求
        speech = await asyncio.to_thread(speech_intervals, pcm)
        rate = event_hit_rate(speech, window_events)
        if rate is not None:
            scores.append(rate)
    if not scores:
        return None
    return sum(scores) / len(scores)


# ---------------------------------------------------------------------------
# L2 全局校准：FFT 互相关 + 帧率假设集（subtitle-ai-translate.md §5.2）
# ---------------------------------------------------------------------------

#: 帧率换算假设集：1（纯偏移）、PAL 加速/减速、24↔25 等常见转换比
SCALE_HYPOTHESES = (1.0, 25 / 23.976, 23.976 / 25, 24 / 25, 25 / 24, 24 / 23.976, 23.976 / 24)
_RASTER_MS = 10  # 栅格粒度（ffsubsync 同款量级）
_MAX_SHIFT_S = 120  # 搜索窗：±2 分钟覆盖片头广告/logo 的现实差异


def _rasterize(intervals: list[tuple[int, int]], total_ms: int) -> np.ndarray:
    """区间表 → 10ms 栅格 0/1 信号。"""
    n = total_ms // _RASTER_MS + 1
    signal = np.zeros(n, dtype=np.float32)
    for s, e in intervals:
        a = max(0, s // _RASTER_MS)
        b = min(n, e // _RASTER_MS + 1)
        if b > a:
            signal[a:b] = 1.0
    return signal


def _best_offset(reference: np.ndarray, candidate: np.ndarray) -> tuple[int, float]:
    """FFT 互相关求 candidate 相对 reference 的最优平移（毫秒）与相关分。

    去均值后做相关：全 1 段不该白得分；限幅在 ±_MAX_SHIFT_S 内取峰。
    """
    n = max(len(reference), len(candidate))
    size = 1 << (2 * n - 1).bit_length()
    ref = reference - reference.mean()
    cand = candidate - candidate.mean()
    fr = np.fft.rfft(ref, size)
    fc = np.fft.rfft(cand, size)
    corr = np.fft.irfft(fr * np.conj(fc), size)
    # corr[k] = sum ref[i+k]*cand[i]（k>=0：cand 需右移 k 格）；负位移在尾部
    # 搜索窗不能超过真实信号长度。短片的 FFT padding 可能小于固定 ±120s
    # 窗口；直接用超长切片会把 corr 尾部的负 lag 重复塞进“正 lag”区，进而
    # 把 -3s 这类正常校准误报成 +70s 以上、且相关分仍很高。
    max_shift = min(
        _MAX_SHIFT_S * 1000 // _RASTER_MS,
        len(reference) - 1,
        len(candidate) - 1,
    )
    if max_shift <= 0:
        return 0, 0.0
    lags = np.concatenate(
        [np.arange(0, max_shift + 1), np.arange(-max_shift, 0)]
    )
    values = np.concatenate([corr[: max_shift + 1], corr[-max_shift:]])
    peak = int(np.argmax(values))
    denom = float(np.sqrt((ref**2).sum() * (cand**2).sum())) or 1.0
    return int(lags[peak]) * _RASTER_MS, float(values[peak] / denom)


@dataclass(frozen=True)
class Calibration:
    """全局校准结论：t' = scale * t + offset_ms。"""

    scale: float
    offset_ms: int
    score: float  # 归一化相关峰（0..1，越高越可信）


def estimate_calibration(
    reference: list[tuple[int, int]], subtitle: list[tuple[int, int]]
) -> Calibration | None:
    """字幕区间相对参考区间（语音区间或另一条已对齐字幕）的全局校准。

    帧率假设集逐个尝试：把字幕区间按假设 scale 缩放后与参考做互相关，
    取相关峰最大的 (scale, offset)。参考/字幕任一为空返回 None。
    """
    if not reference or not subtitle:
        return None
    total = max(max(e for _, e in reference), max(e for _, e in subtitle)) + 1000
    ref_signal = _rasterize(reference, total)
    best: Calibration | None = None
    for scale in SCALE_HYPOTHESES:
        scaled = [(int(s * scale), int(e * scale)) for s, e in subtitle]
        offset, score = _best_offset(ref_signal, _rasterize(scaled, total))
        if best is None or score > best.score:
            best = Calibration(scale=scale, offset_ms=offset, score=score)
    return best


def apply_calibration(
    events: list[tuple[int, int, str]], calibration: Calibration
) -> list[tuple[int, int, str]]:
    """套用校准到事件序列（起止同变换，负值截 0）。"""
    out = []
    for s, e, text in events:
        ns = max(0, int(s * calibration.scale) + calibration.offset_ms)
        ne = max(ns, int(e * calibration.scale) + calibration.offset_ms)
        out.append((ns, ne, text))
    return out

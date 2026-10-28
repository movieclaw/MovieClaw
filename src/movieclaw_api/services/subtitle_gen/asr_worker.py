"""本地语音识别子进程：silero VAD 切段 → SenseVoice 逐段识别，结果逐行输出 JSON。

由 ``asr.transcribe`` 用 ``sys.executable -I <本文件>`` 启动（docs/design/subtitle-asr.md
§4.2）。隔离模式下同目录的模块盖不住标准库，也碰不到 movieclaw 自己的代码；这里只
依赖 sherpa_onnx 与 numpy。模型只在这个进程里加载，任务结束随进程释放，主进程的
内存预算不受影响。

stdin 读一行 JSON 参数（``start``：从片中第几秒接着识别，断点续跑用；``parent``：主进程
pid），stdout 每行一个 JSON 事件：

- ``{"type": "progress", "position": 秒}``：已经过 VAD 的音频位置；
- ``{"type": "language", "language"}``：台词语言定下来了（指定的，或投票锁定的），
  先于第一个 ``segment``；
- ``{"type": "segment", "start_ms", "end_ms", "text", "tokens", "timestamps", "lang"}``：
  一段识别结果，``timestamps`` 是各 token 相对本段起点的秒数；
- ``{"type": "done", "language", "speech_seconds", "segments"}``：全部完成。

``--self-test <wav>``：只识别一段测试音频并打印文本（镜像构建期冒烟用）。
"""

from __future__ import annotations

import contextlib
import json
import os
import sys
import wave
from collections import Counter

import numpy as np

SAMPLE_RATE = 16_000
#: 每次从 WAV 读 10 秒；两小时的片子整读进来要近 1 GB，只在内存里留还没识别的那一段
_CHUNK_FRAMES = SAMPLE_RATE * 10
#: 台词语言未知时，用前 20 段的多数结果锁定语言，再用锁定的语言重识别这 20 段
_DETECT_SEGMENTS = 20
#: 内存里最少留多少秒：VAD 在一段说完（或到 20 秒上限）时才吐出它，起点不会早于这个窗口
_KEEP_SECONDS = 60
SUPPORTED = ("zh", "yue", "en", "ja", "ko")


def _die_with_parent(parent: int | None) -> None:
    """主进程意外死掉（被杀、崩溃）时让内核直接结束本进程。

    因转码暂停（SIGSTOP）中的进程既收不到别的信号、也读不到管道断开，只有 SIGKILL
    能结束它；不设的话主进程崩溃后它会一直停在那里占着约 0.5 GB 内存。
    ``PR_SET_PDEATHSIG`` 只有 Linux 有（镜像就是 Linux），其他平台靠写管道失败退出。
    """
    if not sys.platform.startswith("linux"):
        return
    import ctypes
    import signal

    with contextlib.suppress(OSError, AttributeError):
        ctypes.CDLL(None, use_errno=True).prctl(1, int(signal.SIGKILL))  # PR_SET_PDEATHSIG
    if parent is not None and os.getppid() != parent:
        os._exit(1)  # 设置之前主进程就已经没了


def _emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _recognizer(params: dict, language: str):
    import sherpa_onnx

    return sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=params["model"],
        tokens=params["tokens"],
        num_threads=int(params.get("threads", 2)),
        use_itn=True,
        language=language,
    )


def _vad(params: dict):
    """返回 (VAD, 每次喂入的窗口样本数)。"""
    import sherpa_onnx

    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = params["vad"]
    config.silero_vad.threshold = 0.5
    config.silero_vad.min_silence_duration = 0.25
    config.silero_vad.min_speech_duration = 0.25
    config.silero_vad.max_speech_duration = float(params.get("max_speech", 20.0))
    config.sample_rate = SAMPLE_RATE
    config.num_threads = 1
    vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=60)
    return vad, int(config.silero_vad.window_size)


def _decode(recognizer, samples: np.ndarray):
    stream = recognizer.create_stream()
    stream.accept_waveform(SAMPLE_RATE, samples)
    recognizer.decode_stream(stream)
    return stream.result


def _language(result) -> str:
    return str(getattr(result, "lang", "") or "").strip("<|>")


class _Audio:
    """顺序读 16 kHz 单声道 16 位 WAV，内存里只留还要用到的那一段样本。"""

    def __init__(self, path: str) -> None:
        self._wav = wave.open(path, "rb")  # noqa: SIM115 -- 整个进程期间顺序读，随进程结束释放
        if (
            self._wav.getframerate() != SAMPLE_RATE
            or self._wav.getnchannels() != 1
            or self._wav.getsampwidth() != 2
        ):
            raise SystemExit(f"unsupported wav format: {path}")
        self.total = self._wav.getnframes()
        self.buffer = np.zeros(0, dtype=np.float32)
        self.offset = 0  # buffer[0] 的绝对样本序号
        self.read = 0

    def next_chunk(self) -> np.ndarray | None:
        raw = self._wav.readframes(_CHUNK_FRAMES)
        if not raw:
            return None
        chunk = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        self.buffer = np.concatenate([self.buffer, chunk])
        self.read += len(chunk)
        return chunk

    def slice(self, start: int, end: int) -> np.ndarray:
        return self.buffer[max(0, start - self.offset) : max(0, end - self.offset)]

    def forget_before(self, sample: int) -> None:
        # 不能丢到还没读的位置之后：offset 要始终是 buffer 首个样本的真实位置
        sample = min(sample, self.read)
        drop = sample - self.offset
        if drop > 0:
            self.buffer = self.buffer[drop:]
            self.offset = sample


class _Transcriber:
    """VAD 段 → 补余量 → 识别 → 输出；台词语言未知时先投票再锁定。"""

    def __init__(self, params: dict, audio: _Audio) -> None:
        self.params = params
        self.audio = audio
        self.pad = int(float(params.get("pad", 0.3)) * SAMPLE_RATE)
        language = params.get("language")
        self.language = language if language in SUPPORTED else None
        self.recognizer = _recognizer(params, self.language or "auto")
        self.votes: Counter[str] = Counter()
        self.held: list[tuple[int, int, np.ndarray]] = []
        self.speech = 0
        self.count = 0
        # 一段要等下一段出现才能定右侧余量（不越过两段中点），所以压一段再识别
        self.pending: tuple[int, int] | None = None
        self.left_bound = 0
        if self.language is not None:
            _emit({"type": "language", "language": self.language})

    def add(self, start: int, end: int) -> None:
        self.speech += end - start
        if self.pending is not None:
            self._finish(self.pending, next_start=start)
        self.pending = (start, end)

    def flush(self) -> None:
        if self.pending is not None:
            self._finish(self.pending, next_start=None)
            self.pending = None
        if self.language is None:
            self._lock_language()

    def _finish(self, span: tuple[int, int], *, next_start: int | None) -> None:
        start, end = span
        right_bound = self.audio.total if next_start is None else (end + next_start) // 2
        lo = max(self.left_bound, start - self.pad)
        hi = min(right_bound, end + self.pad)
        self.left_bound = hi
        samples = self.audio.slice(lo, hi).copy()
        self.audio.forget_before(lo)
        if len(samples) == 0:
            return
        if self.language is None:
            result = _decode(self.recognizer, samples)
            language = _language(result)
            if language in SUPPORTED and result.text.strip():
                self.votes[language] += 1
            self.held.append((lo, hi, samples))
            if len(self.held) >= _DETECT_SEGMENTS:
                self._lock_language()
            return
        self._emit_segment(lo, hi, _decode(self.recognizer, samples))

    def _lock_language(self) -> None:
        if self.votes:
            self.language = self.votes.most_common(1)[0][0]
            self.recognizer = _recognizer(self.params, self.language)
            _emit({"type": "language", "language": self.language})
        held, self.held = self.held, []
        for lo, hi, samples in held:
            self._emit_segment(lo, hi, _decode(self.recognizer, samples))

    def _emit_segment(self, lo: int, hi: int, result) -> None:
        text = result.text.strip()
        if not text:
            return
        self.count += 1
        _emit(
            {
                "type": "segment",
                "start_ms": lo * 1000 // SAMPLE_RATE,
                "end_ms": hi * 1000 // SAMPLE_RATE,
                "text": text,
                "tokens": list(result.tokens),
                "timestamps": [round(float(t), 3) for t in result.timestamps],
                "lang": _language(result),
            }
        )


def run(params: dict) -> None:
    _die_with_parent(params.get("parent"))
    with contextlib.suppress(OSError, AttributeError):
        os.nice(19)  # 后台活：CPU 让给播放与接口
    audio = _Audio(params["wav"])
    vad, window = _vad(params)
    transcriber = _Transcriber(params, audio)
    # 断点续跑：VAD 照样从片头跑（只切段、不识别，约 300 倍实时），断点之前的段已经在断点里，
    # 丢掉。VAD 的状态从第一个样本一路带下来，从断点处冷启动或只往回预热一段，之后的切段
    # 都会和不中断时不同（实测预热 60 秒也只保住接缝后约 200 秒）；从片头重放则逐段一致
    resume = int(round(float(params.get("start") or 0) * SAMPLE_RATE))
    transcriber.left_bound = resume
    tail = np.zeros(0, dtype=np.float32)
    keep = _KEEP_SECONDS * SAMPLE_RATE

    def drain() -> None:
        while not vad.empty():
            segment = vad.front
            start = int(segment.start)
            if start >= resume:
                transcriber.add(start, start + len(segment.samples))
            vad.pop()

    while (chunk := audio.next_chunk()) is not None:
        # VAD 要求固定窗口长度喂入：上一块剩下不足一窗的样本拼到这一块前面
        data = np.concatenate([tail, chunk])
        usable = len(data) - len(data) % window
        for i in range(0, usable, window):
            vad.accept_waveform(data[i : i + window])
        tail = data[usable:]
        drain()
        # 只留最近一分钟（VAD 吐出的段起点不会早于这里），压着的那段留到它的左余量
        keep_from = audio.read - keep
        if transcriber.pending is not None:
            keep_from = min(keep_from, transcriber.pending[0] - transcriber.pad)
        audio.forget_before(max(transcriber.left_bound, keep_from))
        # 断点之前重放 VAD 的那段不算进度：进度不能从断点往回跳
        _emit({"type": "progress", "position": round(max(audio.read, resume) / SAMPLE_RATE, 1)})
    vad.flush()
    drain()
    transcriber.flush()
    _emit(
        {
            "type": "done",
            "language": transcriber.language,
            "speech_seconds": round(transcriber.speech / SAMPLE_RATE, 1),
            "segments": transcriber.count,
        }
    )


def self_test(model_dir: str, wav: str) -> int:
    params = {
        "model": os.path.join(model_dir, "model.int8.onnx"),
        "tokens": os.path.join(model_dir, "tokens.txt"),
        "threads": 1,
    }
    audio = _Audio(wav)
    audio.next_chunk()
    text = _decode(_recognizer(params, "auto"), audio.buffer).text.strip()
    print(text)
    return 0 if text else 1


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--self-test":
        return self_test(sys.argv[2], sys.argv[3])
    run(json.loads(sys.stdin.readline()))
    return 0


if __name__ == "__main__":
    sys.exit(main())

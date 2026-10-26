"""ffmpeg 能力探测：hello 里申报什么，全部是本机真跑出来的结论，不是按显卡型号推断的。

NAS 探测不到远程 Worker 的硬件，只能信它的申报（docs/design/remote-transcode.md §5.2）：
``encoders`` / ``filters`` / ``hw_decoders`` / ``read_options`` 都用 ffmpeg 自己实测。

- 登记之前先真跑一遍 NAS 会下发的那条 NVENC 链（硬解 → ``scale_cuda`` → ``h264_nvenc``）：驱动没装、
  显卡不支持、ffmpeg 不是带 CUDA 滤镜的构建，都在启动时就说清楚原因，而不是等到第一次播放失败；
- ``tonemap_cuda`` 同样真跑一遍 HDR 样片才申报：没有它，NAS 的 HDR 片退回本机 CPU 的 ``tonemapx``，
  吞吐只有 GPU 链的四分之一；
- ``hw_decoders`` 逐个编码用一段几帧的样片实测 NVDEC：能不能硬解每块显卡不一样（AV1 要 RTX 30 起，
  Hi10P 的 H.264 谁都解不了），按型号表推断必然有错。

没有样片编码器的编码（VC-1：ffmpeg 没有它的编码器）不申报。探测结果按 ffmpeg 与驱动版本缓存。
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import subprocess
import tempfile
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .config import ffmpeg_env
from .telemetry import memory_status

#: 子进程不弹控制台窗：pythonw / 开机自启时没有可继承的控制台，不加这个每次起 ffmpeg 都会自建黑窗。
#: 常量只有 Windows 有，其它平台取 0
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

#: 缓存格式版本：新增探测项时旧缓存必须失效重探，否则 hello 的新字段恒空
SCHEMA = 1

#: NAS 装命令时用得上的 GPU / 软件滤镜。其余滤镜不申报
REPORTED_FILTERS = ("scale_cuda", "tonemap_cuda", "tonemapx", "hwupload_cuda", "hwdownload")

#: 自检样片的尺寸：NVENC / NVDEC 对太小的画面有下限（H.264 编码器在 Turing 上实测宽度不到 145 就
#: 打不开），样片要选得比各家的下限大
SAMPLE_SIZE = "320x180"

#: HDR10（PQ + BT.2020）自检样片的色彩标签。要靠滤镜写到帧上：编码器的 ``-color_trc`` 选项在新版
#: ffmpeg 里不会进码流，样片就成了「传输特性未知」，tonemap_cuda 会拒绝它
HDR10_SAMPLE_FILTER = (
    "format=p010le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc"
)

#: 与 ``ffmpeg_args.NVENC_TONEMAP`` 同一串（tests/windows_transcoder 里有测试逐字核对）：
#: 探测用的滤镜串必须就是真实转码用的那一串，否则「探测过了」没有意义
NVENC_TONEMAP = "tonemap_cuda=tonemap=bt2390:desat=0:p=bt709:t=bt709:m=bt709:format=yuv420p"

#: NAS 取源时可能加的输入选项（docs/design/transcode-latency.md §6.2）。未知选项会让 ffmpeg 直接
#: 退出，所以要先问 ffmpeg 自己认不认
READ_OPTIONS = ("skip_estimate_duration_from_pts",)


class FfmpegProblem(Exception):
    """这份 ffmpeg 不能登记为硬件转码 Worker。文案直接给人看：说明原因与下一步。"""


@dataclass(frozen=True)
class Capabilities:
    ffmpeg_version: str
    encoders: tuple[str, ...]
    filters: tuple[str, ...]
    hw_decoders: tuple[str, ...]
    read_options: tuple[str, ...]
    hardware: dict[str, object] = field(default_factory=dict)

    @property
    def backends(self) -> list[str]:
        return ["nvenc"] if "h264_nvenc" in self.encoders else []


Runner = Callable[[Sequence[str], float], "subprocess.CompletedProcess[str]"]


def run(args: Sequence[str], timeout: float = 60.0) -> subprocess.CompletedProcess[str]:
    """跑一条命令，输出按 UTF-8 解码（Windows 控制台默认 GBK，ffmpeg 的输出不是）。"""
    return subprocess.run(
        list(args),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        stdin=subprocess.DEVNULL,
        creationflags=NO_WINDOW,
        env=ffmpeg_env(),
        check=False,
    )


# -- 解析（纯函数，单测直接喂 ffmpeg 的样例输出）-----------------------------


def parse_version(output: str) -> str:
    """``ffmpeg version 7.1.1-Jellyfin Copyright …`` → ``7.1.1-Jellyfin``。"""
    first = (output.splitlines() or [""])[0]
    if first.lower().startswith("ffmpeg version "):
        return first[len("ffmpeg version ") :].split()[0]
    return "unknown"


def parse_encoders(output: str) -> list[str]:
    """从 ``ffmpeg -encoders`` 取编码器名。

    输出开头是一段标志位图例（`` V..... = Video``…），它们的第一列同样是 6 个字符，只按列宽过滤
    会把图例的 ``=`` 当成编码器收进来：图例行第二列固定是 ``=``，据此排除；``------`` 分隔行
    只有一列，本来就过不了。
    """
    names: list[str] = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 2 and len(fields[0]) == 6 and fields[1] != "=":
            names.append(fields[1])
    return names


def parse_filters(output: str) -> list[str]:
    """从 ``ffmpeg -filters`` 取滤镜名。数据行形如 `` .S tonemap   V->V   说明``，第三列是输入输出
    类型（含 ``->``）；开头的图例行（``T.. = Timeline support``）第二列是 ``=``、没有 ``->``。"""
    names: list[str] = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 3 and "->" in fields[2]:
            names.append(fields[1])
    return names


def parse_option_names(output: str) -> set[str]:
    """从 ``ffmpeg -h full`` / ``-h filter=…`` 取选项名。

    选项行形如 ``  -name <type> …`` 或 ``name  <type>``。
    """
    names: set[str] = set()
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        head = stripped.split(None, 1)[0]
        names.add(head.lstrip("-"))
    return names


def filter_has_option(help_text: str, option: str) -> bool:
    return option in parse_option_names(help_text)


# -- 样片 ------------------------------------------------------------------

#: (ffmpeg 编码名, 样片用的编码器候选（第一个本机有的）, 额外参数, 扩展名)
_SAMPLES: tuple[tuple[str, tuple[str, ...], tuple[str, ...], str], ...] = (
    ("h264", ("libx264", "h264_nvenc"), (), "mkv"),
    ("hevc", ("libx265", "hevc_nvenc"), (), "mkv"),
    ("vp9", ("libvpx-vp9",), ("-deadline", "realtime", "-cpu-used", "8"), "mkv"),
    ("av1", ("libsvtav1", "libaom-av1", "av1_nvenc"), (), "mkv"),
    ("mpeg2video", ("mpeg2video",), (), "mkv"),
    ("mpeg4", ("mpeg4",), (), "mkv"),
    ("vp8", ("libvpx",), ("-deadline", "realtime", "-cpu-used", "8"), "mkv"),
)


def _make_sample(
    ffmpeg: str, runner: Runner, encoders: set[str], codec: str, directory: Path
) -> Path | None:
    for name, candidates, extra, extension in _SAMPLES:
        if name != codec:
            continue
        encoder = next((c for c in candidates if c in encoders), None)
        if encoder is None:
            return None
        path = directory / f"sample-{codec}.{extension}"
        result = runner(
            [
                ffmpeg, "-hide_banner", "-v", "error", "-y",
                "-f", "lavfi", "-i", f"testsrc2=size={SAMPLE_SIZE}:rate=24:duration=0.5",
                "-pix_fmt", "yuv420p", "-c:v", encoder, *extra, str(path),
            ],
            60.0,
        )  # fmt: skip
        return path if result.returncode == 0 and path.exists() else None
    return None


def _decodes_on_gpu(ffmpeg: str, runner: Runner, sample: Path) -> bool:
    """NVDEC 真能解这段样片：帧必须留在显存里（``hwdownload`` 接得上），否则 ffmpeg 退回软解
    后软件帧喂给 GPU 滤镜会失败——正是 NAS 的 NVENC 命令会撞上的那种失败。"""
    result = runner(
        [
            ffmpeg, "-hide_banner", "-v", "error",
            "-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
            "-i", str(sample), "-vf", "hwdownload,format=nv12",
            "-frames:v", "1", "-f", "null", "-",
        ],
        60.0,
    )  # fmt: skip
    return result.returncode == 0


def _self_test_chain(ffmpeg: str, runner: Runner) -> subprocess.CompletedProcess[str]:
    """NAS 下发的 NVENC 链的缩影：软件帧上传 → ``scale_cuda``（带 format 选项）→ ``h264_nvenc``。"""
    return runner(
        [
            ffmpeg, "-hide_banner", "-v", "error",
            "-init_hw_device", "cuda=cu:0", "-filter_hw_device", "cu",
            "-f", "lavfi", "-i", f"testsrc2=size={SAMPLE_SIZE}:rate=24:duration=0.5",
            "-vf", "format=yuv420p,hwupload_cuda,scale_cuda=format=yuv420p:w=-2:h=144",
            "-c:v", "h264_nvenc", "-f", "null", "-",
        ],
        60.0,
    )  # fmt: skip


def _tonemap_cuda_works(ffmpeg: str, runner: Runner, directory: Path) -> bool:
    """用一段 10-bit PQ（HDR10）样片真跑 NAS 的 HDR 链：解码、色调映射、缩放、编码全在显卡上。"""
    sample = directory / "sample-hdr10.mkv"
    made = runner(
        [
            ffmpeg, "-hide_banner", "-v", "error", "-y",
            "-f", "lavfi", "-i", f"testsrc2=size={SAMPLE_SIZE}:rate=24:duration=0.5",
            "-vf", HDR10_SAMPLE_FILTER,
            "-c:v", "hevc_nvenc", str(sample),
        ],
        60.0,
    )  # fmt: skip
    if made.returncode != 0 or not sample.exists():
        return False
    result = runner(
        [
            ffmpeg, "-hide_banner", "-v", "error",
            "-hwaccel", "cuda", "-hwaccel_output_format", "cuda", "-i", str(sample),
            "-vf", f"{NVENC_TONEMAP},scale_cuda=format=yuv420p:w=-2:h=144",
            "-c:v", "h264_nvenc", "-f", "null", "-",
        ],
        60.0,
    )  # fmt: skip
    return result.returncode == 0


# -- 硬件信息 -----------------------------------------------------------------


def gpu_info(runner: Runner = run) -> tuple[str | None, str | None]:
    """(显卡型号, 驱动版本)：问 ``nvidia-smi``，没有就都是 None（不影响登记）。"""
    exe = shutil.which("nvidia-smi")
    if exe is None:
        return None, None
    try:
        result = runner([exe, "--query-gpu=name,driver_version", "--format=csv,noheader"], 10.0)
    except (OSError, subprocess.SubprocessError):
        return None, None
    if result.returncode != 0 or not result.stdout.strip():
        return None, None
    name, _, driver = result.stdout.splitlines()[0].partition(",")
    return name.strip() or None, driver.strip() or None


# -- 入口 ------------------------------------------------------------------


def probe(
    ffmpeg: str,
    *,
    runner: Runner = run,
    cache_file: Path | None = None,
    work_dir: Path | None = None,
    log: Callable[[str], None] = lambda _message: None,
) -> Capabilities:
    """探测并校验一份 ffmpeg。不能登记为硬件转码 Worker 时抛 ``FfmpegProblem``。"""
    gpu, driver = gpu_info(runner)
    key = _cache_key(ffmpeg, driver)
    if cache_file is not None:
        cached = _load_cache(cache_file, key)
        if cached is not None:
            return cached

    try:
        version_out = runner([ffmpeg, "-hide_banner", "-version"], 15.0)
    except FileNotFoundError:
        raise FfmpegProblem(
            f"找不到 ffmpeg：{ffmpeg}。请用 --ffmpeg 指定 ffmpeg.exe 的路径（推荐 jellyfin-ffmpeg）"
        ) from None
    except (OSError, subprocess.SubprocessError) as exc:
        raise FfmpegProblem(f"ffmpeg 无法运行：{exc}（{ffmpeg}）") from exc
    if version_out.returncode != 0:
        raise FfmpegProblem(f"ffmpeg 无法运行（退出码 {version_out.returncode}）：{ffmpeg}")

    encoders = parse_encoders(runner([ffmpeg, "-hide_banner", "-encoders"], 30.0).stdout)
    if "h264_nvenc" not in encoders:
        raise FfmpegProblem(
            "这份 ffmpeg 没有 h264_nvenc 编码器，不能登记为硬件转码 Worker。"
            "请换一份带 NVENC 的构建（推荐 jellyfin-ffmpeg 的 Windows 版）"
        )
    filters = parse_filters(runner([ffmpeg, "-hide_banner", "-filters"], 30.0).stdout)
    missing = [name for name in ("scale_cuda", "tonemapx") if name not in filters]
    if missing:
        raise FfmpegProblem(
            f"这份 ffmpeg 缺少滤镜 {'、'.join(missing)}：NAS 的 NVENC 命令链与 HDR 色调映射要用到，"
            "请换 jellyfin-ffmpeg（上游 ffmpeg 没有这些）"
        )
    help_scale = runner([ffmpeg, "-hide_banner", "-h", "filter=scale_cuda"], 30.0).stdout
    if not filter_has_option(help_scale, "format"):
        raise FfmpegProblem(
            "这份 ffmpeg 的 scale_cuda 不认 format 选项，NAS 的命令链跑不起来，请换 jellyfin-ffmpeg"
        )

    with _scratch(work_dir) as scratch:
        log("自检 NVENC 命令链…")
        chain = _self_test_chain(ffmpeg, runner)
        if chain.returncode != 0:
            tail = " ".join((chain.stderr or "").strip().splitlines()[-3:])[-400:]
            raise FfmpegProblem(
                "NVENC 自检失败，这台机器现在转不了码："
                + (tail or f"ffmpeg 退出码 {chain.returncode}")
                + "。请确认已安装 NVIDIA 驱动、显卡支持 NVENC，且没有被别的程序占满编码会话"
            )

        encoder_set = set(encoders)
        hw_decoders: list[str] = []
        for codec, *_ in _SAMPLES:
            sample = _make_sample(ffmpeg, runner, encoder_set, codec, scratch)
            if sample is not None and _decodes_on_gpu(ffmpeg, runner, sample):
                hw_decoders.append(codec)
        log("显卡能硬解的编码：" + ("、".join(hw_decoders) or "无"))

        reported = [name for name in REPORTED_FILTERS if name in filters]
        if "tonemap_cuda" in reported and not _tonemap_cuda_works(ffmpeg, runner, scratch):
            reported.remove("tonemap_cuda")
            log("tonemap_cuda 自检没通过：HDR 片会走 CPU 色调映射（慢，但能播）")

    help_full = runner([ffmpeg, "-hide_banner", "-h", "full"], 60.0).stdout
    declared = parse_option_names(help_full)
    capabilities = Capabilities(
        ffmpeg_version=parse_version(version_out.stdout),
        encoders=tuple(sorted(set(encoders) & {"h264_nvenc", "hevc_nvenc"})),
        filters=tuple(reported),
        hw_decoders=tuple(hw_decoders),
        read_options=tuple(name for name in READ_OPTIONS if name in declared),
        hardware=_hardware(gpu),
    )
    if cache_file is not None:
        _save_cache(cache_file, key, capabilities)
    return capabilities


def _hardware(gpu: str | None) -> dict[str, object]:
    info: dict[str, object] = {}
    if gpu:
        info["chip"] = gpu[:128]
    if os.cpu_count():
        info["cpu_cores"] = os.cpu_count()
    memory = memory_status()[0]
    if memory > 0:
        info["memory_bytes"] = memory
    return info


@contextlib.contextmanager
def _scratch(work_dir: Path | None):  # type: ignore[no-untyped-def]
    """样片的临时目录，用完就删。"""
    root = work_dir if work_dir is not None else Path(tempfile.gettempdir())
    root.mkdir(parents=True, exist_ok=True)
    path = Path(tempfile.mkdtemp(prefix="mc-probe-", dir=root))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


# -- 缓存 ------------------------------------------------------------------


def _cache_key(ffmpeg: str, driver: str | None) -> str:
    resolved = shutil.which(ffmpeg) or ffmpeg
    try:
        stat = os.stat(resolved)
        fingerprint = f"{stat.st_mtime_ns}:{stat.st_size}"
    except OSError:
        fingerprint = "?"
    return f"{SCHEMA}|{resolved}|{fingerprint}|{driver or '?'}"


def _load_cache(path: Path, key: str) -> Capabilities | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("key") != key:
            return None
        body = data["capabilities"]
        return Capabilities(
            ffmpeg_version=str(body["ffmpeg_version"]),
            encoders=tuple(body["encoders"]),
            filters=tuple(body["filters"]),
            hw_decoders=tuple(body["hw_decoders"]),
            read_options=tuple(body["read_options"]),
            hardware=dict(body.get("hardware") or {}),
        )
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _save_cache(path: Path, key: str, capabilities: Capabilities) -> None:
    with contextlib.suppress(OSError):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"key": key, "capabilities": asdict(capabilities)}, ensure_ascii=False),
            encoding="utf-8",
        )

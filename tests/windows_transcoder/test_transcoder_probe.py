"""能力探测：hello 里申报什么，全是本机真跑出来的结论，不是按显卡型号推断的。

用 ffmpeg 的替身（``FakeFfmpeg``）按命令行内容应答，逐个场景检查登记条件、申报内容与缓存；
真显卡上跑出来的结果由 ``tests/playback/test_windows_transcoder_e2e.py`` 覆盖。
"""

from __future__ import annotations

import subprocess

import pytest
from movieclaw_transcoder import probe as probe_module
from movieclaw_transcoder.probe import (
    NVENC_TONEMAP,
    READ_OPTIONS,
    SCHEMA,
    FfmpegProblem,
    filter_has_option,
    gpu_info,
    parse_encoders,
    parse_filters,
    parse_option_names,
    parse_version,
    probe,
)

ENCODERS = """Encoders:
 V..... = Video
 A..... = Audio
 S..... = Subtitle
 .F.... = Frame-level multithreading
 ..S... = Slice-level multithreading
 ...X.. = Codec is experimental
 ....B. = Supports draw_horiz_band
 .....D = Supports direct rendering method 1
 ------
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
 V....D libx265              libx265 H.265 / HEVC (codec hevc)
 V....D libvpx-vp9           libvpx VP9 (codec vp9)
 V....D libvpx               libvpx VP8 (codec vp8)
 V....D libsvtav1            SVT-AV1(Scalable Video Technology for AV1) encoder (codec av1)
 V....D mpeg2video           MPEG-2 video
 V....D mpeg4                MPEG-4 part 2
 V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
 V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)
 A....D aac                  AAC (Advanced Audio Coding)
"""

FILTERS = """Filters:
  T.. = Timeline support
  .S. = Slice threading
  ..C = Command support
  A = Audio input/output
  V = Video input/output
  N = Dynamic number and/or type of input/output
  | = Source or sink filter
 ... scale_cuda        V->V       GPU accelerated video resizer
 ... tonemap_cuda      V->V       GPU accelerated HDR image tonemapping
 TS. tonemapx          V->V       Conversion of HDR video to SDR using SIMD
 ... hwupload_cuda     V->V       Upload a system memory frame to a CUDA device.
 ... hwdownload        V->V       Download a hardware frame to a normal frame
 ... scale             V->V       Scale the input video size and/or convert the image format.
"""

SCALE_CUDA_HELP = """Filter scale_cuda
  GPU accelerated video resizer
    Inputs:
       #0: default (video)
    Outputs:
       #0: default (video)
scale_cuda AVOptions:
  w                 <string>     ..FV....... Output video width (default "iw")
  h                 <string>     ..FV....... Output video height (default "ih")
  interp_algo       <int>        ..FV....... Interpolation algorithm for resizing (default nearest)
  format            <pix_fmt>    ..FV....... Output video pixel format (default none)
"""

HELP_FULL = """Generic options:
-skip_estimate_duration_from_pts <boolean> .D......... skip estimation of duration
-reconnect         <boolean>    .D......... auto reconnect after disconnect before EOF
"""

SAMPLE_CODEC = {
    "libx264": "h264", "h264_nvenc": "h264",
    "libx265": "hevc", "hevc_nvenc": "hevc",
    "libvpx-vp9": "vp9", "libsvtav1": "av1", "libaom-av1": "av1", "av1_nvenc": "av1",
    "mpeg2video": "mpeg2video", "mpeg4": "mpeg4", "libvpx": "vp8",
}  # fmt: skip

NVDEC_DECODES = ("h264", "hevc", "vp9", "mpeg2video", "mpeg4", "vp8")  # 没有 AV1：RTX 20 系


def done(stdout: str = "", stderr: str = "", code: int = 0) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess([], code, stdout, stderr)


class FakeFfmpeg:
    """按命令行内容应答的 ffmpeg / nvidia-smi 替身；``calls`` 记录每一次调用。"""

    def __init__(
        self,
        tmp_path,
        *,
        encoders: str = ENCODERS,
        filters: str = FILTERS,
        scale_cuda_help: str = SCALE_CUDA_HELP,
        help_full: str = HELP_FULL,
        self_test: subprocess.CompletedProcess[str] | None = None,
        nvdec: tuple[str, ...] = NVDEC_DECODES,
        tonemap_works: bool = True,
        version: str = "ffmpeg version 7.1.1-Jellyfin Copyright (c) 2000-2025 the FFmpeg devs\n",
    ) -> None:
        self.calls: list[list[str]] = []
        self.path = tmp_path / "ffmpeg.exe"
        self.path.write_bytes(b"fake ffmpeg build 1")
        self.encoders, self.filters = encoders, filters
        self.scale_cuda_help, self.help_full = scale_cuda_help, help_full
        self.self_test = self_test or done()
        self.nvdec, self.tonemap_works = nvdec, tonemap_works
        self.version_text = version
        self.smi_output: str | None = None  # None = 这台机器没有 nvidia-smi

    def __call__(self, args, timeout=60.0):
        argv = [str(arg) for arg in args]
        self.calls.append(argv)
        if "nvidia-smi" in argv[0]:
            return done(self.smi_output or "")
        if "-version" in argv:
            return done(self.version_text)
        if "-encoders" in argv:
            return done(self.encoders)
        if "-filters" in argv:
            return done(self.filters)
        if "filter=scale_cuda" in argv:
            return done(self.scale_cuda_help)
        if "full" in argv:
            return done(self.help_full)
        if "hwupload_cuda" in " ".join(argv):
            return self.self_test
        if "-hwaccel" in argv:  # 解码检查（逐个编码）与 HDR 整条链
            vf = argv[argv.index("-vf") + 1]
            if "tonemap_cuda" in vf:
                return done() if self.tonemap_works else done(stderr="tonemap failed", code=1)
            sample = argv[argv.index("-i") + 1]
            with open(sample, encoding="ascii") as handle:
                codec = SAMPLE_CODEC[handle.read()]
            return done() if codec in self.nvdec else done(stderr="no nvdec", code=1)
        if "lavfi" in argv:  # 造样片：把编码器名写进文件，后面的解码检查靠它认出是哪种编码
            encoder = argv[argv.index("-c:v") + 1]
            if encoder not in self.encoders:
                return done(stderr=f"Unknown encoder '{encoder}'", code=1)
            with open(argv[-1], "w", encoding="ascii") as handle:
                handle.write(encoder)
            return done()
        raise AssertionError(f"替身不认识这条命令：{argv}")

    def run(self, **kwargs):
        return probe(str(self.path), runner=self, **kwargs)


@pytest.fixture
def no_nvidia_smi(monkeypatch):
    monkeypatch.setattr(probe_module.shutil, "which", lambda _name: None)


@pytest.fixture
def fake(tmp_path, no_nvidia_smi):
    return FakeFfmpeg(tmp_path)


# -- 解析 ------------------------------------------------------------------


def test_parse_version_takes_the_first_word_after_ffmpeg_version():
    assert parse_version("ffmpeg version 7.1.1-Jellyfin Copyright (c) 2000-2025\nbuilt with") == (
        "7.1.1-Jellyfin"
    )
    assert parse_version("") == "unknown"
    assert parse_version("something else") == "unknown"


def test_parse_encoders_skips_the_legend_and_the_separator():
    names = parse_encoders(ENCODERS)

    assert "h264_nvenc" in names and "libx264" in names and "aac" in names
    assert "=" not in names and "------" not in names


def test_parse_filters_reads_the_io_column_and_skips_the_legend():
    names = parse_filters(FILTERS)

    assert names == [
        "scale_cuda",
        "tonemap_cuda",
        "tonemapx",
        "hwupload_cuda",
        "hwdownload",
        "scale",
    ]


def test_filter_options_are_read_from_the_help_text():
    assert filter_has_option(SCALE_CUDA_HELP, "format")
    assert not filter_has_option(SCALE_CUDA_HELP.replace("  format ", "  fmt    "), "format")
    assert "skip_estimate_duration_from_pts" in parse_option_names(HELP_FULL)


def test_gpu_info_reads_the_first_line_of_nvidia_smi(monkeypatch):
    monkeypatch.setattr(probe_module.shutil, "which", lambda _name: "nvidia-smi")

    def runner(args, timeout):
        return done("NVIDIA GeForce RTX 2070 SUPER, 576.80\nsecond card, 1.0\n")

    assert gpu_info(runner) == ("NVIDIA GeForce RTX 2070 SUPER", "576.80")


def test_gpu_info_is_empty_without_nvidia_smi(no_nvidia_smi):
    assert gpu_info(lambda args, timeout: done("never")) == (None, None)


# -- 登记条件 ---------------------------------------------------------------


def test_probe_declares_what_this_machine_proved(fake, tmp_path):
    caps = fake.run(work_dir=tmp_path)

    assert caps.ffmpeg_version == "7.1.1-Jellyfin"
    assert caps.encoders == ("h264_nvenc", "hevc_nvenc")
    assert caps.backends == ["nvenc"]
    # 只申报 NAS 装命令用得上、且这份 ffmpeg 里有的滤镜（顺序固定）
    assert caps.filters == ("scale_cuda", "tonemap_cuda", "tonemapx", "hwupload_cuda", "hwdownload")
    # 能不能硬解每块显卡不一样：这台没有 AV1 硬解，就不申报 av1；没有样片编码器的不申报
    assert caps.hw_decoders == NVDEC_DECODES
    assert caps.read_options == READ_OPTIONS
    assert caps.hardware.get("cpu_cores", 0) > 0


def test_a_codec_whose_sample_cannot_be_made_is_not_declared(tmp_path, no_nvidia_smi):
    """没有样片编码器就证明不了硬解：宁可不申报（NAS 对它走软解），也不凭型号猜。"""
    encoders = "\n".join(line for line in ENCODERS.splitlines() if "libvpx-vp9" not in line)

    caps = FakeFfmpeg(tmp_path, encoders=encoders).run(work_dir=tmp_path)

    assert "vp9" not in caps.hw_decoders
    assert "hevc" in caps.hw_decoders


def test_a_card_that_decodes_nothing_declares_nothing(tmp_path, no_nvidia_smi):
    caps = FakeFfmpeg(tmp_path, nvdec=()).run(work_dir=tmp_path)

    assert caps.hw_decoders == ()
    assert caps.backends == ["nvenc"]  # 编码没问题，NAS 会让它整段软解


def test_tonemap_cuda_is_only_declared_after_it_ran_an_hdr_sample(tmp_path, no_nvidia_smi):
    caps = FakeFfmpeg(tmp_path, tonemap_works=False).run(work_dir=tmp_path)

    assert "tonemap_cuda" not in caps.filters
    assert "scale_cuda" in caps.filters and "tonemapx" in caps.filters


def test_the_self_tests_run_the_exact_chains_the_nas_sends(fake, tmp_path):
    """探测用的滤镜串必须就是真实转码用的那一串，否则「探测过了」没有意义。"""
    fake.run(work_dir=tmp_path)

    filters = [call[call.index("-vf") + 1] for call in fake.calls if "-vf" in call]
    assert "format=yuv420p,hwupload_cuda,scale_cuda=format=yuv420p:w=-2:h=144" in filters
    assert f"{NVENC_TONEMAP},scale_cuda=format=yuv420p:w=-2:h=144" in filters
    hdr_sample = next(
        call for call in fake.calls if "setparams=color_primaries=bt2020" in " ".join(call)
    )
    # 色彩标签要靠滤镜写到帧上，编码器的 -color_trc 在新版 ffmpeg 里不会进码流
    assert "smpte2084" in " ".join(hdr_sample) and "-color_trc" not in hdr_sample


def test_a_read_option_ffmpeg_does_not_know_is_not_declared(tmp_path, no_nvidia_smi):
    """未知输入选项会让 ffmpeg 直接退出，所以只申报它自己认的。"""
    caps = FakeFfmpeg(tmp_path, help_full="-reconnect <boolean> auto reconnect\n").run(
        work_dir=tmp_path
    )

    assert caps.read_options == ()


def test_the_gpu_name_goes_into_the_hardware_summary(tmp_path, monkeypatch):
    monkeypatch.setattr(
        probe_module.shutil, "which", lambda name: "nvidia-smi" if "smi" in name else None
    )
    fake = FakeFfmpeg(tmp_path)
    fake.smi_output = "NVIDIA GeForce RTX 2070 SUPER, 576.80\n"

    caps = fake.run(work_dir=tmp_path)

    assert caps.hardware["chip"] == "NVIDIA GeForce RTX 2070 SUPER"


@pytest.mark.parametrize("missing", ["scale_cuda", "tonemapx"])
def test_a_build_without_the_cuda_or_software_tonemap_filters_cannot_register(
    tmp_path, no_nvidia_smi, missing
):
    filters = "\n".join(line for line in FILTERS.splitlines() if f" {missing} " not in line)

    with pytest.raises(FfmpegProblem) as problem:
        FakeFfmpeg(tmp_path, filters=filters).run(work_dir=tmp_path)

    assert missing in str(problem.value) and "jellyfin-ffmpeg" in str(problem.value)


def test_a_build_without_nvenc_cannot_register(tmp_path, no_nvidia_smi):
    encoders = "\n".join(line for line in ENCODERS.splitlines() if "nvenc" not in line)

    with pytest.raises(FfmpegProblem) as problem:
        FakeFfmpeg(tmp_path, encoders=encoders).run(work_dir=tmp_path)

    assert "h264_nvenc" in str(problem.value)


def test_scale_cuda_without_the_format_option_cannot_register(tmp_path, no_nvidia_smi):
    """NAS 的命令链把 8-bit 输出钉在 scale_cuda 的 format 上；不认它整条链跑不起来。"""
    help_text = "\n".join(
        line for line in SCALE_CUDA_HELP.splitlines() if not line.startswith("  format")
    )

    with pytest.raises(FfmpegProblem) as problem:
        FakeFfmpeg(tmp_path, scale_cuda_help=help_text).run(work_dir=tmp_path)

    assert "format" in str(problem.value)


def test_a_failing_nvenc_self_test_says_why_the_machine_cannot_transcode(tmp_path, no_nvidia_smi):
    failure = done(stderr="[h264_nvenc] OpenEncodeSessionEx failed: out of memory (10)\n", code=1)

    with pytest.raises(FfmpegProblem) as problem:
        FakeFfmpeg(tmp_path, self_test=failure).run(work_dir=tmp_path)

    message = str(problem.value)
    assert "NVENC 自检失败" in message
    assert "out of memory" in message  # ffmpeg 自己的原因原样带上
    assert "驱动" in message  # 以及下一步


def test_a_missing_ffmpeg_is_reported_with_the_path(tmp_path, no_nvidia_smi):
    def runner(args, timeout):
        raise FileNotFoundError(args[0])

    with pytest.raises(FfmpegProblem) as problem:
        probe(r"C:\nowhere\ffmpeg.exe", runner=runner)

    assert r"C:\nowhere\ffmpeg.exe" in str(problem.value) and "--ffmpeg" in str(problem.value)


def test_an_ffmpeg_that_will_not_start_is_reported(tmp_path, no_nvidia_smi):
    with pytest.raises(FfmpegProblem) as problem:
        probe("ffmpeg", runner=lambda args, timeout: done(code=3))

    assert "退出码 3" in str(problem.value)


# -- 缓存 ------------------------------------------------------------------


def test_a_second_probe_of_the_same_build_reads_the_cache(fake, tmp_path):
    cache = tmp_path / "capabilities.json"
    first = fake.run(cache_file=cache, work_dir=tmp_path)
    calls = len(fake.calls)

    second = fake.run(cache_file=cache, work_dir=tmp_path)

    assert second == first
    assert len(fake.calls) == calls  # 一条 ffmpeg 都没再跑


def test_a_replaced_ffmpeg_invalidates_the_cache(fake, tmp_path):
    cache = tmp_path / "capabilities.json"
    fake.run(cache_file=cache, work_dir=tmp_path)
    calls = len(fake.calls)

    fake.path.write_bytes(b"a different, longer ffmpeg build")
    fake.run(cache_file=cache, work_dir=tmp_path)

    assert len(fake.calls) > calls


def test_a_new_driver_invalidates_the_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(
        probe_module.shutil, "which", lambda name: "nvidia-smi" if "smi" in name else None
    )
    fake = FakeFfmpeg(tmp_path)
    fake.smi_output = "NVIDIA GeForce RTX 2070 SUPER, 576.80\n"
    cache = tmp_path / "capabilities.json"
    fake.run(cache_file=cache, work_dir=tmp_path)
    calls = len(fake.calls)

    fake.smi_output = "NVIDIA GeForce RTX 2070 SUPER, 581.15\n"
    fake.run(cache_file=cache, work_dir=tmp_path)

    assert len(fake.calls) > calls


def test_an_old_schema_cache_is_ignored(fake, tmp_path):
    cache = tmp_path / "capabilities.json"
    fake.run(cache_file=cache, work_dir=tmp_path)
    cache.write_text(cache.read_text(encoding="utf-8").replace(f'"{SCHEMA}|', f'"{SCHEMA - 1}|'))
    calls = len(fake.calls)

    fake.run(cache_file=cache, work_dir=tmp_path)

    assert len(fake.calls) > calls


@pytest.mark.parametrize("content", ["", "not json", "[]", '{"key": "x"}'])
def test_a_corrupt_cache_is_ignored_not_fatal(fake, tmp_path, content):
    cache = tmp_path / "capabilities.json"
    cache.write_text(content, encoding="utf-8")

    caps = fake.run(cache_file=cache, work_dir=tmp_path)

    assert caps.backends == ["nvenc"]


def test_failures_are_never_cached(tmp_path, no_nvidia_smi):
    cache = tmp_path / "capabilities.json"
    failure = done(stderr="no device", code=1)

    with pytest.raises(FfmpegProblem):
        FakeFfmpeg(tmp_path, self_test=failure).run(cache_file=cache, work_dir=tmp_path)

    assert not cache.exists()

"""硬件加速自检测试（docs/design/web-player.md §5.2）。

自建软件里硬件加速最大的成本不是写代码，是**用户配不对**。所以这里测的重点
不是「探测准不准」（那要真显卡），而是**每一种失败都给出了可操作的中文修法**：
说清是设备没挂、还是权限不够、还是驱动不行——三者的改法完全不同，混成一句
「硬件不可用」用户无从下手。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from pathlib import Path

import pytest

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value, source_render
from movieclaw_api.services.playback import hwprobe
from movieclaw_api.services.playback.ffmpeg_args import (
    HW_BACKENDS,
    VAAPI_TONEMAP,
    encoder_options,
    hevc_encoder,
    hevc_encoder_options,
    native_tonemap_filter,
)


@pytest.fixture(autouse=True)
def clean_cache():
    hwprobe.reset_probe_cache()
    yield
    hwprobe.reset_probe_cache()


def status_of(statuses, name):
    return next(s for s in statuses if s.name == name)


def test_missing_ffmpeg_reports_every_backend_with_a_reason(monkeypatch):
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: None)
    statuses = hwprobe.probe_backends()
    assert statuses and all(not s.available for s in statuses)
    assert all("未找到 ffmpeg" in source_render(s.detail) for s in statuses)
    assert hwprobe.hardware_available() is False


def test_encoder_missing_from_build_says_so(monkeypatch):
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset())
    statuses = hwprobe.probe_backends()
    assert "不含 h264_vaapi 编码器" in source_render(status_of(statuses, "vaapi").detail)


def test_videotoolbox_absence_on_linux_is_explained_as_normal(monkeypatch):
    """别让 Linux 用户以为自己漏配了什么——VideoToolbox 是 macOS 专有的。"""
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset())
    detail = source_render(status_of(hwprobe.probe_backends(), "videotoolbox").detail)
    assert "macOS" in detail and "正常" in detail


def test_missing_dri_tells_the_user_to_mount_the_device(monkeypatch, tmp_path):
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi"}))
    monkeypatch.setattr(hwprobe, "Path", lambda p: tmp_path / "nope")
    detail = source_render(status_of(hwprobe.probe_backends(), "vaapi").detail)
    assert "/dev/dri" in detail and "devices:" in detail


def test_render_node_without_permission_names_the_group_fix(monkeypatch, tmp_path):
    """群晖上最典型的一种：节点在、但容器用户不在 render 组。"""
    dri = tmp_path / "dri"
    dri.mkdir()
    (dri / "renderD128").write_bytes(b"")
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: dri)
    monkeypatch.setattr(hwprobe.os, "access", lambda *_a: False)
    detail = source_render(status_of(hwprobe.probe_backends(), "vaapi").detail)
    assert "无读写权限" in detail
    assert "group_add" in detail
    assert "GID" in detail  # 要报出宿主机上的实际 GID，用户才知道填什么


def test_dri_without_render_nodes_points_at_the_host(monkeypatch, tmp_path):
    dri = tmp_path / "dri"
    dri.mkdir()
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: dri)
    assert "renderD" in source_render(status_of(hwprobe.probe_backends(), "vaapi").detail)


def test_nvidia_without_device_nodes_names_the_toolkit(monkeypatch, tmp_path):
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_nvenc"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: tmp_path / "nope")
    detail = source_render(status_of(hwprobe.probe_backends(), "nvenc").detail)
    assert "NVIDIA Container Toolkit" in detail


@pytest.mark.parametrize(
    "stderr,expected",
    [
        ("Permission denied", "render 组"),
        ("Cannot open display", "设备节点"),
        ("Function not supported", "不支持"),
        ("Failed to initialise VAAPI connection", "驱动初始化失败"),
    ],
)
def test_driver_errors_are_translated_to_actionable_chinese(stderr, expected):
    assert expected in source_render(hwprobe._explain_failure(stderr))


def test_unrecognised_error_carries_the_original_summary():
    """命中不了就原样带上摘要，别装懂——用户报障时这句话就是全部线索。"""
    detail = source_render(hwprobe._explain_failure("Some brand new driver bug 0xdeadbeef"))
    assert "0xdeadbeef" in detail


def test_successful_probe_marks_the_backend_available(monkeypatch, tmp_path):
    """真跑通一秒编码才算可用——只看编码器在不在是最常见的误判来源。"""
    dri = tmp_path / "dri"
    dri.mkdir()
    (dri / "renderD128").write_bytes(b"")
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: dri)
    monkeypatch.setattr(hwprobe.os, "access", lambda *_a: True)
    monkeypatch.setattr(
        hwprobe, "_run_probe",
        lambda *_a, **_k: subprocess.CompletedProcess([], 0, b"", b""),
    )
    statuses = hwprobe.probe_backends()
    assert status_of(statuses, "vaapi").available is True
    assert "真实编码验证" in source_render(status_of(statuses, "vaapi").detail)
    assert "vaapi" in hwprobe.available_backends()


def _vaapi_ready(monkeypatch, tmp_path):
    dri = tmp_path / "dri"
    dri.mkdir()
    (dri / "renderD128").write_bytes(b"")
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: dri)
    monkeypatch.setattr(hwprobe.os, "access", lambda *_a: True)


def test_vaapi_prefers_low_power_encoding_when_it_works(monkeypatch, tmp_path):
    """issue #763：先试低功耗编码，跑通就用它，普通编码不再探（普通编码在那台机器上
    合成画面能过、真实片子挂 GPU，探了也说明不了问题）。低功耗探测要带上真实转码的
    profile / 码率控制——VDEnc 支持的码率控制与普通编码不同；level 与真实转码一样不钉（#964）。"""
    _vaapi_ready(monkeypatch, tmp_path)
    calls: list[list[str]] = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    vaapi = status_of(hwprobe.probe_backends(), "vaapi")
    assert vaapi.available is True
    assert "低功耗" in source_render(vaapi.detail)
    (argv,) = [a for a in calls if "h264_vaapi" in a and "tonemap_vaapi" not in " ".join(a)]
    after = argv[argv.index("h264_vaapi") + 1 :]
    assert after[:2] == ["-low_power", "1"]
    assert {"-profile:v", "-b:v", "-maxrate", "-bufsize"} <= set(after)
    assert "-level:v" not in after
    assert encoder_options(HW_BACKENDS["vaapi"]) == ("-low_power", "1")


def test_vaapi_falls_back_to_normal_encoding_without_low_power(monkeypatch, tmp_path):
    """老核显不支持低功耗：探不通就退回普通编码，行为与原来一致，命令里不带 -low_power。"""
    _vaapi_ready(monkeypatch, tmp_path)
    calls: list[list[str]] = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        failed = "-low_power" in argv
        return subprocess.CompletedProcess(
            argv, 1 if failed else 0, b"", b"low power not supported" if failed else b""
        )

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    vaapi = status_of(hwprobe.probe_backends(), "vaapi")
    assert vaapi.available is True
    assert "低功耗" not in source_render(vaapi.detail)
    assert [
        "-low_power" in a for a in calls
        if "h264_vaapi" in a and "tonemap_vaapi" not in " ".join(a)
    ] == [True, False]
    assert encoder_options(HW_BACKENDS["vaapi"]) == ()


def test_reprobe_drops_a_stale_low_power_conclusion(monkeypatch, tmp_path):
    """设置页「重新检测」：上次探到低功耗、这次设备没了，不能留着旧结论。"""
    _vaapi_ready(monkeypatch, tmp_path)
    monkeypatch.setattr(
        hwprobe.subprocess, "run", lambda argv, **_k: subprocess.CompletedProcess(argv, 0, b"", b"")
    )
    hwprobe.probe_backends()
    assert encoder_options(HW_BACKENDS["vaapi"]) == ("-low_power", "1")
    monkeypatch.setattr(hwprobe, "Path", lambda _p: tmp_path / "gone")
    assert status_of(hwprobe.probe_backends(force=True), "vaapi").available is False
    assert encoder_options(HW_BACKENDS["vaapi"]) == ()


def _hevc_ready(monkeypatch, tmp_path):
    _vaapi_ready(monkeypatch, tmp_path)
    monkeypatch.setattr(
        hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi", "hevc_vaapi"})
    )


def test_hevc_is_enabled_only_after_a_real_hevc_run(monkeypatch, tmp_path):
    """issue #1008：H.264 能编不等于 HEVC 能编。HEVC 真编一秒通过才让离线导出出 HEVC；
    探测带上导出真实会用的 profile 与码率控制，并沿用 H.264 探出的低功耗。"""
    _hevc_ready(monkeypatch, tmp_path)
    calls: list[list[str]] = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    vaapi = status_of(hwprobe.probe_backends(), "vaapi")
    assert vaapi.available is True and "HEVC" in source_render(vaapi.detail)
    (argv,) = [a for a in calls if "hevc_vaapi" in a]
    after = argv[argv.index("hevc_vaapi") + 1 :]
    assert after[:2] == ["-low_power", "1"]
    assert after[after.index("-profile:v") + 1] == "main"
    assert {"-b:v", "-maxrate", "-bufsize"} <= set(after)
    assert hevc_encoder(HW_BACKENDS["vaapi"]) == "hevc_vaapi"
    assert hevc_encoder_options(HW_BACKENDS["vaapi"]) == ("-low_power", "1")


def test_hevc_follows_normal_encoding_when_low_power_is_unsupported(monkeypatch, tmp_path):
    """H.264 退回了普通编码，HEVC 也只探普通编码。"""
    _hevc_ready(monkeypatch, tmp_path)
    calls: list[list[str]] = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        failed = "-low_power" in argv
        return subprocess.CompletedProcess(argv, 1 if failed else 0, b"", b"")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    hwprobe.probe_backends()
    assert [("-low_power" in a) for a in calls if "hevc_vaapi" in a] == [False]
    assert hevc_encoder(HW_BACKENDS["vaapi"]) == "hevc_vaapi"
    assert hevc_encoder_options(HW_BACKENDS["vaapi"]) == ()


def test_hevc_failure_keeps_h264_hardware_transcoding(monkeypatch, tmp_path):
    """HEVC 探不通（老核显）：硬件转码照常可用，只是导出照旧出 H.264。"""
    _hevc_ready(monkeypatch, tmp_path)

    def fake_run(argv, **_kwargs):
        failed = "hevc_vaapi" in argv
        return subprocess.CompletedProcess(argv, 1 if failed else 0, b"", b"unsupported")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    vaapi = status_of(hwprobe.probe_backends(), "vaapi")
    assert vaapi.available is True and "HEVC" not in source_render(vaapi.detail)
    assert hevc_encoder(HW_BACKENDS["vaapi"]) is None


def test_hevc_is_not_probed_without_the_encoder_or_h264(monkeypatch, tmp_path):
    """构建里没有 hevc_vaapi，或 H.264 本身不可用：不探 HEVC，也不登记。"""
    _vaapi_ready(monkeypatch, tmp_path)  # 只有 h264_vaapi
    calls: list[list[str]] = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    hwprobe.probe_backends()
    assert not [a for a in calls if "hevc_vaapi" in a]
    assert hevc_encoder(HW_BACKENDS["vaapi"]) is None
    # 上次探到 HEVC、这次设备没了：旧结论要撤
    monkeypatch.setattr(
        hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi", "hevc_vaapi"})
    )
    hwprobe.probe_backends(force=True)
    assert hevc_encoder(HW_BACKENDS["vaapi"]) == "hevc_vaapi"
    monkeypatch.setattr(hwprobe, "Path", lambda _p: tmp_path / "gone")
    hwprobe.probe_backends(force=True)
    assert hevc_encoder(HW_BACKENDS["vaapi"]) is None


def test_qsv_probe_initialises_its_device_before_hwupload(monkeypatch, tmp_path):
    """QSV 探测的合成源没有硬解这一步，hwupload 要靠显式建的设备。

    缺了 ``-init_hw_device qsv=hw -filter_hw_device hw``，ffmpeg 报找不到设备，
    能用的 Intel 核显被判成不可用（真机 UHD 630：手动带上这两项编码成功）。
    """
    dri = tmp_path / "dri"
    dri.mkdir()
    (dri / "renderD128").write_bytes(b"")
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_qsv"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: dri)
    monkeypatch.setattr(hwprobe.os, "access", lambda *_a: True)
    calls: list[list[str]] = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    assert status_of(hwprobe.probe_backends(), "qsv").available is True
    (argv,) = [a for a in calls if "h264_qsv" in a]
    assert argv[argv.index("-init_hw_device") + 1] == "qsv=hw"
    assert argv[argv.index("-filter_hw_device") + 1] == "hw"
    assert "hwupload" in argv[argv.index("-vf") + 1]


@pytest.mark.parametrize(
    ("name", "encoders", "flag"),
    [("qsv", {"h264_qsv", "hevc_qsv"}, "-forced_idr"),
     ("nvenc", {"h264_nvenc", "hevc_nvenc"}, "-forced-idr")],
)  # fmt: skip
def test_probe_carries_forced_idr_like_real_transcoding(
    monkeypatch, tmp_path, name, encoders, flag
):
    """真实转码给 QSV / NVENC 加强制 IDR（见 ffmpeg_args.HwBackend.forced_idr），探测也带上：
    参数不认的 ffmpeg 在自检就判不可用，而不是播放时才炸。"""
    dri = tmp_path / "dri"
    dri.mkdir()
    (dri / "renderD128").write_bytes(b"")
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset(encoders))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: dri)
    monkeypatch.setattr(hwprobe.os, "access", lambda *_a: True)
    calls: list[list[str]] = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    hwprobe.probe_backends()
    for encoder in encoders:
        (argv,) = [a for a in calls if encoder in a and "-vf" in a and "tonemap" not in " ".join(a)]
        assert argv[argv.index(encoder) + 1 : argv.index(encoder) + 3] == [flag, "1"]


def test_probe_timeout_is_reported_not_swallowed(monkeypatch, tmp_path):
    dri = tmp_path / "dri"
    dri.mkdir()
    (dri / "renderD128").write_bytes(b"")
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_vaapi"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: dri)
    monkeypatch.setattr(hwprobe.os, "access", lambda *_a: True)
    monkeypatch.setattr(hwprobe, "_run_probe", lambda *_a, **_k: None)
    assert "超时" in source_render(status_of(hwprobe.probe_backends(), "vaapi").detail)


def _nvenc_ready(monkeypatch, tmp_path):
    """一台「NVENC 编码器在、设备节点也在」的机器。"""
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset({"h264_nvenc"}))
    monkeypatch.setattr(hwprobe, "Path", lambda _p: tmp_path)


def test_native_tonemap_is_enabled_only_after_a_real_run(monkeypatch, tmp_path):
    """``tonemap_cuda`` 是 jellyfin-ffmpeg 的补丁，上游没有——所以不能按构建
    假定它存在，跑通了才回写给命令装配层。而探测链必须与真实转码链同源，
    否则会出现「探得通、真用炸」。"""
    from movieclaw_api.services.playback.ffmpeg_args import (
        HW_BACKENDS,
        NVENC_TONEMAP,
        native_tonemap_filter,
    )

    _nvenc_ready(monkeypatch, tmp_path)
    seen: list[list[str]] = []

    def fake_probe(_encoder, filters, **_kwargs):
        seen.append(filters)
        return subprocess.CompletedProcess([], 0, b"", b"")

    monkeypatch.setattr(hwprobe, "_run_probe", fake_probe)
    assert status_of(hwprobe.probe_backends(), "nvenc").available is True
    assert native_tonemap_filter(HW_BACKENDS["nvenc"]) == NVENC_TONEMAP

    chain = " ".join(seen[-1])
    assert NVENC_TONEMAP in chain, "探测用的滤镜串必须就是真实转码用的那一串"
    assert "hwupload_cuda" in chain and "scale_cuda" in chain  # 与真实链同构
    assert "smpte2084" in chain, "tone-map 滤镜拒绝非 HDR 输入，得先合成 PQ 源"


def test_native_tonemap_failure_keeps_hardware_transcoding(monkeypatch, tmp_path):
    """探不到色调映射不是「硬件不可用」：HDR 片改用软件 tone-map 照样能放，
    其余的解码与编码仍在显卡上。"""
    from movieclaw_api.services.playback.ffmpeg_args import (
        HW_BACKENDS,
        native_tonemap_filter,
    )

    _nvenc_ready(monkeypatch, tmp_path)

    def fake_probe(_encoder, filters, **_kwargs):
        if any("tonemap_cuda" in f for f in filters):
            return subprocess.CompletedProcess([], 1, b"", b"No such filter: 'tonemap_cuda'")
        return subprocess.CompletedProcess([], 0, b"", b"")

    monkeypatch.setattr(hwprobe, "_run_probe", fake_probe)
    assert status_of(hwprobe.probe_backends(), "nvenc").available is True
    assert native_tonemap_filter(HW_BACKENDS["nvenc"]) is None


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要 ffmpeg")
@pytest.mark.parametrize("name", sorted(hwprobe._NATIVE_TONEMAP_PROBES))
def test_native_tonemap_probe_source_parses_on_real_ffmpeg(name):
    """探测链上传显存之前的那段（合成 HDR10 源）与显卡无关，任何 ffmpeg 都该跑得通。

    上面的用例都替身了 ffmpeg，参数写错照样绿；而写错的后果是能用的卡被静默判成
    没有原生 tone-map、HDR 转码全压到 CPU（#963：``setparams`` 的矩阵名写成了
    ``colorspace`` 滤镜的 ``bt2020ncl``）。这里用真 ffmpeg 把这段跑一遍。"""
    filter_expr, chain = hwprobe._NATIVE_TONEMAP_PROBES[name]
    software_part = chain.format(filter=filter_expr).split(",hwupload", 1)[0]
    input_args = (
        ["-i", str(hwprobe._HDR10_PROBE_SOURCE)] if name == "vaapi"
        else ["-f", "lavfi", "-i", hwprobe._PROBE_SOURCE]
    )
    proc = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-v", "error", *input_args,
            "-vf", software_part, "-f", "null", "-",
        ],
        capture_output=True,
        timeout=60,
    )  # fmt: skip
    assert proc.returncode == 0, proc.stderr.decode(errors="replace")


def test_result_is_cached_until_forced(monkeypatch):
    calls = {"n": 0}

    def counting():
        calls["n"] += 1
        return frozenset()

    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", counting)
    hwprobe.probe_backends()
    hwprobe.probe_backends()
    assert calls["n"] == 1, "缓存没生效——决策要逐次播放问，每次都跑一秒编码不可接受"
    hwprobe.probe_backends(force=True)
    assert calls["n"] == 2, "设置页的「重新检测」必须真的重测"


def test_local_available_backends_excludes_remote_overlay(monkeypatch):
    """远程 Worker 的硬件能力不能变成本地 ffmpeg 参数。"""
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: "/usr/bin/ffmpeg")
    monkeypatch.setattr(hwprobe, "_list_encoders", lambda: frozenset())
    monkeypatch.setattr(
        hwprobe, "remote_backends_available", lambda *a, **k: ("videotoolbox", "nvenc")
    )

    assert hwprobe.available_backends() == ("videotoolbox", "nvenc")
    assert hwprobe.available_local_backends() == ()


def test_remote_backend_does_not_overwrite_the_local_status_of_the_same_name(monkeypatch):
    """NAS 本机没有 NVIDIA 卡、远程 Windows Worker 却是 NVENC：两条各说各的。

    远程能力不写进本机探测结果，同名时不能把「本机为什么不行」顶掉——用户据这行文案
    判断要不要给 NAS 配显卡；远程那条单列，由设置页并排展示。"""
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: None)
    monkeypatch.setattr(hwprobe, "remote_backends_available", lambda *a, **k: ("nvenc",))

    local = {s.name: s for s in hwprobe.probe_backends()}
    assert local["nvenc"].available is False
    assert "未找到 ffmpeg" in source_render(local["nvenc"].detail)
    assert not any(s.remote for s in local.values())

    remote = hwprobe.remote_backend_statuses()
    assert [(s.name, s.available, s.remote) for s in remote] == [("nvenc", True, True)]
    assert source_render(remote[0].label) == "远程转码器 · NVIDIA 显卡（NVENC）"
    with use_locale("en"):
        assert render_value(remote[0].label) == "Remote transcoder · NVIDIA graphics (NVENC)"
    # 决策层看到的是并集：本机没有、远程有，也算「有这种硬件链」
    assert hwprobe.available_backends() == ("nvenc",)
    assert hwprobe.available_local_backends() == ()


def test_remote_workers_go_offline_and_the_overlay_disappears(monkeypatch):
    """Worker 断线后下一次决策立即回到真实的本机结果：叠加不缓存。"""
    monkeypatch.setattr(hwprobe.shutil, "which", lambda _n: None)
    online = ["nvenc"]
    monkeypatch.setattr(hwprobe, "remote_backends_available", lambda *a, **k: tuple(online))

    assert hwprobe.available_backends() == ("nvenc",)
    online.clear()
    assert hwprobe.available_backends() == ()
    assert hwprobe.remote_backend_statuses() == []


def test_every_backend_has_a_human_label():
    """设置页里「vaapi」不如「Intel / AMD 显卡」好懂。"""
    from movieclaw_api.services.playback.ffmpeg_args import HW_BACKENDS

    for name in HW_BACKENDS:
        assert hwprobe.BACKEND_LABELS.get(name), f"{name} 缺少中文名"


@pytest.mark.integration
@pytest.mark.skipif(not Path("/usr/bin/ffmpeg").exists(), reason="需要系统 ffmpeg")
def test_real_probe_runs_and_explains_itself():
    """在没有显卡的机器上跑：每一条都必须给出非空的中文说明，不能只是 False。"""
    statuses = hwprobe.probe_backends(force=True)
    assert len(statuses) >= 4
    for status in statuses:
        assert status.detail, f"{status.name} 没有给出原因"
        assert status.label


@pytest.mark.parametrize("result", [0, 234, None])
def test_vaapi_hdr_probe_controls_only_hdr_capability(monkeypatch, tmp_path, result):
    _vaapi_ready(monkeypatch, tmp_path)
    calls = []

    def fake_run(argv, **_kwargs):
        calls.append(argv)
        if "tonemap_vaapi" in " ".join(argv):
            if result is None:
                raise subprocess.TimeoutExpired(argv, 20)
            return subprocess.CompletedProcess(
                argv, result, b"", b"VAAPI driver doesn't support HDR" if result else b""
            )
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    monkeypatch.setattr(hwprobe.subprocess, "run", fake_run)
    assert status_of(hwprobe.probe_backends(), "vaapi").available
    assert native_tonemap_filter(HW_BACKENDS["vaapi"]) == (VAAPI_TONEMAP if result == 0 else None)
    (argv,) = [a for a in calls if "tonemap_vaapi" in " ".join(a)]
    assert argv[argv.index("-vaapi_device") + 1] == HW_BACKENDS["vaapi"].device
    assert argv[argv.index("-low_power") + 1] == "1"
    assert argv[argv.index("-i") + 1] == str(hwprobe._HDR10_PROBE_SOURCE)
    chain = argv[argv.index("-vf") + 1]
    assert "format=p010le,setparams=range=tv" in chain
    assert "hwupload,tonemap_vaapi" in chain and "scale_vaapi=format=nv12" in chain
    assert chain.endswith(":range=tv")
    # 重新探测失败或设备消失必须清掉之前成功的 HDR 能力。
    if result == 0:
        monkeypatch.setattr(hwprobe, "_run_probe", lambda *_a, **_k: None)
        hwprobe.probe_backends(force=True)
        assert native_tonemap_filter(HW_BACKENDS["vaapi"]) is None


@pytest.mark.skipif(shutil.which("ffprobe") is None, reason="需要 ffprobe")
def test_vaapi_probe_sample_has_real_hdr10_frame_metadata():
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_frames", "-of", "json",
         str(hwprobe._HDR10_PROBE_SOURCE)],
        capture_output=True, timeout=20,
    )
    assert proc.returncode == 0, proc.stderr.decode()
    frames = json.loads(proc.stdout)["frames"]
    assert len(frames) == 25
    for frame in frames:
        assert frame["pix_fmt"] == "yuv420p10le"
        assert frame["color_transfer"] == "smpte2084"
        assert frame["color_primaries"] == "bt2020"
        assert frame["color_space"] == "bt2020nc"
        side_data = {d["side_data_type"] for d in frame["side_data_list"]}
        assert "Mastering display metadata" in side_data


def test_concurrent_backend_queries_wait_for_native_tonemap(monkeypatch, tmp_path):
    _vaapi_ready(monkeypatch, tmp_path)
    hdr_started = threading.Event()
    release_hdr = threading.Event()
    query_started = threading.Event()
    encoders_calls = []
    original_encoders = hwprobe._list_encoders

    def list_encoders():
        encoders_calls.append(True)
        return original_encoders()

    def fake_probe(encoder, filters, **kwargs):
        if "tonemap_vaapi" in " ".join(filters):
            hdr_started.set()
            assert release_hdr.wait(10)
        return subprocess.CompletedProcess([], 0, b"", b"")

    def query_backends():
        query_started.set()
        return hwprobe.available_local_backends()

    monkeypatch.setattr(hwprobe, "_list_encoders", list_encoders)
    monkeypatch.setattr(hwprobe, "_run_probe", fake_probe)
    with ThreadPoolExecutor(max_workers=2) as pool:
        warmup = pool.submit(hwprobe.probe_backends)
        try:
            assert hdr_started.wait(10)
            assert hwprobe._cache is None
            query = pool.submit(query_backends)
            assert query_started.wait(10)
            with pytest.raises(FutureTimeout):
                query.result(timeout=0.2)
        finally:
            release_hdr.set()
        assert status_of(warmup.result(timeout=10), "vaapi").available
        assert query.result(timeout=10) == ("vaapi",)
    assert encoders_calls == [True], "并发查询必须复用同一次探测"
    assert native_tonemap_filter(HW_BACKENDS["vaapi"]) == VAAPI_TONEMAP

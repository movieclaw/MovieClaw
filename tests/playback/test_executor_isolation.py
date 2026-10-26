"""「在哪儿跑」与「用哪种硬件跑」分开：本机与远程的同名后端各是各的。

本机探测（hwprobe）的结论只说 NAS 这块硬件；远程 Worker 的能力只看它自己在 hello 里的申报。
两边同名（NAS 插着 NVIDIA 卡、远程也是 Windows NVENC；以后 NAS 核显与低功耗主机都是 QSV）时，
谁也不能覆盖、继承或撤销另一边。
"""

from __future__ import annotations

from pathlib import Path

import pytest

from movieclaw_api.services.playback import hwprobe
from movieclaw_api.services.playback import plan as plan_module
from movieclaw_api.services.playback import remote_worker as remote_worker_module
from movieclaw_api.services.playback.ffmpeg_args import (
    NVENC_TONEMAP,
    VAAPI_LOW_POWER,
    WorkerVideoCaps,
    build_hls_command,
    register_encoder_options,
    register_native_tonemap,
)
from movieclaw_api.services.playback.hwprobe import HwBackendStatus
from movieclaw_api.services.playback.remote_worker import REMOTE_BACKENDS, RemoteWorkerRegistry
from movieclaw_playback.decide import AudioPlan, PlaybackPlan, PlaybackTier, VideoPlan


class FakeWebSocket:
    async def send_json(self, _message: dict) -> None:
        return None

    async def close(self, **_: object) -> None:
        return None


def _hdr_plan() -> PlaybackPlan:
    return PlaybackPlan(
        tier=PlaybackTier.HARDWARE_TRANSCODE,
        file_id=1,
        container="hls-fmp4",
        video=VideoPlan(
            action="transcode",
            codec="h264",
            height=1080,
            tone_map=True,
            source_codec="hevc",
            source_bit_depth=10,
        ),
        audio=AudioPlan(action="copy"),
    )


def _burn_plan() -> PlaybackPlan:
    """PGS 烧录：滤镜链落到软件侧，VAAPI / QSV 的编码器吃不了软件帧，本机装不出这条链。"""
    return PlaybackPlan(
        tier=PlaybackTier.HARDWARE_TRANSCODE,
        file_id=1,
        container="hls-fmp4",
        video=VideoPlan(action="transcode", codec="h264", height=1080, burn_subtitle="embedded:0"),
        audio=AudioPlan(action="copy"),
    )


def _vf(argv: list[str]) -> str:
    return argv[argv.index("-vf") + 1]


def _command(plan: PlaybackPlan, backend: str, caps: WorkerVideoCaps | None) -> list[str]:
    return build_hls_command(
        plan,
        source_path="/media/a.mkv",
        session_dir=Path("/tmp/s"),
        hw_backend=backend,
        worker_caps=caps,
    ).argv


@pytest.fixture
def registry(monkeypatch):
    """全新的进程级注册表，远程转码开关打开。"""
    fresh = RemoteWorkerRegistry()
    monkeypatch.setattr(remote_worker_module, "_registry", fresh)
    monkeypatch.setattr(remote_worker_module, "remote_worker_enabled", lambda: True)
    return fresh


async def _connect(registry: RemoteWorkerRegistry, worker_id: str, backend: str, **caps):
    encoder = {"videotoolbox": "h264_videotoolbox", "nvenc": "h264_nvenc"}[backend]
    return await registry.register(
        FakeWebSocket(),
        {
            "worker_id": worker_id,
            "capabilities": {"backends": [backend], "encoders": [encoder], **caps},
        },
    )


def test_local_tonemap_probe_and_worker_filters_stay_on_their_own_side():
    """NAS 本机探到 tonemap_cuda、远程 Worker 的 ffmpeg 没有它：本机命令走 GPU 映射，远程命令
    退回软件映射。反过来（本机没有、远程有）也一样，谁也不替谁做主。"""
    plan = _hdr_plan()
    hevc = frozenset({"hevc"})
    with_cuda = WorkerVideoCaps(hw_decoders=hevc, filters=frozenset({"scale_cuda", "tonemap_cuda"}))
    without_cuda = WorkerVideoCaps(hw_decoders=hevc, filters=frozenset({"scale_cuda"}))

    register_native_tonemap("nvenc", NVENC_TONEMAP)
    try:
        assert _vf(_command(plan, "nvenc", None)).startswith("tonemap_cuda=")
        assert not _vf(_command(plan, "nvenc", without_cuda)).startswith("tonemap_cuda=")
    finally:
        register_native_tonemap("nvenc", None)

    assert not _vf(_command(plan, "nvenc", None)).startswith("tonemap_cuda=")
    assert _vf(_command(plan, "nvenc", with_cuda)).startswith("tonemap_cuda=")


def test_remote_nvenc_hdr_chain_stays_on_the_gpu_only_when_the_worker_declares_it():
    """Windows Worker 申报了 tonemap_cuda：HDR 整条链留在显卡上（缩放在映射之前、输出 8-bit）；
    没申报（ffmpeg 不是 jellyfin 构建）：映射退到 CPU，编码照旧在显卡上。"""
    plan = _hdr_plan()
    hevc = frozenset({"hevc"})
    gpu = _vf(
        _command(
            plan, "nvenc", WorkerVideoCaps(hw_decoders=hevc, filters=frozenset({"tonemap_cuda"}))
        )
    )
    assert gpu.startswith("tonemap_cuda=") and "scale_cuda=" in gpu
    cpu = _vf(_command(plan, "nvenc", WorkerVideoCaps(hw_decoders=hevc)))
    assert "tonemap_cuda" not in cpu
    assert "tonemapx" in cpu or "tonemap=" in cpu


def test_remote_command_never_inherits_local_encoder_options():
    """VAAPI 低功耗是 NAS 这块核显自检出来的；同名后端交给远程执行时不能带上它。"""
    plan = PlaybackPlan(
        tier=PlaybackTier.HARDWARE_TRANSCODE,
        file_id=1,
        container="hls-fmp4",
        video=VideoPlan(action="transcode", codec="h264", height=720, source_bit_depth=8),
        audio=AudioPlan(action="copy"),
    )
    register_encoder_options("vaapi", VAAPI_LOW_POWER)
    try:
        assert "-low_power" in _command(plan, "vaapi", None)
        assert "-low_power" not in _command(plan, "vaapi", WorkerVideoCaps())
    finally:
        register_encoder_options("vaapi", ())


@pytest.mark.asyncio
async def test_a_backend_name_in_the_merged_list_does_not_conjure_a_remote_worker(registry):
    """决策用的可用列表是本机与远程的并集。只连着一台 Mac 时，列表里即使有 nvenc（本机的，
    或 Worker 刚断线的残影），也不能因此当成有一台 NVENC Worker——那台机器不在线，派单
    必然 503。远程能不能跑，问注册表（在线 Worker 各自的申报），不问这份列表。"""
    await _connect(registry, "mac", "videotoolbox")
    assert plan_module.select_execution_backend(
        _burn_plan(),
        available=("vaapi", "nvenc", "videotoolbox"),
        local_backends=("vaapi",),
        remote_video_available=True,
    ) == ("videotoolbox", True)
    assert remote_worker_module.remote_backend_can_run(_burn_plan(), "videotoolbox")
    assert not remote_worker_module.remote_backend_can_run(_burn_plan(), "nvenc")


@pytest.mark.asyncio
async def test_windows_nvenc_worker_takes_the_plan_a_local_backend_cannot_run(registry):
    """NAS 只有一块 VAAPI 核显，烧录装不出来；在线的只有 Windows NVENC：交给它。"""
    await _connect(registry, "win", "nvenc", filters=["scale_cuda", "tonemap_cuda"])
    assert plan_module.select_execution_backend(
        _burn_plan(),
        available=("vaapi", "nvenc"),
        local_backends=("vaapi",),
        remote_video_available=True,
    ) == ("nvenc", True)


@pytest.mark.asyncio
async def test_remote_backends_are_ordered_by_priority_and_listed_once(registry):
    """两种 Worker 都在线时 videotoolbox 在前（先接单的跑得久，速度画像更厚）；名单只在
    ``REMOTE_BACKENDS`` 一处，顺序就是派单优先级。"""
    assert REMOTE_BACKENDS == ("videotoolbox", "nvenc")
    await _connect(registry, "win", "nvenc")
    assert remote_worker_module.remote_backends_available() == ("nvenc",)
    await _connect(registry, "mac", "videotoolbox")
    assert remote_worker_module.remote_backends_available() == ("videotoolbox", "nvenc")
    assert plan_module.select_execution_backend(
        _burn_plan(),
        available=("videotoolbox", "nvenc"),
        local_backends=(),
        remote_video_available=True,
    ) == ("videotoolbox", True)


@pytest.mark.asyncio
async def test_same_backend_on_both_sides_keeps_two_separate_entries(registry, monkeypatch):
    """本机与远程都是 NVENC：本机的探测条目原样保留（连同它的不可用原因），远程单列一条；
    决策用的可用列表不重复。Worker 下线后立刻只剩本机的结论。"""
    local = HwBackendStatus(
        name="nvenc", label="NVIDIA 显卡（NVENC）", available=False, detail="驱动版本过低"
    )
    monkeypatch.setattr(hwprobe, "_cache", [local])

    connection = await _connect(registry, "win", "nvenc", filters=["scale_cuda"])
    assert hwprobe.probe_backends() == [local]
    assert [(s.name, s.remote, s.available) for s in hwprobe.remote_backend_statuses()] == [
        ("nvenc", True, True)
    ]
    assert hwprobe.available_backends() == ("nvenc",)
    assert hwprobe.available_local_backends() == ()

    await registry.unregister(connection)
    assert hwprobe.available_backends() == ()
    assert hwprobe.remote_backend_statuses() == []
    assert hwprobe.probe_backends() == [local]


@pytest.mark.asyncio
async def test_worker_hello_never_touches_local_probe_results(registry):
    """Worker 的申报只用于派给它的任务，不写进 NAS 本机的自检结论：本机也有 NVIDIA 卡时，
    两边是两个 ffmpeg 构建，一边的结论套到另一边就会装出缺滤镜的链。上线、断开都不动它。"""
    from movieclaw_api.services.playback.ffmpeg_args import HW_BACKENDS, native_tonemap_filter

    connection = await _connect(registry, "win", "nvenc", filters=["scale_cuda", "tonemap_cuda"])
    nvenc = HW_BACKENDS["nvenc"]
    assert native_tonemap_filter(nvenc) is None, "本机没探到就是没有"
    assert native_tonemap_filter(nvenc, connection.capabilities.video_caps) is not None
    await registry.unregister(connection)
    assert native_tonemap_filter(nvenc) is None


@pytest.mark.parametrize(
    ("declared", "encoders", "expected"),
    [
        (["nvenc"], ["h264_nvenc"], ("nvenc",)),
        (["nvenc"], ["libx264"], ()),  # 申报了后端却没有它的 H.264 编码器：装不起来
        (["vaapi"], ["h264_vaapi"], ()),  # 名单之外的后端一律丢弃
        (["videotoolbox", "nvenc"], ["h264_videotoolbox", "h264_nvenc"], ("videotoolbox", "nvenc")),
    ],
)
def test_hello_backends_are_filtered_by_the_remote_list_and_their_encoder(
    declared, encoders, expected
):
    caps = RemoteWorkerRegistry._parse_capabilities({"backends": declared, "encoders": encoders})
    assert caps.backends == expected

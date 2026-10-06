"""逐项对照旧策略；验证能力、资源压力、容量、性能样本和派单耗时。"""

from __future__ import annotations

import time
from dataclasses import replace

import pytest

from movieclaw_api.services.playback.ffmpeg_args import build_hls_command
from movieclaw_api.services.playback.remote_worker import (
    RemoteWorkerRegistry,
    RemoteWorkerUnavailable,
)
from movieclaw_playback.decide import AudioPlan, PlaybackPlan, PlaybackTier, VideoPlan


class Socket:
    async def send_json(self, message):
        pass

    async def close(self, **kwargs):
        pass


def plan(**video):
    return PlaybackPlan(
        tier=PlaybackTier.HARDWARE_TRANSCODE,
        file_id=7,
        container="hls-fmp4",
        video=VideoPlan(
            action="transcode",
            codec="h264",
            source_codec="hevc",
            source_bit_depth=10,
            height=1080,
            **video,
        ),
        audio=AudioPlan(action="copy", track_ref=None),
    )


async def add(registry, name, **caps):
    return await registry.register(
        Socket(),
        {
            "worker_id": name,
            "capabilities": {
                "backends": ["videotoolbox"],
                "encoders": ["h264_videotoolbox"],
                "max_jobs": 4,
                **caps,
            },
        },
    )


def old_select(workers):
    return min(workers, key=lambda w: (len(w.jobs), w.connected_at))


@pytest.mark.asyncio
@pytest.mark.parametrize("tone_map", [False, True])
async def test_gpu_capability_changes_actual_command_without_assuming_faster(tmp_path, tone_map):
    r = RemoteWorkerRegistry()
    a = await add(r, "older-cpu-filters")
    b = await add(r, "gpu-filters", filters=["scale_vt", "tonemap_videotoolbox"])
    p = plan(tone_map=tone_map)
    assert old_select([a, b]) is a
    assert r.reserve("new", backend="videotoolbox", plan=p) is a
    commands = [
        build_hls_command(
            p,
            source_path="input.mkv",
            session_dir=tmp_path,
            hw_backend="videotoolbox",
            worker_caps=w.capabilities.video_caps,
        ).argv
        for w in (a, b)
    ]
    assert "scale_vt" not in " ".join(commands[0])
    assert "scale_vt" in " ".join(commands[1])
    if tone_map:
        assert "tonemap_videotoolbox" in " ".join(commands[1])


@pytest.mark.asyncio
async def test_hardware_decoder_alone_does_not_claim_faster_and_soft_decode_stays_eligible():
    r = RemoteWorkerRegistry()
    a = await add(r, "older")
    b = await add(r, "av1", hw_decoders=["hevc", "h264", "av1"])
    p = replace(plan(), video=replace(plan().video, source_codec="av1"))
    assert old_select([a, b]) is a
    assert r.reserve("av1", backend="videotoolbox", plan=p) is a
    r.release_job("av1")
    p = replace(p, video=replace(p.video, source_codec="vc1"))
    assert r.reserve("soft", backend="videotoolbox", plan=p) is a


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "video",
    [{"burn_subtitle": "embedded:2"}, {"source_color": "BT.2020"}, {"source_bit_depth": None}],
)
async def test_unusable_gpu_filters_do_not_get_a_false_bonus(video):
    r = RemoteWorkerRegistry()
    a = await add(r, "older")
    await add(r, "gpu", filters=["scale_vt", "tonemap_videotoolbox"])
    p = replace(plan(), video=replace(plan().video, **video))
    assert r.reserve("job", backend="videotoolbox", plan=p) is a


@pytest.mark.asyncio
async def test_capacity_fraction_beats_raw_job_count():
    r = RemoteWorkerRegistry()
    a = await add(r, "small", max_jobs=2)
    b = await add(r, "large", max_jobs=4)
    a.jobs.add("one")
    b.jobs.add("two")
    assert old_select([a, b]) is a
    assert r.reserve("new", backend="videotoolbox") is b


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "load",
    [
        {"cpu": 0.95, "memory_pressure": 0, "thermal_state": 0},
        {"cpu": 0.1, "memory_pressure": 1, "thermal_state": 0},
        {"cpu": 0.1, "memory_pressure": 0, "thermal_state": 2},
    ],
)
async def test_resource_pressure_moves_new_work_but_stale_load_does_not(load):
    r = RemoteWorkerRegistry()
    a = await add(r, "loaded")
    b = await add(r, "available")
    await r.handle_message(a, {"type": "worker.heartbeat", "load": load})
    assert old_select([a, b]) is a
    assert r.reserve("new", backend="videotoolbox") is b
    r.release_job("new")
    a.load_seen -= 16
    assert r.reserve("stale", backend="videotoolbox") is a


@pytest.mark.asyncio
async def test_load_is_smoothed_and_invalid_values_do_not_poison_scheduler():
    r = RemoteWorkerRegistry()
    a = await add(r, "mac")
    for cpu in (0.2, 0.8):
        await r.handle_message(
            a,
            {
                "type": "worker.heartbeat",
                "load": {"cpu": cpu, "memory_pressure": 0, "thermal_state": 0},
            },
        )
    assert a.load["cpu"] == pytest.approx(0.5)
    for cpu in (float("nan"), -1, 2, True, "bad"):
        await r.handle_message(
            a,
            {
                "type": "worker.heartbeat",
                "load": {"cpu": cpu, "memory_pressure": 0, "thermal_state": 0},
            },
        )
        assert a.load["cpu"] == pytest.approx(0.5)


@pytest.mark.asyncio
async def test_cpu_bands_prefer_idle_devices_without_chasing_small_fluctuations():
    r = RemoteWorkerRegistry()
    a = await add(r, "loaded")
    b = await add(r, "idle")
    for worker, cpu in ((a, 0.65), (b, 0.2)):
        r._update_load(worker, {"cpu": cpu, "memory_pressure": 0, "thermal_state": 0})
    assert old_select([a, b]) is a
    assert r.reserve("new", backend="videotoolbox") is b
    r.release_job("new")
    a.load["cpu"] = 0.28
    assert r.reserve("same-band", backend="videotoolbox") is a


@pytest.mark.asyncio
async def test_speed_requires_same_source_and_sufficient_samples_and_ignores_pause():
    r = RemoteWorkerRegistry()
    a = await add(r, "older")
    b = await add(r, "faster")
    p = plan()
    profile = r._profile(p, 7)
    for worker, speed in [(a, 2), (b, 5)]:
        a.draining = worker is b
        b.draining = worker is a
        job = worker.worker_id
        r.reserve(job, backend="videotoolbox", plan=p, source_id=7, learn_speed=True)
        for _ in range(1, 4):
            r._progress_samples[job] = (time.monotonic() - 1, 0)
            await r.handle_message(
                worker, {"type": "job.progress", "job_id": job, "out_time_ms": speed * 1000}
            )
        assert worker.speeds[profile] == pytest.approx(speed, rel=0.01)
        await r.pause(job)
        before = worker.speeds[profile]
        await r.handle_message(
            worker, {"type": "job.progress", "job_id": job, "out_time_ms": 1_000_000}
        )
        assert worker.speeds[profile] == before
        await r.resume(job)
        assert job not in r._progress_samples
        r.release_job(job)
    a.draining = b.draining = False
    assert old_select([a, b]) is a
    assert r.reserve("faster", backend="videotoolbox", plan=p, source_id=7) is b
    r.release_job("faster")
    assert r.reserve("different-file", backend="videotoolbox", plan=p, source_id=8) is a
    r.release_job("different-file")
    for different in (
        replace(p, video=replace(p.video, bitrate_cap_bps=2_000_000)),
        replace(p, audio=replace(p.audio, action="transcode", codec="aac", channels=2)),
        replace(p, container="hls-ts"),
    ):
        assert (
            r.reserve("different-output", backend="videotoolbox", plan=different, source_id=7) is a
        )
        r.release_job("different-output")


@pytest.mark.asyncio
async def test_limited_or_concurrent_jobs_do_not_teach_false_performance():
    r = RemoteWorkerRegistry()
    a = await add(r, "mac")
    p = plan()
    r.reserve("limited", backend="videotoolbox", plan=p, source_id=7)
    assert not r._job_profiles
    r.reserve("other", backend="videotoolbox", plan=p, source_id=7, learn_speed=True)
    r._progress_samples["other"] = (time.monotonic() - 1, 0)
    await r.handle_message(a, {"type": "job.progress", "job_id": "other", "out_time_ms": 5000})
    assert not a.speeds


@pytest.mark.asyncio
async def test_actual_delivery_headroom_protects_busy_gpu_even_with_idle_cpu():
    r = RemoteWorkerRegistry()
    a = await add(r, "gpu", filters=["scale_vt"])
    b = await add(r, "cpu-filters")
    p = plan()
    r.reserve("playing", backend="videotoolbox", plan=p)
    b.jobs.add("fast-playing")
    for _ in range(3):
        r._progress_samples["playing"] = (time.monotonic() - 1, 0)
        await r.handle_message(
            a, {"type": "job.progress", "job_id": "playing", "out_time_ms": 1050}
        )
    assert r.reserve("new", backend="videotoolbox", plan=p) is b
    r.release_job("new")
    await r.pause("playing")
    assert "playing" not in r._job_speeds
    assert r.reserve("buffered", backend="videotoolbox", plan=p) is a


@pytest.mark.asyncio
async def test_reserve_is_fast_and_capacity_is_not_oversubscribed():
    r = RemoteWorkerRegistry()
    workers = [await add(r, f"mac-{i}") for i in range(10)]
    p = plan()
    profile = r._profile(p, 7)
    for worker in workers:
        r._update_load(worker, {"cpu": 0.3, "memory_pressure": 0, "thermal_state": 0})
        worker.speeds[profile] = 3
        worker.speed_samples[profile] = 3
    timings = []
    baseline = []
    for i in range(2000):
        started = time.perf_counter_ns()
        with r._lock:
            min(
                (
                    w
                    for w in workers
                    if len(w.jobs) < w.max_jobs and not w.draining and r._is_fresh(w)
                ),
                key=lambda w: (len(w.jobs), w.connected_at),
            )
        baseline.append((time.perf_counter_ns() - started) / 1_000_000)
        started = time.perf_counter_ns()
        r.reserve(str(i), backend="videotoolbox", plan=p, source_id=7, learn_speed=True)
        r.release_job(str(i))
        timings.append((time.perf_counter_ns() - started) / 1_000_000)
    p99 = sorted(timings)[int(len(timings) * 0.99)]
    old_p99 = sorted(baseline)[int(len(baseline) * 0.99)]
    print(
        f"10 workers, 2000: legacy selection p99={old_p99:.4f} ms; "
        f"new reserve/release p99={p99:.4f} ms"
    )
    assert p99 < 5  # 起播预算：派单含占位/释放不得消耗 5 ms。
    for i in range(40):
        r.reserve(str(i), backend="videotoolbox", plan=p)
    with pytest.raises(RemoteWorkerUnavailable):
        r.reserve("overflow", backend="videotoolbox", plan=p)
    assert all(len(w.jobs) == 4 for w in workers)

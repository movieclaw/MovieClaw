"""AI 字幕「从音轨识别」端到端演练：真实后端 + 真实 ffmpeg + 真实 SenseVoice + 假模型网关。

没有任何字幕的片子，照 iOS 与网页的调用顺序走一遍用户能感知到的完整流程
（docs/design/subtitle-asr.md §9.2）：

- A1 英语片 → 简体中文：预检秒回，讲清楚要从音轨识别、预计多久；任务依次读取音轨、
  识别台词（有确定进度）、翻译、写入；识别原文另存为 asr 外挂；
- A2 同一部片再要繁体中文：已有识别外挂，直接拿它做参考，不再识别；
- A3 另一部英语片 → 英语：同语种，不调用模型（网关零请求）；
- A4 日语片 → 简体中文；
- A5 识别中点停止：秒级生效，识别子进程不留孤儿；
- A6 识别过的片子：默认复用识别外挂，选音轨也只复用；勾「重新识别」才重新识别；
- A7 识别到一半 kill -9 后端：子进程跟着退出，重启后从识别断点接着识别，条数与不中断一致；
- A8 识别到一半优雅重启（应用更新）：任务退回队列，重启后立刻从断点接着识别。

素材用模型包自带的测试音频拼成（不入库、不涉及版权内容）。不进 CI，本机手动跑：
    MOVIECLAW_ASR_DIR=<模型目录> ASR_SAMPLE_DIR=<test_wavs 目录> \\
        .venv/bin/python scripts/perf/e2e_subtitle_asr.py
运行数据落在系统临时目录；最后打印报告，任一检查不通过即非零退出。
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_subtitle_gen as base  # noqa: E402  复用假网关、后端启停与任务跟踪

API, RUN, check, log = base.API, base.RUN, base.check, base.log
REPO = base.REPO
ASR_DIR = Path(os.environ.get("MOVIECLAW_ASR_DIR", REPO / "data/models/asr")).resolve()
SAMPLES = Path(
    os.environ.get(
        "ASR_SAMPLE_DIR",
        REPO
        / "data/models/asr-dl/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/test_wavs",
    )
).resolve()
#: 每部片子 60 句台词：完整度检查要 ≥50 条、覆盖 ≥50% 片长
REPEATS = 60
#: 崩溃 / 重启场景用的长片（约 57 分钟）：识别要几十秒，才来得及在中途打断
LONG_REPEATS = 400
GAP_SECONDS = 3
#: 每句测试音频断成两条字幕（「The tribal chieftain called for the boy.」+ 下一句）
CUES_PER_SENTENCE = 2


def make_movie(path: Path, sample: Path, language: str, repeats: int = REPEATS) -> None:
    """一句台词 + 3 秒静音反复多次，配黑屏视频封成不带任何字幕的 MKV。"""
    work = RUN / "work"
    work.mkdir(exist_ok=True)
    unit = work / f"{sample.stem}-unit.wav"
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-y", "-i", str(sample),
            "-af", f"apad=pad_dur={GAP_SECONDS}", "-ar", "16000", "-ac", "1", str(unit),
        ],
        check=True,
    )  # fmt: skip
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=160x90:r=2",
            "-stream_loop", str(repeats - 1), "-i", str(unit),
            "-shortest", "-map", "0:v", "-map", "1:a",
            "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "20k",
            "-c:a", "aac", "-b:a", "64k", "-metadata:s:a:0", f"language={language}",
            str(path),
        ],
        check=True,
    )  # fmt: skip
    an_hour_ago = time.time() - 3600  # 扫描把刚改过的文件当「疑似写入中」暂缓入账
    os.utime(path, (an_hour_ago, an_hour_ago))


def asr_workers() -> list[str]:
    out = subprocess.run(["pgrep", "-f", "asr_worker.py"], capture_output=True, text=True)
    return [pid for pid in out.stdout.split() if pid]


def cues(path: Path) -> list[tuple[str, str]]:
    return base.read_srt(path) if path.exists() else []


def scenario_english_to_chinese(client: httpx.Client, file_id: int, video: Path) -> None:
    log("A1 英语片 → 简体中文（先识别再翻译）")
    base.gateway(reset_stats=True, latency=0.05)
    pv, ms = base.preview(client, file_id, "chs")
    check("预检秒回", ms < 2000, f"{ms:.0f} ms")
    check(
        "预检选中音轨识别",
        pv.get("selected_source_key") == "audio:0",
        str(pv.get("selected_source_key")),
    )
    notice = pv.get("reference_notice") or ""
    check(
        "确认框讲清楚走本地语音模型、要多久",
        "本地语音模型" in notice and "分钟" in notice,
        notice[:80],
    )
    check(
        "按片长粗估了翻译 token", pv.get("estimated_tokens", 0) > 0, str(pv.get("estimated_tokens"))
    )
    job, ms = base.start(client, file_id, "chs")
    check("发起秒回", ms < 2000, f"{ms:.0f} ms")
    watch = base.JobWatch(client, job)
    watch.until(base.finished, timeout=600)
    phases = watch.phases()
    log(f"    阶段：{' → '.join(phases)}；用时 {watch.timeline[-1][0]} 秒")
    check("任务成功", watch.job["status"] == "succeeded", str(watch.job.get("error")))
    check(
        "先读取音轨再识别台词",
        phases[:3] == ["extracting", "transcribing", "glossary"]
        or (
            "extracting" in phases
            and "transcribing" in phases
            and phases.index("extracting") < phases.index("transcribing")
        ),
        str(phases),
    )
    percents = [
        pct
        for _t, _s, phase, pct, _m in watch.timeline
        if phase == "transcribing" and pct is not None
    ]
    check("识别阶段有确定进度", bool(percents), str(percents[-3:]))
    check("识别阶段不做同步检测", "syncing" not in phases, str(phases))
    asr_cues = cues(video.with_name(f"{video.stem}.asr.eng.srt"))
    zh_cues = cues(video.with_name(f"{video.stem}.ai-chs.chi.srt"))
    check("识别原文另存为 asr 外挂", len(asr_cues) >= 50, f"{len(asr_cues)} 条")
    check(
        "识别出了台词原文",
        any("chieftain" in text.lower() for _t, text in asr_cues),
        asr_cues[0][1] if asr_cues else "",
    )
    check(
        "译文与原文条数一致、时间轴一致",
        [t for t, _ in zh_cues] == [t for t, _ in asr_cues],
        f"{len(zh_cues)} 条",
    )
    stats = base.gateway_stats()
    check("翻译调用了模型", stats["translate_requests"] > 0, f"{stats['translate_requests']} 次")
    check("识别结束没有残留子进程", not asr_workers(), str(asr_workers()))


def scenario_reuse_transcript(client: httpx.Client, file_id: int) -> None:
    log("A2 已有识别外挂：再要繁体中文，直接拿它做参考")
    pv, _ = base.preview(client, file_id, "cht")
    key = pv.get("selected_source_key") or ""
    check("选中已有的识别外挂", key.endswith(".asr.eng.srt"), key)
    job, _ = base.start(client, file_id, "cht")
    watch = base.JobWatch(client, job)
    watch.until(base.finished, timeout=300)
    check("任务成功", watch.job["status"] == "succeeded", str(watch.job.get("error")))
    check("没有再识别一遍", "transcribing" not in watch.phases(), str(watch.phases()))


def scenario_same_language(client: httpx.Client, file_id: int, video: Path) -> None:
    log("A3 英语片 → 英语（同语种，不调用模型）")
    base.gateway(reset_stats=True)
    pv, _ = base.preview(client, file_id, "eng")
    check("同语种预估 0 token", pv.get("estimated_tokens") == 0, str(pv.get("estimated_tokens")))
    check(
        "输出就是识别外挂",
        pv.get("output_filename") == f"{video.stem}.asr.eng.srt",
        str(pv.get("output_filename")),
    )
    job, _ = base.start(client, file_id, "eng")
    watch = base.JobWatch(client, job)
    watch.until(base.finished, timeout=600)
    check("任务成功", watch.job["status"] == "succeeded", str(watch.job.get("error")))
    stats = base.gateway_stats()
    total = sum(stats.get("requests", {}).values())
    check("网关零请求", total == 0, str(stats))
    check("落了识别外挂", len(cues(video.with_name(f"{video.stem}.asr.eng.srt"))) >= 50)


def scenario_japanese(client: httpx.Client, file_id: int, video: Path) -> None:
    log("A4 日语片 → 简体中文")
    pv, _ = base.preview(client, file_id, "chs")
    notice = pv.get("reference_notice") or ""
    check("确认框写明台词是日语", "日语" in notice, notice[:60])
    job, _ = base.start(client, file_id, "chs")
    watch = base.JobWatch(client, job)
    watch.until(base.finished, timeout=600)
    check("任务成功", watch.job["status"] == "succeeded", str(watch.job.get("error")))
    ja = cues(video.with_name(f"{video.stem}.asr.jpn.srt"))
    check(
        "日语识别外挂",
        len(ja) >= 50 and any("弁当" in text for _t, text in ja),
        ja[0][1] if ja else "",
    )
    check("简中译文", len(cues(video.with_name(f"{video.stem}.ai-chs.chi.srt"))) == len(ja))


def scenario_cancel(client: httpx.Client, file_id: int) -> None:
    log("A5 识别中点停止")
    job, _ = base.start(client, file_id, "chs")
    watch = base.JobWatch(client, job)
    watch.until(
        lambda j: j["progress"].get("phase") == "transcribing" or base.finished(j), timeout=120
    )
    check("进入识别阶段", watch.job["progress"].get("phase") == "transcribing", watch.job["status"])
    r = client.post(f"{API}/jobs/{job['id']}/cancel")
    assert r.status_code == 200, r.text
    stop_at = time.monotonic()
    watch.until(base.finished, timeout=60)
    seconds = time.monotonic() - stop_at
    check("停止秒级生效", watch.job["status"] == "cancelled" and seconds < 5, f"{seconds:.1f} 秒")
    time.sleep(1)
    check("识别子进程整组结束", not asr_workers(), str(asr_workers()))


def generation_preview(
    client: httpx.Client, file_id: int, target: str, key: str | None, retranscribe: bool = False
) -> dict:
    params: dict = {"target_language": target, "retranscribe": str(retranscribe).lower()}
    if key:
        params["source_candidate_key"] = key
    r = client.get(f"{API}/libraries/files/{file_id}/subtitles/generation-preview", params=params)
    assert r.status_code == 200, r.text
    return r.json()["data"]


def generation_start(
    client: httpx.Client, file_id: int, target: str, key: str | None, retranscribe: bool = False
) -> dict:
    body = {"target_language": target, "source_candidate_key": key, "retranscribe": retranscribe}
    r = client.post(f"{API}/libraries/files/{file_id}/subtitles/generations", json=body)
    assert r.status_code == 202, r.text
    return r.json()["data"]


def scenario_retranscribe(client: httpx.Client, file_id: int, video: Path) -> None:
    log("A6 识别过的片子：默认复用，勾「重新识别」才重新识别")
    sidecar = video.with_name(f"{video.stem}.asr.eng.srt")
    before = sidecar.stat().st_mtime_ns
    pv = generation_preview(client, file_id, "chs", None)
    kinds = [c["kind"] for c in pv["candidates"]]
    check(
        "默认仍选识别外挂，音轨列在候选里",
        (pv.get("selected_source_key") or "").endswith(".asr.eng.srt") and "audio" in kinds,
        f"{pv.get('selected_source_key')} · {kinds}",
    )
    pv = generation_preview(client, file_id, "chs", "audio:0")
    notice = pv.get("reference_notice") or ""
    check("选音轨：说明直接用上次的识别结果", "已经识别过" in notice, notice[:70])
    job = generation_start(client, file_id, "chs", "audio:0")
    watch = base.JobWatch(client, job)
    watch.until(base.finished, timeout=300)
    check("任务成功", watch.job["status"] == "succeeded", str(watch.job.get("error")))
    check("没有再识别一遍", "transcribing" not in watch.phases(), str(watch.phases()))
    check("识别外挂没被动过", sidecar.stat().st_mtime_ns == before)

    pv = generation_preview(client, file_id, "chs", "audio:0", retranscribe=True)
    notice = pv.get("reference_notice") or ""
    check("勾选重新识别：说明不用上次的结果", "不用上次的识别结果" in notice, notice[:70])
    job = generation_start(client, file_id, "chs", "audio:0", retranscribe=True)
    watch = base.JobWatch(client, job)
    watch.until(base.finished, timeout=600)
    check("重新识别任务成功", watch.job["status"] == "succeeded", str(watch.job.get("error")))
    check("这次确实重新识别了", "transcribing" in watch.phases(), str(watch.phases()))
    check(
        "识别外挂换成了新结果",
        sidecar.stat().st_mtime_ns > before and len(cues(sidecar)) >= 50,
        f"{len(cues(sidecar))} 条",
    )


def _checkpoint_segments(file_id: int) -> int:
    path = RUN / "data" / "cache" / "subtitle_gen" / f"{file_id}.a0.asr.jsonl"
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text(encoding="utf-8").splitlines() if '"segment"' in line)


def _wait_transcribing(watch: base.JobWatch, percent: float) -> float:
    def far_enough(job: dict) -> bool:
        progress = job["progress"]
        return base.finished(job) or (
            progress.get("phase") == "transcribing" and (progress.get("percent") or 0) >= percent
        )

    watch.until(far_enough, timeout=300)
    return float(watch.job["progress"].get("percent") or 0)


def _resumed_transcription(watch: base.JobWatch, since: int) -> list[float]:
    return [
        pct
        for _t, _s, phase, pct, _m in watch.timeline[since:]
        if phase == "transcribing" and pct is not None
    ]


def _check_complete_transcript(video: Path, repeats: int) -> None:
    got = cues(video.with_name(f"{video.stem}.asr.eng.srt"))
    expected = repeats * CUES_PER_SENTENCE
    texts = [text for _t, text in got]
    # 测试音频每句断成的两条交替出现：相邻两条相同就是接缝处重复识别了
    duplicated = sum(1 for a, b in zip(texts, texts[1:], strict=False) if a == b)
    check(
        "续跑后识别外挂完整：条数与不中断一致、接缝处没有重复",
        abs(len(got) - expected) <= 2 and duplicated == 0,
        f"{len(got)} 条（不中断应为 {expected} 条），相邻重复 {duplicated} 处",
    )


def scenario_crash_resume(client: httpx.Client, file_id: int, video: Path, holder: dict) -> None:
    log("A7 识别到一半 kill -9 后端：重启后从断点接着识别")
    job = generation_start(client, file_id, "eng", None)
    watch = base.JobWatch(client, job)
    killed_at = _wait_transcribing(watch, 30)
    check("进入识别阶段", watch.job["progress"].get("phase") == "transcribing", f"{killed_at}%")
    workers = asr_workers()
    os.kill(holder["api"].pid, signal.SIGKILL)
    holder["api"].wait()
    log(f"    已 kill -9 后端（识别到 {killed_at}%，识别子进程 {workers}）")
    deadline = time.monotonic() + 10
    while asr_workers() and time.monotonic() < deadline:
        time.sleep(0.2)
    check("后端被杀后识别子进程也退出（不留孤儿）", not asr_workers(), str(asr_workers()))
    saved = _checkpoint_segments(file_id)
    check("识别断点已经落盘", saved > 0, f"{saved} 段")

    holder["api"] = base.start_api(holder["env"], "api-after-kill.log")
    base.login(client)
    watch.client = client
    mark = len(watch.timeline)
    crash_at = time.monotonic()
    watch.until(base.finished, timeout=600)
    check(
        "重启后任务按租约自愈并完成",
        watch.job["status"] == "succeeded",
        f"重启后 {time.monotonic() - crash_at:.0f} 秒完成，第 {watch.job['attempt']} 次执行",
    )
    resumed = _resumed_transcription(watch, mark)
    log_text = (RUN / "api-after-kill.log").read_text(encoding="utf-8", errors="replace")
    check(
        "从断点接着识别，没有从头再来",
        "从识别断点接着识别" in log_text and bool(resumed) and resumed[0] >= killed_at - 10,
        f"重启后首个识别进度 {resumed[:1]}%（被杀时 {killed_at}%）",
    )
    _check_complete_transcript(video, LONG_REPEATS)
    check("断点用完即删", _checkpoint_segments(file_id) == 0)


def scenario_graceful_restart(
    client: httpx.Client, file_id: int, video: Path, holder: dict
) -> None:
    log("A8 识别到一半优雅重启（应用更新）：重启后立刻接着识别")
    job = generation_start(client, file_id, "eng", None)
    watch = base.JobWatch(client, job)
    stopped_at = _wait_transcribing(watch, 30)
    holder["api"].send_signal(signal.SIGTERM)
    holder["api"].wait(timeout=60)
    check("优雅停机后识别子进程已结束", not asr_workers(), str(asr_workers()))
    holder["api"] = base.start_api(holder["env"], "api-after-restart.log")
    base.login(client)
    watch.client = client
    mark = len(watch.timeline)
    restart_at = time.monotonic()
    watch.until(
        lambda j: base.finished(j) or j["progress"].get("phase") == "transcribing", timeout=60
    )
    waited = time.monotonic() - restart_at
    check("重启后不等租约过期、立刻接着识别", waited < 20, f"{waited:.0f} 秒后恢复识别")
    watch.until(base.finished, timeout=600)
    check("任务成功", watch.job["status"] == "succeeded", str(watch.job.get("error")))
    resumed = _resumed_transcription(watch, mark)
    check(
        "从停机时的位置接着识别",
        bool(resumed) and resumed[0] >= stopped_at - 10,
        f"重启后首个识别进度 {resumed[:1]}%（停机时 {stopped_at}%）",
    )
    _check_complete_transcript(video, LONG_REPEATS)


def main() -> None:
    model_files = [ASR_DIR / name for name in ("model.int8.onnx", "tokens.txt", "silero_vad.onnx")]
    if not all(path.is_file() for path in model_files):
        sys.exit(f"模型不全：{ASR_DIR}")
    if not (SAMPLES / "en.wav").is_file() or not (SAMPLES / "ja.wav").is_file():
        sys.exit(f"测试音频不全：{SAMPLES}")
    (RUN / "data").mkdir(parents=True)
    shim_dir = RUN / "shim"
    shim_dir.mkdir()
    shim = shim_dir / "ffmpeg"
    shim.write_text(base.SHIM.format(python=base.PY, real=base.REAL_FFMPEG), encoding="utf-8")
    shim.chmod(0o755)
    log(f"运行目录：{RUN}")

    media = RUN / "media"
    videos = {
        "english": media / "English Movie (2020)" / "English Movie (2020).mkv",
        "same": media / "Same Language (2021)" / "Same Language (2021).mkv",
        "japanese": media / "Japanese Movie (2022)" / "Japanese Movie (2022).mkv",
        "cancel": media / "Cancel Movie (2023)" / "Cancel Movie (2023).mkv",
        "crash": media / "Crash Movie (2024)" / "Crash Movie (2024).mkv",
        "restart": media / "Restart Movie (2025)" / "Restart Movie (2025).mkv",
    }
    log("生成素材：英语片 ×5、日语片 ×1（不带任何字幕；崩溃 / 重启用的两部是约 57 分钟的长片）")
    make_movie(videos["english"], SAMPLES / "en.wav", "eng")
    make_movie(videos["same"], SAMPLES / "en.wav", "eng")
    make_movie(videos["cancel"], SAMPLES / "en.wav", "eng")
    make_movie(videos["japanese"], SAMPLES / "ja.wav", "jpn")
    make_movie(videos["crash"], SAMPLES / "en.wav", "eng", LONG_REPEATS)
    make_movie(videos["restart"], SAMPLES / "en.wav", "eng", LONG_REPEATS)

    gateway_proc = subprocess.Popen(
        [base.PY, str(REPO / "scripts/perf/fake_llm_gateway.py"), "--port", str(base.GATEWAY_PORT)]
    )
    env = {
        **base.backend_env(0),
        "MOVIECLAW_ASR_DIR": str(ASR_DIR),
        # worktree 里用主仓库 .venv 时，后端要导入的是这里的代码（见 AGENTS 记忆）
        "PYTHONPATH": str(REPO / "src"),
    }
    holder = {"env": env, "api": base.start_api(env, "api.log")}
    try:
        with httpx.Client(timeout=30) as client:
            r = client.post(
                f"{API}/auth/bootstrap", json={"username": "admin", "password": "e2e-pass-1"}
            )
            assert r.status_code == 200, r.text
            r = client.post(
                f"{API}/llm/providers",
                json={
                    "name": "假网关",
                    "provider_type": "openai_compat",
                    "base_url": f"{base.GATEWAY}/v1",
                    "api_key": "sk-fake",
                    "default_model": "fake-model",
                    "extra_models": [
                        {"id": "fake-model", "context_window": 128000, "max_output_tokens": 8000}
                    ],
                },
            )
            assert r.status_code == 200, r.text
            r = client.post(
                f"{API}/libraries",
                json={"name": "识别演练", "kind": "video", "root_paths": [str(media)]},
            )
            assert r.status_code == 200, r.text
            library_id = r.json()["data"]["id"]
            files: dict[str, dict] = {}
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline and len(files) < len(videos):
                time.sleep(1)
                for item in client.get(f"{API}/libraries/{library_id}/items").json()["data"]:
                    detail = client.get(
                        f"{API}/libraries/{library_id}/items/{item['media_item_id']}"
                    ).json()["data"]
                    for f in detail["files"]:
                        if f.get("duration_seconds") and f.get("audio_streams"):
                            files[f["file_path"]] = f
            by_key = {
                key: files[str(path)]["id"] for key, path in videos.items() if str(path) in files
            }
            assert len(by_key) == len(videos), f"扫描没入账全部片子：{list(files)}"
            log(f"    媒体库扫描完成：{by_key}")

            scenario_english_to_chinese(client, by_key["english"], videos["english"])
            scenario_reuse_transcript(client, by_key["english"])
            scenario_same_language(client, by_key["same"], videos["same"])
            scenario_japanese(client, by_key["japanese"], videos["japanese"])
            scenario_cancel(client, by_key["cancel"])
            scenario_retranscribe(client, by_key["english"], videos["english"])
            scenario_crash_resume(client, by_key["crash"], videos["crash"], holder)
            scenario_graceful_restart(client, by_key["restart"], videos["restart"], holder)
    finally:
        for proc in (holder["api"], gateway_proc):
            if proc.poll() is None:
                proc.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    proc.wait(timeout=15)

    failed = [name for name, ok, _ in base.CHECKS if not ok]
    print(f"\n共 {len(base.CHECKS)} 项检查，通过 {len(base.CHECKS) - len(failed)} 项")
    if failed:
        print("未通过：" + "；".join(failed))
        sys.exit(1)
    print("SUBTITLE-ASR-E2E-OK")


if __name__ == "__main__":
    main()

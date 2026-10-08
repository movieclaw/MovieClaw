"""Android TV 首页滑动压测（docs/perf/androidtv-home-scroll-2026-10.md）。

每个场景：强停 App → 冷启动进首页 → 等首屏就绪 → 开 perfetto → 设备上按脚本发遥控器按键 → 停 perfetto →
拉回 trace 用 trace_processor 算指标。多个 --apk 时逐轮交替安装运行（ABAB），抵消机器负载漂移。

前提：模拟器已用 debug 包登录测试服务器（tests/fixture/fixture.py start + tests/perf/seed_home.py），
被测包是 benchmark 构建（与正式包同样 R8 优化、不可调试、可被 perfetto 采样，覆盖安装不丢登录）。
依赖：pip install perfetto（trace_processor 的 Python 封装）。同时连着多台设备时先设 ANDROID_SERIAL。

  python apps/android-tv/scripts/perf/home_scroll.py --apk base=/tmp/base.apk --apk new=app-benchmark.apk \
      --runs 3 --weak --out /tmp/atv-perf

--weak：测量期间把模拟器进程压到 Mac 的能效核上（taskpolicy -b），CPU 慢 4～9 倍，接近低端电视盒子。
--compile：verify（默认，等同刚装完 / 刚升级、全靠 JIT）或 speed-profile（后台编译过基线配置之后）。
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

PKG = "io.movieclaw.androidtv"
VSYNC_MS = 1000 / 60

# 场景：设备上执行的 shell 片段。起点都是冷启动后焦点停在「继续播放」上
STEP = 0.5  # 逐个按：每 0.5 秒一下（边看边挑）
HOLD = 0.05  # 按住：系统按键连发 20 次 / 秒


def keys(code: str, n: int, gap: float) -> str:
    return f"for i in $(seq {n}); do input keyevent {code}; sleep {gap}; done; "


SCENARIOS = {
    "idle": "sleep 6; ",
    "v-step": keys("DPAD_DOWN", 14, STEP) + "sleep 1; " + keys("DPAD_UP", 14, STEP),
    "v-hold": keys("DPAD_DOWN", 14, HOLD) + "sleep 1.5; " + keys("DPAD_UP", 14, HOLD),
    "h-step-upnext": keys("DPAD_DOWN", 1, 1) + keys("DPAD_RIGHT", 12, STEP) + keys("DPAD_LEFT", 12, STEP),
    "h-hold-upnext": keys("DPAD_DOWN", 1, 1) + keys("DPAD_RIGHT", 16, HOLD) + "sleep 1.5; " + keys("DPAD_LEFT", 16, HOLD),
    "h-step-shelf": keys("DPAD_DOWN", 2, 1) + keys("DPAD_RIGHT", 10, STEP) + keys("DPAD_LEFT", 10, STEP),
    "h-hold-shelf": keys("DPAD_DOWN", 2, 1) + keys("DPAD_RIGHT", 12, HOLD) + "sleep 1.5; " + keys("DPAD_LEFT", 12, HOLD),
}

TRACE_CONFIG = f"""
buffers {{ size_kb: 131072 fill_policy: RING_BUFFER }}
buffers {{ size_kb: 4096 fill_policy: RING_BUFFER }}
data_sources {{ config {{ name: "linux.ftrace" target_buffer: 0 ftrace_config {{
  ftrace_events: "sched/sched_switch" ftrace_events: "sched/sched_wakeup"
  atrace_categories: "gfx" atrace_categories: "view" atrace_categories: "input" atrace_categories: "dalvik"
  atrace_apps: "{PKG}" }} }} }}
data_sources {{ config {{ name: "android.surfaceflinger.frametimeline" target_buffer: 0 }} }}
data_sources {{ config {{ name: "linux.process_stats" target_buffer: 1 process_stats_config {{ scan_all_processes_on_start: true }} }} }}
duration_ms: 90000
"""


def adb(*args: str, check: bool = True, capture: bool = True) -> str:
    out = subprocess.run(["adb", *args], check=check, capture_output=capture, text=True)
    return out.stdout if capture else ""


def qemu_pid() -> str | None:
    out = subprocess.run(["pgrep", "-f", "qemu-system"], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def set_weak(on: bool) -> None:
    pid = qemu_pid()
    if pid:
        subprocess.run(["taskpolicy", "-b" if on else "-B", "-p", pid], check=False)


def ensure_device(avd: str | None) -> None:
    """模拟器被别的任务挤到看门狗超时自杀时，按原样冷启动回来（登录状态在数据分区里，不丢）"""
    if subprocess.run(["adb", "get-state"], capture_output=True).returncode == 0:
        return
    if not avd:
        raise SystemExit("设备不在线")
    serial = os.environ.get("ANDROID_SERIAL", "emulator-5554")
    port = serial.rsplit("-", 1)[-1]
    print(f"设备掉线，重新启动模拟器 {avd} ……", flush=True)
    subprocess.Popen(
        ["caffeinate", "-dims", str(Path.home() / "Library/Android/sdk/emulator/emulator"), "-avd", avd, "-port", port,
         "-no-snapshot", "-no-boot-anim", "-crash-report-mode", "never"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    for _ in range(200):
        if adb("shell", "getprop", "sys.boot_completed", check=False).strip() == "1":
            time.sleep(10)
            return
        time.sleep(3)
    raise SystemExit("模拟器没能启动")


def cpu_idle() -> float:
    """宿主机此刻的 CPU 空闲百分比（top 采两次取后一次；负载平均值反应慢，还把等 IO 的进程算进去）"""
    out = subprocess.run(["top", "-l", "2", "-n", "0", "-s", "1"], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines() if l.startswith("CPU usage")]
    return float(lines[-1].rsplit(",", 1)[1].split("%")[0]) if lines else 100.0


def wait_quiet(min_idle: float) -> None:
    """宿主机上别的任务把 CPU 吃满时先等：模拟器的 CPU 被抢走，数字会成倍变差，还可能被看门狗杀掉"""
    waited = 0
    while (idle := cpu_idle()) < min_idle and waited < 7200:
        if waited % 300 == 0:
            print(f"宿主机 CPU 空闲 {idle:.0f}%，等到 {min_idle:.0f}% 以上……", flush=True)
        time.sleep(20)
        waited += 20


def launch(compile_mode: str, settle: float) -> None:
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "cmd", "package", "compile", "-m", compile_mode, "-f", PKG)
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/.MainActivity")
    time.sleep(settle)


def record(name: str, script: str, out: Path) -> Path:
    remote = f"/data/misc/perfetto-traces/{name}.pftrace"
    pid = subprocess.run(
        ["adb", "shell", f"perfetto --txt -c - -o {remote} --background"],
        input=TRACE_CONFIG, capture_output=True, text=True, check=True,
    ).stdout.strip().splitlines()[-1]
    time.sleep(1.0)
    adb("shell", script)
    time.sleep(1.5)
    adb("shell", "kill", "-TERM", pid, check=False)
    for _ in range(50):
        if not adb("shell", f"ps -p {pid} -o pid= || true").strip():
            break
        time.sleep(0.2)
    local = out / f"{name}.pftrace"
    adb("pull", remote, str(local))
    adb("shell", "rm", remote, check=False)
    return local


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]


def analyze(path: Path, scenario: str) -> dict:
    from perfetto.trace_processor import TraceProcessor

    tp = TraceProcessor(trace=str(path))

    def rows(sql: str) -> list:
        return list(tp.query(sql))

    proc = rows(f"select upid, pid from process where name = '{PKG}' order by start_ts desc limit 1")[0]
    upid, pid = proc.upid, proc.pid
    main = rows(f"select utid from thread where tid = {pid}")[0].utid
    rt = rows(f"select utid from thread where upid = {upid} and name = 'RenderThread'")[0].utid
    bounds = rows("select min(ts) a, max(ts + dur) b from slice")[0]
    inputs = rows(
        f"select min(s.ts) a, max(s.ts + s.dur) b from slice s join thread_track tt on s.track_id = tt.id "
        f"where tt.utid = {main} and s.name like 'EarlyPostImeInputStage%'"
    )[0]
    if scenario == "idle" or inputs.a is None:
        start, end = bounds.a + int(0.5e9), bounds.b - int(0.5e9)
    else:
        # 第一下按键前 0.1 秒到最后一下之后 1.2 秒（等滚动、换图收尾）
        start, end = inputs.a - int(0.1e9), inputs.b + int(1.2e9)
    seconds = (end - start) / 1e9

    def thread_slices(utid: int, like: str) -> list:
        return rows(
            f"select s.id, s.ts, s.dur, s.name from slice s join thread_track tt on s.track_id = tt.id "
            f"where tt.utid = {utid} and s.depth = 0 and s.name like '{like}' and s.ts >= {start} and s.ts < {end} order by s.ts"
        )

    def running(utid: int, frames: list) -> dict[int, float]:
        """每个帧切片期间这条线程真正占着 CPU 的毫秒数（按调度记录求交集；等缓冲区、等锁的时间不算）"""
        if not frames:
            return {}
        res = rows(
            f"select s.id, sum(max(0, min(s.ts + s.dur, sc.ts + sc.dur) - max(s.ts, sc.ts))) run from slice s "
            f"join sched sc on sc.utid = {utid} and sc.ts < s.ts + s.dur and sc.ts + sc.dur > s.ts "
            f"where s.id in ({','.join(str(f.id) for f in frames)}) group by s.id"
        )
        return {r.id: r.run / 1e6 for r in res}

    frames_ui = thread_slices(main, "Choreographer#doFrame %")
    frames_rt = thread_slices(rt, "DrawFrame%")
    ui_run, rt_run = running(main, frames_ui), running(rt, frames_rt)
    ui_ms = [ui_run.get(f.id, 0.0) for f in frames_ui]
    rt_ms = [rt_run.get(f.id, 0.0) for f in frames_rt]
    # 每帧 CPU：按 vsync 编号把主线程与渲染线程对上
    rt_by_vsync = {f.name.split()[-1]: ms for f, ms in zip(frames_rt, rt_ms)}
    cpu_ms = [ui + rt_by_vsync.get(f.name.split()[-1], 0.0) for f, ui in zip(frames_ui, ui_ms)]

    # 掉帧（Android 官方口径）：SurfaceFlinger 帧时间线判 App 没在截止时间前交帧（App Deadline Missed）。
    # 不用相邻两帧的呈现间隔：模拟器的宿主合成本身有抖动，静置时也会有一成帧间隔超时
    actual = rows(
        f"select a.ts + a.dur - e.ts - e.dur over, a.jank_type j, a.ts + a.dur e from actual_frame_timeline_slice a "
        f"join expected_frame_timeline_slice e using (upid, surface_frame_token) "
        f"where a.upid = {upid} and a.ts >= {start} and a.ts < {end} order by a.ts"
    )
    late = [a.over / 1e6 for a in actual if a.j and "App Deadline Missed" in a.j]
    ends = [a.e for a in actual]
    gaps = [(b - a) / 1e6 for a, b in zip(ends, ends[1:]) if b - a < 250e6]

    def total(like: str, utid: int = main) -> tuple[int, float]:
        r = rows(
            f"select count(*) n, coalesce(sum(s.dur), 0) d from slice s join thread_track tt on s.track_id = tt.id "
            f"where tt.utid = {utid} and s.name like '{like}' and s.ts >= {start} and s.ts < {end}"
        )[0]
        return r.n, r.d / 1e6

    passes, _ = total("%OpsTask::onExecute%", rt)
    draw_ops, _ = total("%Op", rt)
    save_layers, _ = total("alpha caused saveLayer%", rt)
    layer_renders = rows(
        f"select count(*) n from slice p join descendant_slice(p.id) d where p.name = 'flush layers' "
        f"and d.name like '%OpsTask::onExecute%' and p.ts >= {start} and p.ts < {end}"
    )[0].n
    recompose_n, recompose_ms = total("Recomposer:recompose")
    layout_n, layout_ms = total("AndroidOwner:measureAndLayout")
    jit = rows(f"select utid from thread where upid = {upid} and name like 'Jit thread pool%'")
    jit_ms = total("JIT compiling%", jit[0].utid)[1] if jit else 0.0
    tp.close()
    n = max(1, len(frames_ui))
    return {
        "seconds": round(seconds, 2),
        "frames": len(frames_ui),
        "fps": round(len(actual) / seconds, 1),
        "jank_pct": round(100 * len(late) / max(1, len(actual)), 2),
        "hitch_ms_s": round(sum(late) / seconds, 1),
        "max_late_ms": round(max(late, default=0), 1),
        "max_gap_ms": round(max(gaps, default=0), 1),
        "cpu_p50": round(pct(cpu_ms, 50), 2),
        "cpu_p90": round(pct(cpu_ms, 90), 2),
        "cpu_p99": round(pct(cpu_ms, 99), 2),
        "cpu_max": round(max(cpu_ms, default=0), 1),
        "ui_p90": round(pct(ui_ms, 90), 2),
        "ui_over_16": sum(1 for x in ui_ms if x > VSYNC_MS),
        "rt_p90": round(pct(rt_ms, 90), 2),
        "cpu_ms_s": round(sum(cpu_ms) / seconds, 1),
        "passes_per_frame": round(passes / max(1, len(frames_rt)), 2),
        "ops_per_frame": round(draw_ops / max(1, len(frames_rt)), 1),
        # 离屏：透明度引起的临时离屏（saveLayer）与重画常驻离屏层（flush layers 里的渲染遍）
        "offscreen_per_frame": round((save_layers + layer_renders) / max(1, len(frames_rt)), 2),
        "recompose_ms_s": round(recompose_ms / seconds, 1),
        "recompose_per_frame": round(recompose_n / n, 2),
        "layout_ms_s": round(layout_ms / seconds, 1),
        "jit_ms": round(jit_ms, 0),
    }


COLUMNS = [
    ("fps", "帧/秒"), ("jank_pct", "超时帧%"), ("hitch_ms_s", "超时ms/s"), ("max_late_ms", "最长超时ms"),
    ("cpu_p50", "CPU p50"), ("cpu_p90", "p90"), ("cpu_p99", "p99"), ("ui_over_16", "主线程>16ms"),
    ("passes_per_frame", "渲染遍/帧"), ("ops_per_frame", "绘制调用/帧"), ("offscreen_per_frame", "离屏/帧"), ("recompose_ms_s", "重组ms/s"), ("cpu_ms_s", "CPU ms/s"),
]


def summarize(results: list[dict]) -> str:
    lines = []
    labels = sorted({r["label"] for r in results}, key=[r["label"] for r in results].index)
    for scenario in SCENARIOS:
        group = [r for r in results if r["scenario"] == scenario]
        if not group:
            continue
        lines.append(f"\n## {scenario}")
        lines.append("| 构建 | " + " | ".join(h for _, h in COLUMNS) + " |")
        lines.append("|" + " --- |" * (len(COLUMNS) + 1))
        for label in labels:
            runs = [r["metrics"] for r in group if r["label"] == label]
            if not runs:
                continue
            cells = [str(round(statistics.median(m[k] for m in runs), 2)) for k, _ in COLUMNS]
            lines.append(f"| {label} (n={len(runs)}) | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk", action="append", default=[], help="标签=路径，可多个（交替运行）；不给就测已装的包")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--scenario", action="append", choices=list(SCENARIOS), help="默认全部")
    ap.add_argument("--weak", action="store_true", help="测量期间模拟器只用能效核")
    ap.add_argument("--compile", default="verify", choices=["verify", "speed-profile", "speed"])
    ap.add_argument("--settle", type=float, default=8.0, help="冷启动后等首屏就绪的秒数")
    ap.add_argument("--out", type=Path, default=Path("/tmp/atv-perf"))
    ap.add_argument("--min-idle", type=float, default=40, help="宿主机 CPU 空闲低于这个百分比就先等（默认 40）")
    ap.add_argument("--avd", help="设备掉线时用这个模拟器名重新启动（不给就直接退出）")
    ap.add_argument("--reanalyze", type=Path, help="不录，只重新分析这个目录里已有的 trace（<标签>-<场景>-<轮>.pftrace）")
    args = ap.parse_args()
    if args.reanalyze:
        results = []
        for trace in sorted(args.reanalyze.glob("*.pftrace")):
            label, rest = trace.stem.split("-", 1)
            scenario, run = rest.rsplit("-", 1)
            results.append({"label": label, "scenario": scenario, "run": int(run), "metrics": analyze(trace, scenario)})
        print(summarize(results))
        return 0
    args.out.mkdir(parents=True, exist_ok=True)
    apks = [a.split("=", 1) for a in args.apk] or [["installed", ""]]
    scenarios = args.scenario or list(SCENARIOS)
    results: list[dict] = []
    log = args.out / "results.jsonl"
    try:
        for run in range(args.runs):
            for label, apk in apks:
                installed = False
                for scenario in scenarios:
                    for attempt in range(3):
                        try:
                            wait_quiet(args.min_idle)
                            ensure_device(args.avd)
                            if apk and not installed:
                                adb("install", "-r", apk)
                                installed = True
                            launch(args.compile, args.settle)
                            set_weak(args.weak)
                            try:
                                trace = record(f"{label}-{scenario}-{run}", SCENARIOS[scenario], args.out)
                            finally:
                                set_weak(False)
                            break
                        except subprocess.CalledProcessError as e:
                            print(f"[{run}] {label} {scenario}: adb 失败（{e.returncode}），重试", flush=True)
                            installed = False
                    else:
                        raise SystemExit(f"{label} {scenario} 连续失败")
                    metrics = analyze(trace, scenario)
                    entry = {
                        "label": label, "scenario": scenario, "run": run, "weak": args.weak, "compile": args.compile,
                        # 宿主机负载：同一台 Mac 上别的任务忙起来时数字会整体变差，只比较同一时段交替跑出的结果
                        "load1": round(os.getloadavg()[0], 1), "idle": round(cpu_idle()), "metrics": metrics,
                    }
                    results.append(entry)
                    with log.open("a") as f:
                        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    print(f"[{run}] {label} {scenario}: {json.dumps(metrics, ensure_ascii=False)}", flush=True)
    finally:
        set_weak(False)
    table = summarize(results)
    (args.out / "summary.md").write_text(table, encoding="utf-8")
    print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())

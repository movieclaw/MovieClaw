#!/usr/bin/env python3
"""Run the in-app scroll benchmark (MacScrollBench) against a Release build and collect its trace.

    python3 scripts/perf/mac_scroll_bench.py --app apps/apple/build-perf/Build/Products/Release/MovieClaw.app \
        --scenario home --runs 3 --out /tmp/scroll/baseline

The app must already be signed in (it reuses the sandbox container's session). The system cursor is moved
into the window during the run; keep hands off the trackpad until it quits.
"""
import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

CONTAINER = Path.home() / "Library/Containers/io.movieclaw.app/Data/Library/Caches/perf"

# 窗口 1440×900（点），侧边栏约 236 宽：指针放在内容区中部。
# 一次轻扫 1000 点/秒约滚 620 点（手指 0.12 秒 + 惯性 0.5 秒时间常数），首页约 3500 点高，4 下到底
FLING = 1000


def flings(count, dy):
    return [f"fling 0 {dy}"] * count


def vertical(prefix, count):
    """冷（第一次往下，行与图在这时才建）→ 暖（往上、再往下、再往上）→ 慢拖。每段前后记位置核对确实滚了"""
    steps = [f"pos {prefix}.start", f"seg {prefix}.cold.down", *flings(count, FLING), "end", f"pos {prefix}.cold.end", "wait 1"]
    for name, sign in (("warm.up", -1), ("warm.down", 1), ("warm.up2", -1)):
        steps += [f"seg {prefix}.{name}", *flings(count, sign * FLING), "end", f"pos {prefix}.{name}.end", "wait 1"]
    steps += ["top", "wait 1", f"seg {prefix}.drag", "drag 0 500 2.4", "drag 0 -500 2.4", "end", f"pos {prefix}.drag.end", "wait 1"]
    return steps


def horizontal(name, row):
    return [f"hpointer {row}", "wait 0.6", f"pos {name}.start", f"seg {name}",
            "fling 1500 0", "fling 1500 0", "fling -1500 0", "fling -1500 0", "end", f"pos {name}.end", "wait 1"]


def home(args):
    steps = ["size 1440 900", f"wait {args.settle}", "pointer 840 520", "shot home-top"]
    steps += vertical("v", args.flings)
    # 横：往下挪约半屏，「接下来继续」与下面一行海报都整行露出来，指针按视图树找行
    steps += ["top", "wait 1", "pointer 840 300", "drag 0 400 0.8", "wait 1", "shot home-shelf"]
    steps += horizontal("h.upnext", 0)
    steps += horizontal("h.poster", 1)
    return steps + ["quit"]


def library(args):
    steps = ["size 1440 900", f"tab library-{args.library}", f"wait {args.settle}", "pointer 840 520", "shot library-top"]
    steps += vertical("wall", args.flings)
    return steps + ["quit"]


def quick(args):
    """迭代用的精简版：先上下各滑一遍把行建好（不计），再测暖轻扫、慢拖、两种横滑"""
    steps = ["size 1440 900", f"wait {args.settle}", "pointer 840 520", *flings(4, FLING), *flings(4, -FLING), "top", "wait 1"]
    steps += ["seg v.fling", *flings(args.flings, FLING), *flings(args.flings, -FLING), "end", "pos v.fling.end", "wait 1"]
    steps += ["top", "wait 1", "seg v.drag", "drag 0 500 2.4", "drag 0 -500 2.4", "drag 0 500 2.4", "drag 0 -500 2.4", "end", "wait 1"]
    steps += ["top", "wait 1", "pointer 840 300", "drag 0 400 0.8", "wait 1"]
    steps += horizontal("h.upnext", 0)
    steps += horizontal("h.poster", 1)
    return steps + ["quit"]


SCENARIOS = {"home": home, "library": library, "quick": quick}


def run_once(app, script, out, index, timeout, extra=()):
    """Launch through LaunchServices (a bare exec of the binary never opens the window), then wait for it to quit."""
    wait_until_unlocked()
    app = Path(app).resolve()
    binary = str(app / "Contents/MacOS/MovieClaw")
    before = set(pids(binary))
    subprocess.run(["open", "-n", "-F", "-a", str(app), "--args", "-mcPerf", "YES", "-mcPerfBench", script, *extra], check=True)
    pid = None
    for _ in range(100):
        fresh = set(pids(binary)) - before
        if fresh:
            pid = fresh.pop()
            break
        time.sleep(0.1)
    if pid is None:
        raise RuntimeError("app did not start")
    deadline = time.time() + timeout
    while pid in pids(binary):
        if time.time() > deadline:
            subprocess.run(["kill", str(pid)])
            print(f"run {index}: timed out", file=sys.stderr)
            break
        time.sleep(0.5)
    trace = CONTAINER / f"trace-{pid}.jsonl"
    dest = out / f"run{index}-{pid}.jsonl"
    shutil.copy(trace, dest)
    shots = CONTAINER / "shots"
    if shots.exists() and index == 1:
        shutil.copytree(shots, out / "shots", dirs_exist_ok=True)
    return dest


def wait_until_unlocked():
    """The display link stops while the screen is locked; measuring then is meaningless."""
    warned = False
    while True:
        out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, text=True).stdout
        if "CGSSessionScreenIsLocked" not in out:
            return
        if not warned:
            print("screen is locked; waiting for unlock", file=sys.stderr)
            warned = True
        time.sleep(5)


def pids(binary):
    result = subprocess.run(["pgrep", "-f", "-x", f"{binary}.*"], capture_output=True, text=True)
    return [int(p) for p in result.stdout.split()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, action="append",
                        help="path, or label=path[@diag,flags]; repeat to A/B builds (runs are interleaved to cancel machine-load drift)")
    parser.add_argument("--scenario", choices=SCENARIOS, default="home")
    parser.add_argument("--runs", type=int, default=3, help="runs per app")
    parser.add_argument("--flings", type=int, default=4)
    parser.add_argument("--settle", type=float, default=8, help="seconds to let the page load before measuring")
    parser.add_argument("--library", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    apps = [a.split("=", 1) if "=" in a else (Path(a).stem, a) for a in args.app]
    diag = {label: (["-mcDiag", app.split("@", 1)[1]] if "@" in app else []) for label, app in apps}
    apps = [(label, app.split("@", 1)[0]) for label, app in apps]
    out = Path(args.out)
    script = ";".join(SCENARIOS[args.scenario](args))
    traces = {label: [] for label, _ in apps}
    for index in range(1, args.runs + 1):
        for label, app in apps:
            dest = out / label
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "script.txt").write_text(script.replace(";", "\n") + "\n")
            traces[label].append(run_once(app, script, dest, index, args.timeout, diag[label]))
            print(f"{label} run {index}: {traces[label][-1]}", file=sys.stderr)
            time.sleep(2)
    report = Path(__file__).with_name("mac_scroll_report.py")
    base_label = apps[0][0]
    for label, _ in apps:
        print(f"\n== {label}", flush=True) if False else print(f"\n== {label}" + (f"  (parentheses: {base_label})" if label != base_label else ""))
        extra = ["--base", *map(str, traces[base_label])] if label != base_label else []
        subprocess.run([sys.executable, str(report), *map(str, traces[label]), *extra], check=False)


if __name__ == "__main__":
    main()

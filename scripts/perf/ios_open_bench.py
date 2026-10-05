#!/usr/bin/env python3
"""iOS App 页面打开速度的自动化测量（模拟器 + App 内打点）。

口径见 App 里的 ``PerfTrace``（apps/apple/Shared/Core/PerfTrace.swift）：每次页面打开记
起点 t0（冷启动 = 进程创建；切页签 = 选中那一刻）、首帧、数据就绪、视觉完成（首屏图片全部显示）。
这个脚本负责把 App 反复冷启动、按剧本切页签、收回打点文件，再汇总成中位数 / P90。

场景（``--scenario``）：
- ``launch-library`` / ``launch-subscriptions``：冷启动直接落在该页签（``-mcTab``），
  量「打开 App → 页面完整」；
- ``switch``：冷启动落在默认页签（管理员是发现页），第 4 秒切媒体库、第 8 秒切订阅
  （各自第一次打开），第 12 / 16 秒再切回来（热切换）；
- ``switch-early``：同上但第 1.5 秒就切媒体库（落地页的冷启动请求还在路上，量连接池拥挤）。

客户端缓存（``--client-cache``）：
- ``warm``（默认）：保留 App 的图片与数据缓存，模拟老用户每天打开；
- ``cold``：每轮启动前清空 App 的 Caches 与页面缓存，模拟刚安装 / 缓存被系统清掉。

用法::

    # 编译带打点、开优化的包（Debug 配置 + -O，调试启动参数仍可用）
    python scripts/perf/ios_open_bench.py build --label base
    # 首次登录（之后的轮次不带账号参数，走正式的冷启动恢复路径）
    python scripts/perf/ios_open_bench.py login --label base --server http://127.0.0.1:18601
    # 跑 5 轮
    python scripts/perf/ios_open_bench.py run --label base --scenario switch --runs 5
    # 汇总（可以同时给多个标签对比）
    python scripts/perf/ios_open_bench.py report base opt
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPLE = ROOT / "apps" / "apple"
LAB = Path(os.environ.get("MC_PERF_BENCH", Path.home() / "workspace" / ".mc-perf-bench"))
RESULTS = LAB / "results"
BUNDLE = "io.movieclaw.app"
DEVICE = os.environ.get("MC_PERF_SIM", "MC-Perf")

SCENARIOS = {
    "launch-library": {"args": ["-mcTab", "library"], "duration": 12},
    "launch-subscriptions": {"args": ["-mcTab", "subscriptions"], "duration": 12},
    "switch": {
        "args": ["-mcPerfScript", "library@4,subscriptions@8,library@12,subscriptions@16"],
        "duration": 20,
    },
    # 发现页：冷启动落在发现页（管理员默认落点），第 4 秒切到剧集视角（第一次），
    # 第 7 秒切媒体库、第 10 秒切回发现（热切换）
    "discover": {
        "args": ["-mcPerfScript", "/discover/tv@4,library@7,discover@10"],
        "duration": 13,
    },
    # 从别的页签第一次切到发现页：冷启动落在媒体库，第 4 秒切发现
    "switch-discover": {
        "args": ["-mcTab", "library", "-mcPerfScript", "discover@4,library@7,discover@10"],
        "duration": 13,
    },
    "switch-early": {
        "args": ["-mcPerfScript", "library@1.5,subscriptions@5,library@9,subscriptions@12"],
        "duration": 16,
    },
}


def sh(*args: str, check: bool = True, capture: bool = True) -> str:
    result = subprocess.run(args, check=check, text=True, capture_output=capture)
    return (result.stdout or "").strip()


def simctl(*args: str, check: bool = True) -> str:
    return sh("xcrun", "simctl", *args, check=check)


def app_path(label: str) -> Path:
    return LAB / "builds" / label / "MovieClaw.app"


def data_dir() -> Path:
    return Path(simctl("get_app_container", DEVICE, BUNDLE, "data"))


def boot() -> None:
    simctl("boot", DEVICE, check=False)
    simctl("bootstatus", DEVICE, "-b")


# ---------------------------------------------------------------------------
# 编译与安装
# ---------------------------------------------------------------------------


def cmd_build(ns: argparse.Namespace) -> None:
    """Debug 配置（保留调试启动参数与打点）+ 编译器全优化，产物拷到实验目录按标签存档。"""
    derived = APPLE / "build-opt"
    subprocess.run(["xcodegen", "generate"], cwd=APPLE, check=True, capture_output=True)
    udid = simctl("list", "devices").split(f"{DEVICE} (")[1].split(")")[0]
    command = [
        "xcodebuild",
        "-project",
        "MovieClaw.xcodeproj",
        "-scheme",
        "MovieClaw",
        "-configuration",
        "Debug",
        "-destination",
        f"platform=iOS Simulator,id={udid}",
        "-derivedDataPath",
        str(derived),
        "-clonedSourcePackagesDirPath",
        str(Path.home() / "workspace" / ".mc-ios-spm"),
        "-packageAuthorizationProvider",
        "netrc",
        "SWIFT_OPTIMIZATION_LEVEL=-O",
        "SWIFT_COMPILATION_MODE=wholemodule",
        "GCC_OPTIMIZATION_LEVEL=s",
        "ENABLE_TESTABILITY=NO",
        "build",
    ]
    result = subprocess.run(command, cwd=APPLE, text=True, capture_output=True)
    if "BUILD SUCCEEDED" not in result.stdout:
        errors = [line for line in result.stdout.splitlines() if "error:" in line]
        sys.exit("编译失败：\n" + "\n".join(sorted(set(errors))[:30]))
    target = app_path(ns.label)
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        derived / "Build/Products/Debug-iphonesimulator/MovieClaw.app", target, symlinks=True
    )
    print(f"已编译：{target}")


def install(label: str) -> None:
    boot()
    simctl("terminate", DEVICE, BUNDLE, check=False)
    simctl("install", DEVICE, str(app_path(label)))


# ---------------------------------------------------------------------------
# 单轮运行
# ---------------------------------------------------------------------------


def clear_traces() -> None:
    perf = data_dir() / "Library" / "Caches" / "perf"
    if perf.exists():
        shutil.rmtree(perf)


def clear_client_caches() -> None:
    """清空 App 的缓存（图片、URLCache、页面缓存），保留登录（UserDefaults 与钥匙串）。"""
    data = data_dir()
    caches = data / "Library" / "Caches"
    if caches.exists():
        for child in caches.iterdir():
            shutil.rmtree(child) if child.is_dir() else child.unlink()
    support = data / "Library" / "Application Support" / "PageCache"
    if support.exists():
        shutil.rmtree(support)


def launch(extra: list[str]) -> int:
    out = simctl("launch", DEVICE, BUNDLE, "-mcPerf", "YES", *extra)
    return int(out.rsplit(":", 1)[1].strip())


def collect(pid: int) -> list[dict]:
    path = data_dir() / "Library" / "Caches" / "perf" / f"trace-{pid}.jsonl"
    if not path.exists():
        return []
    events = []
    for line in path.read_text().splitlines():
        with contextlib.suppress(json.JSONDecodeError):
            events.append(json.loads(line))
    return events


def cmd_login(ns: argparse.Namespace) -> None:
    """装包并用调试参数登录一次；之后的轮次不带账号参数，走正式的冷启动恢复路径。"""
    install(ns.label)
    launch(["-mcServer", ns.server, "-mcUser", ns.user, "-mcPass", ns.password])
    time.sleep(8)
    simctl("terminate", DEVICE, BUNDLE, check=False)
    print("已登录并记住服务器")


def cmd_run(ns: argparse.Namespace) -> None:
    scenario = SCENARIOS[ns.scenario]
    if not ns.no_install:
        install(ns.label)
    out_dir = RESULTS / ns.label
    out_dir.mkdir(parents=True, exist_ok=True)
    tag = f"{ns.scenario}.{ns.client_cache}{('.' + ns.tag) if ns.tag else ''}"
    # 同一标签多次运行（A/B 交替）时接着编号，不覆盖上一批
    first = len(list(out_dir.glob(f"{tag}.*.jsonl")))
    for index in range(ns.warmup + ns.runs):
        simctl("terminate", DEVICE, BUNDLE, check=False)
        time.sleep(1.0)
        clear_traces()
        if ns.client_cache == "cold":
            clear_client_caches()
        video = None
        if ns.video and index >= ns.warmup:
            video_path = out_dir / f"{tag}.{first + index - ns.warmup}.mp4"
            video = subprocess.Popen(
                [
                    "xcrun",
                    "simctl",
                    "io",
                    DEVICE,
                    "recordVideo",
                    "--codec=h264",
                    "--force",
                    str(video_path),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            time.sleep(1.0)
        pid = launch(scenario["args"] + ns.extra)
        time.sleep(scenario["duration"])
        if video:
            video.send_signal(2)
            video.wait(timeout=15)
        events = collect(pid)
        simctl("terminate", DEVICE, BUNDLE, check=False)
        if index < ns.warmup:
            print(f"  预热轮 {index + 1}：{len(events)} 条事件（不计入）")
            continue
        run = first + index - ns.warmup
        (out_dir / f"{tag}.{run}.jsonl").write_text(
            "\n".join(json.dumps(e, ensure_ascii=False) for e in events)
        )
        summary = [
            f"{o['page']}/{o['trigger']}: {fmt(o.get('visualComplete'))}"
            for o in page_opens(events)
        ]
        print(f"  第 {run + 1} 轮：" + "；".join(summary))


# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------


def fmt(value: float | None) -> str:
    return "—" if value is None else f"{value:.0f}"


def page_opens(events: list[dict]) -> list[dict]:
    """把事件流按页面打开归组，时间换成距 t0 的毫秒"""
    opens: dict[int, dict] = {}
    # 冷启动的起点另记一份「从 main 算」：模拟器上 main 之前的 dyld 加载要 1.5~3 秒，
    # 绝大部分是模拟器运行时自己的系统库（真机在共享缓存里），不能代表真机
    app_init = next((e["t"] for e in events if e["ev"] == "app.init"), 0.0)
    for event in events:
        if "open" not in event:
            continue
        t0 = app_init if event["trigger"] == "launch" else event["t0"]
        open_ = opens.setdefault(
            event["open"],
            {"page": event["page"], "trigger": event["trigger"], "t0": t0, "stages": []},
        )
        rel = event["t"] - t0
        kind = event["ev"]
        if kind == "page.firstFrame":
            open_["firstFrame"] = rel
        elif kind == "page.dataReady":
            open_["dataReady"] = rel
        elif kind == "page.visualComplete":
            open_["visualComplete"] = rel
            open_["images"] = event.get("images", 0)
            open_["sources"] = {k[4:]: v for k, v in event.items() if k.startswith("img_")}
        elif kind == "page.stage":
            open_["stages"].append((event["stage"], rel))
        elif kind == "page.timeout":
            open_["timeout"] = event
    return [o for o in opens.values() if o["page"] in ("library", "subscriptions", "discover")]


def net_for(events: list[dict], open_: dict, until: float | None) -> list[dict]:
    """这次打开窗口内完成的接口请求（不含图片）"""
    t0 = open_["t0"]
    end = t0 + (until if until is not None else 20000)
    return [
        e
        for e in events
        if e["ev"] == "net" and e.get("session") in ("api", "live") and t0 <= e["t"] <= end + 1
    ]


def pct(values: list[float], q: float) -> float:
    values = sorted(values)
    if not values:
        return float("nan")
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def stat(opens: list[dict], name: str) -> str:
    """一个指标的「中位数 (P90)」"""
    values = [o[name] for o in opens if o.get(name) is not None]
    if not values:
        return "—"
    return f"{statistics.median(values):>6.0f} ({pct(values, 0.9):.0f})"


def cmd_report(ns: argparse.Namespace) -> None:
    for label in ns.labels:
        out_dir = RESULTS / label
        groups: dict[tuple[str, str, str, str], list[dict]] = {}
        for path in sorted(out_dir.glob("*.jsonl")):
            tag = path.name.rsplit(".", 2)[0]
            events = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
            seen: dict[tuple[str, str], int] = {}
            for open_ in page_opens(events):
                key = (open_["page"], open_["trigger"])
                seen[key] = seen.get(key, 0) + 1
                nth = "首次" if seen[key] == 1 else "再次"
                reqs = net_for(events, open_, open_.get("dataReady"))
                open_["requests"] = len(reqs)
                open_["maxQueue"] = max((r.get("queue", 0) for r in reqs), default=0)
                decodes = [
                    e
                    for e in events
                    if e["ev"] == "decode"
                    and open_["t0"] <= e["t"] <= open_["t0"] + (open_.get("dataReady") or 20000)
                ]
                open_["decodeMain"] = sum(e["ms"] for e in decodes if e.get("main"))
                groups.setdefault((tag, open_["page"], open_["trigger"], nth), []).append(open_)
        print(f"\n## {label}")
        header = [
            f"{'场景':<34}{'页面':<14}{'触发':<8}{'次':<4}{'n':>3}",
            f"{'首帧':>13} {'数据就绪':>15} {'视觉完成':>15} {'图片(内/盘/网)':>16}",
            f"{'请求':>5} {'最长排队':>8} {'主线程解码':>9}",
        ]
        print(" ".join(header))
        for (tag, page, trigger, nth), opens in sorted(groups.items()):
            images = [o.get("sources", {}) for o in opens]
            src = "/".join(
                f"{statistics.median([s.get(k, 0) for s in images]):.0f}"
                for k in ("memory", "disk", "network")
            )
            timeouts = sum(1 for o in opens if "timeout" in o)
            requests = statistics.median([o["requests"] for o in opens])
            max_queue = statistics.median([o["maxQueue"] for o in opens])
            decode_main = statistics.median([o["decodeMain"] for o in opens])
            cells = [
                f"{tag:<34}{page:<14}{trigger:<8}{nth:<4}{len(opens):>3}",
                f"{stat(opens, 'firstFrame'):>13} {stat(opens, 'dataReady'):>15}",
                f"{stat(opens, 'visualComplete'):>15} {src:>16}",
                f"{requests:>5.0f} {max_queue:>8.0f} {decode_main:>9.1f}",
            ]
            print(" ".join(cells) + (f"  超时 {timeouts}" if timeouts else ""))
        print("（单位 ms；切页签从选中那一刻算，冷启动从 main 算；格式：中位数 (P90)）")


def cmd_timeline(ns: argparse.Namespace) -> None:
    """打印一轮的时间线（距 main 的毫秒）：页面阶段、接口请求（排队 / TTFB / 下载）、解码"""
    path = Path(ns.file)
    events = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    app_init = next((e["t"] for e in events if e["ev"] == "app.init"), 0.0)
    for event in sorted(events, key=lambda e: e.get("start", e["t"])):
        t = event["t"] - app_init
        kind = event["ev"]
        if kind == "net":
            if not ns.images and event.get("session") not in ("api", "live"):
                continue
            start = event.get("start", event["t"]) - app_init
            reused = " 复用" if event.get("reused") else " 新连接"
            label = f"net[{event.get('session')}] {event.get('path', '')[:90]}"
            print(
                f"{start:8.0f} → {t:8.0f}  {label}  "
                f"排队 {event.get('queue', 0):.0f} TTFB {event.get('ttfb', 0):.0f} "
                f"下载 {event.get('download', 0):.0f} {event.get('bytes', 0) / 1024:.0f}KB{reused}"
            )
        elif kind == "decode":
            main = " 主线程" if event.get("main") else ""
            size = event["bytes"] / 1024
            label = f"decode {event['path'][:60]}"
            print(f"{t:8.0f}            {label} {size:.0f}KB {event['ms']:.1f}ms{main}")
        else:
            extra = {k: v for k, v in event.items() if k not in ("t", "ev", "open", "t0")}
            print(f"{t:8.0f}            {kind} {json.dumps(extra, ensure_ascii=False)}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    build = sub.add_parser("build")
    build.add_argument("--label", required=True)
    login = sub.add_parser("login")
    login.add_argument("--label", required=True)
    login.add_argument("--server", default="http://127.0.0.1:18601")
    login.add_argument("--user", default="admin")
    login.add_argument("--password", default="perf-lab-2026")
    run = sub.add_parser("run")
    run.add_argument("--label", required=True)
    run.add_argument("--scenario", choices=sorted(SCENARIOS), required=True)
    run.add_argument("--runs", type=int, default=5)
    run.add_argument("--warmup", type=int, default=1)
    run.add_argument("--client-cache", choices=["warm", "cold"], default="warm")
    run.add_argument("--tag", default="")
    run.add_argument("--video", action="store_true")
    run.add_argument("--no-install", action="store_true")
    run.add_argument("extra", nargs="*", help="额外启动参数（放在 -- 之后）")
    report = sub.add_parser("report")
    report.add_argument("labels", nargs="+")
    timeline = sub.add_parser("timeline")
    timeline.add_argument("file")
    timeline.add_argument("--images", action="store_true", help="连图片请求一起列出")
    ns = parser.parse_args()
    {
        "build": cmd_build,
        "login": cmd_login,
        "run": cmd_run,
        "report": cmd_report,
        "timeline": cmd_timeline,
    }[ns.cmd](ns)


if __name__ == "__main__":
    main()

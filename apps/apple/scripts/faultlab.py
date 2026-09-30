#!/usr/bin/env python3
"""播放器故障注入实验台：本机取流代理 + 模拟器里的 App + 按日志信号注入故障 + 自动判定。

为什么要它（docs/design/player-engine.md §3.7）：自研引擎要「力保不降级」——断网、
服务端出错、存储写满、引擎楞住，都不该换成服务端流。这些现场靠手工很难复现，
这里把它们变成可重复跑的场景，改播放链路后逐个回归。

怎么工作：App 以调试开关 -mcStreamProxy http://127.0.0.1:<端口> 启动后，取原文件字节
的请求（原文件、光盘镜像、原盘目录里的文件）经本脚本的代理转发到服务器，开会话等
接口照常直连——故障只作用在取流上。代理按场景的时间表拒连、回错误码、挂起、限速、
中途掐断；存储与画面卡住另有调试开关（-mcFakeFreeBytes、-mcStorageFullAfter、
-mcFakeStallAfter）。App 统一带 -mcNoServerFallback：真要换服务端流时停在错误页并打
[EngineFallback]，既不起转码，也方便判定。

用法（App 先用 scripts/build.sh 编好、装进模拟器并登录好服务器）：
    MC_SERVER=http://192.168.1.10:3000 MC_FAULT_MKV='/play/123/s01e01?t=60' \\
        scripts/faultlab.py open-refuse mid-cut
    scripts/faultlab.py --list        列出场景；scripts/faultlab.py all  全部跑一遍
环境变量：
    MC_SIM         模拟器名或 UDID（默认 iPhone 17）
    MC_SERVER      App 登录的服务器，代理转发到这里（默认 http://localhost:3000）
    MC_FAULT_MKV   普通文件的播放路由（MKV / MP4，要带 ?t= 固定起播点）
    MC_FAULT_DISC  原盘目录的播放路由；MC_FAULT_ISO 光盘镜像的播放路由（不给就跳过）
    MC_FAULT_PORT  代理端口（默认 3902）
    MC_FAULT_OUT   日志目录（默认系统临时目录下的 mc-faultlab）
"""

import asyncio
import contextlib
import os
import re
import sys
import tempfile
import time
from urllib.parse import urlparse

SIM = os.environ.get("MC_SIM", "iPhone 17")
_server = urlparse(os.environ.get("MC_SERVER", "http://localhost:3000"))
UPSTREAM = (_server.hostname or "localhost", _server.port or 80)
LISTEN = ("127.0.0.1", int(os.environ.get("MC_FAULT_PORT", "3902")))
OUT = os.environ.get("MC_FAULT_OUT", os.path.join(tempfile.gettempdir(), "mc-faultlab"))
ROUTES = {
    "mkv": os.environ.get("MC_FAULT_MKV"),
    "disc": os.environ.get("MC_FAULT_DISC"),
    "iso": os.environ.get("MC_FAULT_ISO"),
}
APP_ID = "io.movieclaw.app"
SKIP_HEADERS = ("connection:", "host:", "keep-alive:", "proxy-connection:")


class FaultState:
    """当前生效的故障：只作用在新来的取流请求上（cut / stall 作用在正在传的连接上）。

    mode：pass / refuse（接了就断）/ status（回错误码 arg）/ hang（收了请求 arg 秒不回）/
    reset（发够 arg 字节后强断）/ truncate（发够 arg 字节后正常关，短于声明长度）/
    throttle（每条连接各限速 arg 字节每秒）/ link（所有连接共享 arg 字节每秒，模拟一条慢线路）
    """

    def __init__(self):
        self.mode, self.arg, self.until, self.count, self.arm_secs = "pass", None, None, None, None
        self.stall_until = 0.0
        self.cut_gen = 0
        self.link_free_at = 0.0

    async def pace_link(self, size, bps):
        """共享线路：这块字节排在所有连接已占用的时间之后发出"""
        now = time.monotonic()
        self.link_free_at = max(now, self.link_free_at) + size / bps
        await asyncio.sleep(self.link_free_at - now)

    def set(self, mode, arg=None, secs=None, count=None, armed=False):
        """armed=True：时长从下一个取流请求到达时才开始算（引擎何时开始取流不固定）"""
        self.mode, self.arg, self.count = mode, arg, count
        self.arm_secs = secs if armed else None
        self.until = time.monotonic() + secs if (secs and not armed) else None

    def pick(self):
        if self.mode == "pass":
            return "pass", None
        if self.arm_secs:
            self.until, self.arm_secs = time.monotonic() + self.arm_secs, None
        if self.until and time.monotonic() > self.until:
            self.mode = "pass"
            return "pass", None
        if self.count is not None:
            if self.count <= 0:
                self.mode = "pass"
                return "pass", None
            self.count -= 1
        return self.mode, self.arg


class Run:
    """一个场景的现场：代理日志文件与计时起点"""

    def __init__(self, proxy_log):
        self.proxy_log = proxy_log
        self.started = time.monotonic()

    def log(self, message):
        self.proxy_log.write(f"{time.monotonic() - self.started:8.2f} {message}\n")
        self.proxy_log.flush()


state = FaultState()
current: Run | None = None


async def handle(reader, writer):
    try:
        await serve(reader, writer)
    except Exception as exc:  # noqa: BLE001 — 客户端取消请求时常见，只记日志
        current.log(f"proxy error {type(exc).__name__}: {exc}")
    finally:
        with contextlib.suppress(Exception):
            writer.close()


async def serve(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        return
    lines = head.decode("latin1").split("\r\n")
    method, path, _ = lines[0].split(" ", 2)
    headers = [line for line in lines[1:] if line]
    rng = next((h.split(":", 1)[1].strip() for h in headers if h.lower().startswith("range:")), "-")
    mode, arg = state.pick()
    short = re.sub(r"token=[^&]+", "token=…", path)[:90]
    current.log(f"{method} {short} range={rng} fault={mode}{'' if arg is None else ':' + str(arg)}")
    if mode == "refuse":
        writer.transport.abort()
        return
    if mode == "status":
        reply = f"HTTP/1.1 {arg} Fault\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        writer.write(reply.encode())
        await writer.drain()
        return
    if mode == "hang":
        await asyncio.sleep(arg or 3600)
        writer.transport.abort()
        return
    await forward(writer, method, path, headers, mode, arg, short)


async def forward(writer, method, path, headers, mode, arg, short):
    """转发到服务器。每个请求单独连上游，回给 App 也声明 Connection: close，免去 keep-alive 分帧"""
    up_r, up_w = await asyncio.open_connection(*UPSTREAM)
    keep = [h for h in headers if not h.lower().startswith(SKIP_HEADERS)]
    request = f"{method} {path} HTTP/1.1\r\nHost: {UPSTREAM[0]}:{UPSTREAM[1]}\r\n"
    request += "".join(h + "\r\n" for h in keep) + "Connection: close\r\n\r\n"
    up_w.write(request.encode("latin1"))
    await up_w.drain()
    rlines = (await up_r.readuntil(b"\r\n\r\n")).decode("latin1").split("\r\n")
    rkeep = [h for h in rlines[1:] if h and not h.lower().startswith(SKIP_HEADERS)]
    response = rlines[0] + "\r\n" + "".join(h + "\r\n" for h in rkeep) + "Connection: close\r\n\r\n"
    writer.write(response.encode("latin1"))
    sent, gen = 0, state.cut_gen
    limit = arg if mode in ("reset", "truncate") else None
    bps = arg if mode == "throttle" else None
    link_bps = arg if mode == "link" else None
    try:
        while True:
            while time.monotonic() < state.stall_until and gen == state.cut_gen:
                await asyncio.sleep(0.2)
            if gen != state.cut_gen:
                current.log(f"  cut in-flight after {sent} bytes: {short[:60]}")
                writer.transport.abort()
                return
            chunk = await up_r.read(65536)
            if not chunk:
                break
            if limit is not None and sent + len(chunk) >= limit:
                writer.write(chunk[: limit - sent])
                await writer.drain()
                current.log(f"  {mode} after {limit} bytes")
                if mode == "reset":
                    writer.transport.abort()
                return
            writer.write(chunk)
            await writer.drain()
            sent += len(chunk)
            if bps:
                await asyncio.sleep(len(chunk) / bps)
            if link_bps:
                await state.pace_link(len(chunk), link_bps)
    finally:
        up_w.close()


# ---- 场景 ----------------------------------------------------------------------------------
# 触发：("start",) 一开始；("t", 秒) 播放头走过起播点这么多秒（[FrameStats] 的 t）；
#       ("after", 秒) 距上一步
# 动作：("set", mode, arg, 秒数, 请求次数[, "armed"]) / ("cut",) 掐断在途连接 /
#       ("stall", 秒) 在途连接不再给字节
# 预期：play = 到最后都在播、没换播放器；error = 落错误页、没换播放器；
#       fallback = 最后改走服务端流（真解决不了时的兜底）
def armed(mode, arg, secs):
    return (("start",), ("set", mode, arg, secs, None, "armed"))


def cut_then(mode, arg, secs, at=15):
    return [(("t", at), ("cut",)), (("after", 0), ("set", mode, arg, secs, None))]


def scenario(route, secs, expect, steps=(), tmp=False, extra=()):
    return {"route": route, "secs": secs, "expect": expect, "steps": list(steps), "tmp": tmp,
            "extra": list(extra)}


GIB, MIB = 1 << 30, 1 << 20
SCENARIOS = {
    # 起播：开会话成功、取字节出问题
    "open-refuse": scenario("mkv", 45, "play", [armed("refuse", None, 6)]),
    "open-503": scenario("mkv", 45, "play", [armed("status", 503, 6)]),
    "open-401": scenario("mkv", 40, "play", [(("start",), ("set", "status", 401, None, 1))]),
    "open-404": scenario("mkv", 35, "error", [(("start",), ("set", "status", 404, None, None))]),
    "open-429": scenario("mkv", 45, "play", [armed("status", 429, 6)]),
    "open-hang": scenario("mkv", 70, "play", [armed("hang", 40, 25)]),
    "open-truncate": scenario("mkv", 45, "play",
                              [(("start",), ("set", "truncate", 300_000, None, 3))]),
    # 播放中
    "mid-cut": scenario("mkv", 90, "play", cut_then("refuse", None, 20)),
    "mid-stall": scenario("mkv", 100, "play", [(("t", 15), ("stall", 30))]),
    "mid-reset": scenario("mkv", 90, "play", [(("t", 15), ("set", "reset", 200_000, 30, None)),
                                              (("after", 0), ("cut",))]),
    "mid-503-long": scenario("mkv", 170, "play", cut_then("status", 503, 90)),
    "mid-throttle": scenario("mkv", 120, "play",
                             [(("t", 10), ("set", "throttle", 600_000, 60, None)),
                              (("after", 0), ("cut",))]),
    # 断网很久：缓冲吃光后等片源回来（约 1 分钟内回来就接着放）；一直不回来落错误页。都不换播放器。
    # 默认缓冲能撑一两分钟，这里假装存储快满、把分片窗口压到最小，断网很快就吃光缓冲
    "mid-refuse-long": scenario("mkv", 160, "play", cut_then("refuse", None, 60),
                                extra=["-mcFakeFreeBytes", str(300 * MIB)]),
    "mid-refuse-forever": scenario("mkv", 170, "error", cut_then("refuse", None, 900),
                                   extra=["-mcFakeFreeBytes", str(300 * MIB)]),
    # 存储：假装只剩这么多空间（App 的落盘计划与引擎的预算都按它算），记录临时目录占用峰值
    "storage-normal": scenario("disc", 90, "play", tmp=True),
    "storage-uhd-1g": scenario("disc", 90, "play", tmp=True, extra=["-mcFakeFreeBytes", str(GIB)]),
    "storage-300m": scenario("mkv", 70, "play", tmp=True,
                             extra=["-mcFakeFreeBytes", str(300 * MIB)]),
    # 播放中写满：短暂写满（收小缓冲重开后就好）与一直写满（重开后又满，最后改走服务端流）
    # 要走主力通路（换封装写分片）的片源：模拟器上普通 MKV 多走软件通路、不写分片，用原盘
    "storage-full-brief": scenario("disc", 100, "play", extra=["-mcStorageFullAfter", "25,4"]),
    "storage-full-long": scenario("disc", 130, "fallback", extra=["-mcStorageFullAfter", "25,100"]),
    # 画面卡住（看门狗判解码卡死）：一时卡住（原位重开一次就好）与反复卡住（才改走服务端流）
    "stall-brief": scenario("mkv", 80, "play", extra=["-mcFakeStallAfter", "20,20"]),
    "stall-long": scenario("mkv", 110, "fallback", extra=["-mcFakeStallAfter", "20,70"]),
    # 光盘：原盘目录与光盘镜像走各自的读取器
    "disc-open-refuse": scenario("disc", 60, "play", [armed("refuse", None, 8)]),
    "disc-mid-cut": scenario("disc", 100, "play", cut_then("refuse", None, 20)),
    "iso-open-refuse": scenario("iso", 50, "play", [armed("refuse", None, 6)]),
    "iso-mid-cut": scenario("iso", 80, "play", cut_then("refuse", None, 20)),
    # 限画质（会让服务端起转码）：切 720p 后服务端流由自研引擎直连放，再切回自动回到直出原文件
    "quality-switch": scenario("mkv", 80, "play", extra=["-mcAutoQuality", "15:720,50:0"]),
    # 慢线路（外网放 4K 原片）：取流总共只有 6 Mbit/s，等首帧满 8 秒应弹换低画质提议
    # （[QualityOffer]），
    # 弹出即接受后改走服务端转码接着放。MC_FAULT_MKV 要选码率明显高于 6 Mbit/s 的片、从头播
    # 每轮先清片源缓存：冷启动时起播取数是一段一段的（索引、文件头分头取），最考验速度读数
    "slow-link": scenario("mkv", 75, "play", [(("start",), ("set", "link", 750_000, None, None))],
                          extra=["-mcAcceptQualityOffer", "YES", "-mcPurgeByteCache", "YES"]),
    # 慢线路下远跳：先按正常线路起播，播到第 15 秒线路掉到 6 Mbit/s，
    # 打开播放器 25 秒时往后跳 15 分钟，
    # 等落点满 8 秒应弹提议
    "slow-seek": scenario("mkv", 80, "play", [(("t", 15), ("set", "link", 750_000, None, None))],
                          extra=["-mcAcceptQualityOffer", "YES", "-mcPurgeByteCache", "YES",
                                 "-mcAutoSeek", "25:+900"]),
    "baseline": scenario("mkv", 35, "play"),
}


def route_start(route):
    match = re.search(r"[?&]t=(\d+)", ROUTES.get(route) or "")
    return int(match.group(1)) if match else 0


async def quiet(*command):
    proc = await asyncio.create_subprocess_exec(
        *command, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    await proc.wait()


async def run(name):
    global current
    spec = SCENARIOS[name]
    route = ROUTES.get(spec["route"])
    if not route:
        return f"## {name}：跳过（没给 MC_FAULT_{spec['route'].upper()}）", True
    # 上一轮的 App 进程要先退干净，否则这次可能起不来
    await quiet("xcrun", "simctl", "terminate", SIM, APP_ID)
    await asyncio.sleep(2)
    # 场景都按默认画质设计：清掉按片记住的画质
    # （slow-link 接受提议、quality-switch 中途失败都会留下）
    await quiet("xcrun", "simctl", "spawn", SIM, "defaults", "delete",
                (await app_tmp())[:-len("/tmp")] + f"/Library/Preferences/{APP_ID}",
                "movieclaw.player.quality-by-title")
    if spec["tmp"]:
        # 量占用前清掉上一轮留下的缓存（分片、片源字节缓存都只是缓存），否则峰值里混着别的场景的
        await clear_caches()
    state.__init__()
    os.makedirs(OUT, exist_ok=True)
    with open(f"{OUT}/{name}.proxy.log", "w") as proxy_log, \
            open(f"{OUT}/{name}.log", "w") as app_log:
        current = Run(proxy_log)
        fired = await drive(name, spec, route, app_log)
    return summarize(name, spec["expect"], fired)


async def drive(name, spec, route, app_log):
    """起 App、按时间表注入故障，直到场景时长用完。

    播放打上实验室标签（-mcLab faultlab:<场景>，统计默认排除），结束前几秒自动退出播放器，
    播放记录照常收尾上报，再结束 App——直接杀掉会留下「正在播放」标记，
    下次启动被补报成异常退出（docs/design/playback-qoe.md §2）"""
    server = await asyncio.start_server(handle, *LISTEN)
    args = ["-mcAetherLog", "YES", "-mcNoProgress", "YES", "-mcNoServerFallback", "YES",
            "-mcFrameStatsEverySecond", "YES", "-mcStreamProxy", f"http://{LISTEN[0]}:{LISTEN[1]}",
            "-mcRoute", route, "-mcRouteDelay", "2", "-mcLab", f"faultlab:{name}",
            "-mcAutoCloseAfter", str(max(10, spec["secs"] - 12)), *spec["extra"]]
    proc = await asyncio.create_subprocess_exec(
        "xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process",
        SIM, APP_ID, *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    start_t = route_start(spec["route"])
    steps = [(("t", start_t + trig[1]) if trig[0] == "t" else trig, act)
             for trig, act in spec["steps"]]
    fired, last_fire = [], time.monotonic()

    def fire(action):
        nonlocal last_fire
        last_fire = time.monotonic()
        fired.append((round(last_fire - current.started, 1), action))
        current.log(f"== ACTION {action}")
        app_log.write(f"[FaultLab {last_fire - current.started:.1f}] {action}\n")
        if action[0] == "set":
            _, mode, arg, secs, count = action[:5]
            state.set(mode, arg, secs, count, armed=len(action) > 5 and action[5] == "armed")
        elif action[0] == "cut":
            state.cut_gen += 1
        elif action[0] == "stall":
            state.stall_until = time.monotonic() + action[1]

    while steps and steps[0][0][0] == "start":
        fire(steps.pop(0)[1])
    peak = {"segments": 0, "bytecache": 0}
    sampler = asyncio.create_task(sample_tmp(peak)) if spec["tmp"] else None
    deadline = time.monotonic() + spec["secs"]
    while time.monotonic() < deadline:
        while steps and steps[0][0][0] == "after" \
                and time.monotonic() - last_fire >= steps[0][0][1]:
            fire(steps.pop(0)[1])
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), 0.5)
        except TimeoutError:
            continue
        if not line:
            break
        text = line.decode("utf-8", "replace")
        app_log.write(text)
        if steps and steps[0][0][0] == "t":
            match = re.search(r"\[FrameStats\] \w+ t=(\d+)", text)
            if match and int(match.group(1)) >= steps[0][0][1]:
                fire(steps.pop(0)[1])
    if sampler:
        sampler.cancel()
        app_log.write(f"[FaultLab] 临时目录峰值 分片 {peak['segments'] >> 10} MB"
                      f" 片源缓存 {peak['bytecache'] >> 10} MB\n")
    # 播放器已自动退出：给播放记录的上报留几秒
    await asyncio.sleep(3)
    await quiet("xcrun", "simctl", "terminate", SIM, APP_ID)
    with contextlib.suppress(ProcessLookupError):
        proc.kill()
    server.close()
    return fired


async def app_tmp():
    proc = await asyncio.create_subprocess_exec(
        "xcrun", "simctl", "get_app_container", SIM, APP_ID, "data", stdout=asyncio.subprocess.PIPE)
    return (await proc.stdout.read()).decode().strip() + "/tmp"


async def clear_caches():
    base = await app_tmp()
    for sub in ("aether-segments", "aether-bytecache"):
        await quiet("rm", "-rf", f"{base}/{sub}")


async def sample_tmp(peak):
    """每 2 秒量一次 App 临时目录里分片缓存与片源字节缓存的实际占用（du 计真实块数，KB）"""
    base = await app_tmp()
    while True:
        for key, sub in (("segments", "aether-segments"), ("bytecache", "aether-bytecache")):
            du = await asyncio.create_subprocess_exec(
                "du", "-sk", f"{base}/{sub}", stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL)
            out = (await du.stdout.read()).decode().split()
            if out:
                peak[key] = max(peak[key], int(out[0]))
        await asyncio.sleep(2)


def outcome_of(lines):
    """play：最后一次失败之后还有连续前进的帧统计；否则按有没有降级 / 错误页判"""
    text = "\n".join(lines)
    if not lines:
        return "没启动"
    if "[EngineFallback]" in text:
        return "fallback"
    if "[PlayerError]" in text:
        return "error"
    frames = [(i, int(m.group(1))) for i, line in enumerate(lines)
              for m in [re.search(r"\[FrameStats\] \w+ t=(\d+)", line)] if m]
    failures = [i for i, line in enumerate(lines) if "[EngineFailed]" in line]
    tail = [t for i, t in frames if i > max(failures, default=-1)][-4:]
    advancing = len(tail) >= 3 and all(b > a for a, b in zip(tail, tail[1:], strict=False))
    return "play" if advancing else "没在播"


def summarize(name, expect, fired):
    with open(f"{OUT}/{name}.log", encoding="utf-8", errors="replace") as f:
        text = f.read()
    lines = text.splitlines()
    outcome = outcome_of(lines)
    labels = {"play": "在播", "error": "错误页", "fallback": "改走服务端流"}
    passed = outcome == expect
    heads = re.findall(r"\[FrameStats\] \w+ t=(\d+)", text)
    out = [f"## {name}：{'通过' if passed else '不通过'}"
           f"（预期{labels[expect]}，实际{labels.get(outcome, outcome)}）"
           f"  播放头 {heads[0] if heads else '-'} → {heads[-1] if heads else '-'}  动作 {fired}"]
    out += [f"  起播 {s[:140]}" for s in re.findall(r"\[StartupTrace\] (.*)", text)[:3]]
    notes = [g for groups in re.findall(r"\[StoragePlan\] (.*)|\[FaultLab\] (临时目录.*)", text)
             for g in groups if g]
    out += [f"  {note[:160]}" for note in notes[:4]]
    out += [f"  引擎报错 {a[:180]}" for a in re.findall(r"\[AetherFailure\] (.*)", text)[:3]]
    out += [f"  控制器 {f[:180]}" for f in re.findall(r"\[EngineFailed\] (.*)", text)[:4]]
    out += [f"  提议 {f[:160]}" for f in re.findall(r"\[QualityOffer\] (.*)", text)[:2]]
    out += [f"  降级 {f[:150]}" for f in re.findall(r"\[EngineFallback\] (.*)", text)[:1]]
    out += [f"  错误页 {e[:150]}" for e in re.findall(r"\[PlayerError\] (.*)", text)[:1]]
    return "\n".join(out), passed


async def main():
    names = sys.argv[1:]
    if not names or names == ["--list"]:
        for name, spec in SCENARIOS.items():
            print(f"{name:20} 预期 {spec['expect']:8} 路由 {spec['route']}")
        return
    names = list(SCENARIOS) if names == ["all"] else names
    failed = []
    for name in names:
        report, passed = await run(name)
        print(report, flush=True)
        if not passed:
            failed.append(name)
    summary = f"\n{len(names) - len(failed)}/{len(names)} 通过"
    print(summary + (f"，不通过：{' '.join(failed)}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    asyncio.run(main())

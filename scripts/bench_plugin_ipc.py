"""插件进程间通信压测（docs/design/plugin-ipc-http.md §8）。

用真实应用生命周期（uvicorn + lifespan，临时数据目录、全新数据库）拉起三个进程外插件，
测宿主与插件进程之间各条通道的吞吐与延迟。只经过迁移前后都不变的公共路径（钩子分发、
插件服务、宿主操作、插件路由），同一个脚本在迁移前后各跑一次即可对比。

    cd <仓库根目录>          # 启动迁移要找 alembic.ini
    python scripts/bench_plugin_ipc.py --out /tmp/ipc-bench.json [--quick]

NAS 上在容器里跑（以 root 运行时插件进程按生产一样降权隔离）；环境变量全部指向临时目录，
不碰生产数据。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path
from typing import Any

BENCH_PLUGIN = """
import asyncio
import time

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from movieclaw_api import hooks
from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA, PLUGIN_ROUTES
from movieclaw_sdk import plugin


@plugin(
    "bench-ipc",
    title="IPC 压测",
    inject=(PLUGIN_ROUTES, PLUGIN_DATA, HOST_OPS),
    permissions=("health.check",),
)
async def apply(ctx):
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    ops = await ctx.use(HOST_OPS).client(ctx)

    def pick(query):
        return hooks.DownloaderChoice(downloader_id=1, reason="bench")

    async def keep_all(batch, next_):
        return await next_()

    ctx.on(hooks.DOWNLOADER_SELECT, pick, id="pick")
    ctx.on(hooks.CANDIDATES_FILTER, keep_all, id="filter")

    router = APIRouter()

    @router.get("/ping", operation_id="plugins.bench-ipc.ping")
    async def ping() -> dict:
        return {"ok": True}

    @router.get("/blob", operation_id="plugins.bench-ipc.blob")
    async def blob(mb: int = 64):
        chunk = b"\\0" * (1 << 20)

        async def body():
            for _ in range(mb):
                yield chunk

        return StreamingResponse(body(), media_type="application/octet-stream")

    @router.post("/host-calls", operation_id="plugins.bench-ipc.host-calls")
    async def host_calls(kind: str, n: int = 1000, c: int = 16, size: int = 64) -> dict:
        value = "x" * size
        latencies = []
        errors = []
        gate = asyncio.Semaphore(c)

        async def one(i):
            async with gate:
                started = time.perf_counter()
                try:
                    if kind == "data-set":
                        await store.set(f"k{i % 64}", value)
                    elif kind == "data-get":
                        await store.get(f"k{i % 64}")
                    else:
                        await ops.call("health.check")
                except Exception as exc:
                    errors.append(f"{type(exc).__name__}: {exc}")
                latencies.append((time.perf_counter() - started) * 1000)

        started = time.perf_counter()
        await asyncio.gather(*(one(i) for i in range(n)))
        return {
            "elapsed": time.perf_counter() - started,
            "latencies": latencies,
            "failures": len(errors),
            "first_error": errors[0] if errors else None,
        }

    ctx.use(PLUGIN_ROUTES).mount(ctx, router, zone="admin")
"""

HOOK_ONLY_PLUGIN = """
from movieclaw_api import hooks
from movieclaw_sdk import plugin


@plugin("bench-hook", title="只有钩子")
async def apply(ctx):
    ctx.on(hooks.SEARCH_KEYWORDS, lambda payload, next_: next_(), id="kw")
"""

IDLE_PLUGIN = """
import asyncio

from movieclaw_sdk import plugin


@plugin("bench-idle", title="只有后台任务")
async def apply(ctx):
    async def loop():
        while True:
            await asyncio.sleep(60)

    ctx.task(loop(), name="idle")
"""

PLUGINS = {"bench_ipc": BENCH_PLUGIN, "bench_hook": HOOK_ONLY_PLUGIN, "bench_idle": IDLE_PLUGIN}
ENTRIES = {"bench_ipc": "bench-ipc", "bench_hook": "bench-hook", "bench_idle": "bench-idle"}


def prepare(tmp: Path) -> None:
    os.environ.update(
        DATABASE_URL=f"sqlite+aiosqlite:///{tmp / 'bench.db'}",
        SECRET_KEY_FILE=str(tmp / ".secret_key"),
        SITE_CONFIGS_DIR=str(tmp / "site-configs"),
        MOVIECLAW_DATA_DIR=str(tmp),
        SCHEDULER_ENABLED="false",
    )
    (tmp / "plugins").mkdir()
    lines = []
    for module, source in PLUGINS.items():
        (tmp / "plugins" / f"{module}.py").write_text(textwrap.dedent(source), encoding="utf-8")
        lines.append(
            f"- id: {ENTRIES[module]}\n  local: true\n  module: {module}\n  runtime: process\n"
        )
    lines[0] += "  grants: [health.check]\n"
    (tmp / "plugins.yaml").write_text("".join(lines), encoding="utf-8")


def summarize(latencies_ms: list[float], elapsed: float | None = None) -> dict[str, Any]:
    ordered = sorted(latencies_ms)
    out: dict[str, Any] = {
        "n": len(ordered),
        "p50_ms": round(statistics.median(ordered), 3),
        "p99_ms": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))], 3),
        "max_ms": round(ordered[-1], 3),
    }
    if elapsed:
        out["ops_per_s"] = round(len(ordered) / elapsed, 1)
    return out


def rss_mb(pid: int) -> float:
    status = Path(f"/proc/{pid}/status")
    if status.exists():
        for line in status.read_text().splitlines():
            if line.startswith("VmRSS:"):
                return round(int(line.split()[1]) / 1024, 1)
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).strip()
    return round(int(out) / 1024, 1)


async def timed(call, n: int, concurrency: int) -> tuple[list[float], float, int]:
    """并发跑 n 次 call()，返回每次延迟（毫秒）、总耗时、失败次数（call 返回 False 记失败）。"""
    latencies: list[float] = []
    failures = 0
    gate = asyncio.Semaphore(concurrency)

    async def one() -> None:
        nonlocal failures
        async with gate:
            started = time.perf_counter()
            ok = await call()
            latencies.append((time.perf_counter() - started) * 1000)
            if ok is False:
                failures += 1

    started = time.perf_counter()
    await asyncio.gather(*(one() for _ in range(n)))
    return latencies, time.perf_counter() - started, failures


async def run(args: argparse.Namespace) -> dict[str, Any]:
    import httpx
    import uvicorn

    from movieclaw_api import hooks
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services import plugin_runtime
    from movieclaw_api.services.auth import Principal

    scale = 0.2 if args.quick else 1.0

    def n(count: int) -> int:
        return max(20, int(count * scale))

    app = create_app()
    admin = Principal(kind="admin", name="bench")
    app.dependency_overrides[require_login] = lambda: admin
    app.dependency_overrides[require_admin] = lambda: admin
    server = uvicorn.Server(
        uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning", access_log=False)
    )
    serving = asyncio.create_task(server.serve())
    while not server.started:
        if serving.done():
            serving.result()
        await asyncio.sleep(0.05)
    port = server.servers[0].sockets[0].getsockname()[1]
    deadline = time.monotonic() + 60
    while not all(
        e in plugin_runtime.sessions and plugin_runtime.sessions[e].online for e in ENTRIES.values()
    ):
        if time.monotonic() > deadline:
            raise RuntimeError("插件进程 60 秒内没有全部就绪")
        await asyncio.sleep(0.1)

    results: dict[str, Any] = {}
    base = f"http://127.0.0.1:{port}/api/v1/plugins/bench-ipc"
    limits = httpx.Limits(max_connections=64, max_keepalive_connections=64)
    async with httpx.AsyncClient(base_url=base, timeout=120, limits=limits) as client:
        query = hooks.DownloaderQuery(title="压测", media_kind="tv")

        async def bail() -> bool:
            return await hooks.bail(hooks.DOWNLOADER_SELECT, query) is not None

        def batch(size: int) -> hooks.CandidateBatch:
            media = hooks.MediaBrief(id=1, kind="tv", title="压测")
            return hooks.CandidateBatch(
                media=media,
                subscription_id=1,
                selection_mode="best",
                purpose="wanted",
                candidates=tuple(
                    hooks.CandidateView(
                        key=f"s/{i}",
                        site_id="s",
                        torrent_id=str(i),
                        title=f"Some.Show.S01E{i % 99:02d}.2160p.WEB-DL.H265-GROUP{i}",
                        release_group=f"GROUP{i}",
                    )
                    for i in range(size)
                ),
            )

        small, large = batch(2), batch(2000)

        async def waterfall(payload: hooks.CandidateBatch) -> bool:
            result = await hooks.waterfall(
                hooks.CANDIDATES_FILTER, payload, terminal=lambda b: hooks.FilterResult()
            )
            return result is not None

        # 预热：建连接、首次导入、首次授权
        await timed(bail, 50, 4)
        await client.get("/ping")
        await client.post("/host-calls", params={"kind": "ops", "n": 20, "c": 4})

        print("· 钩子（宿主调插件）", flush=True)
        lat, elapsed, fail = await timed(bail, n(2000), 1)
        results["hook_bail_serial"] = summarize(lat, elapsed) | {"failures": fail}
        lat, elapsed, fail = await timed(bail, n(5000), 32)
        results["hook_bail_c32"] = summarize(lat, elapsed) | {"failures": fail}
        lat, elapsed, fail = await timed(lambda: waterfall(small), n(1000), 1)
        results["hook_waterfall_next_serial"] = summarize(lat, elapsed) | {"failures": fail}
        lat, elapsed, fail = await timed(lambda: waterfall(large), n(100), 1)
        results["hook_waterfall_2000_candidates"] = summarize(lat, elapsed) | {"failures": fail}

        print("· 插件调宿主", flush=True)
        for kind, size, count, conc in (
            ("data-get", 64, 2000, 1),
            ("data-get", 64, 5000, 32),
            ("data-set", 64, 2000, 16),
            ("ops", 0, 2000, 1),
            ("ops", 0, 5000, 32),
        ):
            reply = await client.post(
                "/host-calls", params={"kind": kind, "n": n(count), "c": conc, "size": size}
            )
            reply.raise_for_status()
            body = reply.json()
            results[f"plugin_{kind}_c{conc}"] = summarize(body["latencies"], body["elapsed"]) | {
                "failures": body["failures"],
                "first_error": body["first_error"],
            }

        print("· 路由反代", flush=True)

        async def ping() -> bool:
            return (await client.get("/ping")).status_code == 200

        lat, elapsed, fail = await timed(ping, n(2000), 1)
        results["route_ping_serial"] = summarize(lat, elapsed) | {"failures": fail}
        lat, elapsed, fail = await timed(ping, n(5000), 32)
        results["route_ping_c32"] = summarize(lat, elapsed) | {"failures": fail}
        mb = max(16, int(512 * scale))
        started = time.perf_counter()
        received = 0
        async with client.stream("GET", "/blob", params={"mb": mb}) as reply:
            async for chunk in reply.aiter_raw():
                received += len(chunk)
        seconds = time.perf_counter() - started
        results["route_stream"] = {"mb": mb, "mb_per_s": round(received / (1 << 20) / seconds, 1)}

        print("· 队头阻塞（大载荷在途时的小调用）", flush=True)

        async def flood(stop: asyncio.Event, kind: str) -> int:
            done = 0
            while not stop.is_set():
                if kind == "host-to-plugin":
                    await waterfall(large)
                else:
                    await client.post(
                        "/host-calls", params={"kind": "data-set", "n": 8, "c": 8, "size": 60000}
                    )
                done += 1
            return done

        for kind in ("host-to-plugin", "plugin-to-host"):
            stop = asyncio.Event()
            floods = [asyncio.create_task(flood(stop, kind)) for _ in range(4)]
            await asyncio.sleep(0.5)
            lat, elapsed, fail = await timed(bail, n(500), 1)
            stop.set()
            rounds = sum(await asyncio.gather(*floods))
            results[f"hol_bail_during_{kind}"] = summarize(lat, elapsed) | {
                "failures": fail,
                "flood_rounds": rounds,
            }

    results["memory_rss_mb"] = {
        entry: rss_mb(plugin_runtime.sessions[entry].pid) for entry in ENTRIES.values()
    }
    server.should_exit = True
    await serving
    return results


def environment() -> dict[str, Any]:
    from movieclaw_api import __version__

    try:
        sha = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=False
        ).stdout.strip()
    except FileNotFoundError:  # 容器里没有 git
        sha = ""
    return {
        "version": __version__,
        "git": sha or None,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpus": os.cpu_count(),
        "euid": os.geteuid() if hasattr(os, "geteuid") else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--out", type=Path, help="结果写成 JSON")
    parser.add_argument("--quick", action="store_true", help="各场景次数缩到 1/5（冒烟用）")
    args = parser.parse_args()
    if not Path("alembic.ini").exists():
        print("请在仓库根目录（有 alembic.ini 的目录）运行", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="mc-ipc-bench-") as tmp:
        prepare(Path(tmp))
        results = asyncio.run(run(args))
    report = {"environment": environment(), "quick": args.quick, "results": results}
    text = json.dumps(report, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        args.out.write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())

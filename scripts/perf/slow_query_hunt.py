#!/usr/bin/env python3
"""慢查询猎手：在库副本上回放真实流量，记下每条 SQL 的耗时与查询计划。

见 docs/perf/nas-server-baseline-2026-10.md §4。

两种回放：

- ``endpoints``：访问日志里出现过的每个 GET 接口取最常见的 3 个真实路径（带真实 id），
  每个跑 1 次预热 + N 次计时，SQL 取最快一次；
- ``jobs``：逐个跑定时任务的处理函数（跳过纯外网 / 纯扫 NFS 的两个）。

回放跑在**库副本**上，不跑 lifespan。审计钩子兜底：挡掉一切 TCP 连接（同容器的回环就是
正在服务的真实后端）、子进程（ffmpeg）、片库读取，以及 /tmp 与副本目录以外的写和删。
碰网络的接口/任务会在网络处失败，之前的 SQL 照样记下。

用法（NAS 容器内，副本用 sqlite3 backup 拷到 /tmp/mc-bench）::

    METADATA_DIR=/app/data/metadata PYTHONPATH=<src> /venv/bin/python slow_query_hunt.py \\
        endpoints /tmp/mc-bench/bench.db --log access.log --out hunt.json
    ... slow_query_hunt.py jobs /tmp/mc-bench/jobs.db --out jobs.json
"""

from __future__ import annotations

import argparse
import asyncio
import collections
import hashlib
import importlib
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

_TOKEN = "mclaw_bench_" + "0" * 32
_ENCRYPTED = ("auth.session", "extension.sync", "network.egress", "metadata.fanart")
# 长连接与取流：回放它们只会挂住或读片库
_DENY = re.compile(
    r"/(events|stream|streams|sse|hls|download|ws|watch|live)(/|$)|\.m3u8|\.ts$|/master|/segments/"
)
_ACCESS = re.compile(r"method=GET path=(\S+) status_code=(2\d\d)")
_ID = re.compile(r"/(?:[0-9a-f]{8,}(?:-[0-9a-f]{4,})*|\d+)(?=/|$)")
_IN_LIST = re.compile(r"\((?:\s*\?\s*,)+\s*\?\s*\)")
_JOB_MODULES = [
    "movieclaw_api.services.app_update",
    "movieclaw_api.services.download_progress",
    "movieclaw_api.services.download_sources",
    "movieclaw_api.services.library.ingest",
    "movieclaw_api.services.library.nfo_backfill",
    "movieclaw_api.services.library.recycle",
    "movieclaw_api.services.library.scan",
    "movieclaw_api.services.library.series_backfill",
    "movieclaw_api.services.media_refresh",
    "movieclaw_api.services.ratio_boost",
    "movieclaw_api.services.subscription.smart_scheduler",
    "movieclaw_api.services.subscription.upgrade",
    "movieclaw_api.services.subscription.wanted_search",
    "movieclaw_api.services.torrent_matcher",
    "movieclaw_api.services.torrent_sync",
    "movieclaw_scheduler.tasks",
]
_JOB_SKIP = {"check_app_update", "library_reconcile"}


def _corpus(log: Path, per_endpoint: int = 3) -> list[str]:
    by: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for line in log.open(encoding="utf-8", errors="replace"):
        m = _ACCESS.search(line)
        if m and not _DENY.search(m.group(1)):
            by[_ID.sub("/{id}", m.group(1))][m.group(1)] += 1
    return [p for _, c in sorted(by.items()) for p, _ in c.most_common(per_endpoint)]


def _prepare_copy(db: Path) -> None:
    con = sqlite3.connect(db)
    con.execute("DELETE FROM login_device WHERE name = 'bench'")
    con.execute(
        "INSERT INTO login_device (created_at, updated_at, member_id, kind, name, token_hash,"
        " scope, installation_id, last_seen_at) SELECT created_at, updated_at, 0, kind, 'bench',"
        " ?, scope, 'bench', last_seen_at FROM login_device ORDER BY id DESC LIMIT 1",
        (hashlib.sha256(_TOKEN.encode()).hexdigest(),),
    )
    marks = ",".join("?" * len(_ENCRYPTED))
    con.execute(f"DELETE FROM app_setting WHERE namespace IN ({marks})", _ENCRYPTED)
    con.commit()
    con.close()


def _install_guard(db_dir: str) -> collections.Counter[str]:
    blocked: collections.Counter[str] = collections.Counter()
    writable = ("/tmp", db_dir, "/dev/null")

    def hook(event: str, args: tuple) -> None:
        if event == "socket.connect" and isinstance(args[1], tuple):
            blocked["net"] += 1
            raise PermissionError(f"hunt: blocked connect {args[1]}")
        if event in ("subprocess.Popen", "os.posix_spawn", "os.exec", "os.spawn"):
            blocked["proc"] += 1
            raise PermissionError("hunt: blocked process")
        if event == "open" and isinstance(args[0], str):
            path, mode, flags = args
            if path.startswith(("/remote", "/download", "/volume")):
                blocked["media"] += 1
                raise PermissionError(f"hunt: blocked media read {path}")
            writing = (isinstance(mode, str) and any(c in mode for c in "wax+")) or (
                flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT)
            )
            if writing and not path.startswith(writable):
                blocked["write"] += 1
                raise PermissionError(f"hunt: blocked write {path}")
        deleting = event in ("os.remove", "os.rename", "shutil.rmtree", "os.rmdir")
        if deleting and not str(args[0]).startswith(writable):
            blocked["write"] += 1
            raise PermissionError(f"hunt: blocked delete {args[0]}")

    sys.addaudithook(hook)
    return blocked


def _plain(value: object) -> object:
    if hasattr(value, "value"):  # 枚举
        return str(value.value)  # type: ignore[attr-defined]
    if hasattr(value, "isoformat"):
        return value.isoformat(sep=" ")  # type: ignore[call-arg, attr-defined]
    return value


async def _replay(args: argparse.Namespace, db: Path) -> dict:
    from sqlalchemy import event

    from movieclaw_api.core.config import get_settings
    from movieclaw_api.settings import init_setting_store
    from movieclaw_db.crypto import init_secret_box
    from movieclaw_db.engine import init_db

    database = init_db(get_settings().database_url)
    init_secret_box(None, db.parent / "bench.key")
    init_setting_store()
    stmts: dict[str, dict] = {}
    current: dict = {"label": None}

    @event.listens_for(database.engine.sync_engine, "before_cursor_execute")
    def _before(conn, cursor, statement, params, context, many):  # noqa: ANN001
        conn.info.setdefault("t0", []).append(time.perf_counter())

    @event.listens_for(database.engine.sync_engine, "after_cursor_execute")
    def _after(conn, cursor, statement, params, context, many):  # noqa: ANN001
        took = (time.perf_counter() - conn.info["t0"].pop()) * 1000
        if current["label"] is None or many:
            return
        entry = stmts.setdefault(
            _IN_LIST.sub("(?…)", " ".join(statement.split())),
            {"sql": statement, "params": params, "runs": collections.defaultdict(list)},
        )
        entry["runs"][current["label"]].append(took)
        if len(str(params)) > len(str(entry["params"])):  # 留参数最多的那次做执行计划
            entry["sql"], entry["params"] = statement, params

    results = []
    if args.mode == "endpoints":
        import httpx

        from movieclaw_api.app import create_app

        app = create_app()
        headers = {"Authorization": f"Bearer {_TOKEN}", "User-Agent": "hunt"}
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://hunt", headers=headers
        ) as c:
            for path in _corpus(Path(args.log)):
                took, status = [], None
                for rep in range(args.repeat + 1):
                    current["label"] = path if rep else None  # 第一次是预热
                    started = time.perf_counter()
                    try:
                        status = (await asyncio.wait_for(c.get(path), timeout=15)).status_code
                    except Exception as exc:  # noqa: BLE001
                        status = type(exc).__name__
                    if rep:
                        took.append((time.perf_counter() - started) * 1000)
                current["label"] = None
                results.append({"path": path, "status": status, "ms": min(took)})
    else:
        from movieclaw_scheduler.registry import _REGISTRY

        for module in _JOB_MODULES:
            importlib.import_module(module)
        for key, definition in sorted(_REGISTRY.items()):
            if key in _JOB_SKIP:
                continue
            current["label"] = key
            started, error = time.perf_counter(), None
            try:
                await asyncio.wait_for(definition.handler(), timeout=60)
            except BaseException as exc:  # noqa: BLE001
                error = f"{type(exc).__name__}: {str(exc)[:160]}"
            current["label"] = None
            results.append(
                {"task": key, "ms": (time.perf_counter() - started) * 1000, "error": error}
            )
    await database.dispose()

    raw = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    statements = []
    for key, entry in stmts.items():
        params = entry["params"]
        params = [_plain(v) for v in params] if isinstance(params, (list, tuple)) else params
        try:
            plan = [row[3] for row in raw.execute("EXPLAIN QUERY PLAN " + entry["sql"], params)]
        except Exception as exc:  # noqa: BLE001
            plan = [f"(plan error: {exc})"]
        # endpoints 取各次最快（暖缓存）；jobs 只跑一次，取那一次
        best = {label: min(v) for label, v in entry["runs"].items()}
        statements.append(
            {
                "sql": key[:600],
                "plan": plan,
                "ms": max(best.values()),
                "by": best,
                "calls": {label: len(v) for label, v in entry["runs"].items()},
            }
        )
    statements.sort(key=lambda s: -s["ms"])
    return {"results": results, "statements": statements}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("endpoints", "jobs"))
    parser.add_argument("db", type=Path, help="库副本（会被改动，别指向线上库）")
    parser.add_argument("--log", help="endpoints 模式：访问日志（可多天拼接）")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--out", required=True)
    parser.add_argument("--slow-ms", type=float, default=10, help="打印阈值")
    args = parser.parse_args()
    db = args.db.resolve()
    _prepare_copy(db)
    os.environ.setdefault("DATABASE_URL", f"sqlite+aiosqlite:///{db}")
    os.environ.setdefault("APP_ENV", "development")
    os.environ.setdefault("SCHEDULER_ENABLED", "false")
    os.environ.setdefault("APP_ACCESS_LOG_ENABLED", "false")
    os.environ.setdefault("LOG_DIR", tempfile.mkdtemp())
    blocked = _install_guard(str(db.parent))
    report = asyncio.run(_replay(args, db))
    report["blocked"] = dict(blocked)
    Path(args.out).write_text(json.dumps(report, ensure_ascii=False, default=str), encoding="utf-8")
    replayed, kinds = len(report["results"]), len(report["statements"])
    print(f"回放 {replayed} 项，{kinds} 种 SQL，护栏拦截 {dict(blocked)}")
    for s in report["statements"]:
        if s["ms"] < args.slow_ms:
            break
        top = max(s["by"].items(), key=lambda kv: kv[1])[0]
        plan = [p for p in s["plan"] if not p.startswith("LIST")][:3]
        print(f"{s['ms']:8.1f} ms  {top[:60]}\n           {s['sql'][:160]}\n           {plan}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""进程内 A/B 压测首页接口（docs/perf/nas-server-baseline-2026-10.md）。

在 NAS 容器里用**库副本**跑真实 ``create_app()``，同一台机器、同一份数据对比新旧两份代码
（``PYTHONPATH`` 指向不同的 src）。不跑 lifespan：不起消息通道、任务队列和局域网发现，
不会和正在运行的服务抢活。鉴权走真实登录设备令牌——不用 ``dependency_overrides``：
FastAPI 只要有 override，每个请求都对每个子依赖重跑 ``get_dependant``，会把框架开销测歪。

会改动副本：插一台 ``bench`` 登录设备，删掉本机解不开的加密配置。**绝不能指向线上库**。

用法（容器内，副本先用 sqlite3 backup 拷到 /tmp）::

    cd /tmp/mc-bench && METADATA_DIR=/app/data/metadata PYTHONPATH=<src> \\
        /venv/bin/python bench_home_api.py /tmp/mc-bench/bench.db --rounds 30 [--trace] \\
        [--endpoint /api/v1/libraries/20/items?limit=60 ...]
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import logging
import os
import sqlite3
import statistics
import tempfile
import time
from pathlib import Path

_HOME = [
    "/api/v1/libraries",
    "/api/v1/playback/favorites?limit=20&unwatched_first=true",
    "/api/v1/collections",
    "/api/v1/playback/up-next?limit=20",
]
_TOKEN = "mclaw_bench_" + "0" * 32
# 本机解不开的加密配置（副本里删，会话签名密钥会自动重新生成）
_ENCRYPTED = ("auth.session", "extension.sync", "network.egress", "metadata.fanart")


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


async def _run(db: Path, endpoints: list[str], rounds: int, trace: bool) -> None:
    import httpx
    from sqlalchemy import event

    from movieclaw_api.app import create_app
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.settings import init_setting_store
    from movieclaw_db.crypto import init_secret_box
    from movieclaw_db.engine import init_db

    database = init_db(get_settings().database_url)
    init_secret_box(None, db.parent / "bench.key")
    init_setting_store()
    sql = {"n": 0, "s": 0.0, "log": None}

    @event.listens_for(database.engine.sync_engine, "before_cursor_execute")
    def _before(conn, cursor, statement, params, context, many):  # noqa: ANN001
        conn.info.setdefault("t0", []).append(time.perf_counter())

    @event.listens_for(database.engine.sync_engine, "after_cursor_execute")
    def _after(conn, cursor, statement, params, context, many):  # noqa: ANN001
        took = time.perf_counter() - conn.info["t0"].pop()
        sql["n"] += 1
        sql["s"] += took
        if sql["log"] is not None:
            sql["log"].append((took * 1000, " ".join(statement.split())[:150]))

    app = create_app()
    logging.getLogger("httpx").setLevel(logging.WARNING)
    headers = {"Authorization": f"Bearer {_TOKEN}", "User-Agent": "bench"}
    transport = httpx.ASGITransport(app=app)
    client = httpx.AsyncClient(transport=transport, base_url="http://bench", headers=headers)
    async with client as c:
        for endpoint in endpoints:  # 预热：首个请求才构建路由上下文、填各种缓存
            response = await c.get(endpoint)
            assert response.status_code == 200, (endpoint, response.status_code, response.text)

        print("串行（毫秒）：")
        for endpoint in endpoints:
            took, sql_ms = [], []
            for _ in range(rounds):
                n0, s0 = sql["n"], sql["s"]
                started = time.perf_counter()
                response = await c.get(endpoint)
                took.append((time.perf_counter() - started) * 1000)
                sql_ms.append((sql["s"] - s0) * 1000)
            took.sort()
            print(
                f"  p50={statistics.median(took):7.1f} p90={took[int(0.9 * len(took))]:7.1f} "
                f"SQL {sql['n'] - n0:2} 条/{statistics.median(sql_ms):6.1f}  "
                f"{len(response.content) / 1024:6.1f}KB  {endpoint}"
            )

        async def timed(endpoint: str) -> float:
            started = time.perf_counter()
            await c.get(endpoint)
            return (time.perf_counter() - started) * 1000

        walls, each = [], []
        for _ in range(rounds):
            started = time.perf_counter()
            each.append(await asyncio.gather(*(timed(e) for e in endpoints)))
            walls.append((time.perf_counter() - started) * 1000)
        print(
            f"并发（客户端同时发全部接口）：总墙钟 p50={statistics.median(walls):.1f}ms，"
            f"各自完成 p50={[round(statistics.median(x), 1) for x in zip(*each, strict=True)]}"
        )

        if trace:
            for endpoint in endpoints:
                sql["log"] = []
                await c.get(endpoint)
                print(f"## {endpoint}")
                for took_ms, statement in sorted(sql["log"], reverse=True)[:8]:
                    print(f"   {took_ms:6.2f}ms {statement}")
                sql["log"] = None
    await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("db", type=Path, help="库副本（会被改动，别指向线上库）")
    parser.add_argument("--rounds", type=int, default=30)
    parser.add_argument("--endpoint", action="append", help="默认首页四个接口")
    parser.add_argument("--trace", action="store_true", help="每个接口列最慢的几条 SQL")
    args = parser.parse_args()
    db = args.db.resolve()
    _prepare_copy(db)
    os.environ.setdefault("DATABASE_URL", f"sqlite+aiosqlite:///{db}")
    os.environ.setdefault("APP_ENV", "development")
    os.environ.setdefault("SCHEDULER_ENABLED", "false")
    os.environ.setdefault("APP_ACCESS_LOG_ENABLED", "false")
    os.environ.setdefault("LOG_DIR", tempfile.mkdtemp())
    asyncio.run(_run(db, args.endpoint or _HOME, args.rounds, args.trace))


if __name__ == "__main__":
    main()

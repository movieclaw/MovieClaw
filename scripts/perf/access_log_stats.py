#!/usr/bin/env python3
"""按天统计后端访问日志的接口延迟（docs/perf/nas-server-baseline-2026-10.md）。

读 ``movieclaw_api.access`` 行的 ``duration_ms``，路径里的数字/哈希 id 归一成 ``{id}``，
每个接口出 n / p50 / p95 / p99 / max / 总耗时；另附健康接口 >50ms 的次数——它不碰库，
慢了就是事件循环被别的活卡住了。

用法::

    ssh nas 'cat /volume1/docker_stable/movieclaw/logs/movieclaw-2026-10-26.log' \\
        | python3 scripts/perf/access_log_stats.py [--top 30] [--json]
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import sys

_ACCESS = re.compile(
    r"^(\S+ \S+) \| \w+ \| movieclaw_api\.access \| method=(\S+) path=(\S+) "
    r"status_code=(\d+) duration_ms=([\d.]+)"
)
_ID = re.compile(r"/(?:[0-9a-f]{8,}(?:-[0-9a-f]{4,})*|\d+)(?=/|$)")
_HEALTH = "GET /api/v1/health"


def _pct(values: list[float], q: float) -> float:
    return values[min(len(values) - 1, int(q * len(values)))]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--top", type=int, default=30, help="按总耗时列前几个接口")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    groups: dict[str, list[float]] = collections.defaultdict(list)
    status: collections.Counter[str] = collections.Counter()
    for line in sys.stdin:
        m = _ACCESS.match(line)
        if not m:
            continue
        _ts, method, path, code, ms = m.groups()
        groups[f"{method} {_ID.sub('/{id}', path.split('?')[0])}"].append(float(ms))
        status[code[0] + "xx"] += 1

    rows = []
    for endpoint, values in groups.items():
        values.sort()
        rows.append(
            {
                "endpoint": endpoint,
                "n": len(values),
                "p50": _pct(values, 0.5),
                "p95": _pct(values, 0.95),
                "p99": _pct(values, 0.99),
                "max": values[-1],
                "total_s": sum(values) / 1000,
            }
        )
    rows.sort(key=lambda r: -r["total_s"])
    every = sorted(v for values in groups.values() for v in values)
    summary = {
        "requests": len(every),
        "status": dict(status),
        "p50": _pct(every, 0.5) if every else 0,
        "p95": _pct(every, 0.95) if every else 0,
        "p99": _pct(every, 0.99) if every else 0,
        "health_over_50ms": sum(1 for v in groups.get(_HEALTH, []) if v > 50),
        "top": rows[: args.top],
    }
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, default=lambda x: round(x, 1)))
        return
    print(
        f"请求 {summary['requests']}  {summary['status']}  p50={summary['p50']:.1f}ms "
        f"p95={summary['p95']:.0f}ms p99={summary['p99']:.0f}ms  "
        f"健康接口>50ms {summary['health_over_50ms']} 次"
    )
    for r in summary["top"]:
        print(
            f"{r['n']:>6} p50={r['p50']:7.1f} p95={r['p95']:8.1f} p99={r['p99']:8.1f} "
            f"max={r['max']:9.1f} 总={r['total_s']:7.1f}s  {r['endpoint']}"
        )


if __name__ == "__main__":
    main()

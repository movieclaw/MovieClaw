"""真实 HTTP 并发搜索基准：每个连接独立登录，并校验完整结果与预热结果一致。

密码只从 MC_SEARCH_PASSWORD 读取；业务接口只读。可单测宽泛人物缩写，也可混合输入。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx


def latency_summary(samples):
    values = sorted(sample["ms"] for sample in samples)
    return {
        "median": round(statistics.median(values), 2),
        "p95": round(values[math.ceil(len(values) * 0.95) - 1], 2),
        "max": round(values[-1], 2),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--concurrency", type=int, choices=range(1, 17), default=4)
    parser.add_argument("--rounds", type=int, choices=range(1, 101), default=4)
    parser.add_argument("--queries", nargs="+", default=["xjcy", "星际cy", "诺兰", "nl"])
    parser.add_argument("--rotate-queries", action="store_true")
    args = parser.parse_args()
    clients = []
    barrier = threading.Barrier(args.concurrency)

    def search(client, query):
        response = client.get("search/library", params={"q": query})
        response.raise_for_status()
        envelope = response.json()
        assert envelope["success"] and "code" in envelope and "message" in envelope
        data = envelope["data"]
        # 游标随机令牌不参与对比，其有无、全部结果字段与排序仍须一致。
        return {**data, "next_cursor": bool(data["next_cursor"])}

    try:
        for _ in range(args.concurrency):
            client = httpx.Client(base_url=args.url.rstrip("/") + "/api/v1/", timeout=60)
            clients.append(client)
            client.post(
                "auth/login",
                json={"username": args.username, "password": os.environ["MC_SEARCH_PASSWORD"]},
            ).raise_for_status()
        expected = {query: search(clients[0], query) for query in args.queries}

        def run(worker):
            client = clients[worker]
            samples = []
            shift = worker % len(args.queries) if args.rotate_queries else 0
            queries = args.queries[shift:] + args.queries[:shift]
            barrier.wait()
            for iteration in range(args.rounds):
                for query in queries:
                    started = time.perf_counter()
                    actual = search(client, query)
                    elapsed = (time.perf_counter() - started) * 1000
                    assert actual == expected[query], f"{query}: 完整结果或排序发生变化"
                    samples.append(
                        {"worker": worker, "round": iteration, "q": query, "ms": round(elapsed, 3)}
                    )
            return samples

        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            samples = [
                sample for group in pool.map(run, range(args.concurrency)) for sample in group
            ]
        report = {
            "url": args.url,
            "concurrency": args.concurrency,
            "rounds": args.rounds,
            "queries": args.queries,
            "rotate_queries": args.rotate_queries,
            "checks": len(samples),
            "passed": True,
            "latency_ms": latency_summary(samples),
            "by_query": {
                query: latency_summary([s for s in samples if s["q"] == query])
                for query in args.queries
            },
            "samples": samples,
        }
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print({key: report[key] for key in ("concurrency", "checks", "passed", "latency_ms")})
    finally:
        for client in clients:
            try:
                client.post("auth/logout").raise_for_status()
            finally:
                client.close()


if __name__ == "__main__":
    main()

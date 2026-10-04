"""真实 HTTP 搜索验收：登录、名称/拼音、人物、分页、详情、旧契约和错误响应。

仅调用登录/登出及只读业务接口。密码从 MC_SEARCH_PASSWORD 读取，不写入报告。
验收数据需包含《星际穿越》及其诺兰导演关系，用于校验各输入方式的准确召回。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import time
from pathlib import Path

import httpx


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--benchmark-rounds", type=int, default=0, choices=range(21))
    args = parser.parse_args()
    report = {"url": args.url, "checks": [], "queries": []}

    with httpx.Client(base_url=args.url.rstrip("/") + "/api/v1/", timeout=120) as client:

        def check(name, condition):
            report["checks"].append({"name": name, "passed": bool(condition)})
            assert condition, name

        def get(path, params=None, status=200):
            response = client.get(path, params=params)
            check(f"{path}: HTTP {status}", response.status_code == status)
            envelope = response.json()
            check(
                "统一响应信封",
                envelope.get("success") == (status == 200)
                and "code" in envelope
                and "message" in envelope
                and ("data" in envelope if status == 200 else "data" not in envelope)
                and (status != 422 or isinstance(envelope.get("details"), list)),
            )
            return envelope.get("data")

        try:
            get("search/library", {"q": "xjcy"}, 401)
            login = client.post(
                "auth/login",
                json={
                    "username": args.username,
                    "password": os.environ["MC_SEARCH_PASSWORD"],
                },
            )
            check("真实账号登录", login.status_code == 200)
            get("auth/me")
            libraries = get("libraries")
            check("至少一个可见媒体库", len(libraries) > 0)
            timings = []
            signatures = {}
            for query in [
                "星际穿越",
                "星際穿越",
                "Interstellar",
                "INTERSTELLAR",
                "xjcy",
                "xjc",
                "xingji",
                "星际cy",
                "xj穿越",
                "xingjicy",
                "xjchuanyue",
                "诺兰",
                "nl",
                "nolan",
            ]:
                start = time.perf_counter()
                data = get("search/library", {"q": query})
                elapsed = (time.perf_counter() - start) * 1000
                timings.append(elapsed)
                signatures[query] = {
                    **data,
                    "next_cursor": bool(data["next_cursor"]),
                    "index_pending": None,
                }
                titles = [hit["item"]["title"] for hit in data["items"]]
                check(f"{query}: 星际穿越进入首屏", "星际穿越" in titles)
                check(
                    "作品去重",
                    len({h["item"]["media_item_id"] for h in data["items"]}) == len(titles),
                )
                report["queries"].append(
                    {
                        "q": query,
                        "ms": round(elapsed, 2),
                        "titles": titles[:5],
                        "people": [p["name"] for p in data["people"]],
                        "index_pending": data["index_pending"],
                    }
                )
            data = get("search/library", {"q": "诺兰"})
            check("人物入口", bool(data["people"]))
            person = data["people"][0]
            works = get("search/library", {"person_id": person["id"], "limit": 3})
            check("人物作品", bool(works["items"]))
            first = get("search/library", {"q": "星", "limit": 3})
            check("第一页游标", first["next_cursor"] is not None)
            get("search/library", {"q": "沙丘", "cursor": first["next_cursor"]}, 400)
            second = get("search/library", {"q": "星", "limit": 3, "cursor": first["next_cursor"]})
            check(
                "分页不重复",
                not (
                    {h["item"]["media_item_id"] for h in first["items"]}
                    & {h["item"]["media_item_id"] for h in second["items"]}
                ),
            )
            hit = next(
                h
                for h in get("search/library", {"q": "xjcy"})["items"]
                if h["item"]["title"] == "星际穿越"
            )
            item = hit["item"]
            detail = get(f"libraries/{item['library_id']}/items/{item['media_item_id']}")
            check("搜索落点详情", detail["title"] == item["title"])
            for query in ("xjcy", "诺兰"):
                groups = get("search/library-items", {"keyword": query})
                check(
                    "旧客户端也能搜索",
                    any(i["title"] == "星际穿越" for g in groups for i in g["items"]),
                )
            check(
                "无匹配返回空列表",
                get("search/library", {"q": "不存在的影片_xyz987654321"})["items"] == [],
            )
            for params, status in [
                ({}, 400),
                ({"q": " "}, 400),
                ({"q": "%_"}, 400),
                ({"q": "x" * 101}, 422),
                ({"q": "x", "limit": 0}, 422),
                ({"person_id": 0}, 422),
                ({"q": "x", "cursor": "invalid"}, 400),
            ]:
                get("search/library", params, status)
            report["latency_ms"] = {
                "median": round(statistics.median(timings), 2),
                "max": round(max(timings), 2),
            }
            if args.benchmark_rounds:
                samples = []
                for iteration in range(args.benchmark_rounds):
                    for query, signature in signatures.items():
                        start = time.perf_counter()
                        data = get("search/library", {"q": query})
                        elapsed = (time.perf_counter() - start) * 1000
                        check(
                            f"{query}: 多轮完整结果与排序一致",
                            {
                                **data,
                                "next_cursor": bool(data["next_cursor"]),
                                "index_pending": None,
                            }
                            == signature,
                        )
                        samples.append({"round": iteration, "q": query, "ms": round(elapsed, 3)})

                def latency_summary(values):
                    return {
                        "median": round(statistics.median(values), 2),
                        "p95": round(sorted(values)[math.ceil(len(values) * 0.95) - 1], 2),
                        "max": round(max(values), 2),
                    }

                # 前面的功能检查已预热；这里统计所有查询，不挑选最快的一轮。
                report["benchmark"] = {
                    "rounds": args.benchmark_rounds,
                    "samples": samples,
                    "latency_ms": latency_summary([sample["ms"] for sample in samples]),
                    "queries": {
                        query: latency_summary([s["ms"] for s in samples if s["q"] == query])
                        for query in signatures
                    },
                }
        finally:
            client.post("auth/logout")
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(
        json.dumps(
            {
                "checks": len(report["checks"]),
                "passed": all(x["passed"] for x in report["checks"]),
                "latency_ms": report.get("latency_ms"),
                "benchmark_ms": report.get("benchmark", {}).get("latency_ms"),
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()

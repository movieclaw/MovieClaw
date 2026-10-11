"""只读回放实片指纹：整季、追更前三/六集、缺集场景与指定算法基线逐条比较。

输入沿用实验台 meta_zh_backup.json / meta_other.json、fp/ / fp_other/ 格式。
输出保留每集结果和差异，供画面复核；一致性不代表准确率，不读写生产数据库。
示例见 docs/design/skip-intro.md §2.17。
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
import time
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def initialize(baseline, current):
    global OLD, NEW
    OLD = load("baseline_skip", baseline)
    NEW = load("current_skip", current)


def episodes(module, rows, lab):
    result, missing = [], []
    for row in rows:
        paths = [lab / folder / f"{row['id']}.fp" for folder in ("fp", "fp_other")]
        path = next((p for p in paths if p.is_file()), None)
        decoded = module.decode_fingerprint(path.read_bytes()) if path else None
        if decoded is None:
            missing.append(row["id"])
            continue
        meta, windows = decoded
        result.append(
            module.Episode(
                row["id"], row["e"] or 0, float(meta.get("duration") or row["dur"]), windows
            )
        )
    return result, missing


def work(task):
    rows, lab = task
    old, old_missing = episodes(OLD, rows, lab)
    new, missing = episodes(NEW, rows, lab)
    assert missing == old_missing
    scopes = {"full": None, "first3": 3, "first6": 6, "alternating": None, "reversed": None}
    output = {}
    numbers = sorted({e.episode for e in new})
    for scope, count in scopes.items():
        selected = set(numbers[::2] if scope == "alternating" else numbers[:count])
        before_eps = [e for e in old if e.episode in selected]
        after_eps = [e for e in new if e.episode in selected]
        if scope == "reversed":
            before_eps.reverse()
            after_eps.reverse()
        t = time.perf_counter()
        before = {
            str(f): [s.as_dict() for s in v] for f, v in OLD.detect_season(before_eps).items()
        }
        old_s = time.perf_counter() - t
        t = time.perf_counter()
        after = {str(f): [s.as_dict() for s in v] for f, v in NEW.detect_season(after_eps).items()}
        new_s = time.perf_counter() - t
        core = {
            f: [{k: v for k, v in s.items() if k != "lead_start_ms"} for s in segs]
            for f, segs in after.items()
        }
        diffs = {
            f: {"before": before.get(f), "after": core.get(f)}
            for f in before.keys() | core.keys()
            if before.get(f) != core.get(f)
        }
        output[scope] = {"results": after, "diffs": diffs, "old_s": old_s, "new_s": new_s}
    return output, missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument(
        "--current",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "src/movieclaw_playback/skip_segments.py",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    rows = {}
    for name in ("meta_zh_backup.json", "meta_other.json"):
        rows.update({r["id"]: r for r in json.loads((args.lab / name).read_text())})
    groups = defaultdict(list)
    for row in rows.values():
        groups[(row["item"], row["s"])].append(row)
    tasks = [(sorted(rs, key=lambda r: (r["e"] or 0, r["id"])), args.lab) for rs in groups.values()]
    totals, missing = {}, []
    started = time.perf_counter()
    with ProcessPoolExecutor(
        max_workers=args.workers, initializer=initialize, initargs=(args.baseline, args.current)
    ) as pool:
        for i, (output, absent) in enumerate(pool.map(work, tasks), 1):
            missing.extend(absent)
            for scope, data in output.items():
                total = totals.setdefault(
                    scope, {"results": {}, "diffs": {}, "old_s": 0, "new_s": 0}
                )
                for key in ("results", "diffs"):
                    total[key].update(data[key])
                for key in ("old_s", "new_s"):
                    total[key] += data[key]
            if i % 25 == 0:
                print(f"{i}/{len(tasks)} seasons, {time.perf_counter() - started:.0f}s", flush=True)
    args.output.mkdir(parents=True, exist_ok=True)
    summary = {
        "shows": len({r["item"] for r in rows.values()}),
        "seasons": len(groups),
        "missing": sorted(missing),
        "scopes": {},
        "sha256": {
            name: hashlib.sha256(path.read_bytes()).hexdigest()
            for name, path in (("baseline", args.baseline), ("current", args.current))
        },
    }
    for scope, total in totals.items():
        counts = Counter(s["type"] for segs in total["results"].values() for s in segs)
        summary["scopes"][scope] = {
            "files": len(total["results"]),
            "core_diffs": len(total["diffs"]),
            "segments": dict(counts),
            "leads": sum("lead_start_ms" in s for ss in total["results"].values() for s in ss),
            "baseline_seconds": round(total["old_s"], 2),
            "current_seconds": round(total["new_s"], 2),
        }
        (args.output / f"{scope}.json").write_text(json.dumps(total, ensure_ascii=False, indent=2))
    # 单独报告同版算法对输入顺序的敏感性，不与新旧版本回归混为一谈。
    full = totals["full"]["results"]
    reverse = totals["reversed"]["results"]
    summary["input_order_differences"] = [f for f in full if full[f] != reverse[f]]
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return int(
        bool(missing)
        or bool(summary["input_order_differences"])
        or any(t["diffs"] for scope, t in totals.items() if scope != "reversed")
    )


if __name__ == "__main__":
    raise SystemExit(main())

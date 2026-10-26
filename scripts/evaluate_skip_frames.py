"""只读实片画面评测：调用生产 _refine_episode，缓存和结果仅写到指定输出目录。

sample JSON 是一个列表，每项包含 id、path、size、dur、chinese、segments。
片源 path 为本机可读路径；不连接生产数据库，不重新提取音频指纹。
需 PYTHONPATH=src、ffmpeg 和生产 PP-OCR 模型。返回 None 可能是无变化或核对失败，
应同时检查日志及 frame_failures，不能把一次成功运行当成准确率标注。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import time
from pathlib import Path
from types import SimpleNamespace

from movieclaw_api.services.library import skip_segments as service


async def evaluate(args):
    samples = json.loads(args.sample.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    service.frames_path = lambda fid: args.output / f"{fid}.frames.json"
    engine = service._OcrPool(str(args.models))
    semaphore = asyncio.Semaphore(args.workers)
    results = []
    original_grab = service._grab_frame
    failures = {}
    failed_requests = {}

    async def grab(path, t, accurate, width=960):
        frame = await original_grab(path, t, accurate, width)
        if frame is None:
            failures[path] = failures.get(path, 0) + 1
            failed_requests.setdefault(path, []).append(
                {"requested": t, "accurate": accurate, "width": width}
            )
        return frame

    service._grab_frame = grab

    async def one(row):
        async with semaphore:
            start = time.perf_counter()
            path = Path(row["path"])
            before_stat = path.stat()
            assert before_stat.st_size == row["size"], f"片源已更换，需重新生成样本和指纹：{path}"
            file = SimpleNamespace(
                id=row["id"],
                file_path=str(path),
                size_bytes=before_stat.st_size,
                duration_seconds=row["dur"],
            )
            skipped_short = file.duration_seconds < service._MIN_FRAME_DURATION_S
            refined = None
            if not skipped_short:
                refined = await service._refine_episode(
                    file, row["segments"], engine, chinese=row["chinese"]
                )
            after_stat = path.stat()
            assert (before_stat.st_size, before_stat.st_mtime_ns) == (
                after_stat.st_size,
                after_stat.st_mtime_ns,
            ), f"片源在评测中发生变化：{path}"
            after = [
                {k: v for k, v in s.items() if k != "lead_start_ms"}
                for s in (refined if refined is not None else row["segments"])
            ]
            result = {
                **row,
                "source_size_bytes": before_stat.st_size,
                "source_mtime_ns": before_stat.st_mtime_ns,
                "after": after,
                "returned_none": refined is None,
                "skipped_short": skipped_short,
                "frame_failures": failures.get(str(path), 0),
                "failed_requests": failed_requests.get(str(path), []),
                "seconds": round(time.perf_counter() - start, 2),
            }
            results.append(result)
            (args.output / "results.json").write_text(
                json.dumps(sorted(results, key=lambda r: r["id"]), ensure_ascii=False, indent=2)
            )
            print(f"{len(results)}/{len(samples)} {row['id']} {row.get('title', '')}", flush=True)

    try:
        await asyncio.gather(*(one(row) for row in samples))
    finally:
        service._grab_frame = original_grab
        await engine.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sample", required=True, type=Path)
    parser.add_argument("--models", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    asyncio.run(evaluate(args))


if __name__ == "__main__":
    main()

"""给隔离测试库播种 iOS TorrentFiltersUITests 的三条资源快照。

用法：python tests/e2e/seed_torrent_filters.py sqlite+aiosqlite:////tmp/test/app.db
先启动测试后端、创建测试管理员，再运行本脚本；不连接 PT 站点。
"""

import asyncio
import json
import sys

from movieclaw_api.schemas.search import TorrentHit
from movieclaw_db.engine import Database
from movieclaw_db.repositories.search_history_repo import SearchHistoryRepository
from movieclaw_enrich import TorrentAttrs


async def seed(database_url: str) -> None:
    db = Database(database_url)
    try:
        items = []
        for index in range(3):
            alternate = index == 1
            items.append(TorrentHit(
                torrent_id=str(index + 1), title=f"筛选样本{index + 1}",
                site_id="s2" if alternate else "s1",
                site_name="测试站乙" if alternate else "测试站甲",
                seeders=[30, 20, 10][index], size_bytes=1_000_000,
                attrs=TorrentAttrs(
                    media_type="tv", titles_zh=["筛选回归"],
                    year=2023 if alternate else 2024,
                    seasons=[2] if alternate else [1], episodes=[2] if alternate else [1],
                    resolution="1080p" if alternate else "2160p",
                    media_source="Blu-ray" if alternate else "WEB-DL",
                    platforms=["amazon"] if alternate else ["netflix"],
                    video_codec="H.264" if alternate else "HEVC",
                    hdr=["DV"] if alternate else ["HDR10"],
                    audio=["AAC"] if alternate else ["DDP"],
                    subtitle_languages=["en"] if alternate else ["zh-Hans"],
                    release_group="GroupB" if alternate else "GroupA",
                ),
            ).model_dump(mode="json"))
        async with db.session() as session:
            repo = SearchHistoryRepository(session)
            history_id = await repo.record("筛选回归")
            await repo.save_snapshot(history_id, json.dumps({
                "total": 3, "elapsed_ms": 10, "items": items,
                "sites": [
                    {"site_id": "s1", "site_name": "测试站甲", "count": 2},
                    {"site_id": "s2", "site_name": "测试站乙", "count": 1},
                ],
            }))
            print(f"snapshot={history_id}")
    finally:
        await db.dispose()


if __name__ == "__main__":
    asyncio.run(seed(sys.argv[1]))

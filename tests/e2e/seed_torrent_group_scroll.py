"""给隔离测试库播种 iOS TorrentGroupScrollUITests 的「分组滚动」资源快照。

30 个作品（组大小 1～9 不等）+ 4 条未识别，结果足够长、组高矮悬殊，用来验证甩到底不被弹回。
用法：python tests/e2e/seed_torrent_group_scroll.py sqlite+aiosqlite:////tmp/test/app.db
先启动测试后端、创建测试管理员，再运行本脚本；不连接 PT 站点。
"""

import asyncio
import json
import sys

from movieclaw_api.schemas.search import TorrentHit
from movieclaw_db.engine import Database
from movieclaw_db.repositories.search_history_repo import SearchHistoryRepository
from movieclaw_enrich import TorrentAttrs

GROUP_SIZES = [1, 3, 6, 2, 9, 4, 1, 7, 2, 5]


async def seed(database_url: str) -> None:
    db = Database(database_url)
    try:
        items = []
        for group in range(30):
            tv = group % 2 == 0
            for row in range(GROUP_SIZES[group % len(GROUP_SIZES)]):
                items.append(TorrentHit(
                    torrent_id=str(len(items) + 1),
                    title=f"分组样本{group} S01E{row + 1:02d} 2160p WEB-DL HEVC-Group{row}",
                    site_id="s1", site_name="测试站甲",
                    seeders=1000 - len(items), size_bytes=1_000_000_000 * (row + 1),
                    attrs=TorrentAttrs(
                        media_type="tv" if tv else "movie",
                        titles_zh=[f"分组样本{group}"], titles_en=[f"Group Sample {group}"],
                        year=2020 + group % 5, resolution=["2160p", "1080p", "720p"][row % 3],
                        media_source="WEB-DL", video_codec="HEVC", release_group=f"Group{row}",
                        complete=tv and row == 0,
                    ),
                ).model_dump(mode="json"))
        for row in range(4):
            items.append(TorrentHit(
                torrent_id=str(len(items) + 1), title=f"未识别样本 {row}",
                site_id="s1", site_name="测试站甲", seeders=1, size_bytes=1000,
            ).model_dump(mode="json"))
        async with db.session() as session:
            repo = SearchHistoryRepository(session)
            history_id = await repo.record("分组滚动")
            await repo.save_snapshot(history_id, json.dumps({
                "total": len(items), "elapsed_ms": 10, "items": items,
                "sites": [{"site_id": "s1", "site_name": "测试站甲", "count": len(items)}],
            }))
            print(f"snapshot={history_id}")
    finally:
        await db.dispose()


if __name__ == "__main__":
    asyncio.run(seed(sys.argv[1]))

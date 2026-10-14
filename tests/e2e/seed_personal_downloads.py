"""给个人页的独立模拟器准备一个本机下载存档，用于管理动作验收。

先终止模拟器中的 App，再传 simctl get_app_container 返回的数据目录。
不会连接服务器；视频占位文件仅验证列表与删除，不用于播放。
加 --gallery 准备长标题、电影、剧集、暂停任务；大文件用稀疏文件，不实际占用数 GB。
"""

import hashlib
import json
import shutil
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

container = Path(sys.argv[1]).resolve()
if "CoreSimulator/Devices/" not in str(container) or not container.is_dir():
    raise SystemExit("只允许写入现有的 iOS 模拟器 App 数据目录")
stamp = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
instance = "personal-space-fixture"
key = hashlib.sha256(f"{instance}|admin".encode()).digest()[:16].hex()
owner = container / "Library/Application Support/Offline" / key
# 只重建夹具账号的存档，避免上一轮多条数据干扰单条删除测试。
if (owner / "items").exists():
    shutil.rmtree(owner / "items")
unit = owner / "items/9001/units/90011"
unit.mkdir(parents=True, exist_ok=True)


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False))


write(
    owner / "owner.json",
    dict(format=1, instanceId=instance, username="admin", origin="http://127.0.0.1:18842"),
)
write(
    owner / "items/9001/summary.json",
    dict(
        format=1,
        mediaItemId=9001,
        libraryId=1,
        libraryName="测试电影库",
        libraryKind="movie",
        kind="movie",
        title="测试离线电影",
        primaryAspect=0.67,
        addedAt=stamp,
    ),
)
write(
    unit / "unit.json",
    dict(
        format=1,
        fileId=90011,
        mediaItemId=9001,
        season=0,
        episode=0,
        profile="original",
        profileLabel="原画",
        state="done",
        expectedBytes=4096,
        receivedBytes=4096,
        fileExtension="mp4",
        retryable=True,
        attempts=0,
        createdAt=stamp,
        completedAt=stamp,
        damaged=False,
    ),
)
(unit / "media.mp4").write_bytes(bytes(4096))
print("已准备模拟器本机下载：测试离线电影")

if "--gallery" in sys.argv:
    samples = [
        (9001, "星际穿越", "movie", "原画 · 4K", 12_600_000_000, "done"),
        (9002, "奥本海默", "movie", "1080p", 3_200_000_000, "done"),
        (
            9003,
            "碟中谍：致命清算（上）与漫长的最终任务",
            "movie",
            "原画 · 4K",
            8_400_000_000,
            "done",
        ),
        (9004, "漫长的季节", "tv", "1080p", 1_200_000_000, "done"),
        (9005, "人生切割术", "tv", "1080p", 400_000_000, "paused"),
    ]
    for item_id, title, kind, profile_label, size, state in samples:
        item_dir = owner / "items" / str(item_id)
        unit_dir = item_dir / "units" / str(item_id * 10 + 1)
        unit_dir.mkdir(parents=True, exist_ok=True)
        write(
            item_dir / "summary.json",
            dict(
                format=1,
                mediaItemId=item_id,
                libraryId=1,
                libraryName="测试媒体库",
                libraryKind=kind,
                kind=kind,
                title=title,
                primaryAspect=2 / 3,
                posterUrl=f"/e2e/poster/{item_id}.jpg",
                addedAt=(datetime.now(UTC) - timedelta(minutes=item_id)).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                ),
            ),
        )
        write(
            unit_dir / "unit.json",
            dict(
                format=1,
                fileId=item_id * 10 + 1,
                mediaItemId=item_id,
                season=1 if kind == "tv" else 0,
                episode=1 if kind == "tv" else 0,
                profile="original",
                profileLabel=profile_label,
                state=state,
                expectedBytes=size if state == "done" else size * 3,
                receivedBytes=size,
                fileExtension="mp4",
                retryable=True,
                attempts=0,
                createdAt=stamp,
                completedAt=stamp if state == "done" else None,
                damaged=False,
            ),
        )
        if state == "done":
            with (unit_dir / "media.mp4").open("wb") as media:
                media.truncate(size)
    print(
        "已准备 4 部已下载与 1 个暂停任务；"
        "海报可放到 work/personal-space/fixtures/9001.jpg、9002.jpg"
    )

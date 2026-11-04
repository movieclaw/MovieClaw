"""播出日历（issue #547）端到端验收用的隔离测试服务器：iPhone、Mac、Apple TV、Android TV 连同一台。

全新数据库 + 假 TMDB（播出日期按今天现算，所以随时跑都是「今天更新」），后端跑当前工作区的代码。
不生成片子：分集是真的、文件只是库里的记录，能看日历、不能起播。

  .venv/bin/python apps/android-tv/tests/fixture/air_schedule_fixture.py start
  .venv/bin/python apps/android-tv/tests/fixture/air_schedule_fixture.py stop

默认目录 /tmp/mc-air-fixture，后端 8840、假 TMDB 8841（MC_ATV_FIXTURE / MC_ATV_PORT 可改）。
账号见 fixture.py。

库 1「剧集」里四部（条目 id 固定）：
1. 长街夜行：国产、24 集、每天两集，今天播第 13–14 集，已订阅、缺第 7 集，今天的预计入库时刻可信；
2. Harbor Lights：美国、周更、未订阅，下一集 3 天后（可以走一遍「订阅追更」）；
3. 旧城往事：已播完，没有日历；
4. 午夜长河：两季，第 2 季 120 集（长季分段）、每天一集，今天播第 61 集，已订阅、没有缺集。
"""

from __future__ import annotations

import asyncio
import copy
import json
import os
import sys
from datetime import date, timedelta
from pathlib import Path

os.environ.setdefault("MC_ATV_FIXTURE", "/tmp/mc-air-fixture")
os.environ.setdefault("MC_ATV_PORT", "8840")

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import fixture as base  # noqa: E402

CATALOG_OUT = base.FIX / "tmdb_catalog.json"

#: 借假 TMDB 目录里现成的条目（海报、演职员都有），名字和分集按这里改写
NIGHT = 99200001
HARBOR = 99200002
OLD = 99200003
RIVER = 99200005


def _episode(show: int, season: int, number: int, aired: date | None, title: str) -> dict:
    return {
        "air_date": aired.isoformat() if aired else None,
        "crew": [],
        "episode_number": number,
        "episode_type": "standard",
        "guest_stars": [],
        "id": show * 1000 + season * 100 + number,
        "name": f"第 {number} 集「{title}」",
        "overview": f"《{title}》第 {season} 季第 {number} 集。（虚构条目 · 模拟 TMDB）",
        "production_code": "",
        "runtime": 45,
        "season_number": season,
        "show_id": show,
        "still_path": f"/mc{show}s{season}e{number}.jpg",
        "vote_average": 8.1,
        "vote_count": 12,
    }


def _shows(today: date) -> dict[int, dict]:
    """每部剧：名字、产地、状态、各季每集的播出日（都相对今天算）"""
    return {
        NIGHT: {
            "name": "长街夜行",
            "origin": ["CN"],
            "status": "Returning Series",
            "seasons": {1: {n: today + timedelta(days=(n - 1) // 2 - 6) for n in range(1, 25)}},
        },
        HARBOR: {
            "name": "Harbor Lights",
            "origin": ["US"],
            "status": "Returning Series",
            "seasons": {1: {n: today + timedelta(days=(n - 5) * 7 + 3) for n in range(1, 9)}},
        },
        OLD: {
            "name": "旧城往事",
            "origin": ["CN"],
            "status": "Ended",
            "seasons": {1: {n: today - timedelta(days=(11 - n) * 7 + 30) for n in range(1, 11)}},
        },
        RIVER: {
            "name": "午夜长河",
            "origin": ["CN"],
            "status": "Returning Series",
            "seasons": {
                1: {n: today - timedelta(days=(12 - n) * 7 + 200) for n in range(1, 13)},
                2: {n: today + timedelta(days=n - 61) for n in range(1, 121)},
            },
        },
    }


def _write_catalog(today: date) -> None:
    """假 TMDB 的目录：这几部的播出日期按今天改写，订阅建档时读到的和库里的是同一份"""
    catalog = copy.deepcopy(base.CATALOG)
    for show, spec in _shows(today).items():
        entry = catalog[f"tv/{show}"]
        entry.update(
            name=spec["name"],
            original_name=spec["name"],
            status=spec["status"],
            origin_country=spec["origin"],
        )
        entry["number_of_seasons"] = len(spec["seasons"])
        entry["number_of_episodes"] = sum(len(s) for s in spec["seasons"].values())
        entry["seasons"] = []
        for season, episodes in spec["seasons"].items():
            first = min(episodes.values())
            entry["seasons"].append(
                {
                    "air_date": first.isoformat(),
                    "episode_count": len(episodes),
                    "id": show * 100 + season,
                    "name": f"第 {season} 季",
                    "overview": "",
                    "poster_path": f"/mc{show}p.jpg",
                    "season_number": season,
                    "vote_average": 8.1,
                }
            )
            catalog[f"tv/{show}/season/{season}"] = {
                "_id": f"mc{show}s{season}",
                "air_date": first.isoformat(),
                "episodes": [
                    _episode(show, season, n, aired, spec["name"]) for n, aired in episodes.items()
                ],
                "id": show * 100 + season,
                "name": f"第 {season} 季",
                "overview": "",
                "poster_path": f"/mc{show}p.jpg",
                "season_number": season,
            }
    CATALOG_OUT.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")


async def _seed_library(library_id: int, today: date) -> dict[str, int]:
    """把四部剧写进库：条目、分集、文件记录，再给 1、4 建订阅（工单同订阅建好时的样子）"""
    sys.path.insert(0, str(base.ROOT / "src"))
    from movieclaw_db.engine import dispose_db, get_database, init_db
    from movieclaw_db.models import (
        LibraryFile,
        MediaEpisode,
        MediaItem,
        MediaMetadata,
        MediaSeason,
        RuleSet,
        Subscription,
        WantedItem,
        WantedStatus,
        utcnow,
    )

    root = base.MEDIA / "tv"
    init_db(f"sqlite+aiosqlite:///{base.DATA}/movieclaw.db", echo=False)
    owned_map = {
        NIGHT: {1: {n for n in range(1, 13) if n != 7}},
        HARBOR: {1: {1, 2, 3, 4}},
        OLD: {1: set(range(1, 11))},
        RIVER: {1: set(range(1, 13)), 2: set(range(1, 61))},
    }
    ids: dict[str, int] = {}
    shows = _shows(today)
    predicted = (utcnow() + timedelta(hours=1)).isoformat() + "+00:00"
    async with get_database().session() as session:
        for show, spec in shows.items():
            item = MediaItem(
                kind="tv",
                tmdb_id=show,
                title=spec["name"],
                original_title=spec["name"],
                status=spec["status"],
                year=min(min(e.values()) for e in spec["seasons"].values()).year,
                poster_path=f"/mc{show}p.jpg",
                backdrop_path=f"/mc{show}b.jpg",
                # 档案是新鲜的：打开详情页不刷新（一刷新，没有站点观测的「预计入库」就被重算清空了）
                metadata_refreshed_at=utcnow(),
                next_refresh_at=utcnow() + timedelta(days=30),
            )
            session.add(item)
            await session.flush()
            ids[spec["name"]] = item.id
            session.add(
                MediaMetadata(
                    media_item_id=item.id,
                    origin_countries=spec["origin"],
                    overview=f"《{spec['name']}》是一部用来验收播出日历的虚构剧集。",
                    genres=["剧情", "悬疑"],
                    runtime_minutes=45,
                    scraped_at=utcnow(),
                    # 分集下面有一行演职员：验收页面往下翻得动
                    cast=[
                        {"name": actor["name"], "character": actor["character"]}
                        for actor in base.CATALOG[f"tv/{show}"]["credits"]["cast"]
                    ],
                )
            )
            for season, episodes in spec["seasons"].items():
                session.add(
                    MediaSeason(
                        media_item_id=item.id,
                        season_number=season,
                        name=f"第 {season} 季",
                        episode_count=len(episodes),
                        air_date=min(episodes.values()),
                    )
                )
                for number, aired in episodes.items():
                    named = aired <= today + timedelta(days=2)
                    session.add(
                        MediaEpisode(
                            media_item_id=item.id,
                            season_number=season,
                            episode_number=number,
                            air_date=aired,
                            name=f"第 {number} 集「{spec['name']}」" if named else "",
                            overview=f"《{spec['name']}》第 {season} 季第 {number} 集。"
                            if named
                            else None,
                            still_path=f"/mc{show}s{season}e{number}.jpg"
                            if aired < today
                            else None,
                            runtime_minutes=45,
                        )
                    )
                for number in owned_map[show].get(season, ()):
                    session.add(
                        LibraryFile(
                            library_id=library_id,
                            media_item_id=item.id,
                            season_number=season,
                            episode_number=number,
                            file_path=str(root / spec["name"] / f"S{season:02d}E{number:02d}.mkv"),
                            size_bytes=1,
                            source="scanned",
                        )
                    )
        rule_set = RuleSet(name="默认", spec={})
        session.add(rule_set)
        await session.flush()

        async def subscribe(show: int, season: int) -> None:
            spec = shows[show]
            sub = Subscription(media_item_id=ids[spec["name"]], kind="tv", rule_set_id=rule_set.id)
            session.add(sub)
            await session.flush()
            owned = owned_map[show][season]
            for number, aired in spec["seasons"][season].items():
                if number in owned:
                    continue
                forecast = (
                    {"predicted_at": predicted, "confidence": "stable"} if aired == today else None
                )
                session.add(
                    WantedItem(
                        subscription_id=sub.id,
                        media_item_id=ids[spec["name"]],
                        season_number=season,
                        episode_number=number,
                        status=WantedStatus.WANTED,
                        air_date=aired,
                        release_forecast=forecast,
                        # 已播的缺口排着下一轮搜索，「补缺集」才有东西可重排
                        next_search_at=utcnow() + timedelta(hours=6) if aired < today else None,
                    )
                )

        await subscribe(NIGHT, 1)
        await subscribe(RIVER, 2)
        await session.commit()
    await dispose_db()
    return ids


def start() -> int:
    if base.healthy():
        print(f"已在运行：{base.BASE}")
        return 0
    base.FIX.mkdir(parents=True, exist_ok=True)
    base.DATA.mkdir(parents=True, exist_ok=True)
    (base.MEDIA / "tv").mkdir(parents=True, exist_ok=True)
    env = base.server_env()
    sys.path.insert(0, str(base.ROOT / "src"))
    from movieclaw_api.services.library.air_schedule import site_today

    today = site_today()
    _write_catalog(today)
    tmdb = base._spawn(
        "tmdb",
        [sys.executable, str(HERE / "tmdb_mock.py"), "--port", str(base.TMDB_PORT)],
        env={**os.environ, "MC_TMDB_CATALOG": str(CATALOG_OUT)},
    )
    base._wait(f"http://127.0.0.1:{base.TMDB_PORT}/health", tmdb, "tmdb")
    server = base._spawn(
        "server",
        [
            sys.executable, "-m", "uvicorn", "movieclaw_api.app:create_app", "--factory",
            "--host", "0.0.0.0", "--port", str(base.PORT),
        ],
        env=env,
    )  # fmt: skip
    base._wait(base.BASE + "/health", server, "server")

    admin = base.Client()
    admin.call("POST", "/auth/bootstrap", base.ADMIN)
    admin.call("POST", "/members", base.MEMBER)
    library = admin.call(
        "POST", "/libraries", {"name": "剧集", "kind": "tv", "root_paths": [str(base.MEDIA / "tv")]}
    )
    # 智能设置保存过，「订阅追更」才走得通（首次使用的情况单测里有）
    admin.call(
        "PUT",
        "/subscriptions/smart-defaults",
        {
            "movie_revision": 0, "tv_revision": 0, "resolution": "2160p", "source": "web-dl",
            "movie_wait_seconds": 86400, "tv_wait_seconds": 10800,
        },
    )  # fmt: skip
    ids = asyncio.run(_seed_library(library["id"], today))
    print(
        f"就绪：{base.BASE}（Android 模拟器用 http://10.0.2.2:{base.PORT}），"
        f"账号 admin / xiaoyu，密码 {base.PASSWORD}"
    )
    print(f"库 {library['id']}，条目 {ids}")
    return 0


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "start":
        return start()
    if command == "stop":
        return base.stop()
    print("运行中" if base.healthy() else "未运行")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

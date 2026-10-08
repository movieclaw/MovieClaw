"""把测试服务器的首页灌成真实用户的规模，给首页滑动压测用（docs/perf/androidtv-home-scroll-2026-10.md）。

在 fixture.py start 之后跑：假 TMDB 目录里的电影、剧集全部入库（26 部电影、16 部剧），
admin 有 15 张「接下来继续」、12 个收藏，首页 13 行（含按评分、上映、随便看看等自加行）。
可重复执行。

  .venv/bin/python apps/android-tv/tests/perf/seed_home.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fixture"))
import fixture as fx  # noqa: E402


def place_all() -> tuple[int, int]:
    movies = [k.split("/")[1] for k in fx.CATALOG if k.startswith("movie/") and k.split("/")[1].isdigit()]
    for mid in movies:
        movie = fx.CATALOG[f"movie/{mid}"]
        name = f"{movie['title']} ({movie['release_date'][:4]})"
        folder = fx.MEDIA / "movies" / f"{name} [tmdbid={mid}]"
        # 编码矩阵那几部已经放了别的扩展名的片子，不重复放
        if not folder.exists():
            _link(folder / f"{name}.mkv")
    series = sorted({k.split("/")[1] for k in fx.CATALOG if "/season/" in k})
    for tid in series:
        show = fx.CATALOG[f"tv/{tid}"]
        folder = fx.MEDIA / "tv" / f"{show['name']} ({show['first_air_date'][:4]}) [tmdbid={tid}]"
        for key in [k for k in fx.CATALOG if k.startswith(f"tv/{tid}/season/")]:
            season = int(key.rsplit("/", 1)[1])
            for ep in fx.CATALOG[key]["episodes"]:
                _link(folder / f"Season {season:02d}" / f"{show['name']} S{season:02d}E{ep['episode_number']:02d}.mkv")
    return len(movies), len(series)


def _link(target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        target.hardlink_to(fx.CLIPS / "long.mkv")
    old = fx.time.time() - 3600
    fx.os.utime(target, (old, old))


def main() -> int:
    movies, series = place_all()
    admin = fx.Client()
    admin.call("POST", "/auth/login", fx.ADMIN)
    libs = {lib["name"]: lib for lib in admin.call("GET", "/libraries?scope=all")}
    for name, expected in (("电影", movies), ("剧集", series)):
        admin.call("POST", f"/libraries/{libs[name]['id']}/scan")
        items = fx._wait_items(admin, libs[name]["id"], expected, f"「{name}」")
        print(f"「{name}」{len(items)} 条")
    films = admin.call("GET", f"/libraries/{libs['电影']['id']}/items")
    shows = admin.call("GET", f"/libraries/{libs['剧集']['id']}/items")

    device = "fixture-perf-0001"
    for i, item in enumerate(films[:10]):
        body = {"media_item_id": item["media_item_id"], "event": "stop", "position_ms": 60_000 + i * 15_000}
        admin.call("POST", "/playback/progress", {"device_id": device, **body})
    for item in shows[:5]:
        body = {"media_item_id": item["media_item_id"], "season_number": 1, "episode_number": 1, "event": "stop", "position_ms": 120_000}
        admin.call("POST", "/playback/progress", {"device_id": device, **body})
    for item in films[10:20] + shows[5:7]:
        admin.call("POST", "/playback/marks", {"media_item_id": item["media_item_id"], "favorite": True})

    prefs = admin.call("GET", "/ui/preferences")
    lib_rows = [{"id": f"lib:{lib['id']}"} for lib in libs.values()]
    prefs["home"] = {
        "rows": [
            {"id": "up-next"},
            {"id": "favorites"},
            {"id": "row:movie-rating", "media_kind": "movie", "sort": "rating"},
            {"id": "libraries"},
            {"id": "genres:movie"},
            {"id": "row:movie-release", "media_kind": "movie", "sort": "release_date"},
            {"id": "row:tv-added", "media_kind": "tv"},
            {"id": "genres:tv"},
            {"id": "row:movie-random", "media_kind": "movie", "sort": "random"},
            {"id": "row:tv-rating", "media_kind": "tv", "sort": "rating"},
            {"id": "row:movie-title", "media_kind": "movie", "sort": "title"},
            *lib_rows,
        ]
    }
    admin.call("PUT", "/ui/preferences", prefs)
    up_next = admin.call("GET", "/playback/up-next?limit=20")
    print(f"首页 {len(prefs['home']['rows'])} 行；接下来继续 {len(up_next['items'])} 张")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

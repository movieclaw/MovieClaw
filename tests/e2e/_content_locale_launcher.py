"""内容语言端到端的后端启动器（由 test_content_locale_e2e.py 以子进程拉起）。

与生产入口同一 ``create_app``，只替换外部依赖：

- TMDB 指到本进程线程里的**按 language 参数作答**的假服务：同一部剧中文请求给中文、
  英文请求给英文，translations 里中英两份都有——与真实 TMDB 的形态一致；
- 豆瓣指到同一个假服务的 /douban 前缀（只给《沙丘》一条中文详情）；
- PT 站点换成假实现，每次搜索的关键词记下来（``GET /__lab/search-log``）；
- 媒体探测给固定规格（假视频只有几个字节，ffprobe 读不出东西）；
- 「文件写入中」的静默窗口调成 0。
"""

from __future__ import annotations

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

for _var in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
    os.environ.pop(_var, None)

_LOG = Path(os.environ["E2E_TMDB_LOG"])
_LOCK = threading.Lock()


def _zh(language: str) -> bool:
    return language.startswith("zh")


def _severance(language: str) -> dict:
    zh = _zh(language)
    return {
        "id": 95396,
        "name": "人生切割术" if zh else "Severance",
        "original_name": "Severance",
        "original_language": "en",
        "first_air_date": "2022-02-17",
        "overview": "马克领导着一个团队。" if zh else "Mark leads a team of office workers.",
        "status": "Returning Series",
        "vote_average": 8.4,
        "poster_path": "/severance.jpg",
        "backdrop_path": "/severance-backdrop.jpg",
        "genre_ids": [18, 9648],
        "genres": [
            {"id": 18, "name": "剧情" if zh else "Drama"},
            {"id": 9648, "name": "悬疑" if zh else "Mystery"},
        ],
        "origin_country": ["US"],
        "production_countries": [{"iso_3166_1": "US"}],
        "seasons": [{"season_number": 1}],
        "networks": [{"name": "Apple TV+"}],
        "external_ids": {},
        "alternative_titles": {"results": []},
        "content_ratings": {"results": []},
        "credits": {
            "cast": [
                {
                    "id": 1001,
                    "name": "亚当·斯科特" if zh else "Adam Scott",
                    "original_name": "Adam Scott",
                    "character": "Mark",
                    "order": 0,
                    "known_for_department": "Acting",
                }
            ],
            "crew": [],
        },
        # 中文片名 Logo：库语言是中文，刮削挑中的就是它
        "images": {
            "backdrops": [],
            "posters": [],
            "logos": [
                {
                    "file_path": "/severance-logo-zh.png",
                    "iso_639_1": "zh",
                    "width": 800,
                    "height": 300,
                    "vote_average": 5,
                    "vote_count": 3,
                }
            ],
        },
        "recommendations": {"results": []},
        "videos": {
            "results": [
                {
                    "key": "trailer-key",
                    "name": "",
                    "site": "YouTube",
                    "type": "Trailer",
                    "official": True,
                    "published_at": "2022-01-01",
                }
            ]
        },
        "translations": {
            "translations": [
                {
                    "iso_639_1": "en",
                    "iso_3166_1": "US",
                    "data": {"name": "", "overview": "Mark leads a team of office workers."},
                },
                {
                    "iso_639_1": "zh",
                    "iso_3166_1": "CN",
                    "data": {"name": "人生切割术", "overview": "马克领导着一个团队。"},
                },
            ]
        },
    }


def _season(language: str) -> dict:
    zh = _zh(language)
    return {
        "name": "第 1 季" if zh else "Season 1",
        "air_date": "2022-02-17",
        "episodes": [
            {
                "episode_number": 1,
                "name": "好消息" if zh else "Good News About Hell",
                "air_date": "2022-02-17",
            },
            {
                "episode_number": 2,
                "name": "一半一半" if zh else "Half Loop",
                "air_date": "2022-02-18",
            },
        ],
    }


def _hero(language: str) -> dict:
    """华语片（原声语言 zh），给主语言是英文的库用。"""
    zh = _zh(language)
    return {
        "id": 79,
        "title": "英雄" if zh else "Hero",
        "original_title": "英雄",
        "original_language": "zh",
        "release_date": "2002-12-19",
        "overview": "战国末期，刺客无名……" if zh else "In ancient China, a nameless warrior...",
        "status": "Released",
        "poster_path": "/hero.jpg",
        "genres": [{"id": 28, "name": "动作" if zh else "Action"}],
        "production_countries": [{"iso_3166_1": "CN"}],
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "release_dates": {"results": []},
        "credits": {"cast": [], "crew": []},
        "images": {"backdrops": [], "posters": [], "logos": []},
        "translations": {
            "translations": [
                {
                    "iso_639_1": "en",
                    "iso_3166_1": "US",
                    "data": {
                        "title": "Hero",
                        "overview": "In ancient China, a nameless warrior...",
                    },
                },
                {
                    "iso_639_1": "zh",
                    "iso_3166_1": "CN",
                    "data": {"title": "", "overview": "战国末期，刺客无名……"},
                },
            ]
        },
    }


def _dune(language: str) -> dict:
    """原名不是中文的外语片：豆瓣中文名只能跟 TMDB 的中文译名对上。"""
    zh = _zh(language)
    return {
        "id": 438631,
        "title": "沙丘" if zh else "Dune",
        "original_title": "Dune",
        "original_language": "en",
        "release_date": "2021-09-15",
        "overview": "保罗·厄崔迪……" if zh else "Paul Atreides...",
        "status": "Released",
        "poster_path": "/dune.jpg",
        "genres": [{"id": 28, "name": "动作" if zh else "Action"}],
        "production_countries": [{"iso_3166_1": "US"}],
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "release_dates": {"results": []},
        "credits": {"cast": [], "crew": []},
        "images": {"backdrops": [], "posters": [], "logos": []},
        "translations": {
            "translations": [
                {
                    "iso_639_1": "en",
                    "iso_3166_1": "US",
                    "data": {"title": "Dune", "overview": "Paul Atreides..."},
                },
                {
                    "iso_639_1": "zh",
                    "iso_3166_1": "CN",
                    "data": {"title": "沙丘", "overview": "保罗·厄崔迪……"},
                },
            ]
        },
    }


_DOUBAN = {
    "/douban/movie/35": {
        "id": "35",
        "title": "沙丘",
        "type": "movie",
        "year": "2021",
        "cover_url": "https://img.example/dune.jpg",
        "aka": [],
        "pubdate": ["2021-09-15"],
        "genres": ["科幻"],
        "countries": ["美国"],
    },
    "/douban/movie/35/celebrities": {},
}


def _genres(language: str) -> dict:
    zh = _zh(language)
    return {
        "genres": [
            {"id": 18, "name": "剧情" if zh else "Drama"},
            {"id": 9648, "name": "悬疑" if zh else "Mystery"},
            {"id": 28, "name": "动作" if zh else "Action"},
        ]
    }


def _route(path: str, query: dict[str, list[str]]) -> dict | None:
    language = query.get("language", ["en-US"])[0]
    text = query.get("query", [""])[0]
    if path == "/3/tv/95396":
        return _severance(language)
    if path == "/3/tv/95396/season/1":
        return _season(language)
    if path == "/3/movie/79":
        return _hero(language)
    if path == "/3/movie/438631":
        return _dune(language)
    if path in _DOUBAN:
        return _DOUBAN[path]
    if path in ("/3/genre/tv/list", "/3/genre/movie/list"):
        return _genres(language)
    if path == "/3/search/tv":
        hit = "Severance" in text or "人生切割术" in text
        return {"results": [_severance(language)] if hit else []}
    if path == "/3/search/movie":
        if "Dune" in text or "沙丘" in text:
            return {"results": [_dune(language)]}
        hit = "Hero" in text or "英雄" in text
        return {"results": [_hero(language)] if hit else []}
    if path == "/3/search/multi":
        return {"results": [{**_severance(language), "media_type": "tv"}]}
    if path.startswith(("/3/tv/", "/3/trending/tv", "/3/discover/tv")):
        return {
            "page": 1,
            "total_pages": 1,
            "total_results": 4,
            "results": [{**_severance(language), "id": 95396 + i} for i in range(4)],
        }
    if path.startswith(("/3/movie/", "/3/trending/movie", "/3/discover/movie")):
        return {
            "page": 1,
            "total_pages": 1,
            "total_results": 4,
            "results": [{**_hero(language), "id": 79 + i} for i in range(4)],
        }
    return None


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        language = query.get("language", [""])[0]
        with _LOCK, _LOG.open("a", encoding="utf-8") as fh:
            fh.write(f"{parsed.path} {language}\n")
        payload = _route(parsed.path, query)
        body = json.dumps(payload or {}).encode("utf-8")
        self.send_response(200 if payload is not None else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


_server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
threading.Thread(target=_server.serve_forever, daemon=True).start()
_port = _server.server_address[1]
os.environ["TMDB_API_KEY"] = "e2e-fake-key"
os.environ["TMDB_API_BASE_URL"] = f"http://127.0.0.1:{_port}/3"
os.environ["TMDB_IMAGE_BASE_URL"] = f"http://127.0.0.1:{_port}/t/p"
os.environ["DOUBAN_API_BASE_URL"] = f"http://127.0.0.1:{_port}/douban"

import uvicorn  # noqa: E402

import movieclaw_api.services.library.ingest as ingest_mod  # noqa: E402
import movieclaw_api.services.library.scan as scan_mod  # noqa: E402
from movieclaw_api.services.media_probe import MediaSpec  # noqa: E402

_SPEC = MediaSpec("1080p", "h264", None, 8, 3600, None)
ingest_mod.QUIET_SECONDS = 0
scan_mod.NEW_FILE_QUIET_SECONDS = 0
scan_mod.probe_media = lambda _path: _SPEC
ingest_mod.probe_media = lambda _path: _SPEC

import movieclaw_api.services.site_search as site_search  # noqa: E402
from movieclaw_api.app import create_app  # noqa: E402
from movieclaw_tracker.models import SearchResult  # noqa: E402

search_log: list[str] = []


class _Cred:
    site_id = "fixture"
    protected = False


class _FakeSite:
    async def search(self, query):
        search_log.append(query.keyword)
        return SearchResult(items=[], page=query.page, total_pages=1, has_more=False)


class _FakeAccess:
    async def get(self, _site_id):
        return _FakeSite()


async def _active_sites():
    return [_Cred()]


site_search._active_sites = _active_sites
site_search.get_site_access = _FakeAccess

app = create_app()


@app.get("/__lab/search-log")
async def get_search_log():
    return search_log


if __name__ == "__main__":
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=int(os.environ["APP_PORT"]),
        log_config=None,
        access_log=False,
    )

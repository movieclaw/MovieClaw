"""手动下载 e2e 专用的后端启动器（由 test_manual_download_identity_browser.py 以子进程拉起）。

与生产入口同一 ``create_app``，只替换三个外部依赖（沙箱没有外网、PT 站点与下载器）：

- TMDB 指到本地假服务：一部国产剧《繁花》(tv 500, 首播 2023, 产地 CN) 与一部同名
  干扰电影《繁花似锦》(movie 501)；按种子标题（拼音）检索一律零结果——正是乱码命名
  种子的真实处境，只有用户的搜索词「繁花」能在 multi 搜索里找到它；
- 站点访问管理器换成假实现：取种直接返回 download_url 的字节；
- 下载器适配器换成假实现：提交记进 ``E2E_DL_LOG``（JSONL，测试据此断言保存目录），
  ``list_torrents`` 把提交过的种子报告为已完成——监听导入据此按条目名反查 infohash。

另外把"文件写入中"的静默窗口调成 0（同 _api_launcher.py），并去掉代理环境变量。
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

# —— 假 TMDB ——————————————————————————————————————————————

_TV_500 = {
    "id": 500,
    "name": "繁花",
    "original_name": "繁花",
    "first_air_date": "2023-12-27",
    "overview": "一部用于端到端验收的假剧集。",
    "status": "Ended",
    "origin_country": ["CN"],
    "genres": [{"id": 18, "name": "剧情"}],
    "external_ids": {},
    "alternative_titles": {"results": []},
    "translations": {"translations": []},
    "seasons": [{"season_number": 1}],
    "poster_path": "/fanhua.jpg",
}
_MOVIE_501 = {
    "id": 501,
    "title": "繁花似锦",
    "original_title": "繁花似锦",
    "release_date": "2021-01-01",
    "runtime": 100,
    "overview": "同名干扰项。",
    "status": "Released",
    "production_countries": [{"iso_3166_1": "CN"}],
    "genres": [{"id": 10749, "name": "爱情"}],
    "external_ids": {},
    "alternative_titles": {"titles": []},
    "translations": {"translations": []},
    "poster_path": "/fhsj.jpg",
}
ROUTES: dict[str, dict] = {
    "/3/tv/500": _TV_500,
    "/3/tv/500/season/1": {
        "name": "第 1 季",
        "air_date": "2023-12-27",
        "episodes": [
            {"episode_number": n, "name": f"第 {n} 集", "air_date": "2023-12-27"} for n in (1, 2, 3)
        ],
    },
    "/3/movie/501": _MOVIE_501,
}


def _multi(query: str) -> list[dict]:
    """multi 搜索：只有中文片名「繁花」召回（剧在前、同名电影在后）。"""
    if "繁花" not in query:
        return []
    return [
        {**_TV_500, "media_type": "tv", "vote_average": 8.5},
        {**_MOVIE_501, "media_type": "movie", "vote_average": 6.0},
    ]


def _search(kind: str, query: str) -> list[dict]:
    """分类型搜索：按中文名能搜到（监听导入等链路会用），拼音种子名一律零结果。"""
    if "繁花" not in query:
        return []
    return [_TV_500] if kind == "tv" else [_MOVIE_501]


def _serve_tmdb() -> int:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args) -> None:
            return

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query).get("query", [""])[0]
            if parsed.path == "/3/search/multi":
                payload: dict | None = {"results": _multi(query)}
            elif parsed.path in ("/3/search/movie", "/3/search/tv"):
                payload = {"results": _search(parsed.path.rsplit("/", 1)[1], query)}
            else:
                payload = ROUTES.get(parsed.path)
            body = json.dumps(payload or {}).encode("utf-8")
            self.send_response(200 if payload is not None else 404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


_tmdb_port = _serve_tmdb()
os.environ["TMDB_API_KEY"] = "e2e-fake-key"
os.environ["TMDB_API_BASE_URL"] = f"http://127.0.0.1:{_tmdb_port}/3"

import uvicorn  # noqa: E402

import movieclaw_api.services.acquisition_ingest as acquisition_ingest_mod  # noqa: E402
import movieclaw_api.services.downloader_config as downloader_config_mod  # noqa: E402
import movieclaw_api.services.library.ingest as ingest_mod  # noqa: E402
import movieclaw_api.services.library.scan as scan_mod  # noqa: E402
import movieclaw_api.services.torrent_submit as torrent_submit_mod  # noqa: E402
from movieclaw_downloader import DownloaderInfo  # noqa: E402
from movieclaw_downloader.base import BaseDownloader  # noqa: E402
from movieclaw_downloader.models import (  # noqa: E402
    DownloaderLimits,
    DownloadRequest,
    SubmitResult,
    TorrentBrief,
)

ingest_mod.QUIET_SECONDS = 0
# 下载器概览短缓存：建规则时补扫拿到的空列表（种子还没提交）别被提交后的那次巡检复用，
# 否则条目被投递台账判成「还在下载」挂起 5 分钟（真实环境里最多晚一轮轮询，测试等不起）
acquisition_ingest_mod._BRIEFS_TTL_SECONDS = 0
# 假字节视频：本机装了 ffprobe 时入库前终检会判它损坏；按「没装 ffprobe」放行
ingest_mod.ffprobe_available = lambda: False
scan_mod.NEW_FILE_QUIET_SECONDS = 0

_DL_LOG = Path(os.environ["E2E_DL_LOG"])
# 任务名 = 种子名（拼音乱码）：监听目录里的条目名就是它，识别只能靠身份锚
TORRENT_NAME = "Fan.Hua.S01.2160p.WEB-DL.H265-XYZ"
INFO_HASH = "b" * 40
_submitted: list[str] = []


class _FakeSite:
    async def download_torrent(self, url: str) -> bytes:
        return url.encode()


class _FakeSiteAccess:
    async def get(self, site_id: str) -> _FakeSite:
        return _FakeSite()


class _FakeDownloader(BaseDownloader):
    """假下载器：提交即"下完"，供监听导入按名称反查 infohash。"""

    def __init__(self, config) -> None:
        self.config = config

    async def submit(self, request: DownloadRequest) -> SubmitResult:
        with _DL_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"save_path": request.save_path, "tags": request.tags}) + "\n")
        _submitted.append(INFO_HASH)
        return SubmitResult(info_hash=INFO_HASH, name=TORRENT_NAME, already_exists=False)

    async def get_torrent(self, info_hash: str, *args, **kwargs):
        return None

    async def list_torrents(self) -> list[TorrentBrief]:
        return [
            TorrentBrief(name=TORRENT_NAME, content_name=TORRENT_NAME, completed=True, info_hash=h)
            for h in dict.fromkeys(_submitted)
        ]

    async def delete_torrent(self, info_hash: str, *, delete_files: bool = False) -> None:
        return None

    async def set_location(self, info_hash: str, save_path: str) -> None:
        return None

    async def set_file_selection(self, info_hash: str, selected_indices: list[int]) -> None:
        return None

    async def resume(self, info_hash: str) -> None:
        return None

    async def get_limits(self) -> DownloaderLimits:
        return DownloaderLimits()

    async def set_limits(self, limits: DownloaderLimits) -> None:
        return None

    async def transfer_speeds(self) -> tuple[int, int]:
        return (0, 0)

    async def set_download_limits(self, info_hashes: list[str], limit_bytes: int | None) -> None:
        return None

    async def set_upload_limits(self, info_hashes: list[str], limit_bytes: int | None) -> None:
        return None

    async def test_connection(self) -> DownloaderInfo:
        return DownloaderInfo(type=self.config.type, version="v5.0.2")

    async def close(self) -> None:
        return None


def _patch_downloader_factories() -> None:
    """凡是按配置造下载器适配器的模块，都换成假实现（配置/提交/监听导入/任务中心）。"""
    import sys

    import movieclaw_downloader
    import movieclaw_downloader.factory

    # 包级与工厂模块本身也换掉：监听导入是在函数内 `from movieclaw_downloader import ...`
    movieclaw_downloader.create_downloader = _FakeDownloader  # type: ignore[assignment]
    movieclaw_downloader.factory.create_downloader = _FakeDownloader  # type: ignore[assignment]
    for name, module in list(sys.modules.items()):
        if name.startswith("movieclaw_api") and getattr(module, "create_downloader", None):
            module.create_downloader = _FakeDownloader  # type: ignore[attr-defined]


torrent_submit_mod.get_site_access = lambda: _FakeSiteAccess()  # type: ignore[assignment]

from movieclaw_api.app import create_app  # noqa: E402

app = create_app()
downloader_config_mod.create_downloader = _FakeDownloader  # type: ignore[assignment]
_patch_downloader_factories()

if __name__ == "__main__":
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=int(os.environ["APP_PORT"]),
        log_config=None,
        access_log=False,
    )

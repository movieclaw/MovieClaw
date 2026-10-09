"""演示资源站：公开演示站专用的离线站点（docs/design/demo-site.md §10）。

只收录开放授权的影片（Blender 开放电影，CC BY），不连接任何网络：

- **目录**：演示站启动时由 ``build_catalog`` 扫描种子目录（``MOVIECLAW_DEMO_SEED_DIR``，
  每部片一个场景风格命名的文件夹，内含 ``release.json``），给每个文件夹做一枚真实的
  .torrent（v1、私有种），连同目录清单缓存进 ``MOVIECLAW_DEMO_SITE_DIR``；
- **搜索 / 列表**：在目录里按片名、中文名、年份匹配；列表第一页另带几条按时间窗轮换的
  「免费新种」，供刷流在池使用（它们没有实体数据，演示下载器只模拟做种）；
- **下载种子**：从缓存目录读 .torrent；刷流种按种子 ID 现场确定性生成。

站点本身不提供任何影片之外的内容，也不回显访客输入。
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

from movieclaw_tracker.base import BaseSite
from movieclaw_tracker.models import (
    SearchQuery,
    SearchResult,
    TorrentCategory,
    TorrentDetail,
    TorrentListItem,
    TorrentListPage,
    UserProfile,
)

logger = logging.getLogger("movieclaw_tracker.sites.demo")

#: 种子分片大小：4 MiB（演示片几百 MB，分片数在几百以内）
PIECE_LENGTH = 4 * 1024 * 1024
#: 刷流免费种的轮换时间窗与每窗条数
BOOST_WINDOW = timedelta(hours=6)
BOOST_PER_WINDOW = 3
_BOOST_PREFIX = "boost-"


def seed_dir() -> Path:
    """种子目录：每部片一个文件夹（演示下载器从这里取数据）。"""
    return Path(os.environ.get("MOVIECLAW_DEMO_SEED_DIR", "/media/_资源站"))


def site_dir() -> Path:
    """目录清单与 .torrent 的缓存位置（在 data/ 里，随每日还原一起复位）。"""
    return Path(os.environ.get("MOVIECLAW_DEMO_SITE_DIR", "./data/demo-site"))


# ---------------------------------------------------------------------------
# bencode 编码（只用到 int / bytes / str / list / dict）
# ---------------------------------------------------------------------------


def bencode(value: object) -> bytes:
    if isinstance(value, bool):
        raise TypeError("bencode 不支持布尔值")
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, v) for k, v in value.items())
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(f"bencode 不支持 {type(value).__name__}")


def _torrent_bytes(info: dict) -> bytes:
    # 不带 announce：演示种只交给演示下载器，不会联系任何 Tracker
    return bencode({"created by": "MovieClaw demo", "info": info})


# ---------------------------------------------------------------------------
# 目录构建：种子目录 → 真实 .torrent + 目录清单
# ---------------------------------------------------------------------------


def _hash_pieces(files: list[Path]) -> bytes:
    """按 v1 规则把多个文件首尾相接后切 4 MiB 分片，逐片 SHA-1。"""
    pieces = bytearray()
    buffer = bytearray()
    for path in files:
        with path.open("rb") as handle:
            while chunk := handle.read(PIECE_LENGTH):
                buffer += chunk
                while len(buffer) >= PIECE_LENGTH:
                    pieces += hashlib.sha1(buffer[:PIECE_LENGTH]).digest()
                    del buffer[:PIECE_LENGTH]
    if buffer:
        pieces += hashlib.sha1(buffer).digest()
    return bytes(pieces)


def _release_files(folder: Path) -> list[Path]:
    """文件夹里要进种子的文件：跳过 release.json 与隐藏文件，按相对路径排序。"""
    return sorted(
        (
            path
            for path in folder.rglob("*")
            if path.is_file() and path.name != "release.json" and not path.name.startswith(".")
        ),
        key=lambda path: path.relative_to(folder).as_posix(),
    )


def build_catalog(seeds: Path | None = None, out: Path | None = None) -> list[dict]:
    """扫描种子目录，给每个文件夹做 .torrent 并写目录清单；文件没变的跳过重算。"""
    seeds = seeds or seed_dir()
    out = out or site_dir()
    (out / "torrents").mkdir(parents=True, exist_ok=True)
    previous = {entry["name"]: entry for entry in load_catalog(out)}
    catalog: list[dict] = []
    if not seeds.is_dir():
        logger.warning("演示资源站的种子目录不存在：%s，站点将没有可搜的资源", seeds)
    folders = sorted(p for p in seeds.iterdir() if p.is_dir()) if seeds.is_dir() else []
    for index, folder in enumerate(folders, start=1):
        meta_path = folder / "release.json"
        if not meta_path.is_file():
            continue
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        files = _release_files(folder)
        layout = [
            {"path": p.relative_to(folder).as_posix(), "size": p.stat().st_size} for p in files
        ]
        size = sum(item["size"] for item in layout)
        torrent_id = str(1000 + index)
        cached = previous.get(folder.name)
        torrent_path = out / "torrents" / f"{torrent_id}.torrent"
        if cached and cached.get("files") == layout and torrent_path.is_file():
            entry = {**cached, "torrent_id": torrent_id}
        else:
            info = {
                "name": folder.name,
                "piece length": PIECE_LENGTH,
                "pieces": _hash_pieces(files),
                "private": 1,
                "files": [
                    {"length": item["size"], "path": item["path"].split("/")} for item in layout
                ],
            }
            torrent_path.write_bytes(_torrent_bytes(info))
            entry = {
                "torrent_id": torrent_id,
                "name": folder.name,
                "files": layout,
                "info_hash": hashlib.sha1(bencode(info)).hexdigest(),
            }
            logger.info("演示资源站已生成种子：%s", folder.name)
        entry.update(
            size_bytes=size,
            title_zh=meta.get("title_zh", ""),
            title=meta.get("title", ""),
            year=meta.get("year"),
            imdb_id=meta.get("imdb_id"),
            license=meta.get("license", ""),
            # 上架时间：建目录时按序往前排，列表里有新有旧
            upload_time=(datetime.now(UTC) - timedelta(days=index))
            .replace(tzinfo=None)
            .isoformat(),
        )
        catalog.append(entry)
    (out / "catalog.json").write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return catalog


def load_catalog(out: Path | None = None) -> list[dict]:
    path = (out or site_dir()) / "catalog.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


# ---------------------------------------------------------------------------
# 刷流免费种：按时间窗确定性生成（没有实体数据）
# ---------------------------------------------------------------------------


def _window_start(now: datetime) -> datetime:
    epoch = datetime(2026, 1, 1)
    windows = (now - epoch) // BOOST_WINDOW
    return epoch + windows * BOOST_WINDOW


def boost_releases(now: datetime | None = None) -> list[dict]:
    """当前时间窗里的几条免费新种：片名取自目录，体积与 ID 由时间窗确定。"""
    now = now or datetime.now(UTC).replace(tzinfo=None)
    start = _window_start(now)
    catalog = load_catalog()
    if not catalog:
        return []
    window_id = int(start.timestamp())
    releases = []
    for n in range(BOOST_PER_WINDOW):
        base = catalog[(window_id // int(BOOST_WINDOW.total_seconds()) + n) % len(catalog)]
        seed = hashlib.sha256(f"{window_id}:{n}".encode()).digest()
        size = (1 + seed[0] % 4) * 1024**3 + int.from_bytes(seed[1:4], "big")
        name = re.sub(r"\.\d{3,4}p\.", ".2160p.", base["name"]).replace("-BLENDER", "-DEMOSEED")
        releases.append(
            {
                "torrent_id": f"{_BOOST_PREFIX}{window_id}-{n}",
                "name": name,
                "size_bytes": size,
                "title_zh": base.get("title_zh", ""),
                "upload_time": (start + timedelta(minutes=10 * n)).isoformat(),
                "leechers": 3 + seed[4] % 18,
                "seeders": 1 + seed[5] % 4,
            }
        )
    return releases


def _boost_torrent(entry: dict) -> bytes:
    pieces_count = -(-entry["size_bytes"] // PIECE_LENGTH)
    digest = hashlib.sha256(entry["torrent_id"].encode()).digest()
    info = {
        "name": entry["name"] + ".mkv",
        "length": entry["size_bytes"],
        "piece length": PIECE_LENGTH,
        "pieces": (digest[:20] * pieces_count),
        "private": 1,
    }
    return _torrent_bytes(info)


# ---------------------------------------------------------------------------
# 站点适配器
# ---------------------------------------------------------------------------


def _item(entry: dict, *, boost: bool = False) -> TorrentListItem:
    year = entry.get("year")
    license_text = entry.get("license", "")
    subtitle = " ".join(
        part
        for part in (entry.get("title_zh", ""), f"{license_text} 开放授权" if license_text else "")
        if part
    )
    return TorrentListItem(
        torrent_id=entry["torrent_id"],
        title=entry["name"],
        subtitle=subtitle if not boost else f"{entry.get('title_zh', '')} 免费刷流种".strip(),
        category=TorrentCategory.MOVIE,
        site_category_name="电影",
        size_bytes=entry["size_bytes"],
        seeders=entry.get("seeders", 12 if year else 1),
        leechers=entry.get("leechers", 0),
        snatched=entry.get("snatched", 30),
        upload_time=datetime.fromisoformat(entry["upload_time"]),
        uploader="Blender 开放电影",
        free=boost,
        download_volume_factor=0.0 if boost else 1.0,
        hit_and_run=False,
        download_url=f"download.php?id={entry['torrent_id']}",
    )


def _matches(entry: dict, keyword: str) -> bool:
    needle = re.sub(r"[\s._:!-]+", "", keyword).lower()
    if not needle:
        return True
    haystack = " ".join(str(entry.get(key) or "") for key in ("name", "title", "title_zh", "year"))
    return needle in re.sub(r"[\s._:!-]+", "", haystack).lower()


def _id_of(url: str) -> str:
    match = re.search(r"id=([\w-]+)", url)
    return match.group(1) if match else url


class DemoSite(BaseSite):
    """演示资源站：读本地目录，不发任何网络请求。"""

    def __init__(self, **kwargs) -> None:  # type: ignore[no-untyped-def]
        kwargs.pop("category_map", None)
        super().__init__(**kwargs)

    async def list_torrents(
        self,
        *,
        categories: list[TorrentCategory] | None = None,
        page: int = 1,
    ) -> TorrentListPage:
        if page > 1:
            return TorrentListPage(items=[], page=page, total_pages=1)
        items = [_item(entry, boost=True) for entry in boost_releases()]
        items += [_item(entry) for entry in load_catalog()]
        return TorrentListPage(items=items, page=1, total_pages=1)

    async def search(self, query: SearchQuery) -> SearchResult:
        hits = [_item(entry) for entry in load_catalog() if _matches(entry, query.keyword)]
        return SearchResult(items=hits, page=1, total_pages=1, total_results=len(hits))

    async def get_torrent_detail(self, url: str) -> TorrentDetail:
        torrent_id = _id_of(url)
        entry = next((e for e in load_catalog() if e["torrent_id"] == torrent_id), None)
        if entry is None:
            entry = next((e for e in boost_releases() if e["torrent_id"] == torrent_id), None)
        if entry is None:
            raise ValueError(f"演示资源站没有这条资源：{torrent_id}")
        item = _item(entry, boost=torrent_id.startswith(_BOOST_PREFIX)).model_dump()
        return TorrentDetail(
            **{key: value for key, value in item.items() if key in TorrentDetail.model_fields},
            description=entry.get("license", ""),
            imdb_id=entry.get("imdb_id"),
            file_list=[f["path"] for f in entry.get("files", [])],
        )

    async def download_torrent(self, url: str) -> bytes:
        torrent_id = _id_of(url)
        if torrent_id.startswith(_BOOST_PREFIX):
            entry = next((e for e in boost_releases() if e["torrent_id"] == torrent_id), None)
            if entry is None:
                raise ValueError(f"刷流种已过期：{torrent_id}")
            return _boost_torrent(entry)
        path = site_dir() / "torrents" / f"{torrent_id}.torrent"
        if not path.is_file():
            raise ValueError(f"演示资源站没有这条资源：{torrent_id}")
        return path.read_bytes()

    async def get_user_profile(self, user_id: str | None = None) -> UserProfile:
        return UserProfile(
            user_id="1",
            username="demo",
            user_class="演示账号",
            uploaded="1.20 TB",
            uploaded_bytes=1_200 * 1024**3,
            downloaded="300.00 GB",
            downloaded_bytes=300 * 1024**3,
            ratio=4.0,
            seeding_count=len(load_catalog()),
        )

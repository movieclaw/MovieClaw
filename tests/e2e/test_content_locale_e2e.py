"""内容语言的端到端（docs/design/content-locale.md）：看到的跟界面语言，写下来的跟媒体库语言。

真后端（uvicorn 子进程）+ 按 language 参数作答的假 TMDB（真 HTTP）+ 真实 HTTP 请求。
初始化、建库、放文件、扫描刮削全走真实接口；每个场景用不同的 ``Accept-Language``
（就是各端切界面语言时发出去的东西）读同一份数据：

1. 中文读者看中文库：片名、简介、类型、分集都是中文——与改动前一样；
2. 英文读者看同一个中文库：片名、简介、类型英文，分集仍是中文（库语言），文件夹不动；
   发现页向 TMDB 用 en-US 取数、标签英文，统一搜索「全部」不混豆瓣；
3. 主语言 en-US 的库：中文读者看到中文片名简介；召回词含中文名；
4. 不带语言头的老客户端：中文。

标 integration：起子进程、监听端口，CI 不跑。
本地：``pytest -m integration tests/e2e/test_content_locale_e2e.py``。
"""

from __future__ import annotations

import json
import os
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest

REPO = Path(__file__).resolve().parents[2]
ADMIN = {"username": "admin", "password": "e2e-passw0rd"}
ZH = {"Accept-Language": "zh-Hans"}
EN = {"Accept-Language": "en"}

pytestmark = pytest.mark.integration


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("content-locale-e2e")
    data = root / "data"
    data.mkdir()
    tmdb_log = root / "tmdb.log"
    tmdb_log.touch()
    port = _free_port()
    db_path = data / "app.db"
    env = {
        **os.environ,
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(port),
        "DATABASE_URL": f"sqlite+aiosqlite:///{db_path}",
        "MOVIECLAW_DATA_DIR": str(data),
        "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "E2E_TMDB_LOG": str(tmdb_log),
        "PYTHONPATH": str(REPO / "src") + os.pathsep + os.environ.get("PYTHONPATH", ""),
    }
    api_log = (root / "api.log").open("w")
    api = subprocess.Popen(  # noqa: S603
        [sys.executable, str(Path(__file__).with_name("_content_locale_launcher.py"))],
        env=env,
        stdout=api_log,
        stderr=subprocess.STDOUT,
        cwd=str(REPO),
    )
    base = f"http://127.0.0.1:{port}"
    try:
        deadline = time.time() + 90
        while True:
            try:
                if httpx.get(f"{base}/api/v1/auth/bootstrap", timeout=3).status_code < 500:
                    break
            except httpx.HTTPError:
                pass
            if time.time() > deadline or api.poll() is not None:
                raise RuntimeError((root / "api.log").read_text())
            time.sleep(0.5)
        client = httpx.Client(base_url=base, timeout=30)
        created = client.post("/api/v1/auth/bootstrap", json=ADMIN, headers=ZH)
        assert created.status_code == 200, created.text
        yield {"client": client, "root": root, "db": db_path, "tmdb_log": tmdb_log}
        client.close()
    finally:
        api.terminate()
        try:
            api.wait(timeout=15)
        except subprocess.TimeoutExpired:
            api.kill()
        api_log.close()


def _ok(response: httpx.Response):
    assert response.status_code in (200, 202), response.text
    return response.json()["data"]


def _wait_idle(client: httpx.Client, library_id: int) -> None:
    for _ in range(600):
        if not _ok(client.get(f"/api/v1/libraries/{library_id}"))["scanning"]:
            return
        time.sleep(0.05)
    raise AssertionError("扫描未结束")


def _library(client: httpx.Client, root: Path, kind: str, **extra) -> int:
    root.mkdir(parents=True, exist_ok=True)
    library_id = _ok(
        client.post(
            "/api/v1/libraries",
            json={"name": root.name, "kind": kind, "root_paths": [str(root)], **extra},
        )
    )["id"]
    _wait_idle(client, library_id)
    return library_id


def _scan(client: httpx.Client, library_id: int) -> None:
    job_id = _ok(client.post(f"/api/v1/libraries/{library_id}/scan"))["job_id"]
    for _ in range(1200):
        job = _ok(client.get(f"/api/v1/jobs/{job_id}"))
        if job["status"] == "succeeded":
            return
        assert job["status"] not in {"failed", "blocked", "cancelled"}, job
        time.sleep(0.05)
    raise AssertionError("扫描作业未完成")


def _requests(log: Path) -> list[tuple[str, str]]:
    lines = log.read_text(encoding="utf-8").splitlines()
    return [tuple(line.split(" ", 1)) for line in lines]  # type: ignore[misc]


@pytest.fixture(scope="module")
def libraries(stack):
    client: httpx.Client = stack["client"]
    shows_root = stack["root"] / "media" / "剧集"
    shows = _library(client, shows_root, "tv")
    season = shows_root / "Severance (2022)" / "Season 1"
    season.mkdir(parents=True)
    for episode in (1, 2):
        (season / f"Severance.S01E0{episode}.1080p.mkv").write_bytes(b"video")
    _scan(client, shows)

    movies_root = stack["root"] / "media" / "English movies"
    movies = _library(
        client, movies_root, "movie", scrape_overrides={"language_priority": ["en-US"]}
    )
    (movies_root / "Hero (2002)").mkdir()
    (movies_root / "Hero (2002)" / "Hero.2002.1080p.mkv").write_bytes(b"video")
    _scan(client, movies)
    return {"shows": shows, "movies": movies, "shows_root": shows_root}


def _only(client: httpx.Client, library_id: int, headers: dict) -> dict:
    items = _ok(client.get(f"/api/v1/libraries/{library_id}/items", headers=headers))
    assert len(items) == 1, items
    return items[0]


def _detail(client, library_id, item_id, headers) -> dict:
    return _ok(client.get(f"/api/v1/libraries/{library_id}/items/{item_id}", headers=headers))


def _episodes(client, library_id, item_id, headers) -> list[str]:
    view = _ok(
        client.get(
            f"/api/v1/libraries/{library_id}/items/{item_id}/episodes",
            params={"season_number": 1},
            headers=headers,
        )
    )
    return [episode["name"] for episode in view["episodes"]]


def test_chinese_reader_sees_chinese_library_as_before(stack, libraries):
    client = stack["client"]
    item = _only(client, libraries["shows"], ZH)
    assert item["title"] == "人生切割术"
    detail = _detail(client, libraries["shows"], item["media_item_id"], ZH)
    assert detail["title"] == "人生切割术"
    assert detail["local_meta"]["plot"] == "马克领导着一个团队。"
    assert detail["local_meta"]["genres"] == ["剧情", "悬疑"]
    assert _episodes(client, libraries["shows"], item["media_item_id"], ZH) == [
        "好消息",
        "一半一半",
    ]
    showcase = _ok(
        client.get(
            "/api/v1/libraries/showcase", params={"ids": [item["media_item_id"]]}, headers=ZH
        )
    )
    assert showcase[0]["overview"] == "马克领导着一个团队。"
    assert showcase[0]["genres"] == ["剧情", "悬疑"]


def test_english_reader_sees_english_titles_but_library_language_on_disk(stack, libraries):
    client = stack["client"]
    item = _only(client, libraries["shows"], EN)
    assert item["title"] == "Severance"
    detail = _detail(client, libraries["shows"], item["media_item_id"], EN)
    assert detail["title"] == "Severance"
    assert detail["local_meta"]["plot"] == "Mark leads a team of office workers."
    assert detail["local_meta"]["genres"] == ["Drama", "Mystery"]
    # 分集标题是「写下来的」，跟媒体库语言
    assert _episodes(client, libraries["shows"], item["media_item_id"], EN) == [
        "好消息",
        "一半一半",
    ]
    showcase = _ok(
        client.get(
            "/api/v1/libraries/showcase", params={"ids": [item["media_item_id"]]}, headers=EN
        )
    )
    assert showcase[0]["overview"] == "Mark leads a team of office workers."
    assert showcase[0]["genres"] == ["Drama", "Mystery"]
    # 库里存的仍是主语言（中文）；英文只在译文列
    with sqlite3.connect(stack["db"]) as db:
        title, translations = db.execute(
            "SELECT title, title_translations FROM media_item WHERE id = ?",
            (item["media_item_id"],),
        ).fetchone()
    assert title == "人生切割术"
    assert json.loads(translations) == {"en-US": "Severance"}
    assert (libraries["shows_root"] / "Severance (2022)" / "Season 1").is_dir()


def test_discover_follows_each_reader(stack, libraries):
    client = stack["client"]
    log: Path = stack["tmdb_log"]
    log.write_text("", encoding="utf-8")
    collection = "/api/v1/discover/collections/tmdb:tv:popular/titles"
    english = _ok(client.get(collection, headers=EN))
    chinese = _ok(client.get(collection, headers=ZH))
    assert english["titles"][0]["title"] == "Severance"
    assert english["titles"][0]["genres"] == ["Drama", "Mystery"]
    assert chinese["titles"][0]["title"] == "人生切割术"
    assert chinese["titles"][0]["genres"] == ["剧情", "悬疑"]
    languages = {lang for path, lang in _requests(log) if path == "/3/tv/popular"}
    assert languages == {"en-US", "zh-CN"}

    for headers, country, language, kind in (
        (EN, "United States", "English", "Trailer"),
        (ZH, "美国", "英语", "预告片"),
    ):
        detail = _ok(client.get("/api/v1/discover/titles/tmdb:tv:95396", headers=headers))
        assert detail["metadata"]["country"] == country
        assert detail["metadata"]["language"] == language
        assert detail["videos"][0]["kind"] == kind
        assert detail["videos"][0]["name"] == kind

    # 缓存按语言分开：再读一次英文，不会拿到刚缓存的中文
    again = _ok(client.get(collection, headers=EN))
    assert again["titles"][0]["title"] == "Severance"



def test_english_library_shows_chinese_to_chinese_readers(stack, libraries):
    client = stack["client"]
    zh_item = _only(client, libraries["movies"], ZH)
    en_item = _only(client, libraries["movies"], EN)
    assert en_item["title"] == "Hero"
    assert zh_item["title"] == "英雄"
    detail = _detail(client, libraries["movies"], zh_item["media_item_id"], ZH)
    assert detail["local_meta"]["plot"] == "战国末期，刺客无名……"
    assert detail["local_meta"]["genres"] == ["动作"]
    # 写下来的跟库语言：库内原列是英文
    with sqlite3.connect(stack["db"]) as db:
        row = db.execute(
            "SELECT title, original_title, english_title, title_translations"
            " FROM media_item WHERE id = ?",
            (zh_item["media_item_id"],),
        ).fetchone()
    assert row[0] == "Hero"

    # 召回词：中文 PT 站要的中文名回来了

    from movieclaw_api.services.subscription.wanted_search import recall_keywords
    from movieclaw_db.models import MediaItem
    from movieclaw_db.models.media_item import MediaSource

    item = MediaItem(
        kind="movie",
        source=MediaSource.TMDB,
        aliases=[],
        title=row[0],
        original_title=row[1],
        english_title=row[2],
        title_translations=json.loads(row[3]),
    )
    assert "英雄" in recall_keywords(item)


def test_requests_without_language_header_stay_chinese(stack, libraries):
    client = stack["client"]
    item = _only(client, libraries["shows"], {})
    assert item["title"] == "人生切割术"
    titles = _ok(client.get("/api/v1/discover/collections/tmdb:tv:popular/titles"))["titles"]
    assert titles[0]["title"] == "人生切割术"



def test_search_resources_keeps_the_chinese_name_for_english_readers(stack, libraries):
    """「搜索资源」以显示出来的片名为主词：英文界面下服务端补上中文名，中文 PT 站才搜得到。"""
    client = stack["client"]
    shows = libraries["shows"]
    item_id = _only(client, shows, ZH)["media_item_id"]
    assert _detail(client, shows, item_id, EN)["chinese_title"] == "人生切割术"
    assert _detail(client, shows, item_id, ZH)["chinese_title"] is None
    assert _detail(client, shows, item_id, {})["chinese_title"] is None
    discover = {
        lang: _ok(client.get("/api/v1/discover/titles/tmdb:tv:95396", headers=headers))
        for lang, headers in (("en", EN), ("zh", ZH))
    }
    assert discover["en"]["metadata"]["chinese_title"] == "人生切割术"
    assert discover["zh"]["metadata"]["chinese_title"] is None


def test_title_logo_only_for_readers_of_the_library_language(stack, libraries):
    """片名 Logo 是库语言的文字图：中文读者照旧拿到，英文读者拿不到、各端退回文字片名。"""
    client = stack["client"]
    shows = libraries["shows"]
    item_id = _only(client, shows, ZH)["media_item_id"]
    zh = _detail(client, shows, item_id, ZH)
    en = _detail(client, shows, item_id, EN)
    assert zh["logo_url"] and "severance-logo-zh" in zh["logo_url"]
    assert en["logo_url"] is None
    assert en["title"] == "Severance"
    showcase = {
        lang: _ok(
            client.get("/api/v1/libraries/showcase", params={"ids": [item_id]}, headers=headers)
        )[0]
        for lang, headers in (("zh", ZH), ("en", EN))
    }
    assert showcase["zh"]["logo_url"] and showcase["en"]["logo_url"] is None
    assert _detail(client, shows, item_id, {})["logo_url"] == zh["logo_url"]  # 老客户端照旧

def test_continue_watching_and_player_title_follow_reader(stack, libraries):
    client = stack["client"]
    item_id = _only(client, libraries["shows"], ZH)["media_item_id"]
    _ok(
        client.post(
            "/api/v1/playback/progress",
            json={
                "media_item_id": item_id,
                "season_number": 1,
                "episode_number": 1,
                "event": "progress",
                "position_ms": 60_000,
            },
        )
    )
    for headers, title, overview, genres in (
        (EN, "Severance", "Mark leads a team of office workers.", ["Drama", "Mystery"]),
        (ZH, "人生切割术", "马克领导着一个团队。", ["剧情", "悬疑"]),
    ):
        items = _ok(client.get("/api/v1/playback/up-next", headers=headers))["items"]
        card = next(i for i in items if i["media_item_id"] == item_id)
        assert card["title"] == title
        assert card["genres"] == genres
        # 分集还没有简介时退回整部剧的简介：跟读者语言
        assert card["overview"] == overview
        assert card["episode_title"] == "好消息"  # 分集标题跟库语言
        # 片名 Logo 只给读得了库语言的人
        assert bool(card["logo_url"]) is (headers is ZH)
        player = _ok(client.get(f"/api/v1/playback/items/{item_id}", headers=headers))
        assert player["title"] == title


def test_people_gallery_and_search_follow_reader(stack, libraries):
    client = stack["client"]
    shows = libraries["shows"]
    for headers, title in ((EN, "Severance"), (ZH, "人生切割术")):
        person = _ok(client.get("/api/v1/people/1001", headers=headers))
        assert [c["title"] for c in person["credits"]] == [title]
        gallery = _ok(client.get(f"/api/v1/libraries/{shows}/gallery", headers=headers))
        assert [g["title"] for g in gallery] == [title]
        found = _ok(
            client.get("/api/v1/search/library", params={"q": "Severance"}, headers=headers)
        )
        assert [hit["item"]["title"] for hit in found["items"]] == [title]


def test_metadata_refresh_fills_translations_for_existing_rows(stack, libraries):
    """升级前刮削的条目没有译文：英文读者先看到主语言，刷新一次元数据后自愈。"""
    client = stack["client"]
    shows = libraries["shows"]
    item_id = _only(client, shows, ZH)["media_item_id"]
    with sqlite3.connect(stack["db"]) as db:
        db.execute("UPDATE media_item SET title_translations = NULL WHERE id = ?", (item_id,))
        db.execute(
            "UPDATE media_metadata SET overview_translations = NULL WHERE media_item_id = ?",
            (item_id,),
        )
    assert _only(client, shows, EN)["title"] == "人生切割术"
    legacy = _detail(client, shows, item_id, EN)
    assert legacy["local_meta"]["plot"] == "马克领导着一个团队。"
    assert legacy["logo_url"]  # 文字片名也是中文：Logo 照旧给

    job_id = _ok(client.post(f"/api/v1/libraries/{shows}/items/{item_id}/metadata/refresh"))[
        "job_id"
    ]
    for _ in range(1200):
        job = _ok(client.get(f"/api/v1/jobs/{job_id}"))
        if job["status"] == "succeeded":
            break
        assert job["status"] not in {"failed", "blocked", "cancelled"}, job
        time.sleep(0.05)
    else:
        raise AssertionError("刷新作业未完成")
    assert _only(client, shows, EN)["title"] == "Severance"
    refreshed = _detail(client, shows, item_id, EN)
    assert refreshed["local_meta"]["plot"] == "Mark leads a team of office workers."
    assert refreshed["logo_url"] is None
    assert _only(client, shows, ZH)["title"] == "人生切割术"


def test_english_library_douban_subscription_converges_and_searches_chinese_name(stack, libraries):
    """库语言是英文时：豆瓣《沙丘》仍能收敛到 TMDB，PT 站搜索词里有中文名。"""
    client = stack["client"]
    log: Path = stack["tmdb_log"]
    _ok(client.put("/api/v1/scrape/config", json={"language_priority": ["en-US"]}))
    log.write_text("", encoding="utf-8")

    preview = _ok(
        client.post("/api/v1/subscriptions/title-preview", json={"title_ref": "douban:35"})
    )
    assert preview["status"] == "ready", preview
    searches = {lang for path, lang in _requests(log) if path == "/3/search/movie"}
    assert searches == {"zh-CN"}  # 拿中文名搜中文，与库语言无关

    created = client.post("/api/v1/subscriptions", json={"title_ref": "douban:35"})
    assert created.status_code == 200, created.text
    with sqlite3.connect(stack["db"]) as db:
        title, translations = db.execute(
            "SELECT title, title_translations FROM media_item WHERE tmdb_id = 438631"
        ).fetchone()
    assert title == "Dune"  # 写下来的跟库语言
    assert json.loads(translations) == {"zh-CN": "沙丘"}

    for _ in range(200):
        keywords = client.get("/__lab/search-log").json()
        if keywords:
            break
        time.sleep(0.1)
    assert keywords[:2] == ["Dune", "沙丘"], keywords

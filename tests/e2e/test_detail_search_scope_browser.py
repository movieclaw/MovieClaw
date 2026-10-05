"""详情页「搜索资源」按影片类型收窄分类的浏览器端到端。

此前两处详情页的「搜索资源」只带片名，落地结果页的分类是「全部」，同名的另一类资源
（同名电影/剧集、音乐、游戏）会混进来。现在剧集只搜「剧集」、电影只搜「电影」，
等同在结果页点了对应的内置分类胶囊。

基座沿用 test_library_manage_browser 的 stack（真后端 + 假 TMDB + 真前端 + 无头 Chromium）。
覆盖：媒体库条目详情（剧集 / 电影，⋯ 菜单）→ 发现详情（假 TMDB 的剧集 200 / 电影 300，
主按钮）→ 落地 URL 的 cats/label 与结果页高亮的分类胶囊。

标 integration：要 pnpm（apps/web 已 install）与 Playwright Chromium，CI 不跑。
本地：``pytest -m integration tests/e2e/test_detail_search_scope_browser.py``。
"""

from __future__ import annotations

import asyncio
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import pytest

from .test_library_manage_browser import (  # noqa: F401  (stack 是 fixture，按名注入)
    ADMIN,
    _chromium_kwargs,
    _wait_for,
    stack,
)

playwright = pytest.importorskip("playwright.sync_api")

pytestmark = [pytest.mark.integration]


async def _seed(db_path: Path, movie_lib: int, tv_lib: int, movies: Path, tv: Path) -> dict:
    """库里一部电影一部剧，各挂一个真实落盘的文件。电影的 tmdb_id 故意不撞假 TMDB 的
    300——发现详情页上的那部电影不能算「已在库」，否则「搜索资源」按钮会被收掉。"""
    from movieclaw_db.engine import dispose_db, get_database, init_db
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem

    init_db(f"sqlite+aiosqlite:///{db_path}", echo=False)
    db = get_database()
    try:
        async with db.session() as session:
            movie = MediaItem(
                kind="movie",
                tmdb_id=301,
                title="九门",
                original_title="Nine Gates",
                year=2025,
                aliases=[],
            )
            show = MediaItem(
                kind="tv",
                tmdb_id=3,
                title="权力的游戏",
                original_title="Game of Thrones",
                year=2011,
                aliases=[],
            )
            session.add_all([movie, show])
            await session.flush()
            for lib, item, path in (
                (movie_lib, movie, movies / "九门 (2025)" / "九门.2025.1080p.mkv"),
                (tv_lib, show, tv / "权力的游戏 (2011)" / "Season 01" / "S01E01.mkv"),
            ):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"x" * 1024)
                session.add(
                    LibraryFile(
                        library_id=lib,
                        media_item_id=item.id,
                        file_path=str(path),
                        size_bytes=1024,
                        source=FileSource.SCANNED,
                        **({"season_number": 1, "episode_number": 1} if item is show else {}),
                    )
                )
            await session.commit()
            return {"movie": movie.id, "show": show.id}
    finally:
        await dispose_db()


def _assert_scope(page, keyword: str, kind: str, label: str) -> None:
    """落地是站点资源结果页：URL 带单一分类，结果页对应胶囊高亮、「全部」不亮。"""
    from playwright.sync_api import expect

    page.wait_for_url(re.compile(r"/search\?"))
    params = parse_qs(urlparse(page.url).query)
    assert params["q"] == [keyword], page.url
    assert params["cats"] == [kind], page.url
    assert params["label"] == [label], page.url
    chips = page.get_by_role("radiogroup", name="站点资源搜索分类")
    expect(chips.get_by_role("radio", name=label, exact=True)).to_have_attribute(
        "aria-checked", "true"
    )
    expect(chips.get_by_role("radio", name="全部", exact=True)).to_have_attribute(
        "aria-checked", "false"
    )


# 外部 id → (provider, media_type, 片名)
_TITLES = {
    "200": ("tmdb", "tv", "测试剧集"),
    "300": ("tmdb", "movie", "某电影"),
    "36000001": ("douban", "tv", "豆瓣剧集"),
}


def _fulfill_title(route) -> None:
    """发现详情接口夹具：按 title_ref 末尾的外部 id 回一份最小详情（不在库、无图）。"""
    ref = unquote(urlparse(route.request.url).path.rsplit("/", 1)[1])
    external_id = ref.rsplit(":", 1)[-1]
    if external_id not in _TITLES:
        route.fulfill(status=404, json={"code": 404, "message": "not found", "data": None})
        return
    provider, media_type, title = _TITLES[external_id]
    route.fulfill(
        json={
            "code": 0,
            "message": "ok",
            "data": {
                "title": {
                    "title_ref": ref,
                    "provider": provider,
                    "external_id": external_id,
                    "media_type": media_type,
                    "title": title,
                    "original_title": title,
                    "release_year": 2024,
                    "provider_rating": 8.0,
                    "genres": [],
                    "extent_label": "",
                    "overview": "端到端夹具。",
                    "poster_url": "",
                    "backdrop_url": None,
                    "library_status": None,
                },
                "metadata": {
                    "directors": [],
                    "director_credits": [],
                    "cast": [],
                    "country": "",
                    "language": "",
                    "released": "",
                    "network": None,
                    "aliases": [],
                    "source_url": None,
                },
                "videos": [],
                "backdrop_original_url": None,
                "backdrops": [],
                "posters": [],
                "collection": None,
                "recommendations": [],
                "library_links": [],
            },
        }
    )


def test_detail_search_follows_media_kind(stack) -> None:  # noqa: F811
    from playwright.sync_api import expect, sync_playwright

    base = stack["base"]
    roots: dict[str, Path] = stack["roots"]
    shots: Path = stack["shots"]
    shots.mkdir(exist_ok=True)
    db_path = roots["movies"].parent.parent / "data" / "app.db"

    def api(page, method: str, path: str, **kw) -> dict:
        resp = page.request.fetch(f"{base}/api/v1{path}", method=method, **kw)
        assert resp.ok, f"{method} {path}: {resp.status} {resp.text()}"
        return resp.json()["data"]

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, **_chromium_kwargs())
        context = browser.new_context(viewport={"width": 1440, "height": 900}, locale="zh-CN")
        page = context.new_page()
        page.set_default_timeout(20_000)
        page.set_default_navigation_timeout(120_000)
        page_errors: list[str] = []
        page.on("pageerror", lambda e: page_errors.append(str(e)))

        # ---- 首次引导 + 登录（登录页先是欢迎屏，走 API 拿 Cookie） ----
        resp = context.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        if resp.status == 409:
            resp = context.request.post(f"{base}/api/v1/auth/login", data=ADMIN)
        assert resp.ok, resp.text()

        libs = {
            kind: api(
                page,
                "POST",
                "/libraries",
                data={
                    "name": name,
                    "kind": kind,
                    "root_paths": [str(roots[root])],
                    "realtime_watch": False,
                },
            )["id"]
            for kind, name, root in (("movie", "电影", "movies"), ("tv", "剧集", "tv"))
        }

        def all_idle():
            rows = api(page, "GET", "/libraries")
            return rows if all(not r["scanning"] and r["last_scan"] for r in rows) else None

        _wait_for(all_idle, timeout=120, what="两个库首次扫描完成")
        with ThreadPoolExecutor(max_workers=1) as pool:
            ids = pool.submit(
                asyncio.run,
                _seed(db_path, libs["movie"], libs["tv"], roots["movies"], roots["tv"]),
            ).result()

        # ---- 媒体库条目详情：⋯ 菜单 →「搜索资源」 ----
        for kind, item, title, label in (
            ("tv", ids["show"], "权力的游戏", "剧集"),
            ("movie", ids["movie"], "九门", "电影"),
        ):
            page.goto(f"{base}/library/{libs[kind]}/item/{item}")
            page.get_by_role("button", name="更多操作").click()
            page.get_by_role("menuitem", name="搜索资源").click()
            _assert_scope(page, title, kind, label)
            page.screenshot(path=str(shots / f"library-{kind}-search.png"))

        # ---- 发现详情：主操作区的「搜索资源」 ----
        # 发现服务走自己的 TMDB/豆瓣客户端（不读假 TMDB），详情接口在浏览器层给夹具；
        # 被测的是前端按 media_type 拼跳转，页面渲染与跳转仍是真的
        page.route(re.compile(r"/api/v1/discover/titles/[^?]+"), _fulfill_title)
        for path, kind, title, label in (
            ("/media/tv/200", "tv", "测试剧集", "剧集"),
            ("/media/movie/300", "movie", "某电影", "电影"),
            # 豆瓣详情路由不带类型，类型只来自接口的 media_type
            ("/media/douban/36000001", "tv", "豆瓣剧集", "剧集"),
        ):
            page.goto(f"{base}{path}")
            link = page.get_by_role("link", name="搜索资源")
            expect(link).to_be_visible()
            link.click()
            _assert_scope(page, title, kind, label)
            page.screenshot(path=str(shots / f"discover-{path.rsplit('/', 2)[1]}-{kind}.png"))

        # ---- 订阅详情「手动选种」：同样收窄，放宽到「全部」时仍在选种模式 ----
        sub = api(
            page,
            "POST",
            "/subscriptions",
            data={"title_ref": "tmdb:tv:200", "selected_seasons": [1]},
        )["subscription"]
        page.goto(f"{base}/subscriptions/{sub['id']}")
        page.get_by_role("link", name="手动选种").click()
        _assert_scope(page, "测试剧集", "tv", "剧集")
        assert parse_qs(urlparse(page.url).query)["for_sub"] == [str(sub["id"])], page.url
        banner = page.get_by_text(re.compile("正在为《测试剧集》手动选种"))
        expect(banner).to_be_visible()

        chips = page.get_by_role("radiogroup", name="站点资源搜索分类")
        chips.get_by_role("radio", name="全部", exact=True).click()
        page.wait_for_url(lambda u: "cats=" not in u)
        assert parse_qs(urlparse(page.url).query)["for_sub"] == [str(sub["id"])], page.url
        expect(chips.get_by_role("radio", name="全部", exact=True)).to_have_attribute(
            "aria-checked", "true"
        )
        expect(banner).to_be_visible()
        page.screenshot(path=str(shots / "manual-pick-widened.png"))

        assert not page_errors, f"页面报错：{page_errors}"
        context.close()
        browser.close()

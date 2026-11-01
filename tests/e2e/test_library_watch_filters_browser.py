"""首页观看条件到跨库/单库列表：真实 Next + API + SQLite，不改生产资料库。"""

import re
import time

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_subscription_cancel_browser import _run

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


async def _seed(database_url, roots, offset):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem, PlaybackState
    from movieclaw_db.repositories.library_repo import LibraryRepository

    database = Database(database_url)
    ids = []
    library_ids = []
    try:
        async with database.session() as session:
            for kind, folder in zip(["movie", "tv"], roots, strict=True):
                library = await LibraryRepository(session).create(
                    name=f"Watch {kind} {offset}",
                    kind=kind,
                    root_paths=[str(folder)],
                    realtime_watch=False,
                )
                library_ids.append(library.id)
            for kind, count, library_id, folder in zip(
                ["movie", "tv"], [70, 3], library_ids, roots, strict=True
            ):
                for index in range(count):
                    title = f"{kind} watch {offset} {index:03}"
                    item = MediaItem(
                        kind=kind,
                        tmdb_id=880000 + offset + len(ids),
                        title=title,
                        original_title=title,
                        year=2024,
                    )
                    session.add(item)
                    await session.flush()
                    ids.append(item.id)
                    for episode in range(1, 7) if kind == "tv" else [0]:
                        path = folder / f"{index}-{episode}.mkv"
                        path.write_bytes(b"isolated watch filter fixture")
                        session.add(
                            LibraryFile(
                                library_id=library_id,
                                media_item_id=item.id,
                                season_number=1 if kind == "tv" else 0,
                                episode_number=episode,
                                file_path=str(path),
                                size_bytes=path.stat().st_size,
                                source=FileSource.SCANNED,
                            )
                        )
                        # 0=全部看完；1=电影只看一点/剧集看完前三集；其他=从未看过。
                        if index == 0 or (index == 1 and (kind == "movie" or episode <= 3)):
                            session.add(
                                PlaybackState(
                                    member_id=0,
                                    media_item_id=item.id,
                                    season_number=1 if kind == "tv" else 0,
                                    episode_number=episode,
                                    played=index == 0 or kind == "tv",
                                    position_ms=1 if kind == "movie" and index == 1 else 0,
                                )
                            )
            await session.commit()
            await LibraryRepository(session).refresh_stats(library_ids)
        return library_ids
    finally:
        await database.dispose()


@pytest.mark.parametrize("width", [1280, 390])
def test_home_watch_filters_survive_navigation_and_can_be_cleared(stack, browser, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 900})
    page = context.new_page()
    page.set_default_navigation_timeout(120000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    requests = []
    page.on("request", lambda request: requests.append(request.url))
    try:
        if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
            assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

        def api(method, path, **kwargs):
            response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
            assert response.ok, response.text()
            return response.json()["data"]

        prefs = api("get", "/ui/preferences")
        prefs.update(language="en", theme="silver", theme_mobile="silver", theme_desktop="silver")
        root = stack["data"] / f"watch-{width}"
        root.mkdir()
        roots = [root / kind for kind in ["movie", "tv"]]
        for folder in roots:
            folder.mkdir()
        libraries = _run(_seed(stack["database_url"], roots, width * 100))
        movie_library, tv_library = libraries
        # 上一参数的库不参与这一次的跨库墙。
        for row in api("get", "/libraries"):
            if row["id"] not in libraries:
                api(
                    "put",
                    f"/libraries/{row['id']}",
                    data={
                        "name": row["name"],
                        "kind": row["kind"],
                        "root_paths": row["root_paths"],
                        "exclude_from_home": True,
                        "realtime_watch": False,
                    },
                )
        prefs["home"] = {
            "rows": [
                {
                    "id": "row:pending-movies",
                    "media_kind": "movie",
                    "name": "Unfinished movies",
                    "sort": "title",
                    "order": "desc",
                    "unfinished": True,
                },
                {
                    "id": "row:pending-tv",
                    "media_kind": "tv",
                    "name": "Unfinished shows",
                    "sort": "title",
                    "unfinished": True,
                },
                {
                    "id": "row:seen",
                    "library_id": movie_library,
                    "name": "Seen movies",
                    "sort": "last_played",
                },
                {
                    "id": f"lib:{movie_library}",
                    "name": "Single unfinished",
                    "sort": "title",
                    "unfinished": True,
                },
            ]
        }
        api("put", "/ui/preferences", data=prefs)
        page.add_init_script("""
            localStorage.setItem('movieclaw.library.kind-wall-sort.movie', 'rating');
            localStorage.setItem('movieclaw.library.wall-sort', 'runtime:rev');""")
        page.goto(base + "/library")
        row = page.get_by_test_id("home-row-row:pending-movies")
        expect(row).to_be_visible()
        link = row.get_by_role("link", name="View all", exact=True)
        expect(link).to_have_attribute("href", re.compile(r"sort=title&order=desc&w=unfinished"))
        link.click()
        control = page.get_by_test_id("kind-watch-filter")
        expect(control).to_have_value("unfinished")
        expect(page.get_by_test_id("kind-watch-clear")).to_have_text("Unfinished ×")
        page.screenshot(path=str(root / "unfinished-list.png"), full_page=True)
        expect(page.get_by_text(re.compile(r"^69 titles ·"))).to_be_visible()
        # 首次请求和后续翻页都带同一观看条件与方向。
        page.locator("[data-library-item-id]").last.scroll_into_view_if_needed()
        deadline = time.monotonic() + 30
        while not any("offset=60" in url and "w=unfinished" in url for url in requests):
            assert time.monotonic() < deadline
            page.locator("[data-library-item-id]").last.scroll_into_view_if_needed()
            page.wait_for_timeout(100)
        assert all(
            "w=unfinished" in url and "order=desc" in url
            for url in requests
            if "/libraries/kinds/movie/items?" in url
        )
        page.reload()
        expect(page.get_by_test_id("kind-watch-filter")).to_have_value("unfinished")
        # 空筛选也保留清除入口。
        page.get_by_test_id("kind-watch-filter").select_option("favorite")
        expect(
            page.get_by_text("No matching titles. Change or clear the watch filter.")
        ).to_be_visible()
        page.get_by_test_id("kind-watch-clear").click()
        expect(page.get_by_test_id("kind-watch-filter")).to_have_value("")
        expect(page.get_by_text(re.compile(r"^70 titles ·"))).to_be_visible()
        assert "sort=title" in page.url and "order=desc" in page.url and "w=" not in page.url
        # 清除仅改变当前列表，不回写首页配置。
        assert api("get", "/ui/preferences")["home"]["rows"][0]["unfinished"] is True
        page.goto(base + "/library")
        page.get_by_test_id("home-row-row:pending-tv").get_by_role(
            "link", name="View all", exact=True
        ).click()
        expect(page.get_by_test_id("kind-watch-filter")).to_have_value("unfinished")
        expect(page.get_by_text(re.compile(r"^2 titles ·"))).to_be_visible()
        # 看完前三集但没有续播点的剧依然可见；单个作品详情往返不丢条件。
        card = page.locator("[data-library-item-id]").first
        card.locator("a").first.click()
        page.wait_for_url(re.compile(r"/library/\d+/item/\d+"))
        page.go_back()
        expect(page.get_by_test_id("kind-watch-filter")).to_have_value("unfinished")
        expect(page.get_by_text(re.compile(r"^2 titles ·"))).to_be_visible()
        # 单库入口也继承观看条件和排序。
        page.goto(base + "/library")
        page.get_by_test_id(f"home-row-lib:{movie_library}").get_by_role(
            "link", name="View all", exact=True
        ).click()
        page.wait_for_url(re.compile(rf"/library/{movie_library}\?"))
        assert "w=unfinished" in page.url and "sort=title" in page.url
        expect(page.get_by_role("button", name="Remove Watch status: Unfinished")).to_be_visible()
        page.get_by_role("button", name="Sort", exact=True).click()
        default_sort = page.get_by_role("menuitemradio", checked=True)
        expect(default_sort).to_contain_text("By title")
        default_sort.click()
        expect(page).to_have_url(re.compile(r"sort=title&order=desc&w=unfinished"))
        assert page.evaluate("localStorage.getItem('movieclaw.library.wall-sort')") == "default:rev"
        page.keyboard.press("Escape")
        page.get_by_role("button", name="Remove Watch status: Unfinished").click()
        assert "w=" not in page.url and "sort=title" in page.url
        page.goto(base + "/library")
        page.get_by_test_id("home-row-row:seen").get_by_role(
            "link", name="View all", exact=True
        ).click()
        expect(
            page.get_by_role("button", name="Remove Watch status: Previously watched")
        ).to_be_visible()
        assert "w=seen" in page.url
        # 「最近添加」的 URL 排序映射到默认菜单项；点击当前项应反转方向。
        page.goto(base + "/library/kind/movie?sort=added_at&order=asc&w=unfinished")
        page.get_by_role("button", name="Sort", exact=True).click()
        selected = page.get_by_role("menuitemradio", checked=True)
        expect(selected).to_contain_text("Recently added")
        selected.click()
        expect(page).to_have_url(re.compile(r"sort=added_at&order=desc&w=unfinished"))
        page.keyboard.press("Escape")
        # 首页选择控件可保存新状态，旧 unwatched 不会并存。
        page.goto(base + "/library/customize")
        editable = page.get_by_test_id(f"home-row-item-lib:{tv_library}")
        editable.get_by_test_id("row-title").click()
        editable.get_by_test_id("row-watch").select_option("unfinished")
        deadline = time.monotonic() + 10
        while not any(
            r["id"] == f"lib:{tv_library}" and r.get("unfinished")
            for r in api("get", "/ui/preferences")["home"]["rows"]
        ):
            assert time.monotonic() < deadline
            page.wait_for_timeout(100)
        page.screenshot(path=str(root / "watch-filter.png"), full_page=True)
        assert not errors, errors
    finally:
        context.close()

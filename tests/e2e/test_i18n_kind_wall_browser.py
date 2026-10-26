"""Cross-library genres, paging and recent/favorite summaries on a real reader-local stack."""

import re
import sqlite3
from urllib.parse import parse_qs, urlsplit

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO

browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack
pytestmark = pytest.mark.integration


async def _seed(stack):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        FileSource,
        LibraryFile,
        MediaItem,
        MediaMetadata,
        MediaSeason,
    )
    from movieclaw_db.repositories.library_repo import LibraryRepository

    database = Database(stack["database_url"])
    folder = stack["data"] / "kind-wall-sources"
    folder.mkdir()
    paths, movie_ids, tv_ids = [], [], []
    try:
        async with database.session() as session:
            libs = []
            for name, kind in [
                ("作者电影库 A", "movie"),
                ("作者电影库 B", "movie"),
                ("作者剧集库", "tv"),
            ]:
                library = await LibraryRepository(session).create(
                    name=name, kind=kind, root_paths=[str(folder)]
                )
                libs.append(library.id)
            for index in range(62):
                item = MediaItem(
                    kind="movie",
                    tmdb_id=960000 + index,
                    title=f"作者电影 {index:02}",
                    original_title=f"Author movie {index:02}",
                    year=2024,
                )
                session.add(item)
                await session.flush()
                movie_ids.append(item.id)
                session.add(
                    MediaMetadata(
                        media_item_id=item.id,
                        genre_ids=[16 if index % 2 == 0 else 878],
                        vote_average=index / 10,
                    )
                )
                for library_id in libs[:2] if index == 0 else [libs[0]]:
                    path = folder / f"movie-{item.id}-{library_id}.mkv"
                    path.write_bytes(f"Original movie {item.id} in library {library_id}".encode())
                    paths.append(path)
                    session.add(
                        LibraryFile(
                            library_id=library_id,
                            media_item_id=item.id,
                            file_path=str(path),
                            size_bytes=path.stat().st_size,
                            source=FileSource.SCANNED,
                        )
                    )
            for index, title in enumerate(("作者整季", "作者连续集", "作者跨季")):
                item = MediaItem(
                    kind="tv", tmdb_id=970000 + index, title=title, original_title=title, year=2024
                )
                session.add(item)
                await session.flush()
                tv_ids.append(item.id)
                session.add(MediaMetadata(media_item_id=item.id, genre_ids=[10765]))
                units = [(2, 1), (2, 2), (2, 3)] if index < 2 else [(1, 1), (2, 1)]
                for season in {unit[0] for unit in units}:
                    session.add(
                        MediaSeason(
                            media_item_id=item.id,
                            season_number=season,
                            episode_count=3 if index == 0 else 10,
                        )
                    )
                for season, episode in units:
                    path = folder / f"tv-{item.id}-{season}-{episode}.mkv"
                    path.write_bytes(f"Original episode {item.id} {season} {episode}".encode())
                    paths.append(path)
                    session.add(
                        LibraryFile(
                            library_id=libs[2],
                            media_item_id=item.id,
                            season_number=season,
                            episode_number=episode,
                            file_path=str(path),
                            size_bytes=path.stat().st_size,
                            source=FileSource.SCANNED,
                            added_batch_id=f"author-batch-{index}",
                        )
                    )
            await session.commit()
            await LibraryRepository(session).refresh_stats(libs)
        return {"libraries": libs, "movies": movie_ids, "shows": tv_ids, "paths": paths}
    finally:
        await database.dispose()


@pytest.fixture(scope="module")
def inventory(stack):
    return _run(_seed(stack))


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_reader_local_walls_preserve_scope_sort_and_batches(
    stack, browser, inventory, theme_id, width
):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": width, "height": 1100},
        is_mobile=width == 320,
        has_touch=width == 320,
    )
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(path):
        response = context.request.get(base + "/api/v1" + path)
        assert response.ok, response.text()
        return response.json()["data"]

    preferences = api("/ui/preferences")
    preferences.update(
        theme=theme_id,
        theme_desktop=theme_id,
        theme_mobile=theme_id,
        language="en",
        home={"rows": [{"id": "kind:movie", "sort": "added_at", "name": "作者总览"}]},
    )
    assert context.request.put(base + "/api/v1/ui/preferences", data=preferences).ok
    expected_home = api("/ui/preferences")["home"]
    context.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
    for index, item_id in enumerate(inventory["shows"]):
        marked = context.request.post(
            base + "/api/v1/playback/marks",
            data={
                "media_item_id": item_id,
                "season_number": 2 if index != 2 else 0,
                "favorite": True,
            },
        )
        assert marked.ok, marked.text()

    def facts():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return [
                db.execute(query).fetchall()
                for query in [
                    "SELECT id, title, tmdb_id FROM media_item ORDER BY id",
                    "SELECT media_item_id, genre_ids FROM media_metadata ORDER BY media_item_id",
                    "SELECT media_item_id, season_number, episode_number, "
                    "added_batch_id, file_path "
                    "FROM library_file ORDER BY id",
                    "SELECT media_item_id, season_number, episode_number, is_favorite "
                    "FROM playback_state ORDER BY id",
                ]
            ]

    original = facts(), [path.read_bytes() for path in inventory["paths"]]
    page = context.new_page()
    page.set_default_timeout(30000)
    errors, item_reads = [], []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on(
        "response",
        lambda response: (
            item_reads.append(response) if "/libraries/kinds/movie/items?" in response.url else None
        ),
    )
    shots = REPO / ".tmp-uidev/i18n/kind-wall"
    shots.mkdir(parents=True, exist_ok=True)
    page.goto(base + "/library")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", theme_id)
    entry = page.get_by_test_id("home-row-kind:movie").get_by_role(
        "link", name="View all", exact=True
    )
    expect(entry).to_be_visible()
    # Retry a real read after an HTTP failure. No internal UI or data helper is mocked.
    page.route(
        "**/api/v1/libraries/kinds/movie/items?**",
        lambda route: route.fulfill(status=503, json={"detail": "Fixture unavailable"}),
    )
    entry.click()
    expect(page.get_by_text("Could not load", exact=True)).to_be_visible()
    page.unroute("**/api/v1/libraries/kinds/movie/items?**")
    page.get_by_role("button", name="Retry", exact=True).click()
    expect(page.get_by_role("heading", name="All movies", exact=True)).to_be_visible()
    expect(
        page.get_by_text("62 titles · 2 libraries, with each title counted once", exact=True)
    ).to_be_visible()
    # Scroll to the actual pagination sentinel and reconcile the second page by raw IDs.
    with page.expect_response(
        lambda response: (
            "/libraries/kinds/movie/items?" in response.url
            and parse_qs(urlsplit(response.url).query).get("offset") == ["60"]
        )
    ):
        page.locator('div[aria-live="polite"][class*="mt-8"]').scroll_into_view_if_needed()
    pages = [response.json()["data"] for response in item_reads if response.ok]
    assert len({row["media_item_id"] for rows in pages for row in rows}) == 62
    sort = page.get_by_role("button", name="Sort", exact=True)
    sort.click()
    with page.expect_response(
        lambda response: (
            "/libraries/kinds/movie/items?" in response.url and "sort=rating" in response.url
        )
    ):
        page.get_by_role("menuitemradio", name=re.compile("^By rating")).click()
    page.keyboard.press("Escape")
    sort.click()
    with page.expect_response(
        lambda response: (
            "/libraries/kinds/movie/items?" in response.url and "order=asc" in response.url
        )
    ):
        page.get_by_role("menuitemradio", name=re.compile("^By rating")).click()
    page.keyboard.press("Escape")
    storage_key = "movieclaw.library.kind-wall-sort.movie"
    assert page.evaluate("key => localStorage.getItem(key)", storage_key) == "rating:rev"
    expect(sort).to_have_attribute("title", "By rating · Low → high")
    filtered_ids = None
    for language in ("en", "zh-Hans", "en"):
        page.goto(base + "/settings/appearance")
        control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
        control.check()
        expect(control).to_be_enabled()
        page.goto(base + "/library")
        expect(page.locator("html")).to_have_attribute("lang", language)
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", theme_id)
        genres = page.get_by_test_id("home-row-genres:movie")
        card = genres.locator('a[href="/library/kind/movie?g=16"]')
        expect(card).to_have_attribute(
            "aria-label",
            "Browse Animation, 31 movies" if language == "en" else "浏览动画，31 部电影",
        )
        card.scroll_into_view_if_needed()
        page.screenshot(
            path=str(shots / f"{theme_id}-{width}-{language}-genre.png"), animations="disabled"
        )
        with page.expect_response(
            lambda response: (
                "/libraries/kinds/movie/items?" in response.url
                and parse_qs(urlsplit(response.url).query).get("g") == ["16"]
            )
        ):
            card.click()
        expect(
            page.get_by_role(
                "heading", name="Animation" if language == "en" else "动画", exact=True
            )
        ).to_be_visible()
        rows = api("/libraries/kinds/movie/items?g=16&sort=rating&order=asc&limit=60")
        ids = [row["media_item_id"] for row in rows]
        assert ids == inventory["movies"][::2]
        if filtered_ids is None:
            filtered_ids = ids
        assert ids == filtered_ids
        assert page.evaluate("key => localStorage.getItem(key)", storage_key) == "rating:rev"
        page.screenshot(
            path=str(shots / f"{theme_id}-{width}-{language}-wall.png"), animations="disabled"
        )
        page.goto(base + "/library")
        recent = page.get_by_test_id(f"home-row-lib:{inventory['libraries'][2]}")
        expect(
            recent.locator("a").filter(has=page.get_by_text("作者整季", exact=True))
        ).to_have_attribute(
            "aria-label",
            re.compile("Season 2 · All 3 episodes" if language == "en" else "第2季 · 全3集"),
        )
        expect(
            recent.locator("a").filter(has=page.get_by_text("作者连续集", exact=True))
        ).to_have_attribute("aria-label", re.compile("S02E01–03"))
        expect(
            recent.locator("a").filter(has=page.get_by_text("作者跨季", exact=True))
        ).to_have_attribute(
            "aria-label",
            re.compile("Added 2 seasons · 2 episodes" if language == "en" else "新增2季 · 2集"),
        )
        favorite = page.get_by_test_id("favorites-row")
        expect(
            favorite.locator("a").filter(has=page.get_by_text("作者整季", exact=True))
        ).to_have_attribute(
            "aria-label", re.compile("Favorited Season 2" if language == "en" else "收藏了第 2 季")
        )
        assert api("/ui/preferences")["home"] == expected_home
        assert facts() == original[0]
        assert [path.read_bytes() for path in inventory["paths"]] == original[1]
    page.goto(base + "/library/kind/movie?g=999999")
    expect(page.get_by_role("heading", name="Genre 999999", exact=True)).to_be_visible()
    page.goto(base + "/library/kind/video")
    expect(page.get_by_text("No other video libraries to browse yet", exact=True)).to_be_visible()
    for kind, title in [("movie", "Movie subscriptions"), ("tv", "Series subscriptions")]:
        page.goto(base + "/subscriptions/wall/" + kind)
        expect(page).to_have_title(re.compile(title))
    assert not errors, errors
    context.close()

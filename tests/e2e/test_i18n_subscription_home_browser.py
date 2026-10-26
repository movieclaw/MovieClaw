"""Subscription shelves, week calendar and recent playback with real API/SQLite/media."""

import re
import shutil
import subprocess
from datetime import timedelta

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run

stack = inventory.stack
browser = theme.browser
pytestmark = pytest.mark.integration


async def _seed(database_url, roots, clip, default_rule, custom_rule):
    from sqlmodel import select
    from tests.api.subscription_ordering_fixture import seed_subscription_ordering

    from movieclaw_api.services.media_probe import probe_media
    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        Library,
        LibraryFile,
        MediaEpisode,
        MediaItem,
        MediaSeason,
        Subscription,
        WantedItem,
        utcnow,
    )

    database = Database(database_url)
    try:
        async with database.session() as session:
            ids = await seed_subscription_ordering(session)
            libraries = (await session.execute(select(Library))).scalars().all()
            for library in libraries:
                library.root_paths = [str(roots["shows" if library.kind == "tv" else "movies"])]
                session.add(library)
            for kind in ("movie", "tv"):
                rows = (
                    (
                        await session.execute(
                            select(WantedItem).where(
                                WantedItem.subscription_id == ids[kind]["pipeline"]
                            )
                        )
                    )
                    .scalars()
                    .all()
                )
                for row in rows:
                    row.info_hash = f"{row.subscription_id:040x}"
                    row.grabbed_at = utcnow() - timedelta(minutes=1)
                    session.add(row)
                sub = await session.get(Subscription, ids[kind]["search"])
                sub.selection_mode = "rules"
                sub.smart_policy = None
                sub.rule_set_id = default_rule if kind == "movie" else custom_rule
                session.add(sub)
            recent = await session.get(Subscription, ids["tv"]["done"])
            files = (
                (
                    await session.execute(
                        select(LibraryFile).where(LibraryFile.media_item_id == recent.media_item_id)
                    )
                )
                .scalars()
                .all()
            )
            spec = probe_media(clip)
            assert spec
            for file in files:
                destination = roots["shows"] / f"Recent.S01E{file.episode_number:02d}.mp4"
                shutil.copyfile(clip, destination)
                file.file_path = str(destination)
                file.size_bytes = destination.stat().st_size
                file.container = "mp4"
                for field in (
                    "video_codec",
                    "resolution",
                    "duration_seconds",
                    "bit_depth",
                    "frame_rate",
                    "color_space",
                    "audio_streams",
                    "subtitle_streams",
                ):
                    setattr(file, field, getattr(spec, field))
                session.add(file)
            for row in (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == recent.id)
                )
            ).scalars():
                row.imported_at = utcnow() - timedelta(minutes=5)
                session.add(row)
            for episode in (
                await session.execute(
                    select(MediaEpisode).where(MediaEpisode.media_item_id == recent.media_item_id)
                )
            ).scalars():
                episode.name = f"原始集名 {episode.episode_number}"
                session.add(episode)
            future = MediaItem(
                kind="tv",
                tmdb_id=989999,
                title="未来更新",
                original_title="Upcoming Raw",
                status="Returning Series",
            )
            session.add(future)
            await session.flush()
            future_sub = Subscription(
                media_item_id=future.id,
                kind="tv",
                selected_seasons=[1],
                follow_future=True,
                rule_set_id=default_rule,
                library_id=next(library.id for library in libraries if library.kind == "tv"),
            )
            session.add(future_sub)
            await session.flush()
            day = utcnow().date() + timedelta(days=2)
            session.add(
                MediaSeason(
                    media_item_id=future.id, season_number=1, name="第 1 季", episode_count=1
                )
            )
            session.add(
                MediaEpisode(
                    media_item_id=future.id, season_number=1, episode_number=1, air_date=day
                )
            )
            session.add(
                WantedItem(
                    subscription_id=future_sub.id,
                    media_item_id=future.id,
                    season_number=1,
                    episode_number=1,
                    air_date=day,
                    next_search_at=utcnow() + timedelta(days=2),
                )
            )
            await session.commit()
            return ids, future_sub.id, day.day, recent.media_item_id
    finally:
        await database.dispose()


def test_home_walls_calendar_and_recent_playback_follow_locale(stack, browser, tmp_path):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/subscription-home"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    default = next(rule for rule in api("get", "/rule-sets") if rule["is_default"])
    custom = api("post", "/rule-sets", data={"name": "我的规则", "spec": {}})
    clip = tmp_path / "clip.mp4"
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x180:r=24:d=90",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=90",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-movflags",
            "+faststart",
            str(clip),
        ],
        check=True,
    )
    ids, future_id, day_number, recent_item = _run(
        _seed(stack["database_url"], stack["roots"], clip, default["id"], custom["id"])
    )
    raw = (
        [sub["media"]["title"] for sub in api("get", "/subscriptions")]
        + [library["name"] for library in api("get", "/libraries")]
        + ["我的规则", "原始集名 1", "原始集名 2"]
    )

    def english():
        text = page.locator("body").inner_text()
        for value in sorted(raw, key=len, reverse=True):
            text = text.replace(value, "")
        assert not re.search(r"[\u3400-\u9fff]", text), text

    def theme_page(theme_id, width, path):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + path)
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        theme_page(theme_id, width, "/subscriptions")
        page.locator("[data-subscription-id]").first.wait_for()
        if theme_id == "silver":
            expect(page.get_by_role("heading", name="Schedule", exact=True)).to_be_visible()
            expect(page.get_by_role("heading", name="Just added", exact=True)).to_be_visible()
            for kind in ("tv", "movie"):
                section = page.locator(f'section[aria-labelledby="subs-shelf-{kind}"]')
                expected = [ids[kind]["pipeline"]]
                if kind == "tv":
                    expected.append(future_id)
                expected += [
                    ids[kind][state] for state in ("mixed", "search", "upgrade", "paused", "done")
                ]
                assert (
                    section.locator("[data-subscription-id]").evaluate_all(
                        "els => els.map(el => Number(el.dataset.subscriptionId))"
                    )
                    == expected
                )
            tab = page.get_by_role("tab", name=re.compile("1 title releasing$"))
            tab.click()
            expect(tab).to_have_attribute("aria-selected", "true")
            expect(page.get_by_role("tabpanel")).to_contain_text("未来更新")
        english()
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-home-en.png")
        if theme_id == "silver":
            shelf = page.locator('section[aria-labelledby="subs-shelf-tv"]')
            shelf.scroll_into_view_if_needed()
            _snapshot(page, shots / f"{theme_id}-{width}-shelf-en.png")
            shelf.locator(
                f'[data-subscription-id="{ids["tv"]["paused"]}"]'
            ).scroll_into_view_if_needed()
            _snapshot(page, shots / f"{theme_id}-{width}-resting-en.png")
        for kind in ("movie", "tv"):
            page.goto(base + f"/subscriptions/wall/{kind}")
            active = page.get_by_role("region", name="In progress", exact=True)
            active.locator("[data-subscription-id]").first.wait_for()
            expected = [ids[kind]["pipeline"]]
            if kind == "tv":
                expected.append(future_id)
            expected += [ids[kind][state] for state in ("mixed", "search", "upgrade")]
            page.wait_for_function(
                """ids => JSON.stringify([...document.querySelectorAll(
                    'section[aria-label="In progress"] [data-subscription-id]'
                )].map(el => Number(el.dataset.subscriptionId))) === JSON.stringify(ids)""",
                arg=expected,
            )
            expect(
                page.get_by_text(
                    "Default rule set" if kind == "movie" else "我的规则", exact=False
                ).first
            ).to_be_visible()
            english()
            assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
            _snapshot(page, shots / f"{theme_id}-{width}-{kind}-wall-en.png")

    theme_page("silver", 1280, "/subscriptions")
    tab = page.get_by_role("tab", name=re.compile("1 title releasing$"))
    tab.click()
    page.evaluate("window.homeMarker = 716")
    for locale in ("zh-Hans", "en"):
        _change_language(page, locale)
        # Opening settings replaces the existing page subtree; return to the same calendar.
        tab = page.get_by_role("tab", name=re.compile("1 (title releasing|部更新)$"))
        tab.click()
        expect(tab).to_contain_text(str(day_number))
        expect(page.get_by_role("tabpanel")).to_contain_text("未来更新")
        assert page.evaluate("window.homeMarker") == 716
        if locale == "en":
            english()
        _snapshot(page, shots / f"same-document-{locale}.png")
    recent = page.locator('section[aria-labelledby="subs-recent-title"]').get_by_role("link").first
    expect(recent).to_have_attribute("href", f"/play/{recent_item}/s01e01")
    recent.click()
    page.wait_for_url(f"**/play/{recent_item}/s01e01")
    video = page.locator("video").first
    expect(video).to_be_visible()
    page.wait_for_function("document.querySelector('video')?.readyState >= 2", timeout=30_000)
    _snapshot(page, shots / "recent-playback-en.png")
    assert not errors
    context.close()

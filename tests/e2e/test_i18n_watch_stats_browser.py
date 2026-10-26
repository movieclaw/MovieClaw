"""Real statistics API and SQLite: metrics, comparisons, drilldown, charts and empty periods."""

import re
from datetime import timedelta

import pytest

from . import test_smart_subscription_browser as smart
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run

stack = smart.smart_stack
browser = theme.browser
pytestmark = pytest.mark.integration


async def _seed(database_url, root):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        Library,
        LibraryFile,
        MediaItem,
        MediaMetadata,
        Member,
        PlaybackLog,
        PlaybackMetric,
        utcnow,
    )

    db = Database(database_url)
    try:
        async with db.session() as session:
            library = Library(name="Raw library", kind="movie", root_paths=[str(root / "movies")])
            session.add(library)
            await session.flush()
            members = [
                Member(username=f"RawMember{i}", password_hash="fixture-login-disabled")
                for i in range(1, 9)
            ]
            quiet = Member(username="QuietMember", password_hash="fixture-login-disabled")
            past = Member(username="PastMember", password_hash="fixture-login-disabled")
            session.add_all([*members, quiet, past])
            await session.flush()
            now = utcnow()
            (root / "movies").mkdir()
            items = []
            for index, member in enumerate(members):
                media = MediaItem(
                    kind="movie",
                    tmdb_id=909100 + index,
                    title=f"RawTitle{index + 1}",
                    original_title=f"RawOriginal{index + 1}",
                    year=2026,
                )
                session.add(media)
                await session.flush()
                items.append(media)
                path = root / "movies" / f"raw-{index}.mkv"
                path.write_bytes(b"statistics fixture; never played or modified")
                session.add(
                    LibraryFile(
                        library_id=library.id,
                        media_item_id=media.id,
                        file_path=str(path),
                        size_bytes=path.stat().st_size,
                        source="scanned",
                    )
                )
                session.add(MediaMetadata(media_item_id=media.id, runtime_minutes=100))
                for previous in (False, True):
                    at = now - timedelta(days=10 if previous else 2, hours=index)
                    watched = 120_000 if previous or index % 2 else 6_000_000
                    session.add(
                        PlaybackLog(
                            member_id=member.id,
                            media_item_id=media.id,
                            kind="movie",
                            title=media.title,
                            device_id=f"raw-device-{index}",
                            client=f"RawClient{index + 1}",
                            started_at=at,
                            last_seen_at=at + timedelta(milliseconds=watched),
                            ended_at=at + timedelta(milliseconds=watched),
                            watched_ms=watched,
                            start_position_ms=0,
                            end_position_ms=watched,
                        )
                    )
            for member, days in ((past, 10), (None, 70)):
                at = now - timedelta(days=days)
                session.add(
                    PlaybackLog(
                        member_id=member.id if member else 0,
                        media_item_id=items[0].id,
                        kind="movie",
                        title=items[0].title,
                        device_id=f"raw-{days}",
                        client="RawArchive",
                        started_at=at,
                        last_seen_at=at + timedelta(minutes=2),
                        ended_at=at + timedelta(minutes=2),
                        watched_ms=120_000,
                        start_position_ms=0,
                        end_position_ms=120_000,
                    )
                )
            session.add_all(
                [
                    PlaybackMetric(member_id=member.id, tier=index % 5, watched_ms=120_000)
                    for index, member in enumerate(members)
                ]
            )
            await session.commit()
            return {
                "members": [member.id for member in members],
                "quiet": quiet.id,
                "past": past.id,
            }
    finally:
        await db.dispose()


def test_statistics_metrics_charts_and_empty_drilldowns(stack, browser):
    from playwright.sync_api import expect

    base, _, root = stack
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    _run(_seed(f"sqlite+aiosqlite:///{root / 'data.db'}", root))
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/watch-stats"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english(scope):
        assert not re.search(r"[\u3400-\u9fff]", scope.inner_text()), scope.inner_text()
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    def filter_option(theme_id, label, option):
        page.get_by_role(
            "button", name="Filters" if theme_id == "silver" else label, exact=True
        ).click()
        page.get_by_role(
            "menuitemradio" if theme_id == "silver" else "menuitem", name=option, exact=True
        ).click()

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/activity?view=stats")
        expect(page.get_by_role("button", name=re.compile("^Time watched"))).to_be_visible()
        filter_option(theme_id, "Period", "Last 7 days")
        if theme_id == "silver":
            page.get_by_role("button", name="Filters", exact=True).click()
            expect(
                page.get_by_role("menuitemradio", name="Last 7 days", exact=True)
            ).to_be_checked()
            page.keyboard.press("Escape")
        else:
            expect(page.get_by_role("button", name="Period", exact=True)).to_contain_text(
                "Last 7 days"
            )
        for title in ("Time watched", "Plays", "Completion rate", "Active members"):
            button = page.get_by_role("button", name=re.compile("^" + title))
            button.click()
            expect(button).to_have_attribute("aria-pressed", "true")
            expect(page.get_by_role("img", name=title + " trend", exact=True)).to_be_visible()
            english(page.locator("main"))
        # All metric chips must fit their own cards, including long percentage-point labels.
        completion_card = page.get_by_role("button", name=re.compile("^Completion rate"))
        assert completion_card.evaluate("""button => {
          const box = button.getBoundingClientRect();
          return [...button.querySelectorAll('[title]')].every(chip => {
            const r = chip.getBoundingClientRect();
            return r.left >= box.left && r.right <= box.right && r.bottom <= box.bottom;
          });
        }""")
        for metric_title in ("Time watched", "Plays", "Completion rate", "Active members"):
            metric_card = page.get_by_role("button", name=re.compile("^" + metric_title))
            assert metric_card.evaluate("""button => {
              const chip = button.querySelector('[title]');
              if (!chip) return true;
              const previous = chip.nextElementSibling;
              const a = chip.getBoundingClientRect(), b = previous.getBoundingClientRect();
              return chip.scrollWidth <= chip.clientWidth + 1 &&
                (a.right <= b.left + 1 || a.bottom <= b.top + 1);
            }""")
        podium = page.get_by_role("region", name="Most popular this period", exact=True)
        assert podium.get_by_text("First place", exact=True).evaluate(
            "el => el.parentElement.getBoundingClientRect().width >= 90"
        )
        member_row = (
            page.get_by_role("region", name="By member", exact=True).get_by_role("button").first
        )
        assert member_row.evaluate("""row => {
          const secondary = row.querySelector('span.tnum');
          if (!secondary) return true;
          const a = secondary.previousElementSibling.getBoundingClientRect();
          const b = secondary.getBoundingClientRect();
          return a.right <= b.left + 1 || a.bottom <= b.top + 1;
        }""")
        _snapshot(page, shots / f"{theme_id}-{width}-metrics-en.png")
        titles = page.get_by_role("region", name="Most watched", exact=True)
        titles.get_by_role("button", name="Show all 8 titles", exact=True).click()
        expect(titles.get_by_text("RawTitle8", exact=True)).to_be_visible()
        titles.scroll_into_view_if_needed()
        english(titles)
        _snapshot(page, shots / f"{theme_id}-{width}-breakdown-en.png")
        heatmap = page.get_by_role("region", name="Viewing times", exact=True)
        heatmap.scroll_into_view_if_needed()
        expect(heatmap.get_by_text("Mon", exact=True)).to_be_visible()
        english(heatmap)
        _snapshot(page, shots / f"{theme_id}-{width}-heatmap-en.png")
        if width == 320:
            heatmap.locator("div.overflow-x-auto").evaluate(
                "el => { el.scrollLeft = el.scrollWidth; }"
            )
            expect(heatmap.get_by_text("18", exact=True)).to_be_in_viewport()
            _snapshot(page, shots / f"{theme_id}-{width}-heatmap-late-en.png")

        # Keep the chosen metric while changing periods; narrow charts fold into weeks.
        filter_option(theme_id, "Period", "Last 90 days")
        expect(page.get_by_role("button", name=re.compile("^Active members"))).to_have_attribute(
            "aria-pressed", "true"
        )
        chart = page.get_by_role("img", name="Active members trend", exact=True)
        chart.scroll_into_view_if_needed()
        chart.hover(position={"x": 120, "y": 80})
        english(page.locator("main"))
        _snapshot(page, shots / f"{theme_id}-{width}-trend-en.png")

    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/activity?view=stats")
    filter_option("silver", "Period", "Last 7 days")
    by_member = page.get_by_role("region", name="By member", exact=True)
    by_member.get_by_role("button", name=re.compile("RawMember1")).click()
    expect(page.get_by_role("region", name="Most watched this period", exact=True)).to_be_visible()
    filter_option("silver", "Member", "PastMember")
    expect(page.get_by_text("PastMember has no plays this period", exact=True)).to_be_visible()
    english(page.locator("main"))
    _snapshot(page, shots / "previous-only-en.png")
    filter_option("silver", "Member", "QuietMember")
    filter_option("silver", "Period", "Last 90 days")
    expect(
        page.get_by_text("QuietMember has no plays in the last 90 days", exact=True)
    ).to_be_visible()
    english(page.locator("main"))
    _snapshot(page, shots / "empty-member-en.png")
    page.get_by_role("button", name="View all members", exact=True).click()
    expect(page.get_by_role("button", name=re.compile("^Time watched"))).to_be_visible()
    page.evaluate("window.watchStatsMarker = 430")
    for locale in ("zh-Hans", "en"):
        _change_language(page, locale)
        expect(page.get_by_text("RawTitle1", exact=True).first).to_be_visible()
        if locale == "en":
            english(page.locator("main"))
        assert page.evaluate("window.watchStatsMarker") == 430
    assert not errors
    context.close()

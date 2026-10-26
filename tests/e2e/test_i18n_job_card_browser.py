"""Localized task cards with persistent mute/undo and an actual library-scan retry."""

import re

import pytest

from . import test_smart_subscription_browser as smart
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import _wait_for

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    # Empty-library scans still construct a metadata client. Keep it isolated from real services.
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("TMDB_API_KEY", "isolated-job-card-test")
        patch.setenv("TMDB_API_BASE_URL", "http://127.0.0.1:1")
        yield from smart.smart_stack.__wrapped__(tmp_path_factory)


async def _seed(database_url, root):
    from movieclaw_api.i18n.stored import stored_fields
    from movieclaw_api.services import jobs
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Job, JobStatus, Library, LibraryFile, MediaItem, utcnow

    db = Database(database_url)
    try:
        async with db.session() as session:
            roots = {name: root / name for name in ("stock", "empty")}
            for path in roots.values():
                path.mkdir()
            libraries = []
            for name, path in roots.items():
                library = Library(name=f"原始{name}库", kind="movie", root_paths=[str(path)])
                session.add(library)
                await session.flush()
                libraries.append(library)
            media = MediaItem(
                kind="movie", tmdb_id=797700, title="原始作品", original_title="Original raw"
            )
            session.add(media)
            await session.flush()
            path = roots["stock"] / "Original.Movie.mkv"
            path.write_bytes(b"existing media bytes stay intact during dismissal")
            file = LibraryFile(
                library_id=libraries[0].id,
                media_item_id=media.id,
                file_path=str(path),
                size_bytes=path.stat().st_size,
                source="scanned",
            )
            session.add(file)
            await session.flush()
            error = {
                "code": "LAB_FAILURE",
                **stored_fields("activity.jobs.handlerUnavailable"),
                "actions": [
                    {"type": "retry_job", "label": "重试", "label_key": "activity.jobs.retry"}
                ],
            }
            subtitle = Job(
                id="job_i18n_subtitle",
                job_type="subtitle.generate",
                subject="原始字幕任务",
                status=JobStatus.FAILED,
                origin="scheduler",
                actor_name="原始发起人",
                input_data={
                    "file_id": file.id,
                    "target_language": "chs",
                    "secondary_language": "eng",
                },
                progress={
                    **jobs.default_progress(),
                    "phase": "translating",
                    "mode": "determinate",
                    "current": 1,
                    "total": 2,
                    "percent": 50,
                    "phase_index": 2,
                    "phase_count": 3,
                    "details": {
                        "done_events": 1,
                        "total_events": 2,
                        "parallelism": 2,
                        "rate_limit_count": 1,
                    },
                },
                error=error,
                finished_at=utcnow(),
                provider_ref="Original Provider",
                usage={
                    "request_count": 1,
                    "failed_request_count": 1,
                    "prompt_tokens": 12345,
                    "completion_tokens": 2,
                    "total_tokens": 12347,
                    "cache_read_tokens": 4,
                    "total_duration_ms": 1550,
                    "max_duration_ms": 950,
                },
            )
            scan = Job(
                id="job_i18n_scan",
                job_type="library.scan",
                subject="原始扫描任务",
                status=JobStatus.FAILED,
                input_data={"library_id": libraries[1].id},
                progress=jobs.default_progress(),
                error=error,
                finished_at=utcnow(),
            )
            session.add(subtitle)
            session.add(scan)
            await session.commit()
            return {"subtitle": subtitle.id, "scan": scan.id, "file": file.id, "path": path}
    finally:
        await db.dispose()


async def _mutes(database_url, file_id):
    from sqlmodel import select

    from movieclaw_db.engine import Database
    from movieclaw_db.models import SubtitleAutoMute

    db = Database(database_url)
    try:
        async with db.session() as session:
            return [
                row.target_language
                for row in (
                    await session.execute(
                        select(SubtitleAutoMute).where(SubtitleAutoMute.library_file_id == file_id)
                    )
                ).scalars()
            ]
    finally:
        await db.dispose()


def test_cards_usage_mute_restore_and_real_scan_retry(stack, browser):
    from playwright.sync_api import expect

    base, _, root = stack
    database_url = f"sqlite+aiosqlite:///{root / 'data.db'}"
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    data = _run(_seed(database_url, root))
    original = data["path"].read_bytes()
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/job-card"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def card(title):
        return page.locator("article").filter(
            has=page.get_by_role("heading", name=title, exact=True)
        )

    def english(scope):
        text = scope.inner_text()
        for raw in ("原始字幕任务", "原始扫描任务", "原始发起人"):
            text = text.replace(raw, "")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/activity?view=attention")
        expect(page.locator("html")).to_have_attribute("lang", "en")
        subtitle = card("原始字幕任务")
        expect(subtitle).to_be_visible()
        expect(subtitle.get_by_role("img", name="Status: Unfinished", exact=True)).to_be_visible()
        expect(subtitle.get_by_text("Translating subtitles", exact=False)).to_be_visible()
        expect(
            subtitle.get_by_text("Simplified Chinese + English (bilingual)", exact=True)
        ).to_be_visible()
        subtitle.get_by_role("button", name=re.compile("View model usage")).click()
        expect(subtitle.get_by_text("12,347 tokens · 1 request", exact=True)).to_be_visible()
        expect(subtitle.get_by_text("950 milliseconds", exact=False)).to_be_visible()
        english(subtitle)
        subtitle.scroll_into_view_if_needed()
        _snapshot(page, shots / f"{theme_id}-{width}-usage-en.png")
        subtitle.get_by_role("button", name="More actions for 原始字幕任务", exact=True).click()
        page.get_by_role("menuitem", name="Dismiss this task", exact=True).click()
        dialog = page.get_by_role("dialog", name="Dismiss task", exact=True)
        expect(dialog.get_by_role("checkbox")).to_be_checked()
        english(dialog)
        _snapshot(page, shots / f"{theme_id}-{width}-dismiss-en.png")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        expect(dialog).to_be_hidden()
        assert api("get", f"/jobs/{data['subtitle']}")["dismissed_at"] is None
        subtitle.get_by_role("button", name="More actions for 原始字幕任务", exact=True).click()
        page.get_by_role("menuitem", name="Dismiss this task", exact=True).click()
        expect(dialog.get_by_role("checkbox")).to_be_checked()
        dialog.get_by_role("button", name="Dismiss", exact=True).click()
        expect(dialog).to_be_hidden()
        expect(subtitle).to_have_count(0)
        saved = api("get", f"/jobs/{data['subtitle']}")
        assert saved["status"] == "failed" and saved["dismissed_at"]
        assert _run(_mutes(database_url, data["file"])) == ["chs"]
        assert data["path"].read_bytes() == original
        api("post", f"/jobs/{data['subtitle']}/undismiss")
        assert _run(_mutes(database_url, data["file"])) == []

    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/activity?view=attention")
    page.evaluate("window.jobCardMarker = 406")
    for locale in ("zh-Hans", "en"):
        _change_language(page, locale)
        subtitle = card("原始字幕任务")
        expect(subtitle).to_be_visible()
        if locale == "en":
            english(subtitle)
        else:
            expect(subtitle.get_by_text("简体中文 + 英语（双语）", exact=True)).to_be_visible()
        assert page.evaluate("window.jobCardMarker") == 406
        _snapshot(page, shots / f"same-document-{locale}.png")
    scan = card("原始扫描任务")
    scan.get_by_role("button", name="More actions for 原始扫描任务", exact=True).click()
    with page.expect_response(
        lambda response: f"/jobs/{data['scan']}/retry" in response.url
    ) as retry:
        page.get_by_role("menuitem", name="Retry", exact=True).click()
    assert retry.value.ok
    retried = retry.value.json()["data"]["job"]
    assert retried["retry_of_job_id"] == data["scan"]
    assert retried["input_data"]["library_id"]
    _wait_for(
        lambda: api("get", f"/jobs/{retried['id']}")["status"] == "succeeded",
        timeout=30,
        what="actual empty-library scan retry",
    )
    assert api("get", f"/jobs/{data['scan']}")["status"] == "failed"
    assert data["path"].read_bytes() == original
    assert not errors
    context.close()

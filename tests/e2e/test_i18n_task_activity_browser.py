"""Translated task timelines, file histories, delete defaults and protected cleanup."""

import os
import re
import subprocess
import sys

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import _free_port, _wait_http

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("task-activity-i18n")
    api_port, web_port = _free_port(), _free_port()
    api_log = (root / "api.log").open("w")
    web_log = (root / "web.log").open("w")
    env = {
        **os.environ,
        "DATABASE_URL": f"sqlite+aiosqlite:///{root / 'data.db'}",
        "SECRET_KEY_FILE": str(root / "secret"),
        "SCHEDULER_ENABLED": "false",
        "SUBSCRIPTION_DISPATCH_DRY_RUN": "true",
        "METADATA_DIR": str(root / "metadata"),
        "LOG_DIR": str(root / "logs"),
        "PYTHONPATH": f"{theme.REPO / 'src'}:{theme.REPO}",
        "E2E_TASK_FILES": str(root / "files"),
    }
    api = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._task_activity_launcher:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(api_port),
        ],
        cwd=theme.REPO,
        env=env,
        stdout=api_log,
        stderr=subprocess.STDOUT,
    )
    web = subprocess.Popen(
        ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
        cwd=theme.WEB,
        env={
            **os.environ,
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
            "NEXT_DIST_DIR": ".next-smart-e2e",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 120)
        yield f"http://127.0.0.1:{web_port}", f"http://127.0.0.1:{api_port}", root
    finally:
        for proc in (web, api):
            proc.terminate()
        for proc in (web, api):
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        api_log.close()
        web_log.close()


async def _seed(database_url):
    from datetime import timedelta

    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        DownloaderClient,
        Job,
        JobStatus,
        MediaItem,
        RatioBoostTask,
        RuleSet,
        SiteCredential,
        Subscription,
        SubscriptionDownloadAttempt,
        WantedItem,
        utcnow,
    )

    db = Database(database_url)
    try:
        async with db.session() as session:
            downloader = DownloaderClient(
                name="原始下载器",
                client_type="qbittorrent",
                url="http://127.0.0.1:1",
                status="active",
            )
            media = MediaItem(
                kind="tv", tmdb_id=987651, title="原始剧集", original_title="Raw Show"
            )
            rule = RuleSet(name="原始规则", is_default=True)
            session.add_all([downloader, media, rule])
            await session.flush()
            sub = Subscription(
                media_item_id=media.id, kind="tv", selected_seasons=[1], rule_set_id=rule.id
            )
            session.add(sub)
            await session.flush()
            session.add_all(
                [
                    WantedItem(
                        subscription_id=sub.id,
                        media_item_id=media.id,
                        season_number=1,
                        episode_number=i,
                        status="imported" if i == 1 else "grabbed",
                        info_hash="a" * 40,
                    )
                    for i in (1, 2, 3)
                ]
            )
            session.add(
                SubscriptionDownloadAttempt(
                    subscription_id=sub.id,
                    downloader_id=downloader.id,
                    info_hash="a" * 40,
                    site_id="raw-site",
                    torrent_id="1",
                    torrent_title="Raw.Show.S01",
                    units=[[1, 1], [1, 2], [1, 3]],
                    owned_by_movieclaw=True,
                    status="active",
                    last_progress_at=utcnow(),
                )
            )
            session.add(
                RatioBoostTask(
                    site_id="raw-site",
                    torrent_id="2",
                    info_hash="c" * 40,
                    downloader_id=downloader.id,
                    title="Raw.Boost",
                    size_bytes=2048,
                    completed=True,
                    completed_at=utcnow(),
                    created_at=utcnow(),
                    hit_and_run=True,
                )
            )
            session.add(SiteCredential(site_id="raw-site", auth_type="cookie", boost_enabled=False))
            session.add(
                Job(
                    id="job_i18n_import_history",
                    job_type="library.ingest",
                    status=JobStatus.SUCCEEDED,
                    subject="原始剧集",
                    input_data={"ready_files": ["Raw.Show.S01E01.mkv", "Raw.Show.S01E02.mkv"]},
                    progress={
                        "phase": "done",
                        "mode": "indeterminate",
                        "message": "复制 1 个文件",
                        "details": {
                            "imported_files": ["Raw.Show.S01E01.mkv"],
                            "already_present_files": ["Raw.Show.S01E02.mkv"],
                        },
                    },
                    finished_at=utcnow() - timedelta(minutes=1),
                )
            )
            await session.commit()
    finally:
        await db.dispose()


def test_timelines_history_delete_and_protected_cleanup(stack, browser):
    from playwright.sync_api import expect

    base, direct, root = stack
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    _run(_seed(f"sqlite+aiosqlite:///{root / 'data.db'}"))
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/task-activity"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english(scope):
        text = scope.inner_text()
        for raw in ("原始剧集", "原始下载器", "原始规则"):
            text = text.replace(raw, "")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        assert context.request.post(direct + "/__lab/task-reset").ok
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/activity?view=active")
        expect(page.locator("html")).to_have_attribute("lang", "en")
        expect(page.get_by_text("原始剧集", exact=True).first).to_be_visible()
        coverage = page.locator("summary").filter(has_text="1 episode imported")
        coverage.click()
        expect(page.get_by_text("E01", exact=True)).to_be_visible()
        expect(page.get_by_text("E03", exact=True)).to_be_visible()
        english(page.locator("main"))
        _snapshot(page, shots / f"{theme_id}-{width}-active-en.png")
        # External downloads are observed, and removal is an explicit opt-in for data files.
        external = page.locator("article").filter(has_text="Raw.External.Movie")
        expect(external).to_be_visible()
        external.get_by_role(
            "button", name="More actions for Raw.External.Movie", exact=True
        ).click()
        page.get_by_role("menuitem", name="Delete task", exact=True).click()
        dialog = page.get_by_role("dialog", name="Delete torrent task", exact=True)
        expect(dialog.get_by_role("checkbox")).not_to_be_checked()
        english(dialog)
        _snapshot(page, shots / f"{theme_id}-{width}-delete-en.png")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert context.request.get(direct + "/__lab/task-deletions").json() == []
        assert (root / "files" / f"{'b' * 40}.mkv").exists()
        external.get_by_role(
            "button", name="More actions for Raw.External.Movie", exact=True
        ).click()
        page.get_by_role("menuitem", name="Delete task", exact=True).click()
        dialog.get_by_role("button", name="Delete task only", exact=True).click()
        expect(dialog).to_be_hidden()
        assert context.request.get(direct + "/__lab/task-deletions").json() == [["b" * 40, False]]
        assert (root / "files" / f"{'b' * 40}.mkv").exists()
        page.goto(base + "/activity?view=history")
        expect(page.get_by_text("Raw.Show.S01E01.mkv", exact=True)).to_have_count(0)
        page.get_by_text("View file details", exact=True).click()
        expect(page.get_by_text("Raw.Show.S01E01.mkv", exact=True)).to_be_visible()
        expect(page.get_by_text("Raw.Show.S01E02.mkv", exact=True)).to_be_visible()
        english(page.locator("main"))
        _snapshot(page, shots / f"{theme_id}-{width}-history-en.png")

    # Same document language change retains the underlying data, IDs and file snapshots.
    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/activity?view=history")
    page.evaluate("window.taskActivityMarker = 410")
    for locale in ("zh-Hans", "en"):
        _change_language(page, locale)
        expect(page.get_by_text("原始剧集", exact=False).first).to_be_visible()
        if locale == "en":
            english(page.locator("main"))
        assert page.evaluate("window.taskActivityMarker") == 410
    # Explicitly select data deletion on the isolated fixture only.
    assert context.request.post(direct + "/__lab/task-reset").ok
    page.goto(base + "/activity?view=active")
    external = page.locator("article").filter(has_text="Raw.External.Movie")
    external.get_by_role("button", name="More actions for Raw.External.Movie", exact=True).click()
    page.get_by_role("menuitem", name="Delete task", exact=True).click()
    dialog = page.get_by_role("dialog", name="Delete torrent task", exact=True)
    dialog.get_by_role("checkbox").check()
    dialog.get_by_role("button", name="Delete task and files", exact=True).click()
    expect(dialog).to_be_hidden()
    assert context.request.get(direct + "/__lab/task-deletions").json() == [["b" * 40, True]]
    assert not (root / "files" / f"{'b' * 40}.mkv").exists()
    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.goto(base + "/activity?view=boost")
    expect(page.get_by_text("Raw.Boost", exact=True)).to_be_visible()
    page.get_by_role("button", name="Clean up boost torrents", exact=True).click()
    cleanup = page.get_by_role("dialog")
    expect(cleanup.get_by_role("checkbox")).not_to_be_checked()
    english(cleanup)
    _snapshot(page, shots / "protected-cleanup-en.png")
    cleanup.get_by_role("button", name="Cancel", exact=True).click()
    assert not api("get", "/sites/boost-pool")["tasks"][0]["cleanup_scheduled"]
    page.get_by_role("button", name="Clean up boost torrents", exact=True).click()
    expect(cleanup.get_by_role("checkbox")).not_to_be_checked()
    with page.expect_response(
        lambda response: "/sites/boost-pool/cleanup" in response.url
    ) as receipt:
        cleanup.get_by_role("button", name="Clean up", exact=True).click()
    assert receipt.value.ok
    outcome = receipt.value.json()["data"]
    assert outcome["deleted_count"] == 0 and outcome["scheduled_count"] == 1
    assert api("get", "/sites/boost-pool")["tasks"][0]["cleanup_scheduled"]
    assert (root / "files" / f"{'c' * 40}.mkv").exists()
    assert context.request.get(direct + "/__lab/task-deletions").json() == [["b" * 40, True]]
    assert not errors
    context.close()

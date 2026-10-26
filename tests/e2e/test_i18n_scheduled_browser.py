"""Schedule editing through Next, real API/SQLite and live APScheduler job replacement."""

import os
import re
import signal
import subprocess
import sys
from contextlib import suppress
from datetime import UTC, datetime, timedelta

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO, WEB, _free_port, _wait_http

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("scheduled-browser")
    mounts = root / "mounts"
    media = root / "network-library"
    media.mkdir()
    mounts.write_text(f"server:/media {media} nfs rw 0 0\n")
    database_url = f"sqlite+aiosqlite:///{root / 'data.db'}"
    env = {
        **os.environ,
        "DATABASE_URL": database_url,
        "SCHEDULER_ENABLED": "false",
        "MOVIECLAW_DATA_DIR": str(root / "data"),
        "METADATA_DIR": str(root / "metadata"),
        "LOG_DIR": str(root / "logs"),
        "SECRET_KEY_FILE": str(root / "secret"),
        "E2E_SCHEDULE_MOUNTS": str(mounts),
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
    }
    api_port, web_port = _free_port(), _free_port()
    logs = [(root / name).open("w") for name in ("api.log", "web.log")]
    api = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._scheduled_api_launcher:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(api_port),
        ],
        cwd=REPO,
        env=env,
        stdout=logs[0],
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    web = subprocess.Popen(
        ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
        cwd=WEB,
        env={
            **env,
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
            "NEXT_DIST_DIR": ".next-scheduled-e2e",
        },
        stdout=logs[1],
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        base = f"http://127.0.0.1:{web_port}"
        _wait_http(base + "/login", 120)
        yield {
            "base": base,
            "api": f"http://127.0.0.1:{api_port}",
            "root": root,
            "database_url": database_url,
            "media": media,
        }
    finally:
        for process in (web, api):
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
        for process in (web, api):
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        for log in logs:
            log.close()


async def _seed(database_url, media):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Library
    from movieclaw_db.repositories.scheduled_task_repo import ScheduledTaskRepository

    database = Database(database_url)
    try:
        async with database.session() as session:
            session.add(Library(name="Raw network library", kind="movie", root_paths=[str(media)]))
            repository = ScheduledTaskRepository(session)
            for key, trigger, interval, cron, enabled in [
                ("library_reconcile", "interval", 21600, None, True),
                ("check_app_update", "cron", None, "30 3 * * *", False),
                ("cleanup_task_runs", "cron", None, "10 2 * * 1", True),
                ("legacy_unregistered", "interval", 7200, None, False),
            ]:
                await repository.create_if_absent(
                    task_key=key,
                    trigger_type=trigger,
                    interval_seconds=interval,
                    cron_expr=cron,
                    enabled=enabled,
                )
            await repository.mark_run(
                "library_reconcile", datetime.now(UTC).replace(tzinfo=None) - timedelta(hours=2)
            )
            await session.commit()
    finally:
        await database.dispose()


def test_schedules_drafts_toggles_cron_and_language(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    _run(_seed(stack["database_url"], stack["media"]))
    source = stack["media"] / "原始文件.txt"
    source.write_bytes(b"schedule edits must preserve media")
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/scheduled"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def tasks():
        return {row["key"]: row for row in api("get", "/scheduled-tasks")}

    def jobs():
        response = context.request.get(stack["api"] + "/__lab/scheduled/jobs")
        assert response.ok
        return {job["key"]: job for job in response.json()}

    def saved(action, status=200):
        with page.expect_response(
            lambda r: r.request.method == "PUT" and "/scheduled-tasks/" in r.url
        ) as result:
            action()
        assert result.value.status == status, result.value.text()
        return result.value.json()

    def primary():
        toggle = page.get_by_label("Enable “Library reconciliation”", exact=True)
        row = toggle.locator("xpath=ancestor::div[contains(@class, 'min-h-[56px]')][1]/..")
        return row, toggle

    def assert_next():
        task = tasks()["library_reconcile"]
        job = jobs()["library_reconcile"]
        value = datetime.fromisoformat(task["next_run_at"].replace("Z", "+00:00"))
        if value.tzinfo is None:
            value = value.replace(tzinfo=UTC)
        assert value == datetime.fromisoformat(job["next_run_at"])
        assert value > datetime.now(UTC)

    def english():
        text = page.locator("main").inner_text()
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    assert "legacy_unregistered" not in tasks()
    assert not jobs()  # Reading translated definitions never starts or reschedules a task.
    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        api(
            "put",
            "/scheduled-tasks/library_reconcile",
            data={
                "enabled": True,
                "trigger_type": "interval",
                "interval_seconds": 21600,
            },
        )
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/app?tab=tasks")
        expect(page.get_by_role("button", name="Run every hour", exact=True)).to_be_visible()
        row, toggle = primary()
        hours = row.get_by_role("spinbutton", name="Interval in hours", exact=True)
        expect(hours).to_have_value("6")
        if width == 320:
            text = row.locator('div[class*="min-h-[56px]"] > .flex-1')
            assert text.bounding_box()["width"] >= 200
        english()
        _snapshot(page, shots / f"{theme_id}-{width}-tasks-en.png")
        hours.fill("9")
        saved(toggle.click)
        expect(hours).to_have_value("9")
        assert tasks()["library_reconcile"]["interval_seconds"] == 21600
        assert "library_reconcile" not in jobs()
        expect(row.get_by_role("button", name="Save", exact=True)).to_be_enabled()
        saved(toggle.click)
        expect(hours).to_have_value("9")
        assert jobs()["library_reconcile"]["seconds"] == 21600
        saved(row.get_by_role("button", name="Save", exact=True).click)
        expect(row.get_by_role("button", name="Save", exact=True)).to_be_disabled()
        assert tasks()["library_reconcile"]["interval_seconds"] == 32400
        assert jobs()["library_reconcile"]["seconds"] == 32400
        assert_next()
        mode = row.get_by_role("combobox", name="Schedule type", exact=True)
        mode.select_option("daily")
        time = row.get_by_label("Daily time", exact=True)
        time.fill("03:45")
        saved(row.get_by_role("button", name="Save", exact=True).click)
        assert tasks()["library_reconcile"]["cron_expr"] == "45 3 * * *"
        assert jobs()["library_reconcile"]["trigger_type"] == "CronTrigger"
        assert_next()
        mode.select_option("cron")
        cron = row.get_by_role("textbox", name="cron expression", exact=True)
        cron.fill("invalid cron")
        before = jobs()["library_reconcile"]
        saved(row.get_by_role("button", name="Save", exact=True).click, 400)
        assert tasks()["library_reconcile"]["cron_expr"] == "45 3 * * *"
        assert jobs()["library_reconcile"] == before
        cron.fill("0 4 * * 1")
        saved(row.get_by_role("button", name="Save", exact=True).click)
        assert tasks()["library_reconcile"]["cron_expr"] == "0 4 * * 1"
        assert_next()
        _snapshot(page, shots / f"{theme_id}-{width}-cron-en.png")
        mode.select_option("interval")
        hours.fill("0")
        expect(hours).to_have_value("1")
        hours.fill("169")
        expect(hours).to_have_value("168")
        hours.fill("6")
        saved(row.get_by_role("button", name="Save", exact=True).click)
        saved(page.get_by_role("button", name="Run every hour", exact=True).click)
        expect(page.get_by_role("button", name="Run every hour", exact=True)).to_have_count(0)
        assert tasks()["library_reconcile"]["interval_seconds"] == 3600
        assert jobs()["library_reconcile"]["seconds"] == 3600
        assert_next()
        english()
        assert source.read_bytes() == b"schedule edits must preserve media"

    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/library")
    page.evaluate("window.__scheduledLanguageDocument = true")
    before = jobs()
    _change_language(page, "zh-Hans")
    assert page.evaluate("window.__scheduledLanguageDocument")
    page.goto(base + "/settings/app?tab=tasks")
    expect(page.get_by_label("启用「媒体库对账」", exact=True)).to_be_visible()
    assert jobs() == before
    _snapshot(page, shots / "scheduled-zh.png")
    page.goto(base + "/library")
    _change_language(page, "en")
    page.goto(base + "/settings/app?tab=tasks")
    expect(page.get_by_label("Enable “Library reconciliation”", exact=True)).to_be_visible()
    assert jobs() == before
    english()
    assert not errors, errors
    context.close()

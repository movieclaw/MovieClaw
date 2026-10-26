"""Reader-language quality upgrade confirmation and actual scheduling through the UI."""

from __future__ import annotations

import re

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_i18n_subscription_cancel_browser import _run

stack = inventory.stack
browser = theme.browser
pytestmark = pytest.mark.integration


async def _seed(database_url, identity, *, paused=False):
    from tests.api import test_upgrade_run as upgrades

    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        SubscriptionDownloadAttempt,
        SubscriptionStatus,
        WantedStatus,
        utcnow,
    )

    database = Database(database_url)
    try:
        library_id, item_id, sub_id, _ = await upgrades._seed(
            database,
            tmdb_id=identity,
            spec={"upgrade_source": "blu-ray"},
            episodes=tuple((1, number) for number in range(1, 6)),
            status=SubscriptionStatus.PAUSED if paused else SubscriptionStatus.COMPLETED,
        )
        async with database.session() as session:
            for number in (1, 2, 3, 5):
                row = upgrades._file(library_id, item_id, 1, number)
                row.file_path = row.file_path.replace("/Stock/", f"/Stock-{identity}/")
                session.add(row)
            await session.commit()
            for number, quality in (
                (1, upgrades._WEBDL),
                (2, {"resolution": "1080p", "media_source": "Blu-ray"}),
                (3, {}),
                (5, upgrades._WEBDL),
            ):
                await upgrades._add_wanted(session, sub_id, item_id, 1, number, quality=quality)
            await upgrades._add_wanted(session, sub_id, item_id, 1, 4, status=WantedStatus.WANTED)
            session.add(
                SubscriptionDownloadAttempt(
                    subscription_id=sub_id,
                    info_hash=f"{identity:040x}",
                    purpose="upgrade",
                    units=[[1, 5]],
                    last_progress_at=utcnow(),
                )
            )
            await session.commit()
        return sub_id
    finally:
        await database.dispose()


def test_upgrade_confirmation_report_and_resume(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/upgrade-report"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    for index, (theme_id, width) in enumerate(
        (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320))
    ):
        paused = index == 3
        identity = 400 + index
        sub_id = _run(_seed(stack["database_url"], identity, paused=paused))
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(f"{base}/subscriptions/{sub_id}?upgrade-run=1")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")
        dialog = page.get_by_role("dialog", name="Run a quality upgrade", exact=True)
        expect(dialog).to_be_visible()
        expect(dialog.get_by_text(re.compile(f"^洗版组-{identity}"))).to_be_visible()
        expect(dialog.get_by_text(re.compile("1080p Blu-ray")).first).to_be_visible()
        # User names are source data; all surrounding confirmation copy is English.
        copy = re.sub(r"洗版组-\d+", "", dialog.inner_text().replace("存量剧", ""))
        assert not re.search(r"[\u3400-\u9fff]", copy), copy
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-confirmation-en.png")
        dialog.get_by_role(
            "button", name="Resume and start upgrade" if paused else "Check and upgrade", exact=True
        ).click()
        expect(
            dialog.get_by_role("heading", name="Upgrade check report", exact=True)
        ).to_be_visible()
        expect(
            dialog.get_by_text(
                "1 unit ready for an upgrade; search queued; 1 upgrade already in progress; "
                "1 unit meets the target; 1 current version could not be identified; "
                "1 missing unit will download normally",
                exact=True,
            )
        ).to_be_visible()
        for state in ("Upgrade queued", "Upgrading", "Target reached", "Unconfirmed", "Missing"):
            expect(dialog.get_by_text(state, exact=True)).to_be_visible()
        assert not re.search(r"[\u3400-\u9fff]", dialog.inner_text().replace("存量剧", ""))
        _snapshot(page, shots / f"{theme_id}-{width}-report-en.png")
        expect(
            dialog.get_by_text(
                "Current 1080p WEB-DL → target 1080p Blu-ray; queued for immediate search",
                exact=True,
            )
        ).to_be_visible()
        if paused:
            assert api("get", f"/subscriptions/{sub_id}")["status"] != "paused"
        # The action, rather than rendering a report, must schedule the actual work item.
        detail = api("get", f"/subscriptions/{sub_id}")
        assert detail["progress"]["upgrading"] >= 1
        dialog.get_by_role("button", name="Done", exact=True).click()
        expect(dialog).not_to_be_visible()

    # Keep the original Chinese confirmation and report as exact regression expectations.
    sub_id = _run(_seed(stack["database_url"], 405))
    prefs = api("get", "/ui/preferences")
    prefs.update(language="zh-Hans")
    api("put", "/ui/preferences", data=prefs)
    page.goto(f"{base}/subscriptions/{sub_id}?upgrade-run=1")
    dialog = page.get_by_role("dialog", name="洗一轮版", exact=True)
    expect(dialog).to_be_visible()
    expect(dialog.get_by_role("button", name=re.compile("^洗版组-405当前使用"))).to_be_visible()
    expect(dialog.get_by_text("当前使用", exact=True)).to_be_visible()
    dialog.get_by_role("button", name="开始体检并洗版", exact=True).click()
    expect(dialog.get_by_role("heading", name="洗版体检报告", exact=True)).to_be_visible()
    expect(
        dialog.get_by_text("当前 1080p WEB-DL → 目标 1080p 蓝光，已排入立即搜索", exact=True)
    ).to_be_visible()
    _snapshot(page, shots / "netflix-320-report-zh.png")
    assert not errors
    context.close()

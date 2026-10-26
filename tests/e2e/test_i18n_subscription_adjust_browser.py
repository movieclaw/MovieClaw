"""Adjust seasons, retain cross-season downloads and recycle only explicitly selected files."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_i18n_subscription_cancel_browser import _file_state, _run
from .test_library_manage_browser import _wait_for

stack = inventory.stack
browser = theme.browser
pytestmark = pytest.mark.integration


async def _seed(database_url, identity, root):
    from datetime import date

    from tests.api import test_upgrade_run as upgrades

    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        ClientType,
        DownloaderClient,
        Library,
        MediaSeason,
        Subscription,
        SubscriptionDownloadAttempt,
        SubscriptionStatus,
        utcnow,
    )

    root.mkdir()
    database = Database(database_url)
    try:
        library_id, item_id, sub_id, _ = await upgrades._seed(
            database,
            tmdb_id=identity,
            episodes=((1, 1), (2, 1), (3, 1)),
            status=SubscriptionStatus.ACTIVE,
        )
        async with database.session() as session:
            sub = await session.get(Subscription, sub_id)
            sub.selected_seasons = [1, 2, 3]
            library = await session.get(Library, library_id)
            library.root_paths = [str(root)]
            files = {}
            for season in (1, 2, 3):
                session.add(
                    MediaSeason(
                        media_item_id=item_id,
                        season_number=season,
                        episode_count=1,
                        air_date=date(2020, 1, 1),
                    )
                )
                path = root / f"S{season:02d}E01.mkv"
                path.write_bytes(f"original season {season}".encode())
                row = upgrades._file(library_id, item_id, season, 1)
                row.file_path = str(path)
                row.size_bytes = path.stat().st_size
                session.add(row)
                await session.flush()
                files[season] = (row.id, path, path.read_bytes())
                await upgrades._add_wanted(
                    session,
                    sub_id,
                    item_id,
                    season,
                    1,
                    quality=upgrades._WEBDL,
                )
            downloader = DownloaderClient(
                name=f"我的下载器-{identity}",
                client_type=ClientType.QBITTORRENT,
                url="http://127.0.0.1:1",
                save_path="/downloads",
            )
            session.add(downloader)
            await session.flush()
            for offset, units in enumerate(([[2, 1]], [[2, 1], [3, 1]])):
                session.add(
                    SubscriptionDownloadAttempt(
                        subscription_id=sub_id,
                        downloader_id=downloader.id,
                        info_hash=f"{identity * 10 + offset:040x}",
                        units=units,
                        torrent_title="Show.S02" if offset == 0 else "Show.S02-S03.COMPLETE",
                        hit_and_run=True,
                        last_progress_at=utcnow(),
                    )
                )
            await session.commit()
        return sub_id, files
    finally:
        await database.dispose()


def test_adjust_and_cleanup_real_files_in_both_themes(stack, browser, tmp_path):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/subscription-adjust"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    destination = tmp_path / "destination"
    destination.mkdir()
    target = api(
        "post",
        "/libraries",
        data={
            "name": "我的目标库",
            "kind": "tv",
            "root_paths": [str(destination)],
        },
    )

    def open_adjust(sub_id, theme_id, language="en"):
        page.goto(f"{base}/subscriptions/{sub_id}")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")
        page.get_by_role("button", name="More" if language == "en" else "更多", exact=True).click()
        item = page.get_by_role(
            "menuitem", name="Adjust subscription…" if language == "en" else "调整订阅…", exact=True
        )
        if item.count():
            item.click()
        else:
            page.get_by_role(
                "button", name="Adjust subscription" if language == "en" else "调整订阅", exact=True
            ).last.click()
        return page.get_by_role(
            "dialog", name="Adjust subscription" if language == "en" else "调整订阅", exact=True
        )

    for index, (theme_id, width) in enumerate(
        (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320))
    ):
        sub_id, files = _run(_seed(stack["database_url"], 600 + index, tmp_path / str(index)))
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        dialog = open_adjust(sub_id, theme_id)
        save = dialog.get_by_role("button", name="Save changes", exact=True)
        expect(save).to_be_disabled()
        expect(dialog.get_by_text("1 episode has aired", exact=True).first).to_be_visible()
        if theme_id == "silver" and width == 320:
            dialog.get_by_role("button", name=re.compile("^Import to")).click()
            page.get_by_role("menuitemradio", name=re.compile("^我的目标库")).click()
        else:
            dialog.get_by_role("combobox", name="Import to", exact=True).select_option(
                str(target["id"])
            )
        removed = [1, 2] if index == 1 else [2]
        role = "button" if theme_id == "silver" and width == 320 else "checkbox"
        for season in removed:
            dialog.get_by_role(role, name=re.compile(f"^Season {season} ")).click()
        expect(
            dialog.get_by_text(re.compile("^Season.*already.*download progress"))
        ).to_be_visible()
        _snapshot(page, shots / f"{theme_id}-{width}-adjust-en.png")
        save.click()
        cleanup = page.get_by_role("dialog", name=re.compile("^Clean up content for Seasons? "))
        expect(cleanup).to_be_visible()
        assert api("get", f"/subscriptions/{sub_id}")["selected_seasons"] == [
            s for s in (1, 2, 3) if s not in removed
        ]
        assert api("get", f"/subscriptions/{sub_id}")["library_id"] == target["id"]
        # Saving an adjustment alone cannot delete or move the original content.
        for _, path, original in files.values():
            assert path.read_bytes() == original
        tasks = cleanup.get_by_role("checkbox", name=re.compile("^Also remove download tasks"))
        library_files = cleanup.get_by_role(
            "checkbox", name=re.compile("^Also remove library files")
        )
        expect(tasks).not_to_be_checked()
        expect(library_files).not_to_be_checked()
        tasks.check()
        expect(
            cleanup.get_by_text(re.compile("^1 torrent still has H&R requirements"))
        ).to_be_visible()
        tasks.uncheck()
        expect(
            cleanup.get_by_text(
                "1 cross-season torrent is still used by seasons you kept "
                "(such as a pack covering Seasons 2 and 3) and will be retained.",
                exact=True,
            )
        ).to_be_visible()
        text = cleanup.inner_text().replace("存量剧", "")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        expect(page.get_by_text("Subscription updated", exact=True)).not_to_be_visible(
            timeout=10_000
        )
        _snapshot(page, shots / f"{theme_id}-{width}-cleanup-en.png")
        if index == 0:
            cleanup.get_by_role("button", name="Keep content", exact=True).click()
            for _, path, original in files.values():
                assert path.read_bytes() == original
        else:
            library_files.check()
            cleanup.get_by_role("button", name=re.compile("^Clean up Seasons? ")).click()
            for season in removed:
                file_id, old_path, original = files[season]
                _wait_for(
                    lambda file_id=file_id: (
                        _run(_file_state(stack["database_url"], file_id))[0] == "trashed"
                    ),
                    timeout=20,
                    what="explicitly selected season files recycled",
                )
                _, recycled = _run(_file_state(stack["database_url"], file_id))
                assert not old_path.exists() and Path(recycled).read_bytes() == original
            assert files[3][1].read_bytes() == files[3][2]
        expect(cleanup).not_to_be_visible()

    # Chinese singular text must use the original “这一季”, despite CLDR Chinese plurals.
    sub_id, files = _run(_seed(stack["database_url"], 604, tmp_path / "chinese"))
    prefs = api("get", "/ui/preferences")
    prefs.update(language="zh-Hans")
    api("put", "/ui/preferences", data=prefs)
    dialog = open_adjust(sub_id, "netflix", "zh-Hans")
    dialog.get_by_role("checkbox", name=re.compile("^第 2 季 ")).click()
    dialog.get_by_role("button", name="保存调整", exact=True).click()
    cleanup = page.get_by_role("dialog", name="清理第 2 季的内容", exact=True)
    expect(
        cleanup.get_by_text(
            "《存量剧》的这一季不再追了。要不要把已经下载的内容也清理掉？"
            "不清理也没关系， 种子和文件都原样留着。",
            exact=True,
        )
    ).to_be_visible()
    expect(
        cleanup.get_by_text(
            "另有 1 个跨季种子（如 第 2、3 季合集）仍被保留的季使用，不会删除。", exact=True
        )
    ).to_be_visible()
    _snapshot(page, shots / "netflix-320-cleanup-zh.png")
    cleanup.get_by_role("button", name="保留内容", exact=True).click()
    assert files[2][1].read_bytes() == files[2][2]
    assert not errors
    context.close()

"""Cancellation previews and real recycle behavior through UI, API, SQLite and files."""

from __future__ import annotations

import asyncio
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import _wait_for

stack = inventory.stack
browser = theme.browser
pytestmark = pytest.mark.integration


def _run(coroutine):
    with ThreadPoolExecutor(max_workers=1) as executor:
        return executor.submit(asyncio.run, coroutine).result()


async def _seed(database_url, sub_id, path):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        ClientType,
        DownloaderClient,
        FileSource,
        LibraryFile,
        Subscription,
        SubscriptionDownloadAttempt,
        utcnow,
    )
    from movieclaw_db.repositories.library_repo import LibraryRepository

    database = Database(database_url)
    try:
        async with database.session() as session:
            sub = await session.get(Subscription, sub_id)
            library = await LibraryRepository(session).create(
                name="我的保留文件", kind="movie", root_paths=[str(path.parent)]
            )
            downloader = DownloaderClient(
                name="我的下载器",
                client_type=ClientType.QBITTORRENT,
                url="http://127.0.0.1:1",
                save_path="/downloads",
            )
            session.add(downloader)
            await session.flush()
            for index, hit_and_run in enumerate((True, False)):
                session.add(
                    SubscriptionDownloadAttempt(
                        subscription_id=sub_id,
                        downloader_id=downloader.id,
                        info_hash=str(index + 1) * 40,
                        torrent_title=f"Movie.release.{index}",
                        hit_and_run=hit_and_run,
                        last_progress_at=utcnow(),
                    )
                )
            row = LibraryFile(
                library_id=library.id,
                media_item_id=sub.media_item_id,
                file_path=str(path),
                size_bytes=path.stat().st_size,
                source=FileSource.SCANNED,
            )
            session.add(row)
            await session.commit()
            await session.refresh(row)
            return row.id
    finally:
        await database.dispose()


async def _file_state(database_url, file_id):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import LibraryFile

    database = Database(database_url)
    try:
        async with database.session() as session:
            row = await session.get(LibraryFile, file_id)
            return str(row.state), row.file_path
    finally:
        await database.dispose()


def test_cancellation_copy_defaults_and_real_file_recycle(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/subscription-cancel"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def create():
        result = api(
            "post",
            "/subscriptions",
            data={"title_ref": "tmdb:movie:300", "selection_mode": "rules"},
        )
        return result["subscription"]["id"]

    sub_id = create()
    path = stack["roots"]["movies"] / "kept.mkv"
    path.write_bytes(b"movieclaw cancellation fixture")
    original = path.read_bytes()
    file_id = _run(_seed(stack["database_url"], sub_id, path))
    title = api("get", f"/subscriptions/{sub_id}")["media"]["title"]

    def open_cancel(language="en"):
        page.goto(f"{base}/subscriptions/{sub_id}")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")
        page.get_by_role("button", name=re.compile("^(更多|More)$")).click()
        item = page.get_by_role("menuitem", name=re.compile("^(取消订阅|Cancel subscription)$"))
        if item.count():
            item.click()
        else:
            page.get_by_role(
                "button", name=re.compile("^(取消订阅|Cancel subscription)$")
            ).last.click()
        return page.get_by_role(
            "dialog",
            name=f"Cancel subscription to “{title}”"
            if language == "en"
            else f"取消订阅《{title}》",
            exact=True,
        )

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        dialog = open_cancel()
        role = "switch" if theme_id == "silver" and width == 320 else "checkbox"
        tasks = dialog.get_by_role(role, name=re.compile("^Also remove 2 related download tasks"))
        files = dialog.get_by_role(role, name=re.compile("^Also remove library files.*1 file"))
        expect(tasks).to_be_enabled()
        expect(files).to_be_enabled()
        assert (
            tasks.evaluate(
                "el => el.getAttribute('aria-checked') === 'true' || el.checked === true"
            )
            is False
        )
        assert (
            files.evaluate(
                "el => el.getAttribute('aria-checked') === 'true' || el.checked === true"
            )
            is False
        )
        tasks.click()
        expect(
            dialog.get_by_text(re.compile("^1 torrent still has H&R requirements"))
        ).to_be_visible()
        files.click()
        expect(
            dialog.get_by_text(
                "Files move to the library recycle bin and can be restored for 7 days.", exact=True
            )
        ).to_be_visible()
        expect(
            dialog.get_by_text(re.compile("^The subscription is canceled immediately"))
        ).to_be_visible()
        assert not re.search(r"[\u3400-\u9fff]", dialog.inner_text().replace(title, ""))
        assert dialog.evaluate("el => el.scrollWidth <= el.clientWidth + 1")
        _snapshot(page, shots / f"{theme_id}-{width}-cleanup-en.png")
        dialog.get_by_role("button", name="Not now", exact=True).click()
        expect(dialog).to_have_count(0)
        assert path.read_bytes() == original
        assert api("get", f"/subscriptions/{sub_id}")["id"] == sub_id

    # A fresh opening resets both destructive options. Default cancellation preserves the file.
    dialog = open_cancel()
    tasks = dialog.get_by_role("checkbox", name=re.compile("^Also remove 2 related download tasks"))
    files = dialog.get_by_role("checkbox", name=re.compile("^Also remove library files.*1 file"))
    expect(tasks).not_to_be_checked()
    expect(files).not_to_be_checked()
    dialog.get_by_role("button", name="Cancel subscription", exact=True).click()
    expect(dialog).to_have_count(0)
    assert context.request.get(base + f"/api/v1/subscriptions/{sub_id}").status == 404
    assert path.read_bytes() == original
    state, _ = _run(_file_state(stack["database_url"], file_id))
    assert state != "trashed"

    # Recreate the subscription and explicitly recycle its library file through the real worker.
    sub_id = create()
    dialog = open_cancel()
    expect(
        dialog.get_by_role("checkbox", name=re.compile("^Also remove related download tasks"))
    ).to_be_disabled()
    files = dialog.get_by_role("checkbox", name=re.compile("^Also remove library files.*1 file"))
    files.check()
    dialog.get_by_role("button", name="Cancel subscription", exact=True).click()
    expect(dialog).to_have_count(0)
    _wait_for(
        lambda: _run(_file_state(stack["database_url"], file_id))[0] == "trashed",
        timeout=20,
        what="real background recycle",
    )
    state, recycled_path = _run(_file_state(stack["database_url"], file_id))
    assert state == "trashed" and not path.exists()
    assert Path(recycled_path).read_bytes() == original
    sub_id = create()
    dialog = open_cancel()
    expect(
        dialog.get_by_role(
            "checkbox", name="Also remove related download tasks (none to remove)", exact=True
        )
    ).to_be_disabled()
    expect(
        dialog.get_by_role(
            "checkbox",
            name="Also remove library files (this title is not in the library)",
            exact=True,
        )
    ).to_be_disabled()
    dialog.get_by_role("button", name="Not now", exact=True).click()
    prefs = api("get", "/ui/preferences")
    prefs["language"] = "zh-Hans"
    api("put", "/ui/preferences", data=prefs)
    dialog = open_cancel("zh-Hans")
    expect(dialog.get_by_role("heading", name=f"取消订阅《{title}》？", exact=True)).to_be_visible()
    expect(
        dialog.get_by_role(
            "checkbox", name="同时删除相关的下载任务（没有可删除的任务）", exact=True
        )
    ).to_be_disabled()
    expect(
        dialog.get_by_role(
            "checkbox", name="同时删除媒体库里的资源（媒体库中没有该作品）", exact=True
        )
    ).to_be_disabled()
    expect(
        dialog.get_by_text(
            "将停止追踪剩余内容。默认只取消订阅，已经下载或入库的内容都会保留。", exact=True
        )
    ).to_be_visible()
    _snapshot(page, shots / "netflix-320-empty-zh.png")
    dialog.get_by_role("button", name="先不", exact=True).click()
    assert not errors
    context.close()

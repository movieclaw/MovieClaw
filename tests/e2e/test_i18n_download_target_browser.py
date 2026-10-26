"""Real target resolution, remembered destination and import of a valid MKV."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess

import pytest

from . import test_manual_download_identity_browser as download
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import _wait_for

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_REAL_DOWNLOAD_MEDIA", "1")
        yield from download.stack.__wrapped__(tmp_path_factory)


def _api(context, base, method, path, **kwargs):
    response = getattr(context.request, method)(f"{base}/api/v1{path}", **kwargs)
    assert response.ok, response.text()
    return response.json().get("data")


def test_identity_mapping_memory_and_real_import(stack, browser, tmp_path):
    from playwright.sync_api import expect

    base, dirs = stack["base"], stack["dirs"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
    _api(context, base, "post", "/auth/bootstrap", data=download.ADMIN)
    _api(
        context,
        base,
        "post",
        "/libraries",
        data={
            "name": "默认剧集库",
            "kind": "tv",
            "root_paths": [str(dirs["shows"])],
        },
    )
    library = _api(
        context,
        base,
        "post",
        "/libraries",
        data={
            "name": "国产剧",
            "kind": "tv",
            "root_paths": [str(dirs["cn_shows"])],
            "match_rules": [{"field": "origin_countries", "op": "any_of", "values": ["CN"]}],
        },
    )
    _api(
        context,
        base,
        "post",
        "/downloaders",
        data={
            "name": "Home qBittorrent",
            "client_type": "qbittorrent",
            "url": "http://fixture.invalid:8080",
            "save_path": str(dirs["watch"]),
            "path_mappings": [{"local": str(dirs["watch"]), "remote": "/downloads"}],
        },
    )
    _wait_for(
        lambda: _api(context, base, "get", "/downloaders")[0]["usable"],
        timeout=10,
        what="verified downloader",
    )
    rule = _api(
        context,
        base,
        "post",
        "/import-watch",
        data={
            "source_path": str(dirs["watch"]),
            "strategy": "copy",
            "library_id": library["id"],
        },
    )
    history_id = download._seed_snapshot(stack["database_url"])

    # A third, correctly identified resource can reuse the saved smart import policy.
    async def add_identified(session):
        from movieclaw_db.models import SearchHistory

        row = await session.get(SearchHistory, history_id)
        snapshot = json.loads(row.snapshot_json)
        snapshot["items"].append(
            download._hit(
                "1003",
                "Known.Series.S01.2023.mkv",
                {
                    "media_type": "tv",
                    "titles_zh": ["繁花"],
                    "year": 2023,
                },
                seeders=20,
            )
        )
        snapshot["total"] += 1
        row.snapshot_json = json.dumps(snapshot, ensure_ascii=False)
        session.add(row)
        await session.commit()

    download._run_db(stack["database_url"], add_identified)
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/download-target"
    shots.mkdir(parents=True, exist_ok=True)
    url = f"{base}/search?q=繁花&snapshot={history_id}&view=list"

    def open_resource(title):
        page.goto(url)
        row = page.get_by_role("listitem").filter(has=page.get_by_text(title, exact=True))
        expect(row).to_be_visible(timeout=30_000)
        row.hover()
        row.get_by_role("button", name="Download", exact=True).click()
        return page.get_by_role("dialog")

    for theme_name in ("silver", "netflix"):
        prefs = _api(context, base, "get", "/ui/preferences")
        prefs.update(theme=theme_name, theme_desktop=theme_name, theme_mobile=theme_name)
        _api(context, base, "put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": 1440, "height": 1000})
        dialog = open_resource(download.TORRENT_NAME)
        if theme_name == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
        expect(dialog.get_by_text("Which title is this?", exact=True)).to_be_visible()
        expect(dialog.get_by_role("button", name="Confirm download", exact=True)).to_be_disabled()
        expect(
            dialog.get_by_role("button", name="繁花似锦 (2021) Movie", exact=True)
        ).to_be_visible()
        dialog.get_by_role("button", name="Other destinations", exact=True).click()
        expect(
            dialog.get_by_text("Downloader path: /downloads (Default save directory)", exact=True)
        ).to_be_visible()
        expect(
            dialog.get_by_role("link", name="Settings → Downloaders", exact=True)
        ).to_be_visible()
        dialog.get_by_role("button", name="繁花 (2023) Series", exact=True).click()
        smart = dialog.get_by_role("button", name=re.compile("^Automatically import into “国产剧”"))
        expect(smart).to_have_attribute("data-active", "true")
        expect(smart).to_contain_text("Matched “国产剧”: Region=Mainland China")
        expect(
            dialog.get_by_role("button", name="Download to “国产剧”", exact=True)
        ).to_be_enabled()
        # Only source titles and library names contain Han characters.
        own = dialog.inner_text()
        for name in ("繁花似锦", "繁花", "国产剧"):
            own = own.replace(name, "")
        assert not re.search(r"[\u3400-\u9fff]", own), own
        _snapshot(page, shots / f"{theme_name}-desktop-en.png")
        page.set_viewport_size({"width": 320, "height": 900})
        expect(
            dialog.get_by_role("button", name="Download to “国产剧”", exact=True)
        ).to_be_visible()
        button = dialog.get_by_role("button", name="Download to “国产剧”", exact=True)
        assert button.evaluate("element => element.scrollHeight <= element.clientHeight + 1")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_name}-mobile-en.png")
        if theme_name == "silver":
            dialog.get_by_role("button", name="Cancel", exact=True).click()
    dialog.get_by_role("checkbox").check()
    dialog.get_by_role("button", name="Download to “国产剧”", exact=True).click()
    expect(dialog).to_have_count(0)
    submits = [json.loads(line) for line in stack["dl_log"].read_text().splitlines()]
    assert [row["save_path"] for row in submits] == ["/downloads"]
    intent = download._intent(stack["database_url"])
    assert (intent["kind"], intent["tmdb_id"], intent["library_id"]) == ("tv", 500, library["id"])
    remembered = _api(context, base, "get", "/downloaders/target-prefs")
    assert remembered[0]["category"] == "tv" and remembered[0]["kind"] == "smart"

    video = tmp_path / "complete.mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=5:duration=10",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            str(video),
        ],
        check=True,
        timeout=60,
    )
    digest = hashlib.sha256(video.read_bytes()).hexdigest()
    entry = dirs["watch"] / download.TORRENT_NAME
    entry.mkdir()
    source = entry / "Fan.Hua.S01E01.2160p.WEB-DL.H265-XYZ.mkv"
    video.replace(source)

    def imported():
        entries = _api(context, base, "get", f"/import-watch/{rule['id']}/entries")
        return entries if entries["counts"].get("imported") else None

    _wait_for(imported, timeout=120, what="valid MKV imported with the identity anchor")
    files = list(dirs["cn_shows"].rglob("*.mkv"))
    assert len(files) == 1 and hashlib.sha256(files[0].read_bytes()).hexdigest() == digest
    assert hashlib.sha256(source.read_bytes()).hexdigest() == digest

    async def probe_record(session):
        from sqlmodel import select

        from movieclaw_db.models import LibraryFile

        return (
            await session.execute(select(LibraryFile).where(LibraryFile.file_path == str(files[0])))
        ).scalar_one()

    probe = download._run_db(stack["database_url"], probe_record)
    assert probe.video_codec == "h264" and probe.duration_seconds == 10 and probe.probe_version
    assert [
        item["title"] for item in _api(context, base, "get", f"/libraries/{library['id']}/items")
    ] == ["繁花"]

    page.set_viewport_size({"width": 1440, "height": 1000})
    dialog = open_resource("Known.Series.S01.2023.mkv")
    expect(dialog).to_have_attribute("aria-label", "Confirm destination")
    expect(dialog.get_by_text("Smart import", exact=True)).to_be_visible()
    expect(dialog.get_by_role("button", name="Forget this choice", exact=True)).to_be_visible()
    for button in dialog.get_by_role("button").all():
        bounds = button.bounding_box()
        modal = dialog.bounding_box()
        assert bounds and modal and bounds["x"] + bounds["width"] <= modal["x"] + modal["width"] + 1
    _snapshot(page, shots / "remembered-en.png")
    page.set_viewport_size({"width": 320, "height": 900})
    expect(dialog.get_by_role("button", name="Confirm download", exact=True)).to_be_visible()
    assert dialog.get_by_role("button", name="Confirm download", exact=True).evaluate(
        """element => element.scrollWidth <= element.clientWidth + 1
        && element.scrollHeight <= element.clientHeight + 1"""
    )
    _snapshot(page, shots / "remembered-mobile-en.png")
    dialog.get_by_role("button", name="Forget this choice", exact=True).click()
    expect(
        page.get_by_text(re.compile("^The default destination for “TV shows” was cleared"))
    ).to_be_visible()
    assert _api(context, base, "get", "/downloaders/target-prefs") == []
    assert len(stack["dl_log"].read_text().splitlines()) == 1
    assert not errors, errors
    context.close()


def test_member_destination_ui_and_default_submission(stack, browser):
    from datetime import UTC, datetime

    from playwright.sync_api import expect

    base = stack["base"]
    admin = browser.new_context(locale="en-US")
    response = admin.request.post(f"{base}/api/v1/auth/bootstrap", data=download.ADMIN)
    if response.status == 409:
        _api(admin, base, "post", "/auth/login", data=download.ADMIN)
    else:
        assert response.ok, response.text()
    if not _api(admin, base, "get", "/libraries"):
        for name, root in (("默认剧集库", "shows"), ("国产剧", "cn_shows")):
            _api(
                admin,
                base,
                "post",
                "/libraries",
                data={
                    "name": name,
                    "kind": "tv",
                    "root_paths": [str(stack["dirs"][root])],
                },
            )
    if not _api(admin, base, "get", "/downloaders"):
        _api(
            admin,
            base,
            "post",
            "/downloaders",
            data={
                "name": "Home qBittorrent",
                "client_type": "qbittorrent",
                "url": "http://fixture.invalid:8080",
                "save_path": str(stack["dirs"]["watch"]),
                "path_mappings": [{"local": str(stack["dirs"]["watch"]), "remote": "/downloads"}],
            },
        )
        _wait_for(
            lambda: _api(admin, base, "get", "/downloaders")[0]["usable"],
            timeout=10,
            what="verified member default downloader",
        )
    credentials = {"username": "download-reader", "password": "isolated-test-pass"}
    member = _api(admin, base, "post", "/members", data=credentials)
    _api(
        admin,
        base,
        "put",
        f"/members/{member['id']}",
        data={
            "allow_search": True,
            "allow_direct_download": True,
            "all_libraries": True,
            "all_sites": True,
        },
    )

    async def seed(session):
        from movieclaw_db.models import SearchHistory

        hit = download._hit(
            "member-1",
            "Member.Resource.2023.mkv",
            {
                "media_type": "movie",
                "titles_en": ["Member Resource"],
                "year": 2023,
            },
            seeders=5,
        )
        # Relative torrent IDs use the tracker contract without a real HTTP destination.
        hit["download_url"] = "member-1"
        row = SearchHistory(
            member_id=member["id"],
            keyword="Member resource",
            vertical="torrent",
            snapshot_at=datetime.now(UTC).replace(tzinfo=None),
            snapshot_json=json.dumps({"items": [hit], "sites": [], "total": 1}),
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        return row.id

    history_id = download._run_db(stack["database_url"], seed)
    reader = browser.new_context(locale="en-US", viewport={"width": 320, "height": 900})
    _api(reader, base, "post", "/auth/login", data=credentials)
    page = reader.new_page()
    requested = []
    page.on("request", lambda request: requested.append(request.url.split("?", 1)[0]))
    page.goto(f"{base}/search?q=Member%20resource&snapshot={history_id}&view=list")
    page.get_by_role(
        "button", name="Open resource actions for “Member.Resource.2023.mkv”", exact=True
    ).click()
    page.get_by_role("dialog").get_by_role("button", name="Download", exact=True).click()
    dialog = page.get_by_role("dialog").filter(
        has=page.get_by_role("heading", name="Choose a destination", exact=True)
    )
    expect(
        dialog.get_by_text("This TV library does not match the resource type.", exact=True).first
    ).to_be_visible()
    expect(dialog.get_by_role("checkbox")).to_have_count(0)
    expect(dialog.get_by_text("Downloader’s default directory", exact=True)).to_be_visible()
    assert base + "/api/v1/downloaders" not in requested
    assert base + "/api/v1/downloaders/resolve-target" not in requested
    button = dialog.get_by_role("button", name="Confirm download", exact=True)
    expect(button).to_be_enabled()
    assert button.evaluate("element => element.scrollHeight <= element.clientHeight + 1")
    shots = theme.REPO / ".tmp-uidev/i18n/download-target"
    _snapshot(page, shots / "member-mobile-en.png")
    count = len(stack["dl_log"].read_text().splitlines())
    button.click()
    expect(dialog).to_have_count(0)
    assert len(stack["dl_log"].read_text().splitlines()) == count + 1
    assert json.loads(stack["dl_log"].read_text().splitlines()[-1])["save_path"] == "/downloads"
    reader.close()
    admin.close()

"""Member UI to real authentication, library permissions, content ratings and deletion facts."""

import re
from datetime import date

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
    from movieclaw_db.models import Library, LibraryFile, MediaItem, MediaMetadata, utcnow

    database = Database(database_url)
    try:
        async with database.session() as session:
            libraries = []
            for mode, name in (("everyone", "Raw Shared"), ("selected", "原始私人库")):
                folder = root / mode
                folder.mkdir()
                library = Library(
                    name=name, kind="movie", access_mode=mode, root_paths=[str(folder)]
                )
                session.add(library)
                libraries.append(library)
            await session.flush()
            items = []
            for index, (title, rating) in enumerate(
                (("RawFamily", "G"), ("RawAdult", "R"), ("RawUnrated", None))
            ):
                item = MediaItem(
                    kind="movie", tmdb_id=981100 + index, title=title, original_title=title
                )
                session.add(item)
                await session.flush()
                items.append(item)
                session.add(
                    MediaMetadata(
                        media_item_id=item.id,
                        content_rating=rating,
                        release_date=date(2020, 1, 1),
                        scraped_at=utcnow(),
                    )
                )
                path = root / "everyone" / f"raw-{index}.mkv"
                path.write_bytes(b"isolated member library fixture; preserve on member deletion")
                session.add(
                    LibraryFile(
                        library_id=libraries[0].id,
                        media_item_id=item.id,
                        file_path=str(path),
                        size_bytes=path.stat().st_size,
                        source="scanned",
                    )
                )
            await session.commit()
            return {"shared": libraries[0].id, "private": libraries[1].id, "item": items[0].id}
    finally:
        await database.dispose()


async def _subscribe(database_url, item_id, member_id):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Subscription

    database = Database(database_url)
    try:
        async with database.session() as session:
            row = Subscription(
                media_item_id=item_id,
                kind="movie",
                created_by_member_id=member_id,
                selection_mode="smart",
                smart_policy={},
                status="paused",
            )
            session.add(row)
            await session.commit()
            await session.refresh(row)
            return row.id
    finally:
        await database.dispose()


async def _owner(database_url, subscription_id):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Subscription

    database = Database(database_url)
    try:
        async with database.session() as session:
            row = await session.get(Subscription, subscription_id)
            assert row is not None
            return row.created_by_member_id
    finally:
        await database.dispose()


def test_member_creation_permissions_passwords_and_lifecycle(stack, browser):
    from playwright.sync_api import expect

    base, _, root = stack
    context = browser.new_context(
        locale="en-US",
        viewport={"width": 1280, "height": 1000},
        permissions=["clipboard-read", "clipboard-write"],
    )
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    fixture = _run(_seed(f"sqlite+aiosqlite:///{root / 'data.db'}", root))
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/members"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english(scope):
        text = (
            scope.inner_text().replace("原始私人库", "").replace("原始昵称", "").replace("原", "")
        )
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        if scope.get_attribute("role") == "dialog":
            assert scope.evaluate("element => element.scrollWidth <= element.clientWidth")

    def menu(nickname):
        page.get_by_role("button", name="More actions for " + nickname, exact=True).click()

    accounts = []
    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/members")
        page.wait_for_function(
            "theme => (document.documentElement.dataset.theme || 'silver') === theme", arg=theme_id
        )
        expect(page.get_by_role("button", name="Add member", exact=True)).to_be_visible()
        english(page.locator("main"))
        page.get_by_role("button", name="Add member", exact=True).click()
        create = page.get_by_role("dialog", name="Add member", exact=True)
        username = f"raw-{theme_id}-{width}"
        nickname = "原始昵称" if not accounts else username
        create.get_by_role("textbox", name=re.compile("^Username")).fill(username)
        create.get_by_role("textbox", name=re.compile("^Nickname")).fill(nickname)
        credential = create.get_by_role("button", name="Password, click to copy", exact=True)
        old = credential.locator("span.font-mono").inner_text()
        create.get_by_role("button", name=re.compile("^Generate another password")).click()
        password = credential.locator("span.font-mono").inner_text()
        assert password != old and len(password) >= 8
        credential.click()
        assert page.evaluate("navigator.clipboard.readText()") == password
        english(create)
        _snapshot(page, shots / f"{theme_id}-{width}-create-en.png")
        create.get_by_role("button", name="Create member", exact=True).click()
        result = page.get_by_role("dialog", name="Member created", exact=True)
        expect(result.get_by_text(password, exact=True)).to_be_visible()
        if width == 320:
            assert result.get_by_text(password, exact=True).evaluate(
                "element => element.getBoundingClientRect().height <= "
                "parseFloat(getComputedStyle(element).lineHeight) * 1.1"
            )
        result.get_by_role("button", name="Account and password, click to copy", exact=True).click()
        assert (
            page.evaluate("navigator.clipboard.readText()")
            == f"Username: {username}\nPassword: {password}"
        )
        english(result)
        _snapshot(page, shots / f"{theme_id}-{width}-credentials-en.png")
        result.get_by_role("button", name="Done", exact=True).click()
        member = next(m for m in api("get", "/members") if m["username"] == username)
        accounts.append(
            {"username": username, "password": password, "id": member["id"], "nickname": nickname}
        )
        assert member["allow_subscribe"] and not member["allow_search"] and member["all_libraries"]
        menu(nickname)
        page.get_by_role("menuitem", name="Edit member", exact=True).click()
        edit = page.get_by_role("dialog", name="Edit member " + nickname, exact=True)
        edit.get_by_role("checkbox", name=re.compile("^Torrent search")).check()
        edit.get_by_role("checkbox", name=re.compile("^Direct download")).check()
        edit.get_by_role("checkbox", name=re.compile("^Torrent search")).uncheck()
        expect(
            edit.get_by_role("checkbox", name=re.compile("^Direct download"))
        ).not_to_be_checked()
        expect(edit.get_by_role("checkbox", name=re.compile("^Direct download"))).to_be_disabled()
        edit.get_by_role("checkbox", name=re.compile("^Torrent search")).check()
        edit.get_by_role("button", name="Ages 12 and under", exact=True).click()
        edit.get_by_role("checkbox", name=re.compile("^Allow unrated titles")).check()
        edit.get_by_role("button", name="原始私人库", exact=True).click()
        edit.get_by_role("heading", name="Content ratings", exact=True).scroll_into_view_if_needed()
        english(edit)
        _snapshot(page, shots / f"{theme_id}-{width}-edit-en.png")
        edit.get_by_role("button", name="Cancel", exact=True).click()
        after = api("get", "/members/" + str(member["id"]))
        assert after["content_age_limit"] is None and after["library_ids"] == []
        assert not after["allow_unrated"] and not after["allow_search"]

    # Save actual capabilities and selected-member library grants, then test the member's access.
    target = accounts[0]
    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/settings/members")
    page.wait_for_function("(document.documentElement.dataset.theme || 'silver') === 'silver'")
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Edit member", exact=True).click()
    edit = page.get_by_role("dialog", name="Edit member " + target["nickname"], exact=True)
    edit.get_by_role("checkbox", name=re.compile("^Subscription tracking")).uncheck()
    edit.get_by_role("checkbox", name=re.compile("^Download videos to devices")).uncheck()
    edit.get_by_role("button", name="Ages 12 and under", exact=True).click()
    edit.get_by_role("button", name="原始私人库", exact=True).click()
    edit.get_by_role("button", name="Save settings", exact=True).click()
    expect(edit).to_be_hidden()
    saved = api("get", "/members/" + str(target["id"]))
    assert saved["content_age_limit"] == 12 and not saved["allow_video_download"]
    assert saved["library_ids"] == [fixture["private"]] and saved["all_libraries"]
    member = browser.new_context(locale="en-US")
    assert member.request.post(
        base + "/api/v1/auth/login",
        data={"username": target["username"], "password": target["password"]},
    ).ok
    assert {row["id"] for row in member.request.get(base + "/api/v1/libraries").json()["data"]} == {
        fixture["shared"],
        fixture["private"],
    }
    listing = member.request.get(base + f"/api/v1/libraries/{fixture['shared']}/items").json()[
        "data"
    ]
    assert {row["title"] for row in listing} == {"RawFamily"}
    assert member.request.get(base + "/api/v1/members").status == 403
    assert member.request.get(base + "/api/v1/search/torrents?keyword=RawFamily").status == 403
    app = member.request.post(
        base + "/api/v1/auth/device/login",
        data={
            "username": target["username"],
            "password": target["password"],
            "client": {"kind": "ios", "installation_id": "raw-member-phone", "name": "RawPhone"},
        },
    )
    assert app.ok, app.text()
    app_token = app.json()["data"]["token"]
    grant = api(
        "post", "/auth/device/authorize", data={"client_type": "cli", "client_name": "RawAgent"}
    )
    assert member.request.post(
        base + "/api/v1/auth/devices/requests/" + grant["user_code"] + "/approve"
    ).ok
    cli_token = api("post", "/auth/device/token", data={"device_code": grant["device_code"]})[
        "token"
    ]
    anonymous = browser.new_context()

    def token_status(token):
        return anonymous.request.get(
            base + "/api/v1/auth/me", headers={"Authorization": "Bearer " + token}
        ).status

    # Reset cancels first, then invalidates browser/App credentials while retaining paired clients.
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Reset password", exact=True).click()
    reset_title = "Reset the password for “" + target["nickname"] + "”?"
    reset = page.get_by_role("dialog", name=reset_title, exact=True)
    english(reset)
    reset.get_by_role("button", name="Cancel", exact=True).click()
    assert token_status(app_token) == 200
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Reset password", exact=True).click()
    page.get_by_role("dialog", name=reset_title, exact=True).get_by_role(
        "button", name="Reset password", exact=True
    ).click()
    result = page.get_by_role("dialog", name="Password reset", exact=True)
    password = (
        result.get_by_role("button", name="Password, click to copy", exact=True)
        .locator("span.font-mono")
        .inner_text()
    )
    assert password != target["password"]
    result.get_by_role("button", name="Done", exact=True).click()
    assert member.request.get(base + "/api/v1/auth/me").status == 401
    assert token_status(app_token) == 401 and token_status(cli_token) == 200
    assert (
        member.request.post(
            base + "/api/v1/auth/login",
            data={"username": target["username"], "password": target["password"]},
        ).status
        == 401
    )
    assert member.request.post(
        base + "/api/v1/auth/login", data={"username": target["username"], "password": password}
    ).ok
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Sign out everywhere", exact=True).click()
    signout = page.get_by_role(
        "dialog", name="Sign out “" + target["nickname"] + "” on all devices?", exact=True
    )
    with page.expect_response(
        lambda response: (
            response.request.method == "POST"
            and response.url.endswith(f"/members/{target['id']}/sign-out")
        )
    ) as signed_out:
        signout.get_by_role("button", name="Sign out everywhere", exact=True).click()
    assert signed_out.value.ok
    expect(signout).to_be_hidden()
    assert token_status(cli_token) == 401
    assert member.request.get(base + "/api/v1/auth/me").status == 401

    menu(target["nickname"])
    page.get_by_role("menuitem", name="Disable member", exact=True).click()
    disable = page.get_by_role("dialog", name="Disable “" + target["nickname"] + "”?", exact=True)
    disable.get_by_role("button", name="Cancel", exact=True).click()
    assert api("get", "/members/" + str(target["id"]))["status"] == "active"
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Disable member", exact=True).click()
    page.get_by_role(
        "dialog", name="Disable “" + target["nickname"] + "”?", exact=True
    ).get_by_role("button", name="Disable member", exact=True).click()
    expect(page.get_by_text("Member disabled", exact=True)).to_be_visible()
    assert (
        member.request.post(
            base + "/api/v1/auth/login", data={"username": target["username"], "password": password}
        ).status
        == 401
    )
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Enable member", exact=True).click()
    expect(page.get_by_text("Member enabled", exact=True)).to_be_visible()
    assert member.request.post(
        base + "/api/v1/auth/login", data={"username": target["username"], "password": password}
    ).ok

    sub_id = _run(
        _subscribe(f"sqlite+aiosqlite:///{root / 'data.db'}", fixture["item"], target["id"])
    )
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Delete member", exact=True).click()
    delete_title = "Delete member “" + target["nickname"] + "”?"
    deletion = page.get_by_role("dialog", name=delete_title, exact=True)
    english(deletion)
    _snapshot(page, shots / "delete-consequences-en.png")
    deletion.get_by_role("button", name="Cancel", exact=True).click()
    assert _run(_owner(f"sqlite+aiosqlite:///{root / 'data.db'}", sub_id)) == target["id"]
    menu(target["nickname"])
    page.get_by_role("menuitem", name="Delete member", exact=True).click()
    with page.expect_response(
        lambda r: r.request.method == "DELETE" and r.url.endswith("/members/" + str(target["id"]))
    ):
        page.get_by_role("dialog", name=delete_title, exact=True).get_by_role(
            "button", name="Delete member", exact=True
        ).click()
    assert not any(row["id"] == target["id"] for row in api("get", "/members"))
    assert _run(_owner(f"sqlite+aiosqlite:///{root / 'data.db'}", sub_id)) is None
    assert member.request.get(base + "/api/v1/auth/me").status == 401
    assert all(
        path.read_bytes() == b"isolated member library fixture; preserve on member deletion"
        for path in [root / "everyone" / f"raw-{index}.mkv" for index in range(3)]
    )
    page.goto(base + "/library")
    page.evaluate("window.memberLanguageMarker = 825")
    _change_language(page, "zh-Hans")
    assert page.evaluate("window.memberLanguageMarker") == 825
    page.goto(base + "/settings/members")
    expect(page.get_by_role("button", name="添加成员", exact=True)).to_be_visible()
    _snapshot(page, shots / "members-zh.png")
    assert not errors, errors
    anonymous.close()
    member.close()
    context.close()

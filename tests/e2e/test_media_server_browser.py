"""网页上接入媒体服务器（只读后端）：真实 Next + API + SQLite + 进程外 SDK 插件。

按用户的操作走（docs/design/media-server-plugins.md §4）：填表连上服务器、建库时挂上对方的库，
这一行标「只读」、没有「设为主根」；片子进库后删除对话框只说明原因，没有可确认的删除。
"""

import re
import time

import pytest

from . import test_i18n_drive_settings_browser as drives
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = drives.browser
search_provider = drives.search_provider

PLUGIN = """
from pydantic import BaseModel, Field, SecretStr

from movieclaw_sdk import plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS, AccountInfo, Capabilities, DirectLink, DriveBackend, Login, LoginResult,
    RemoteDir, RemoteFile, RemoteTree,
)


class Credentials(BaseModel):
    address: str = Field(title="Server address")
    token: SecretStr = Field(title="Access token")


class HomeServer(DriveBackend):
    type = "home-server"
    title = "Home Server"
    capabilities = Capabilities(
        writable=False, recheck_hours=1, default_qps=1000.0, default_daily_budget=100000,
    )
    login = Login(form=Credentials)

    async def login_with_form(self, values):
        return LoginResult(
            user_id="server-1", display_name="Living room", credentials={"token": "secret"}
        )

    async def account_info(self, account):
        return AccountInfo(display_name="Living room")

    async def list_dir(self, account, dir_id):
        if dir_id:
            return []
        return [RemoteDir(remote_id="films", name="Films", has_children=False)]

    async def list_tree(self, account, dir_id):
        return RemoteTree(
            files=(
                RemoteFile(
                    remote_id="f1", name="Test.Movie.2024.mkv", size=1_000_000,
                    rel_path="测试电影 (2024) [tmdbid=100]/Test.Movie.2024.mkv",
                ),
            )
        )

    async def direct_link(self, account, remote_id, user_agent):
        return DirectLink(
            url=f"http://127.0.0.1:9/{remote_id}", headers={"X-Token": account.credentials["token"]}
        )


@plugin("media-server-fixture", title="Home Server")
async def apply(ctx):
    ctx.contribute(DRIVE_BACKENDS, "home-server", HomeServer())
"""


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider):
    with drives.running_stack(
        tmp_path_factory.mktemp("media-server-browser"),
        plugin_id="media-server-fixture",
        plugin_source=PLUGIN,
        search_upstream=search_provider[0],
    ) as running:
        yield running


@pytest.mark.parametrize("width", [1280, 390], ids=["desktop", "phone"])
def test_read_only_server_in_the_library_form_and_delete_dialog(stack, browser, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/media-server"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    prefs = api("get", "/ui/preferences")
    prefs.update(language="en")
    api("put", "/ui/preferences", data=prefs)
    for row in api("get", "/libraries"):
        api("delete", f"/libraries/{row['id']}")
    for account in api("get", "/drives/accounts"):
        api("delete", f"/drives/accounts/{account['id']}")

    # 连上服务器：只有填表一种登录方式
    page.goto(base + "/settings/drives")
    page.get_by_role("button", name="Add cloud drive account", exact=True).click()
    login = page.get_by_role("dialog", name="Add Home Server account", exact=True)
    login.locator('input[type="text"]').fill("http://192.168.1.10:8096")
    login.locator('input[type="password"]').fill("secret")
    login.get_by_role("button", name="Verify and sign in", exact=True).click()
    expect(login).not_to_be_visible()
    expect(page.get_by_text("Living room", exact=True)).to_be_visible()

    # 建库：本地目录放旁车和新片，挂上对方的库
    local_root = stack["data"] / f"local-{width}"
    local_root.mkdir()
    page.goto(base + "/library/manage")
    page.get_by_role("button", name="Create library", exact=True).click()
    form = page.get_by_role("dialog", name="Add library", exact=True)
    form.get_by_role("button", name=re.compile("^Movie")).click()
    form.get_by_placeholder("e.g. Movies / Animation").fill(f"From server {width}")
    form.get_by_role("button", name="Browse and add a server folder", exact=True).click()
    server_picker = page.get_by_role("dialog", name="Choose a server folder", exact=True)
    expect(
        server_picker.get_by_role("button", name="Choose this folder", exact=True)
    ).to_be_enabled()
    server_picker.get_by_title("Enter path manually", exact=True).click()
    field = server_picker.get_by_placeholder("Enter an absolute path and press Enter")
    field.fill(str(local_root))
    field.press("Enter")
    expect(server_picker.locator("p[title]")).to_have_attribute("title", str(local_root.resolve()))
    server_picker.get_by_role("button", name="Choose this folder", exact=True).click()
    form.get_by_role("button", name="Home Server folders", exact=True).click()
    picker = page.get_by_role("dialog", name="Choose a cloud drive folder", exact=True)
    picker.get_by_role("button", name=re.compile("^Films")).click()
    picker.get_by_role("button", name="Choose this folder", exact=True).click()
    expect(picker).not_to_be_visible()

    # 这一行标只读，不能设为主根；说明写在悬浮提示里
    row = form.locator("div.group").filter(has_text="Living room")
    expect(row.get_by_text("Read-only", exact=True)).to_be_visible()
    expect(row.get_by_text("Set as primary root", exact=True)).to_have_count(0)
    _snapshot(page, shots / f"form-{width}.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    form.get_by_role("button", name="Next: collection scope", exact=True).click()
    form.get_by_role("button", name="Skip, create and start scan", exact=True).click()
    expect(form).not_to_be_visible()

    library = next(r for r in api("get", "/libraries") if r["name"] == f"From server {width}")
    [folder] = library["cloud_folders"]
    assert folder["is_primary"] is False and folder["remote_dir_id"] == "films"
    deadline = time.monotonic() + 90
    while True:
        library = next(r for r in api("get", "/libraries") if r["id"] == library["id"])
        if not library["scanning"] and library["cloud_folders"][0]["file_count"] == 1:
            break
        assert time.monotonic() < deadline, library
        time.sleep(0.2)

    # 接口同样拒绝，并给出原因（绕过界面的客户端、插件）
    refused = context.request.put(
        base + f"/api/v1/libraries/{library['id']}",
        headers={"Accept-Language": "en"},
        data={
            "name": library["name"],
            "kind": library["kind"],
            "root_paths": library["root_paths"],
            "cloud_folders": [
                {
                    "account_id": folder["account_id"],
                    "remote_dir_id": "films",
                    "display_path": "Films",
                    "is_primary": True,
                }
            ],
        },
    )
    assert refused.status == 400
    assert "read-only" in refused.json()["message"]

    # 删除：只说清楚为什么，不出现「永久删除」的确认流程
    item_id = api("get", f"/libraries/{library['id']}/items")[0]["media_item_id"]
    page.goto(f"{base}/library/{library['id']}/item/{item_id}")
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Delete title", exact=True).click()
    dialog = page.get_by_role("dialog", name="Delete title", exact=True)
    expect(
        dialog.get_by_text(re.compile("These files are on Home Server, which is read-only here"))
    ).to_be_visible()
    expect(dialog.get_by_role("button", name="Delete permanently", exact=True)).to_have_count(0)
    expect(dialog.get_by_role("checkbox")).to_have_count(0)
    expect(dialog.get_by_text("permanently deletes", exact=False)).to_have_count(0)
    _snapshot(page, shots / f"delete-{width}.png")
    assert not re.search(r"[\u3400-\u9fff]", dialog.inner_text().replace("测试电影", ""))
    dialog.get_by_text("Close", exact=True).click()
    expect(dialog).not_to_be_visible()
    assert api("get", f"/libraries/{library['id']}/items")
    assert not errors, errors
    context.close()

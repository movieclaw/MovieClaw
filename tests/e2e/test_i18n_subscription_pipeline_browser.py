"""Real settings checks, repair links and rule previews without creating subscriptions."""

import re

import pytest

from . import test_smart_subscription_browser as smart
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_i18n_subscription_cancel_browser import _run

stack = smart.smart_stack
browser = theme.browser
pytestmark = pytest.mark.integration


async def _configure(database_url, root, *, repair=False, watch=False):
    from sqlmodel import select

    from movieclaw_db.engine import Database
    from movieclaw_db.models import ImportWatch, Library, SiteCredential
    from movieclaw_db.models.downloader_client import ClientType, DownloaderClient
    from movieclaw_db.models.site_credential import AuthType, ConfigStatus

    db = Database(database_url)
    try:
        async with db.session() as session:
            if repair:
                downloader = (await session.execute(select(DownloaderClient))).scalar_one()
                downloader.path_mappings = [{"local": str(root), "remote": "/downloads"}]
                session.add(downloader)
            elif watch:
                library = (
                    await session.execute(select(Library).where(Library.kind == "movie"))
                ).scalar_one()
                source, target = root / "watch", root / "staging"
                source.mkdir()
                target.mkdir()
                session.add(
                    ImportWatch(
                        source_path=str(source),
                        target_path=str(target),
                        library_id=library.id,
                        strategy="copy",
                    )
                )
            else:
                for kind, name in (("movie", "我的电影库"), ("tv", "我的剧集库")):
                    path = root / kind
                    path.mkdir()
                    session.add(
                        Library(name=name, kind=kind, root_paths=[str(path)], is_default=True)
                    )
                session.add(
                    DownloaderClient(
                        name="原始下载器",
                        client_type=ClientType.QBITTORRENT,
                        url="http://127.0.0.1:1",
                        status=ConfigStatus.ACTIVE,
                        is_default=True,
                        path_mappings=[{"local": "/unmapped", "remote": "/downloads"}],
                    )
                )
                session.add(
                    SiteCredential(
                        site_id="raw-site",
                        auth_type=AuthType.COOKIE,
                        cookie="x",
                        enabled=True,
                        status=ConfigStatus.ACTIVE,
                    )
                )
            await session.commit()
    finally:
        await db.dispose()


def test_pipeline_checks_repairs_and_real_rule_preview(stack, browser):
    from playwright.sync_api import expect

    base, _, root = stack
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    admin = {"username": "smart-admin", "password": "isolated-test-only"}
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=admin).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/subscription-pipeline"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def open_page(theme_id, width, path):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + path)
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")

    def english(scope):
        text = scope.inner_text()
        for raw in ("我的电影库", "我的剧集库", "原始下载器", "我的电影规则", "测试电影"):
            text = text.replace(raw, "")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    for width in (1280, 320):
        open_page("silver", width, "/settings/overview")
        panel = page.locator("section").filter(
            has=page.get_by_role("heading", name="Subscription pipeline check", exact=True)
        )
        expect(panel.get_by_text("Connect release sites", exact=True)).to_be_visible()
        expect(panel.get_by_text("Connect a downloader", exact=True)).to_be_visible()
        english(panel)
        _snapshot(page, shots / f"setup-{width}-en.png")

    database_url = f"sqlite+aiosqlite:///{root / 'data.db'}"
    _run(_configure(database_url, root))
    api(
        "post",
        "/rule-sets",
        data={
            "name": "我的电影规则",
            "spec": {},
            "match_rules": [{"field": "kind", "op": "any_of", "values": ["movie"]}],
        },
    )
    before = api("get", "/subscriptions")
    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        open_page(theme_id, width, "/settings/overview")
        panel = page.locator("section").filter(
            has=page.get_by_role("heading", name="Subscription pipeline check", exact=True)
        )
        expect(
            panel.get_by_text("Add one common parent path mapping (smallest change)", exact=False)
        ).to_be_visible()
        mapping = panel.get_by_role("link", name="Add mapping", exact=False)
        expect(mapping).to_have_attribute("href", re.compile("suggest_mapping="))
        expect(panel.get_by_role("link", name="Create rules", exact=False)).to_have_attribute(
            "href", re.compile("suggest=auto")
        )
        english(panel)
        _snapshot(page, shots / f"{theme_id}-{width}-checks-en.png")
        panel.get_by_role("button", name="See all", exact=True).first.click()
        expect(panel.get_by_role("button", name="Collapse", exact=True)).to_be_visible()
        english(panel)

        page.goto(base + "/settings/subscription")
        page.get_by_role("tab", name="Custom rules", exact=True).click()
        page.get_by_role("button", name="Preview matching", exact=True).click()
        dialog = page.get_by_role("dialog", name="Rule and import preview", exact=True)
        dialog.get_by_role("searchbox", name="Search for a preview title").fill("测试电影")
        candidate = dialog.get_by_role("button", name=re.compile("^测试电影"))
        candidate.wait_for()
        pattern = "**/api/v1/subscriptions/download-routing-preview?*"
        page.route(pattern, lambda route: route.abort())
        candidate.click()
        expect(dialog.get_by_role("alert")).to_contain_text("Preview failed. Try again.")
        page.unroute(pattern)
        dialog.get_by_role("button", name="Retry preview", exact=True).click()
        expect(dialog.get_by_text(re.compile("Selected.*我的电影规则"))).to_be_visible()
        dialog.locator("summary").click()
        expect(
            dialog.get_by_text(re.compile("Download directly into library directory"))
        ).to_be_visible()
        english(dialog)
        assert dialog.locator("details").evaluate("el => el.scrollWidth <= el.clientWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-preview-en.png")
        page.keyboard.press("Escape")
        expect(dialog).to_be_hidden()
        assert api("get", "/subscriptions") == before

    _run(_configure(database_url, root, repair=True))
    open_page("silver", 1280, "/settings/overview")
    expect(page.get_by_text("Healthy", exact=True)).to_have_count(2)
    assert api("get", "/subscriptions/automation-readiness")["status"] == "ok"
    page.evaluate("window.pipelineMarker = 902")
    for locale in ("zh-Hans", "en"):
        current_english = page.locator("html").get_attribute("lang") == "en"
        page.get_by_role(
            "button",
            name="Appearance and language" if current_english else "外观与语言",
            exact=True,
        ).click()
        group = page.get_by_test_id("language-settings")
        group.locator(f'input[value="{locale}"]').check()
        expect(page.locator("html")).to_have_attribute("lang", locale)
        page.get_by_role(
            "button", name="概览" if locale == "zh-Hans" else "Overview", exact=True
        ).click()
        title = "订阅链路体检" if locale == "zh-Hans" else "Subscription pipeline check"
        panel = page.locator("section").filter(
            has=page.get_by_role("heading", name=title, exact=True)
        )
        expect(
            panel.get_by_role(
                "button", name="重新体检" if locale == "zh-Hans" else "Run checks again"
            )
        ).to_be_enabled()
        assert page.evaluate("window.pipelineMarker") == 902
        if locale == "en":
            expect(panel.get_by_text("Healthy", exact=True)).to_have_count(2)
            english(panel)
        else:
            expect(panel.get_by_text("正常", exact=True)).to_have_count(2)
        _snapshot(page, shots / f"repaired-{locale}.png")
    _run(_configure(database_url, root, watch=True))
    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        open_page(theme_id, width, "/settings/overview")
        panel = page.locator("section").filter(
            has=page.get_by_role("heading", name="Subscription pipeline check", exact=True)
        )
        expect(panel.get_by_text("Send to watched directory", exact=True)).to_be_visible()
        expect(panel.get_by_text("Organize output", exact=True)).to_be_visible()
        expect(panel.get_by_text("External transfer", exact=True)).to_be_visible()
        expect(panel.get_by_text("Record returned files", exact=True)).to_be_visible()
        english(panel)
        step = panel.get_by_text("Send to watched directory", exact=True)
        step.scroll_into_view_if_needed()
        # Each flow capsule must fit the card even when a full source path is present.
        assert step.evaluate("el => el.parentElement.getBoundingClientRect().right <= innerWidth")
        assert panel.get_by_text("Organize output", exact=True).evaluate(
            "el => el.parentElement.getBoundingClientRect().right <= innerWidth"
        )
        _snapshot(page, shots / f"{theme_id}-{width}-watch-en.png")
    assert api("get", "/subscriptions") == before
    assert not errors
    context.close()

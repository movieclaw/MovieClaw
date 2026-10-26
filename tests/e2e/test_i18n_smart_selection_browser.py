"""Real release matching, wait extension and explicit downloads in reader languages."""

import re
from datetime import datetime

import pytest

from . import test_smart_memory_browser as lab
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_library_manage_browser import _wait_for

browser = lab.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("MC_LAB_SMART_SELECTION", "1")
        yield from lab.stack.__wrapped__(tmp_path_factory)


def test_smart_wait_subtitles_and_manual_downloads_follow_reader_language(stack, browser):
    from playwright.sync_api import expect

    base, server = stack
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/smart-selection"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    defaults = api("get", "/subscriptions/smart-defaults")
    api(
        "put",
        "/subscriptions/smart-defaults",
        data={
            "movie_revision": defaults["movie_revision"],
            "tv_revision": defaults["tv_revision"],
            "resolution": "2160p",
            "source": "blu-ray",
            "allow_upgrade": True,
            "strict_resolution": False,
            "movie_wait_seconds": 86400,
            "tv_wait_seconds": 10800,
        },
    )

    def create(kind, identity, answer):
        title_ref = f"tmdb:{kind}:{identity}"
        plan = api("post", "/subscriptions/title-preview", data={"title_ref": title_ref})["smart"]
        body = {
            "title_ref": title_ref,
            "selection_mode": "smart",
            "smart_profile_revision": plan["profile_revision"],
            "smart_memory_revision": plan["memory_revision"],
            "smart_language_answer": answer,
        }
        if kind == "tv":
            body["selected_seasons"] = [1]
        return api("post", "/subscriptions", data=body)["subscription"]

    def detail(sub_id):
        return api("get", f"/subscriptions/{sub_id}")

    def release(kind, identity):
        response = context.request.post(
            f"{server}/__lab/release/{kind}/{identity}?name=FixtureGroup"
        )
        assert response.ok, response.text()
        assert response.json()["dispatched"] == 0

    def english(locator, *metadata):
        text = locator.inner_text()
        for raw in metadata:
            text = text.replace(raw, "")
        assert not re.search(r"[\u3400-\u9fff]", text), text

    def open_detail(sub_id, theme_id):
        page.goto(f"{base}/subscriptions/{sub_id}")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")

    for index, ((theme_id, width), movie_id, tv_id) in enumerate(
        zip(
            (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)),
            (701, 702, 703, 706),
            (801, 802, 804, 805),
            strict=True,
        )
    ):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        sub = create("movie", movie_id, "subtitles")
        release("movie", movie_id)
        open_detail(sub["id"], theme_id)
        waiting = page.get_by_role("group", name="Waiting for a subtitled release", exact=True)
        expect(waiting).to_be_visible()
        english(waiting, sub["media"]["original_title"])
        state = detail(sub["id"])["wanted"][0]["selection_state"]
        assert "None of the releases found" in state["wait_explanation"]
        waiting.scroll_into_view_if_needed()
        _snapshot(page, shots / f"{theme_id}-{width}-subtitles-en.png")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        if index == 0:
            page.evaluate("window.smartSelectionMarker = 612")
            for locale in ("zh-Hans", "en"):
                _change_language(page, locale)
                expect(
                    page.get_by_role(
                        "group",
                        name="等待字幕版"
                        if locale == "zh-Hans"
                        else "Waiting for a subtitled release",
                        exact=True,
                    )
                ).to_be_visible()
                reread = detail(sub["id"])["wanted"][0]["selection_state"]
                assert reread["deadline"] == state["deadline"]
                assert reread["candidate_key"] == state["candidate_key"]
                assert page.evaluate("window.smartSelectionMarker") == 612
                if locale == "zh-Hans":
                    assert (
                        reread["wait_explanation"]
                        == "已找到的资源都没有你看得懂的字幕或音轨，继续等待带字幕的版本。"
                    )
        waiting.get_by_role("button", name="Download the original this time", exact=True).click()
        follow = page.get_by_role("group", name="Do you understand this language?", exact=True)
        expect(follow).to_be_visible()
        english(follow)
        _snapshot(page, shots / f"{theme_id}-{width}-understood-en.png")
        follow.get_by_role(
            "button", name="Just this time" if index % 2 == 0 else "I understand it", exact=True
        ).click()
        expect(follow).not_to_be_visible()
        _wait_for(
            lambda sub_id=sub["id"]: detail(sub_id)["wanted"][0]["status"] != "wanted",
            timeout=15,
            what="explicit original download to dispatch",
        )
        events = api("get", f"/subscriptions/{sub['id']}/activities")
        assert (
            sum(
                event["message_key"] == "activity.subscription.smartCandidateRequested"
                for event in events
            )
            == 1
        )

        show = create("tv", tv_id, "understood")
        release("tv", tv_id)
        open_detail(show["id"], theme_id)
        page.get_by_role("button", name=re.compile("^E01 ")).click()
        reasoning = page.get_by_role("group", name="Smart selection reasoning", exact=True)
        expect(reasoning).to_be_visible()
        english(reasoning, show["media"]["original_title"])
        before = next(row for row in detail(show["id"])["wanted"] if row["selection_state"])
        with page.expect_response(
            lambda response: "/smart-wait" in response.url and response.request.method == "POST"
        ) as updated:
            reasoning.get_by_role("button", name="Extend by 2 hours", exact=True).click()
        assert updated.value.ok, updated.value.text()
        changed = updated.value.json()["data"]
        assert (
            datetime.fromisoformat(changed["selection_state"]["deadline"])
            - datetime.fromisoformat(before["selection_state"]["deadline"])
        ).total_seconds() == 7200
        assert changed["selection_version"] == before["selection_version"] + 1
        english(reasoning, show["media"]["original_title"])
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        reasoning.scroll_into_view_if_needed()
        _snapshot(page, shots / f"{theme_id}-{width}-extended-en.png")
        reasoning.get_by_role("button", name="Download current candidate now", exact=True).click()
        _wait_for(
            lambda sub_id=show["id"]: detail(sub_id)["wanted"][0]["status"] != "wanted",
            timeout=15,
            what="explicit candidate download to dispatch",
        )
    assert len(api("get", "/subscriptions")) == 8
    assert not errors
    context.close()

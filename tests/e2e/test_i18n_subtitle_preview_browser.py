"""Real embedded/external subtitle reads and zero-LLM timing calibration."""

from __future__ import annotations

import hashlib
import random
import re
import subprocess

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_i18n_share_artwork_browser import _api
from .test_library_manage_browser import _wait_for

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_I18N_DISCOVERY", "1")
        patch.setenv("E2E_I18N_ARTWORK", "1")
        yield from inventory.stack.__wrapped__(tmp_path_factory)


def _subtitles(offset=0):
    def format_srt_time(ms):
        return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"

    rng = random.Random(2642)
    start = 1000
    cues = []
    for index in range(60):
        end = start + rng.randrange(30, 130) * 10
        cues.append(
            f"{index + 1}\n{format_srt_time(start + offset)} --> "
            f"{format_srt_time(end + offset)}\nOriginal 对白 {index + 1}\n"
        )
        start = end + rng.randrange(20, 120) * 10
    return "\n".join(cues)


def test_preview_and_calibration_in_both_languages(stack, browser, tmp_path):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
    _api(context, base, "post", "/auth/bootstrap", data=inventory.ADMIN)
    root = stack["roots"]["movies"]
    entry = root / "某电影 (2020)"
    entry.mkdir()
    reference = tmp_path / "reference.srt"
    reference.write_text(_subtitles())
    video = entry / "某电影.2020.mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=5:duration=120",
            "-i",
            str(reference),
            "-map",
            "0:v",
            "-map",
            "1:s",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-c:s",
            "srt",
            "-metadata:s:s:0",
            "language=eng",
            "-metadata:s:s:0",
            "title=Original dialogue",
            str(video),
        ],
        check=True,
        timeout=60,
    )
    original_hash = hashlib.sha256(video.read_bytes()).hexdigest()
    external = video.with_suffix(".eng.srt")
    external.write_text(_subtitles(2000))
    short = video.with_suffix(".chi.srt")
    short.write_text("1\n00:00:01,000 --> 00:00:02,000\n单句原文\n")
    video.with_suffix(".nfo").write_text(
        "<movie><title>某电影</title><year>2020</year>"
        "<uniqueid type='tmdb' default='true'>300</uniqueid></movie>"
    )
    library = _api(
        context,
        base,
        "post",
        "/libraries",
        data={
            "name": "Subtitle samples",
            "kind": "movie",
            "root_paths": [str(root)],
            "realtime_watch": False,
        },
    )
    lid = library["id"]
    _wait_for(
        lambda: (
            (row := _api(context, base, "get", f"/libraries/{lid}"))["last_scan"]
            and not row["scanning"]
        ),
        timeout=120,
        what="subtitle scan",
    )
    items = _api(context, base, "get", f"/libraries/{lid}/items")
    assert len(items) == 1
    item_id = items[0]["media_item_id"]
    detail = _api(context, base, "get", f"/libraries/{lid}/items/{item_id}")
    file_id = detail["files"][0]["id"]
    shots = theme.REPO / ".tmp-uidev/i18n/subtitle-preview"
    shots.mkdir(parents=True, exist_ok=True)
    page = context.new_page()
    page.set_default_timeout(30_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(f"{base}/library/{lid}/item/{item_id}")
    page.get_by_role("button", name=re.compile(r"English.*×2")).click()
    page.get_by_role("button", name=re.compile("^Preview subtitle:.*Original dialogue")).click()
    dialog = page.get_by_role("dialog", name=re.compile("^Subtitle preview:"))
    expect(dialog.get_by_text("Original 对白 1", exact=True)).to_be_visible(timeout=60_000)
    expect(dialog.get_by_text("60 lines of dialogue", exact=True)).to_be_visible()
    expect(dialog.get_by_text("Embedded", exact=True)).to_be_visible()
    expect(dialog.get_by_role("button", name="Calibrate timing", exact=True)).to_have_count(0)
    _snapshot(page, shots / "embedded-en.png")
    dialog.get_by_role("button", name="Close subtitle preview", exact=True).click()

    page.get_by_role("button", name=re.compile(r"English.*×2")).click()
    page.get_by_role("button", name=re.compile(r"^Preview subtitle:.*eng\.srt")).click()
    dialog = page.get_by_role("dialog", name=re.compile("^Subtitle preview:"))
    expect(dialog.get_by_text("00:00:03.000", exact=True)).to_be_visible()
    dialog.get_by_role("button", name="Calibrate timing", exact=True).click()
    expect(
        dialog.get_by_text(re.compile("^Calibration complete .*offset -2.00 seconds"))
    ).to_be_visible(timeout=60_000)
    expect(dialog.get_by_text("00:00:01.000", exact=True)).to_be_visible()
    from movieclaw_api.services.subtitle_gen.extract import parse_events

    assert parse_events(external.read_text(), "srt") == parse_events(reference.read_text(), "srt")
    assert hashlib.sha256(video.read_bytes()).hexdigest() == original_hash
    _snapshot(page, shots / "calibrated-en.png")
    page.set_viewport_size({"width": 320, "height": 844})
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    assert dialog.evaluate("element => element.scrollWidth <= element.clientWidth")
    _snapshot(page, shots / "calibrated-mobile-en.png")
    dialog.get_by_role("button", name="Calibrate timing", exact=True).click()
    expect(dialog.get_by_text(re.compile("^The subtitle is already synchronized"))).to_be_visible()
    dialog.get_by_role("button", name="Close subtitle preview", exact=True).click()

    page.get_by_role("button", name=re.compile(r"Chinese")).click()
    page.get_by_role("button", name=re.compile(r"^Preview subtitle:.*chi\.srt")).click()
    dialog = page.get_by_role("dialog", name=re.compile("^Subtitle preview:"))
    expect(dialog.get_by_text("1 line of dialogue", exact=True)).to_be_visible()
    dialog.get_by_role("button", name="Calibrate timing", exact=True).click()
    expect(
        dialog.get_by_text("There are too few subtitle cues for reliable calibration", exact=True)
    ).to_be_visible()
    assert short.read_text().endswith("单句原文\n")
    _snapshot(page, shots / "short-mobile-en.png")
    for locale, expected in (
        ("zh-Hans", "字幕事件太少，无法可靠校准"),
        ("en", "There are too few subtitle cues for reliable calibration"),
    ):
        response = context.request.post(
            f"{base}/api/v1/libraries/files/{file_id}/subtitles/timing-calibration",
            data={"filename": short.name},
            headers={"Accept-Language": locale},
        )
        assert response.ok, response.text()
        assert response.json()["data"]["message"] == expected
        assert response.json()["data"]["message_key"] == "library.subtitleCalibration.tooFew"
    chinese = browser.new_context(
        locale="zh-CN",
        storage_state=context.storage_state(),
        viewport={"width": 320, "height": 844},
    )
    chinese.add_cookies([{"name": "mc_locale", "value": "zh-Hans", "url": base}])
    page = chinese.new_page()
    page.goto(f"{base}/library/{lid}/item/{item_id}")
    page.get_by_role("button", name=re.compile(r"中文")).click()
    page.get_by_role("button", name=re.compile(r"^预览字幕：.*chi\.srt")).click()
    dialog = page.get_by_role("dialog", name=re.compile("^字幕预览："))
    expect(dialog.get_by_text("共 1 条对白", exact=True)).to_be_visible()
    dialog.get_by_role("button", name="校准时间轴", exact=True).click()
    expect(dialog.get_by_text("字幕事件太少，无法可靠校准", exact=True)).to_be_visible()
    _snapshot(page, shots / "short-mobile-zh.png")
    assert not errors
    chinese.close()
    context.close()

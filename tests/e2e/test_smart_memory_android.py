"""智能订阅记忆的 Android 模拟器验收：真实 App → 真实接口 → 临时数据库。

驱动方式：adb 启动调试包（`mc_server/mc_user/mc_pass` 登录，`mc_subscribe` 打开订阅抽屉，
`mc_route subscription/<id>` 打开订阅详情），uiautomator 读界面树（Compose testTag 暴露为
resource-id），按坐标点按。后端是 tests/e2e/_smart_memory_api_launcher.py（假 TMDB、dry-run 投递）。

运行（需要已启动的模拟器与已安装的调试包；服务端每次用全新数据库）：
  MC_ANDROID_E2E=1 MC_TEST_PORT=8831 .venv/bin/python -m pytest \
    tests/e2e/test_smart_memory_android.py -m integration
"""

from __future__ import annotations

import os
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import httpx
import pytest

pytestmark = pytest.mark.integration

PORT = os.environ.get("MC_TEST_PORT", "8831")
API = f"http://127.0.0.1:{PORT}"
APP_SERVER = f"http://10.0.2.2:{PORT}"
ADB = os.environ.get("ADB", str(Path.home() / "Library/Android/sdk/platform-tools/adb"))
PACKAGE = "io.movieclaw.android"
ADMIN = ("android-memory", "isolated-android-test")
SHOTS = Path(os.environ.get("MC_SHOT_DIR", "/tmp/smart-memory-shots"))

if os.environ.get("MC_ANDROID_E2E") != "1":
    pytest.skip("需要 MC_ANDROID_E2E=1、运行中的模拟器与隔离服务端", allow_module_level=True)


def adb(*args: str) -> str:
    return subprocess.run([ADB, *args], capture_output=True, text=True, timeout=60).stdout


def screen() -> ET.Element:
    for _ in range(3):
        adb("shell", "uiautomator", "dump", "/sdcard/mc-ui.xml")
        root = ET.fromstring(adb("shell", "cat", "/sdcard/mc-ui.xml") or "<hierarchy/>")
        # 模拟器偶发的系统「应用无响应」对话框（多见于启动器）：点「等待」继续，不算 App 的问题
        wait = next(
            (n for n in root.iter("node") if n.get("resource-id") == "android:id/aerr_wait"), None
        )
        if wait is None:
            return root
        tap(wait)
    return root


def nodes(root: ET.Element):
    return root.iter("node")


def matches(node, *, rid=None, text=None, contains=None, desc=None):
    if rid is not None and node.get("resource-id") != rid:
        return False
    if text is not None and node.get("text") != text:
        return False
    if contains is not None and contains not in (node.get("text") or ""):
        return False
    return desc is None or node.get("content-desc") == desc


def find(timeout=20.0, scroll=False, **query):
    deadline = time.time() + timeout
    while True:
        for node in nodes(screen()):
            if matches(node, **query):
                return node
        if time.time() > deadline:
            raise AssertionError(f"界面上没有 {query}")
        if scroll:
            adb("shell", "input", "swipe", "540", "1900", "540", "1300", "300")
        time.sleep(0.8)


def absent(timeout=3.0, **query) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(matches(n, **query) for n in nodes(screen())):
            return True
        time.sleep(0.8)
    return False


def tap(node) -> None:
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
    time.sleep(0.6)


def tap_on(timeout=20.0, scroll=True, **query) -> None:
    deadline = time.time() + timeout
    while True:
        for node in nodes(screen()):
            if matches(node, **query):
                tap(node)
                return
        if time.time() > deadline:
            raise AssertionError(f"点不到 {query}")
        if scroll:
            adb("shell", "input", "swipe", "540", "1900", "540", "1300", "300")
        time.sleep(0.6)


def shot(name: str) -> None:
    SHOTS.mkdir(parents=True, exist_ok=True)
    data = subprocess.run(
        [ADB, "exec-out", "screencap", "-p"], capture_output=True, timeout=30
    ).stdout
    (SHOTS / f"android-{name}.png").write_bytes(data)


def launch(*, subscribe: str | None = None, route: str | None = None, user=ADMIN) -> None:
    # 新装的调试包首次启动会弹通知授权框，先授予，免得盖住界面
    adb("shell", "pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS")
    adb("shell", "am", "force-stop", PACKAGE)
    args = ["shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity",
            "--es", "mc_server", APP_SERVER, "--es", "mc_user", user[0], "--es", "mc_pass", user[1]]
    if subscribe:
        args += ["--es", "mc_subscribe", subscribe]
    if route:
        args += ["--es", "mc_route", route]
    adb(*args)


def submit() -> None:
    tap_on(text="确认订阅", scroll=False)
    assert absent(timeout=20, rid="smart-card"), "订阅抽屉没有关闭"


@pytest.fixture(scope="module")
def api():
    with httpx.Client(base_url=API, timeout=30) as client:
        client.post("/api/v1/auth/bootstrap", json={"username": ADMIN[0], "password": ADMIN[1]})
        assert client.post(
            "/api/v1/auth/login", json={"username": ADMIN[0], "password": ADMIN[1]}
        ).status_code == 200
        yield client


def detail(api, tmdb_id):
    rows = api.get("/api/v1/subscriptions").json()["data"]
    sub = next(s for s in rows if s["media"]["tmdb_id"] == tmdb_id)
    return api.get(f"/api/v1/subscriptions/{sub['id']}").json()["data"]


def change_quality(value_tag: str, scope_tag: str) -> None:
    tap_on(rid="smart-quality")
    tap_on(rid=value_tag, scroll=False)
    tap_on(rid=scope_tag)
    shot(f"quality-{scope_tag}")
    tap_on(rid="smart-quality-done", scroll=False)


def test_household_journey_on_android(api):
    # 1 首次设置在抽屉里完成；第一次碰到英语就问一次，默认已选好
    launch(subscribe="tmdb:movie:701")
    tap_on(rid="smart-setup")
    tap_on(rid="smart-save", scroll=False)
    find(text="这是英语片，要中文字幕吗？")
    assert find(rid="smart-language-subtitles").get("checked") == "true"
    shot("01-first-english-question")
    submit()
    assert detail(api, 701)["smart_policy"]["watchable_languages"] == ["zh"]

    # 2 只有英语原版：详情写明在等字幕；这次先下原版，然后追问看不看得懂
    released = api.post("/__lab/release/movie/701?name=RAW&hours_ago=1").json()
    assert released["dispatched"] == 0
    oppenheimer = detail(api, 701)["id"]
    launch(route=f"subscription/{oppenheimer}")
    find(rid="smart-awaiting-subtitles", timeout=30, scroll=True)
    find(text="已有 1 个原版，在等带字幕的版本")
    find(text="英语 · 只下带中文字幕的")
    shot("02-awaiting-subtitles")
    tap_on(rid="smart-download-original")
    find(text="已开始下载原版。你看得懂英语吗？")
    shot("03-understood-dialog")
    tap_on(text="只这次", scroll=False)
    time.sleep(2)
    assert detail(api, 701)["wanted"][0]["status"] != "wanted"

    # 3 同一种语言不再问；点「改」改成看得懂
    launch(subscribe="tmdb:tv:804")
    assert find(rid="smart-subtitle-line").get("text") == "英语 · 只下带中文字幕的"
    assert absent(contains="要中文字幕吗")
    tap_on(rid="smart-language-edit")
    tap_on(rid="smart-language-understood")
    shot("04-change-language")
    submit()
    assert detail(api, 804)["smart_policy"]["watchable_languages"] == []

    # 4 改了画质才问要不要记住，原因由用户自己点
    launch(subscribe="tmdb:tv:801")
    find(text="这是韩语片，要中文或英语字幕吗？")
    change_quality("smart-quality-resolution-1080p", "smart-scope-region:tv:KR")
    find(text="优先 1080p WEB-DL")
    submit()
    launch(subscribe="tmdb:tv:802")
    assert find(rid="smart-quality-label").get("text") == "优先 1080p WEB-DL"
    assert find(rid="smart-quality-note").get("text") == "按「韩国的剧」的习惯"
    shot("05-habit-applied")

    # 5 平台习惯比地区具体，写明被盖住的那条
    launch(subscribe="tmdb:tv:803")
    change_quality("smart-quality-resolution-2160p", "smart-scope-network:tv:Netflix")
    submit()
    launch(subscribe="tmdb:tv:806")
    assert find(rid="smart-quality-note").get("text") == "按「Netflix 的剧」的习惯"
    assert find(rid="smart-quality-shadow").get("text") == "「韩国的剧」是 1080p"
    assert find(rid="smart-quality-label").get("text") == "优先 4K WEB-DL"
    shot("06-conflict-order")

    # 6 「只这部」不会白设：续集沿用
    launch(subscribe="tmdb:movie:703")
    change_quality("smart-quality-source-remux", "smart-scope-only")
    submit()
    launch(subscribe="tmdb:movie:704")
    assert find(rid="smart-quality-note").get("text") == "按《沙丘》的设置"
    assert find(rid="smart-quality-label").get("text") == "优先 4K Remux"
    shot("07-series")
    submit()
    assert detail(api, 704)["smart_policy"]["source"] == "remux"

    # 7 设置：记住的东西都在这里，写明来源，可以删
    launch(subscribe="tmdb:movie:705")
    tap_on(rid="smart-edit")
    find(rid="smart-language-en", timeout=20, scroll=True)
    find(text="韩国的剧 · 1080p", scroll=True)
    find(text="来自《请回答1988》", scroll=True)
    shot("08-settings-memory")
    tap_on(desc="移除韩国的剧")
    assert absent(timeout=10, text="韩国的剧 · 1080p")
    assert detail(api, 801)["smart_policy"]["resolution"] == "2160p"
    tap_on(rid="smart-cancel-edit", scroll=False)

    # 8 成员只看结论，不能改，也不会被问
    assert api.post(
        "/api/v1/members", json={"username": "android-kid", "password": "member-pass-1"}
    ).status_code == 200
    launch(subscribe="tmdb:tv:805", user=("android-kid", "member-pass-1"))
    assert find(rid="smart-subtitle-line").get("text") == "日语 · 只下带中文或英语字幕的"
    assert absent(rid="smart-quality")
    assert absent(rid="smart-language-edit")
    assert absent(contains="字幕吗")
    shot("09-member")

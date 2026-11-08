"""详情页完整简介（issue #1238）的 Android TV 模拟器验收：真实 App → 真实接口 → 夹具库。

驱动方式：adb 启动调试包（`mc_server/mc_user/mc_pass` 登录，`mc_item <库>-<条目>` 直接进详情），
遥控器按键走 `input keyevent`，uiautomator 读界面树
（Compose testTag 暴露为 resource-id，焦点看 focused）。
后端是 apps/android-tv/tests/fixture/fixture.py（夹具里《星际回声》简介 134 字，首屏三行放不下）。

运行（需要已启动的电视模拟器、已安装的调试包、已起好的夹具）：
  MC_ATV_FIXTURE=/tmp/mc-atv MC_ATV_PORT=8820 \
    .venv/bin/python apps/android-tv/tests/fixture/fixture.py start
  MC_ANDROID_E2E=1 MC_ATV_PORT=8820 \
    .venv/bin/python -m pytest tests/e2e/test_overview_androidtv.py -m integration
可选：MC_OVERVIEW_LONG_ITEM=<库>-<条目> 指一部简介长到完整简介页一屏放不下的条目，验证上下键滚动；
MC_SHOT_DIR 存截图。
"""

from __future__ import annotations

import os
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

pytestmark = pytest.mark.integration

PORT = os.environ.get("MC_ATV_PORT", "8810")
APP_SERVER = f"http://10.0.2.2:{PORT}"
ADB = os.environ.get("ADB", str(Path.home() / "Library/Android/sdk/platform-tools/adb"))
PACKAGE = "io.movieclaw.androidtv"
ADMIN = ("admin", "mclaw-atv-2026")
MOVIE = os.environ.get("MC_OVERVIEW_ITEM", "1-10")  # 《星际回声》
SHOW = os.environ.get("MC_OVERVIEW_SHOW", "2-18")  # 《雾港疑云》
SHOTS = Path(os.environ.get("MC_SHOT_DIR", "/tmp/overview-androidtv-shots"))

if os.environ.get("MC_ANDROID_E2E") != "1":
    pytest.skip("需要 MC_ANDROID_E2E=1、运行中的电视模拟器与夹具服务端", allow_module_level=True)


def adb(*args: str) -> str:
    return subprocess.run([ADB, *args], capture_output=True, text=True, timeout=60).stdout


def screen() -> ET.Element:
    adb("shell", "uiautomator", "dump", "/sdcard/mc-ui.xml")
    return ET.fromstring(adb("shell", "cat", "/sdcard/mc-ui.xml") or "<hierarchy/>")


def node(rid: str, root: ET.Element | None = None) -> ET.Element | None:
    root = root if root is not None else screen()
    return next((n for n in root.iter("node") if n.get("resource-id") == rid), None)


def focused(root: ET.Element | None = None) -> str | None:
    """拿着焦点的那一项的 testTag。

    焦点常落在带标签节点里面的子节点上（卡片），往上找最近的标签；都没有返回空串。
    """
    root = root if root is not None else screen()
    parents = {child: parent for parent in root.iter() for child in parent}
    hit = next((n for n in root.iter("node") if n.get("focused") == "true"), None)
    if hit is None:
        return None
    while hit is not None:
        if hit.get("resource-id"):
            return hit.get("resource-id")
        hit = parents.get(hit)
    return ""


def wait(predicate, timeout: float = 10.0, message: str = ""):
    deadline = time.time() + timeout
    while True:
        root = screen()
        value = predicate(root)
        # XML 节点没有子节点时布尔值为假，只认「不是 None / False」
        if value is not None and value is not False:
            return value
        if time.time() > deadline:
            raise AssertionError(f"{message}（当前焦点：{focused(root)!r}）")
        time.sleep(0.5)


def wait_focus(rid: str, message: str, timeout: float = 8.0):
    wait(lambda root: focused(root) == rid, timeout, message)


def key(name: str, *, long: bool = False):
    adb("shell", "input", "keyevent", *(["--longpress"] if long else []), name)
    time.sleep(0.8)


def shot(name: str):
    SHOTS.mkdir(parents=True, exist_ok=True)
    (SHOTS / f"{name}.png").write_bytes(capture())


def capture() -> bytes:
    command = [ADB, "exec-out", "screencap", "-p"]
    return subprocess.run(command, capture_output=True, timeout=60).stdout


def open_item(item: str):
    adb("shell", "am", "force-stop", PACKAGE)
    adb(
        "shell",
        "am",
        "start",
        "-n",
        f"{PACKAGE}/.MainActivity",
        "--es",
        "mc_server",
        APP_SERVER,
        "--es",
        "mc_user",
        ADMIN[0],
        "--es",
        "mc_pass",
        ADMIN[1],
        "--es",
        "mc_item",
        item,
    )
    wait_focus("play", "进详情页焦点没有落在主按钮上", timeout=40)


def test_stage_overview_opens_full_text():
    """截断的简介：进页面落在主按钮 → 往上聚焦简介 → 确认打开完整简介 →
    返回关掉、焦点回简介 → 往下回主按钮"""
    open_item(MOVIE)
    assert node("overview") is not None, "简介超过三行，却不能聚焦"
    key("DPAD_UP")
    wait_focus("overview", "主按钮往上没有落到简介上")
    shot("androidtv-overview-focused")

    key("DPAD_CENTER")
    wait(lambda root: node("overview-panel", root) is not None, message="按确认没有打开完整简介")
    assert node("overview-text") is not None
    shot("androidtv-overview-panel")

    key("BACK")
    wait(lambda root: node("overview-panel", root) is None, message="按返回没有关掉完整简介")
    wait_focus("overview", "关掉完整简介后焦点没回到简介上")

    key("DPAD_DOWN")
    wait_focus("play", "简介往下没有回到主按钮")


def test_long_overview_scrolls():
    """一屏放不下的简介：完整简介页上下键滚动"""
    item = os.environ.get("MC_OVERVIEW_LONG_ITEM")
    if not item:
        pytest.skip("没有超长简介条目（MC_OVERVIEW_LONG_ITEM）")
    open_item(item)
    key("DPAD_UP")
    wait_focus("overview", "主按钮往上没有落到简介上")
    key("DPAD_CENTER")
    wait(lambda root: node("overview-text", root), message="按确认没有打开完整简介")
    time.sleep(0.5)
    before = capture()
    key("DPAD_DOWN")
    time.sleep(0.6)
    shot("androidtv-overview-scrolled")
    assert node("overview-panel") is not None, "下键把焦点带出了完整简介"
    assert capture() != before, "按下键正文没有滚动"
    key("DPAD_UP")
    time.sleep(0.6)
    assert capture() == before, "按上键没有滚回顶部"
    key("BACK")
    wait(lambda root: node("overview-panel", root) is None, message="按返回没有关掉完整简介")


def test_episode_long_press_menu_opens_overview():
    """分集卡下面的简介只有四行：长按分集卡，菜单里选「完整简介」打开这一集的全文，返回回到这张卡"""
    open_item(SHOW)
    episode = None
    for _ in range(4):
        key("DPAD_DOWN")
        current = focused()
        if current and current.startswith("ep:"):
            episode = current
            break
    assert episode, "往下走不到分集横排"

    key("DPAD_CENTER", long=True)
    item = wait(
        lambda root: next((n for n in root.iter("node") if n.get("text") == "完整简介"), None),
        message="长按分集卡的菜单里没有「完整简介」",
    )
    assert item is not None
    shot("androidtv-episode-menu")
    # 「完整简介」排在菜单最后一项
    for _ in range(3):
        key("DPAD_DOWN")
    key("DPAD_CENTER")
    wait(
        lambda root: node("overview-panel", root) is not None,
        message="选「完整简介」没有打开完整简介",
    )
    shot("androidtv-episode-overview")
    key("BACK")
    wait(lambda root: node("overview-panel", root) is None, message="按返回没有关掉完整简介")
    wait_focus(episode, "关掉完整简介后焦点没回到那张分集卡")

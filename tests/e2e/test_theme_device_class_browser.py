"""手机横过来拿，主题仍按「手机」那份取——浏览器端到端。

主题按设备类分开存：``theme_mobile`` 给手机、``theme_desktop`` 给电脑（2026-09-24）。当时的判据
只有页面宽度（< 768 = 手机），于是 iPhone 系统转横屏后宽 844~956、越过断点，被当成电脑，取了
电脑上存的那份（2026-10-21 用户发现：手机上是银玻璃，转横屏变成电脑选的 Netflix）。判据现在是
「宽 < 768，或粗指针且高 ≤ 500」（lib/themes.ts 的 PHONE_THEME_QUERY）。

真后端（uvicorn 子进程）+ 真前端（``pnpm dev``）+ Chrome 按设备形态开页，直接读
``<html data-theme>``（默认主题银玻璃没有这个属性）：

1. 电脑存 Netflix、手机存银玻璃（以及反过来）：手机竖拿 / 横拿（含大屏手机）都取手机那份；
2. 不刷新页面直接转屏（改视口尺寸）：主题不跳，竖 → 横 → 竖始终是手机那份；
3. 电脑形态仍取电脑那份：桌面窗口、iPad 横屏、桌面上被压矮的窗口（细指针）；
   宽度不到 768 的窄窗口仍是手机那份（老规则不变）；
4. 防闪烁脚本与 React 写入同一个判据：刷新后 DOMContentLoaded（React 还没水合）时
   data-theme 就是对的；
5. 设置页在横屏手机上改主题，落的是 ``theme_mobile``，不是 ``theme_desktop``。

标 integration：要 pnpm（apps/web 已 install），CI 不跑。本地：
``pytest -m integration tests/e2e/test_theme_device_class_browser.py``。
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest

playwright = pytest.importorskip("playwright.sync_api")

REPO = Path(__file__).resolve().parents[2]
WEB = REPO / "apps" / "web"
ADMIN = {"username": "admin", "password": "e2e-passw0rd"}
_CHROMIUM_CANDIDATES = (
    os.environ.get("E2E_CHROMIUM"),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/opt/pw-browsers/chromium",
)
PNPM = shutil.which("pnpm")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(PNPM is None, reason="需要 pnpm 启动前端 dev server"),
    pytest.mark.skipif(
        not (WEB / "node_modules").is_dir(), reason="apps/web 未安装依赖（pnpm install）"
    ),
]

#: (名字, 宽, 高, 触屏手机 / 平板). 触屏 = is_mobile + has_touch，Chrome 据此报粗指针、无悬停
PHONE_PORTRAIT = ("iPhone 竖拿", 390, 844, True)
PHONE_LANDSCAPE = ("iPhone 横拿", 844, 390, True)
PHONE_LANDSCAPE_MAX = ("大屏 iPhone 横拿", 932, 430, True)
ANDROID_LANDSCAPE = ("安卓手机横拿", 915, 412, True)
DESKTOP = ("桌面窗口", 1280, 800, False)
IPAD_LANDSCAPE = ("iPad 横拿", 1180, 820, True)
DESKTOP_SHORT = ("被压矮的桌面窗口（细指针）", 1280, 420, False)
DESKTOP_NARROW = ("窄的桌面窗口（宽 < 768）", 700, 900, False)

#: 两种偏好方向都要验：电脑 Netflix / 手机银玻璃，以及反过来
PREFS = [
    pytest.param({"desktop": "netflix", "mobile": "silver"}, id="电脑netflix-手机silver"),
    pytest.param({"desktop": "silver", "mobile": "netflix"}, id="电脑silver-手机netflix"),
]

#: 文档解析阶段挂钩子：DOMContentLoaded 时 <html data-theme> 的值。那一刻 React 还没水合，
#: 读到的就是 layout.tsx 防闪烁脚本写的
_FIRST_PAINT = """() => {
  document.addEventListener('DOMContentLoaded', () => {
    window.__dcl = document.documentElement.getAttribute('data-theme') || 'silver';
  });
}"""


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_http(url: str, timeout: float) -> None:
    deadline = time.time() + timeout
    last: Exception | None = None
    while time.time() < deadline:
        try:
            if httpx.get(url, timeout=3).status_code < 500:
                return
        except Exception as exc:  # noqa: BLE001
            last = exc
        time.sleep(1)
    raise RuntimeError(f"服务未就绪：{url}（{last}）")


def _stop(proc: subprocess.Popen) -> None:
    """收掉子进程。Windows 上 terminate() 只杀 pnpm 这一层，next dev 会留在端口上，要连树杀。"""
    if sys.platform == "win32":
        subprocess.run(  # noqa: S603
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],  # noqa: S607
            capture_output=True,
            check=False,
        )
    else:
        proc.terminate()


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    """拉起后端 + 前端、建好超管；模块结束时收掉子进程。"""
    root = tmp_path_factory.mktemp("theme-device-class-e2e")
    tmdb_log = root / "tmdb-requests.log"
    tmdb_log.touch()
    api_port, web_port = _free_port(), _free_port()
    data = root / "data"
    data.mkdir()
    env = {
        **os.environ,
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(api_port),
        "DATABASE_URL": f"sqlite+aiosqlite:///{(data / 'app.db').as_posix()}",
        "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "E2E_TMDB_LOG": str(tmdb_log),
    }
    api_log = (root / "api.log").open("w")
    api = subprocess.Popen(  # noqa: S603
        [sys.executable, str(Path(__file__).with_name("_api_launcher.py"))],
        env=env,
        stdout=api_log,
        stderr=subprocess.STDOUT,
        cwd=str(root),
    )
    web_log = (root / "web.log").open("w")
    web = subprocess.Popen(  # noqa: S603
        [PNPM, "dev", "-p", str(web_port)],
        env={
            **os.environ,
            "NEXT_DIST_DIR": ".next-e2e",
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
        cwd=str(WEB),
    )
    try:
        base = f"http://127.0.0.1:{web_port}"
        # 冷启动包含完整空库迁移和插件装配；就绪后才开始计浏览器操作的超时。
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 300)
        _wait_http(f"{base}/login", 180)
        yield base
    finally:
        for proc in (web, api):
            _stop(proc)
        for proc in (web, api):
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        api_log.close()
        web_log.close()


def _chromium_kwargs() -> dict:
    for candidate in _CHROMIUM_CANDIDATES:
        if candidate and Path(candidate).exists():
            return {"executable_path": candidate}
    return {}


@pytest.fixture(scope="module")
def browser(stack):
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, **_chromium_kwargs())
        yield browser
        browser.close()


class _Account:
    """一个已登录的超管：用接口存偏好，也给各个页面上下文发会话。"""

    def __init__(self, browser, base: str) -> None:
        self.base = base
        self._seed = browser.new_context()
        self._seed.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        resp = self._seed.request.post(f"{base}/api/v1/auth/login", data=ADMIN)
        assert resp.ok, f"登录失败：{resp.status} {resp.text()}"
        self.state = self._seed.storage_state()

    def save_themes(self, *, desktop: str, mobile: str) -> None:
        resp = self._seed.request.put(
            f"{self.base}/api/v1/ui/preferences",
            data={"theme": "silver", "theme_desktop": desktop, "theme_mobile": mobile},
        )
        assert resp.ok, resp.text()

    def saved_themes(self) -> dict:
        data = self._seed.request.get(f"{self.base}/api/v1/ui/preferences").json()["data"]
        return {"desktop": data["theme_desktop"], "mobile": data["theme_mobile"]}

    def close(self) -> None:
        self._seed.close()


@pytest.fixture
def account(browser, stack):
    acct = _Account(browser, stack)
    yield acct
    acct.close()


def _open(browser, account: _Account, shape: tuple, path: str = "/", *, first_paint: bool = False):
    """按设备形态开一个页面，等外壳渲染、偏好拉回并写上 <html>。"""
    _name, width, height, touch = shape
    context = browser.new_context(
        viewport={"width": width, "height": height},
        is_mobile=touch,
        has_touch=touch,
        device_scale_factor=2 if touch else 1,
        storage_state=account.state,
    )
    if first_paint:
        context.add_init_script(f"({_FIRST_PAINT})()")
    page = context.new_page()
    page.set_default_timeout(60_000)
    with page.expect_response(
        lambda r: r.url.endswith("/api/v1/ui/preferences") and r.request.method == "GET"
    ):
        page.goto(f"{account.base}{path}", wait_until="domcontentloaded")
    page.wait_for_selector(".app-shell")
    time.sleep(0.8)  # 偏好到账后 effect 写 data-theme
    return context, page


def _theme(page) -> str:
    """当前生效的主题 id：默认主题（银玻璃）没有 data-theme 属性。"""
    return page.evaluate("() => document.documentElement.getAttribute('data-theme') || 'silver'")


@pytest.mark.parametrize("prefs", PREFS)
@pytest.mark.parametrize(
    "shape", [PHONE_PORTRAIT, PHONE_LANDSCAPE, PHONE_LANDSCAPE_MAX, ANDROID_LANDSCAPE]
)
def test_phone_takes_the_phone_theme_in_either_orientation(browser, account, prefs, shape) -> None:
    """手机竖拿、横拿都取手机那份。修前横拿宽过 768，拿到的是电脑那份。"""
    account.save_themes(**prefs)
    context, page = _open(browser, account, shape)
    assert _theme(page) == prefs["mobile"], f"{shape[0]}：取到了 {_theme(page)}"
    context.close()


@pytest.mark.parametrize("prefs", PREFS)
def test_rotating_without_reload_does_not_flip_the_theme(browser, account, prefs) -> None:
    """系统转屏不刷新页面：竖 → 横 → 竖，主题始终是手机那份，不闪成电脑的。"""
    account.save_themes(**prefs)
    context, page = _open(browser, account, PHONE_PORTRAIT)
    assert _theme(page) == prefs["mobile"]
    for width, height in ((844, 390), (390, 844), (932, 430)):
        page.set_viewport_size({"width": width, "height": height})
        time.sleep(0.8)
        assert _theme(page) == prefs["mobile"], f"转到 {width}x{height} 后主题跳了"
    context.close()


@pytest.mark.parametrize("prefs", PREFS)
@pytest.mark.parametrize("shape", [DESKTOP, IPAD_LANDSCAPE, DESKTOP_SHORT])
def test_computer_shapes_keep_the_desktop_theme(browser, account, prefs, shape) -> None:
    """回归：桌面、iPad 横拿、被压矮的桌面窗口（细指针）仍取电脑那份。"""
    account.save_themes(**prefs)
    context, page = _open(browser, account, shape)
    assert _theme(page) == prefs["desktop"], f"{shape[0]}：取到了 {_theme(page)}"
    context.close()


@pytest.mark.parametrize("prefs", PREFS)
def test_narrow_desktop_window_is_still_phone_class(browser, account, prefs) -> None:
    """回归：宽度不到 768 的窄窗口按老规则仍是手机那份。"""
    account.save_themes(**prefs)
    context, page = _open(browser, account, DESKTOP_NARROW)
    assert _theme(page) == prefs["mobile"]
    context.close()


@pytest.mark.parametrize("prefs", PREFS)
def test_first_paint_script_uses_the_same_device_class(browser, account, prefs) -> None:
    """刷新后缓存已在：React 水合之前（DOMContentLoaded）防闪烁脚本就写对了主题。"""
    account.save_themes(**prefs)
    context, page = _open(browser, account, PHONE_LANDSCAPE, first_paint=True)  # 写进偏好缓存
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector(".app-shell")
    assert page.evaluate("() => window.__dcl") == prefs["mobile"]
    context.close()


def test_settings_on_a_landscape_phone_write_the_mobile_field(browser, account) -> None:
    """横屏手机上打开设置改主题：脚注说是移动端，落的是 theme_mobile，电脑那份不动。"""
    account.save_themes(desktop="silver", mobile="silver")
    context, page = _open(browser, account, PHONE_LANDSCAPE, "/settings/appearance")
    assert "当前设置的是移动端的主题" in page.get_by_text("当前设置的是").first.inner_text()
    page.get_by_role("button", name="Netflix").first.click()
    page.wait_for_function(
        "() => document.documentElement.getAttribute('data-theme') === 'netflix'"
    )
    assert account.saved_themes() == {"desktop": "silver", "mobile": "netflix"}
    context.close()

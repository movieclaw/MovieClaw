"""详情页选了版本再播剧集，切到下一集不能还带着上一集的文件——浏览器端到端。

详情页版本选择器里明确选过版本再点播放，播放页用 ``?file=`` 锁定该文件起播（服务端 ``file_id``
的优先级高于 ``media_item_id + 季集``，直接放这个文件）。但自动连播 / 点「下一集」只是在播放页里
换 unit、不重新导航，``lockedFileId`` 这个 prop 在整个播放页生命周期里一直都在：不按集收口，
第 2 集的会话请求会带着第 1 集的 ``file_id``，实际又播了一遍第 1 集，界面与进度却按第 2 集走
（评审发现）。

真后端（uvicorn 子进程）+ 真前端（``pnpm dev``）+ 无头 Chrome 真放 ffmpeg 现做的小 mp4
（h264/aac，直出），文件走真扫描入库（假 TMDB 识别）。照用户的操作走：

1. 剧集第 1 集有两个版本；详情页的版本下拉里选**不是默认高亮**的那个，点播放；
2. 播放页地址带 ``?file=<所选>``，第 1 集的会话请求带着同一个 ``file_id``
   （同一集里无论重开几次都锁）；
3. 播到片尾，点下一集卡片的「立即播放」→ 第 2 集的会话请求**不带** ``file_id``，画面照常放起来。

标 integration：要 pnpm（apps/web 已 install）、ffmpeg 与带 H.264 的 Chrome，CI 不跑。本地：
``E2E_CHROMIUM="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
pytest -m integration tests/e2e/test_player_locked_file_next_episode_browser.py``。
"""

from __future__ import annotations

import os
import re
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
#: 每集的片长（秒）：够起播、够拖到片尾，又不拖慢测试
_CLIP_S = 12

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(PNPM is None, reason="需要 pnpm 启动前端 dev server"),
    pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要 ffmpeg 生成测试视频"),
    pytest.mark.skipif(
        not (WEB / "node_modules").is_dir(), reason="apps/web 未安装依赖（pnpm install）"
    ),
]


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
    """拉起后端 + 前端；模块结束时收掉子进程。"""
    root = tmp_path_factory.mktemp("locked-file-e2e")
    media = root / "media"
    media.mkdir()
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
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 90)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 180)
        yield {"base": f"http://127.0.0.1:{web_port}", "media": media}
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
    for cand in _CHROMIUM_CANDIDATES:
        if cand and Path(cand).exists():
            return {"executable_path": cand}
    return {}


def _make_clip(path: Path, width: int, height: int) -> None:
    """低码率的真视频：h264 + aac 的 mp4，浏览器直出；两个版本只差分辨率。"""
    subprocess.run(  # noqa: S603
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate=24:duration={_CLIP_S}",
            "-f", "lavfi", "-i", f"sine=frequency=440:duration={_CLIP_S}",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "24", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "48k", "-movflags", "+faststart",
            str(path),
        ],
        check=True,
    )  # fmt: skip


def _library_root(path: Path) -> str:
    """库根路径必须以 / 开头（API 校验）：Windows 上去掉盘符。"""
    return re.sub(r"^[A-Za-z]:", "", path.as_posix())


def _wait_playing(page, *, past: float = 0.3) -> float:
    """等画面真的走起来（不只是元素挂上），返回当时的播放位置（秒）。"""
    page.wait_for_function(
        "past => { const v = document.querySelector('video');"
        " return v && !v.paused && v.readyState >= 3 && v.currentTime > past }",
        arg=past,
        timeout=60_000,
    )
    return page.evaluate("() => document.querySelector('video').currentTime")


def test_locked_version_does_not_follow_to_the_next_episode(stack) -> None:
    from playwright.sync_api import sync_playwright

    base = stack["base"]
    # 剧名对上假 TMDB 的《测试剧集》(Test Show, 2024)，扫描能识别；第 1 集两个版本、第 2 集一个
    season_dir = stack["media"] / "Test Show (2024)" / "Season 01"
    season_dir.mkdir(parents=True)
    _make_clip(season_dir / "Test Show - S01E01 - 360p.mp4", 640, 360)
    _make_clip(season_dir / "Test Show - S01E01 - 180p.mp4", 320, 180)
    _make_clip(season_dir / "Test Show - S01E02.mp4", 320, 180)

    def api(page, method: str, path: str, **kwargs):
        resp = getattr(page.request, method)(f"{base}/api/v1{path}", **kwargs)
        assert resp.ok, f"{method} {path}: {resp.status} {resp.text()}"
        return resp.json()["data"]

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=["--autoplay-policy=no-user-gesture-required"],
            **_chromium_kwargs(),
        )
        context = browser.new_context(viewport={"width": 1440, "height": 900}, locale="zh-CN")
        page = context.new_page()
        page.set_default_timeout(30_000)
        page.set_default_navigation_timeout(120_000)
        page_errors: list[str] = []
        page.on("pageerror", lambda e: page_errors.append(str(e)))
        # 播放页起会话的请求体：file_id 有没有、带的是哪一集，就看这里
        sessions: list[dict] = []
        page.on(
            "request",
            lambda r: sessions.append(r.post_data_json)
            if r.method == "POST" and r.url.split("?")[0].endswith("/api/v1/playback/sessions")
            else None,
        )

        page.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        resp = page.request.post(f"{base}/api/v1/auth/login", data=ADMIN)
        assert resp.ok, f"登录失败：{resp.status} {resp.text()}"
        library_id = api(
            page,
            "post",
            "/libraries",
            data={"name": "剧集", "kind": "tv", "root_paths": [_library_root(stack["media"])]},
        )["id"]
        # 建库即扫描：等三个文件都入库（识别 + 探测）
        deadline = time.time() + 120
        item_id = None
        while time.time() < deadline:
            items = api(page, "get", f"/libraries/{library_id}/items")
            if items:
                item_id = items[0]["media_item_id"]
                detail = api(page, "get", f"/libraries/{library_id}/items/{item_id}")
                files = [f for f in detail.get("files", []) if f.get("state") == "in_place"]
                if len(files) >= 3:
                    break
            time.sleep(1)
        else:
            raise AssertionError("扫描没把三个测试视频入库")

        # ---- 详情页：第 1 集的版本下拉里，选不是默认高亮的那个，点播放 ----
        # 不等 networkidle：详情页会一直轮询（刮削状态），永远不会空闲
        page.goto(f"{base}/library/{library_id}/item/{item_id}", wait_until="domcontentloaded")
        select = page.get_by_label("选择视频文件")
        select.wait_for()
        default_value = select.input_value()
        values = [o.get_attribute("value") for o in select.locator("option").all()]
        picked = next(v for v in values if v != default_value)
        select.select_option(picked)
        assert select.input_value() == picked, "版本下拉没有停在所选版本上"
        page.get_by_role("button", name=re.compile("^播放")).click()
        page.wait_for_url(re.compile(rf"/play/\d+/s01e01\?file={picked}$"))
        _wait_playing(page)

        first = [s for s in sessions if s.get("episode_number") == 1]
        assert first, f"第 1 集没发起会话：{sessions}"
        assert all(s.get("file_id") == int(picked) for s in first), (
            f"第 1 集应一直锁定所选版本 {picked}：{first}"
        )

        # ---- 播到片尾 → 下一集卡片 → 立即播放 ----
        page.evaluate(
            "s => { document.querySelector('video').currentTime = s }", float(_CLIP_S) - 2.5
        )
        page.locator('[data-testid="upnext-play"]').click(timeout=60_000)
        deadline = time.time() + 60
        while not any(s.get("episode_number") == 2 for s in sessions):
            assert time.time() < deadline, f"切到第 2 集后没有发起会话：{sessions}"
            time.sleep(0.5)

        second = [s for s in sessions if s.get("episode_number") == 2]
        assert all(not s.get("file_id") for s in second), (
            f"第 2 集不能带第 1 集锁定的文件（带了会把第 1 集又播一遍）：{second}"
        )
        # 画面照常放起来
        _wait_playing(page)
        assert page_errors == [], f"页面抛了异常：{page_errors}"
        browser.close()

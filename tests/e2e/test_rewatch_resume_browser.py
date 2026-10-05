"""看完的片子重看到一半、退出重进要接着这次重看的位置——浏览器端到端。

真后端（uvicorn 子进程）+ 真前端（``pnpm dev``）+ 无头 Chrome 真放一段 ffmpeg 现做的
mp4（h264/aac，直出），文件走真扫描入库（假 TMDB 识别、ffprobe 量片长）。整条链路照
用户的操作走：

1. 播放器里拖到片尾附近、等心跳 → 已看完，详情页按钮是「重新播放」；
2. 点「重新播放」从头放，拖到 40%、等心跳上报，然后直接关掉浏览器（强退）；
3. 重新打开（登录态保留）→ 详情页按钮是「继续观看」并写着看到哪；接口侧已看
   标记保留、续播点在，「接下来继续」里有它、「在看」筛选能筛到；
4. 点「继续观看」→ 播放器从这次重看的位置接着放，而不是从头。

标 integration：要 pnpm（apps/web 已 install）、ffmpeg 与带 H.264 的 Chrome，CI 不跑。
本地：``E2E_CHROMIUM="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
pytest -m integration tests/e2e/test_rewatch_resume_browser.py``。
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
#: 片长要过 300 秒：更短的算短片，过了开头就直接判看完，没有续播点
_DURATION_S = 400
#: 重看拖到的位置（40%）
_REWATCH_AT_S = 160

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("pnpm") is None, reason="需要 pnpm 启动前端 dev server"),
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
    import urllib.request

    deadline = time.time() + timeout
    last: Exception | None = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:  # noqa: S310
                if resp.status < 500:
                    return
        except Exception as exc:  # noqa: BLE001
            last = exc
        time.sleep(1)
    raise RuntimeError(f"服务未就绪：{url}（{last}）")


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    """拉起后端 + 前端；模块结束时收掉子进程。"""
    root = tmp_path_factory.mktemp("rewatch-e2e")
    media = root / "media"
    media.mkdir()
    tmdb_log = root / "tmdb-requests.log"
    tmdb_log.touch()
    api_port, web_port = _free_port(), _free_port()
    data = root / "data"
    data.mkdir()
    database_url = f"sqlite+aiosqlite:///{data / 'app.db'}"
    env = {
        **os.environ,
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(api_port),
        "DATABASE_URL": database_url,
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
        cwd=str(REPO),
    )
    web_log = (root / "web.log").open("w")
    web = subprocess.Popen(  # noqa: S603
        ["pnpm", "dev", "-p", str(web_port)],
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
        yield {
            "base": f"http://127.0.0.1:{web_port}",
            "media": media,
            "shots": root / "shots",
            "state": root / "storage-state.json",
        }
    finally:
        for proc in (web, api):
            proc.terminate()
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


def _make_movie(path: Path) -> None:
    """低码率的真视频：h264 + aac 的 mp4，浏览器直出，两秒一个关键帧好拖动。"""
    subprocess.run(  # noqa: S603
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", f"testsrc2=size=320x180:rate=24:duration={_DURATION_S}",
            "-f", "lavfi", "-i", f"sine=frequency=440:duration={_DURATION_S}",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "48", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "48k", "-movflags", "+faststart",
            str(path),
        ],
        check=True,
    )  # fmt: skip


def _login(page, base: str) -> None:
    """走登录页背后的同一对接口建超管、登录；会话 Cookie 落进浏览器上下文。

    登录表单本身不是这里要测的（登录页先是欢迎屏，表单要多点一步）。
    """
    page.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
    resp = page.request.post(f"{base}/api/v1/auth/login", data=ADMIN)
    assert resp.ok, f"登录失败：{resp.status} {resp.text()}"


def _video_time(page) -> float:
    return page.evaluate("() => document.querySelector('video')?.currentTime ?? -1")


def _wait_playing(page, *, past: float = 0.5) -> float:
    """等画面真的走起来（不只是元素挂上），返回当时的播放位置（秒）。"""
    page.wait_for_function(
        "past => { const v = document.querySelector('video');"
        " return v && !v.paused && v.readyState >= 3 && v.currentTime > past }",
        arg=past,
        timeout=60_000,
    )
    return _video_time(page)


def _seek(page, seconds: float) -> None:
    page.evaluate("s => { document.querySelector('video').currentTime = s }", seconds)
    _wait_playing(page, past=seconds)


def test_rewatch_resumes_where_the_rewatch_stopped(stack) -> None:  # noqa: PLR0915
    from playwright.sync_api import expect, sync_playwright

    base = stack["base"]
    shots: Path = stack["shots"]
    shots.mkdir(exist_ok=True)
    # 片名年份对上假 TMDB 的《某电影》(2020)，扫描能识别
    _make_movie(stack["media"] / "某电影 (2020).mp4")

    def api(page, method: str, path: str, **kwargs) -> dict:
        resp = getattr(page.request, method)(f"{base}/api/v1{path}", **kwargs)
        assert resp.ok, f"{method} {path}: {resp.status} {resp.text()}"
        return resp.json()["data"]

    def wait_state(page, item_id: int, check, timeout: float = 30) -> dict:
        """等心跳把状态写进服务端（心跳 10 秒一跳）。"""
        deadline = time.time() + timeout
        while True:
            state = api(page, "get", "/playback/resume", params={"media_item_id": item_id})
            if check(state) or time.time() > deadline:
                return state
            time.sleep(1)

    launch = {
        "headless": True,
        "args": ["--autoplay-policy=no-user-gesture-required"],
        **_chromium_kwargs(),
    }
    with sync_playwright() as p:
        # ---- 第一次打开：登录、建库、落一部真能放的电影 ----
        browser = p.chromium.launch(**launch)
        context = browser.new_context(viewport={"width": 1440, "height": 900}, locale="zh-CN")
        page = context.new_page()
        page.set_default_timeout(30_000)
        page.set_default_navigation_timeout(120_000)
        page_errors: list[str] = []
        page.on("pageerror", lambda e: page_errors.append(str(e)))
        _login(page, base)
        library_id = api(
            page,
            "post",
            "/libraries",
            data={"name": "电影", "kind": "movie", "root_paths": [str(stack["media"])]},
        )["id"]
        # 建库即扫描：等它入库（识别 + 探测片长）
        deadline = time.time() + 90
        while not (items := api(page, "get", f"/libraries/{library_id}/items")):
            assert time.time() < deadline, "扫描没把测试视频入库"
            time.sleep(1)
        item_id = items[0]["media_item_id"]
        detail_url = f"{base}/library/{library_id}/item/{item_id}"

        # ---- 先看完一遍：拖到片尾附近、等心跳 → 已看完 ----
        page.goto(detail_url)
        page.wait_for_load_state("networkidle")
        page.screenshot(path=str(shots / "00-detail-unwatched.png"))
        page.get_by_role("button", name=re.compile("^播放")).click()
        page.wait_for_url(re.compile(r"/play/"))
        _wait_playing(page)
        _seek(page, _DURATION_S - 20)
        state = wait_state(page, item_id, lambda s: s["played"])
        assert state["played"] is True and state["position_ms"] == 0, state

        page.goto(detail_url)
        expect(page.get_by_role("button", name=re.compile("^重新播放"))).to_be_visible()
        page.screenshot(path=str(shots / "01-finished-replay.png"))

        # ---- 重看：从头放，拖到 40%，等心跳上报后直接关掉浏览器（强退） ----
        page.get_by_role("button", name=re.compile("^重新播放")).click()
        page.wait_for_url(re.compile(r"/play/"))
        assert _wait_playing(page) < 10, "看完的片子重播从头开始"
        _seek(page, _REWATCH_AT_S)
        state = wait_state(page, item_id, lambda s: s["position_ms"] >= _REWATCH_AT_S * 1000)
        assert state["played"] is True, "重看不把已看标记悄悄改掉"
        assert state["position_ms"] >= _REWATCH_AT_S * 1000, state
        context.storage_state(path=str(stack["state"]))
        assert page_errors == [], page_errors
        browser.close()

        # ---- 重新打开（登录态保留）：接口侧的事实 ----
        browser = p.chromium.launch(**launch)
        context = browser.new_context(
            viewport={"width": 1440, "height": 900},
            locale="zh-CN",
            storage_state=str(stack["state"]),
        )
        page = context.new_page()
        page.set_default_timeout(30_000)
        page.set_default_navigation_timeout(120_000)
        page.on("pageerror", lambda e: page_errors.append(str(e)))
        state = api(page, "get", "/playback/resume", params={"media_item_id": item_id})
        resume_s = state["position_ms"] / 1000
        assert state["played"] is True
        assert _REWATCH_AT_S <= resume_s < _DURATION_S * 0.9, state
        up_next = api(page, "get", "/playback/up-next")["items"]
        assert [i["media_item_id"] for i in up_next] == [item_id], "接下来继续里要有它"
        watching = api(page, "get", f"/libraries/{library_id}/items", params={"watch": "watching"})
        assert [i["media_item_id"] for i in watching] == [item_id], "在看筛选能筛到"

        # ---- 详情页：「继续观看」，写着看到哪 ----
        page.goto(detail_url)
        clock = f"{int(resume_s // 60)}:{int(resume_s % 60):02d}"  # 不足一小时分钟不补零
        play = page.get_by_role("button", name=re.compile("^继续观看"))
        expect(play).to_be_visible()
        expect(page.get_by_text(f"看到 {clock}")).to_be_visible()
        page.screenshot(path=str(shots / "02-rewatch-continue.png"))

        # ---- 点「继续观看」：接着这次重看的位置放，不是从头 ----
        play.click()
        page.wait_for_url(re.compile(r"/play/"))
        started = _wait_playing(page)
        assert abs(started - resume_s) < 5, f"起播 {started:.1f}s，续播点 {resume_s:.1f}s"
        page.screenshot(path=str(shots / "03-player-resumed.png"))
        assert page_errors == [], page_errors
        browser.close()

"""原盘（BDMV）的 PGS 由网页前端渲染、不转码：真后端 + 真前端 + Chrome + 真 ffmpeg + 真 BDMV 目录。

默认选中的图形字幕走旁挂：服务端按主播放列表把轨抽成 ``.sup``，前端 libbitsub 画在 canvas 上。
原盘的 ``file_path`` 是目录，这条路曾经走不通（字幕接口 404，网页上静默没字幕）。这里验证的是
用户看到的结果：字幕在**播放列表时间**对的那一刻出现在画面上——剪辑的 IN/OUT 之外的字幕不算、
第二段的字幕接在第一段后面——而且视频全程没有转码。

替身只有一处：PATH 里包的 ffmpeg 可以把抽字幕拖慢（夹具的盘只有几 MB，真盘要读几分钟），用来
验证抽取耗时超过代理与浏览器的等待上限时，播放不受影响、字幕读完自己出现。

标 integration：要 ffmpeg（含 libx264）、pnpm（apps/web 已 install）与 Chrome。
"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest
from tests.e2e.test_media_share_browser import (
    ADMIN,
    REPO,
    WEB,
    _chromium_kwargs,
    _free_port,
    _play_current_video,
    _wait_for,
    _wait_http,
)
from tests.playback.disc_fixture import Clip, make_bdmv, sup_presentations

pytest.importorskip("playwright.sync_api")
Image = pytest.importorskip("PIL.Image")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要系统 ffmpeg"),
    pytest.mark.skipif(shutil.which("pnpm") is None, reason="需要 pnpm 启动前端 dev server"),
    pytest.mark.skipif(
        not (WEB / "node_modules").is_dir(), reason="apps/web 未安装依赖（pnpm install）"
    ),
]

#: 画面里字幕矩形的位置（视频像素）：左右两块都避开正中的播放按钮和上下的控制条
LEFT = {"x": 60, "y": 150, "w": 120, "h": 60}
RIGHT = {"x": 460, "y": 150, "w": 120, "h": 60}
#: 多剪辑盘第一段的时长：第二段的字幕要落在它后面
FIRST_CLIP_S = 20

MULTI_CLIP = [
    Clip("00001", FIRST_CLIP_S, 100.0, [[{"start_s": 3, "end_s": 8, **LEFT}]]),
    # 第二段只用中间 20 秒（IN=5、OUT=25）：片头片尾的字幕属于别的播放列表，不该出现
    Clip(
        "00002",
        30,
        500.0,
        [
            [
                {"start_s": 2, "end_s": 3, **LEFT},
                {"start_s": 12, "end_s": 18, **RIGHT},
                {"start_s": 27, "end_s": 29, **LEFT},
            ]
        ],
        in_s=5,
        out_s=25,
    ),
]
#: 播放列表时间：第一段字幕 3～8，第二段字幕 (12-5)+20 = 27～33
MULTI_CLIP_SHOWN = [3, 8, 27, 33]

#: 单剪辑、播放列表只用它的一截（IN=4）：字幕在剪辑里是 10～16 秒，播放列表时间 6～12
SINGLE_CLIP = [Clip("00007", 30, 300.0, [[{"start_s": 10, "end_s": 16, **LEFT}]], in_s=4, out_s=28)]
SINGLE_CLIP_SHOWN = [6, 12]

#: 读得慢的盘：抽字幕要 35 秒，比前面这层反代（next dev 30 秒掐断）等得久
SLOW_CLIP = [Clip("00003", 30, 700.0, [[{"start_s": 20, "end_s": 26, **RIGHT}]])]
SLOW_READ_S = 35

#: 抽字幕时可拖慢：控制文件里写秒数。每次抽取记一行，用来数通读了几遍（其余命令原样转给真 ffmpeg）
_SLOW_FFMPEG = """#!/bin/sh
case "$*" in
  *.sup*)
    echo read >> "$MC_SUP_READ_LOG"
    [ -s "$MC_SUP_DELAY_FILE" ] && sleep "$(cat "$MC_SUP_DELAY_FILE")"
    ;;
esac
exec "{real}" "$@"
"""


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("disc-pgs-e2e")
    movie_root = root / "media" / "movies"
    make_bdmv(movie_root / "某电影 (2020)", MULTI_CLIP, languages=["zho"])
    make_bdmv(movie_root / "单剪辑原盘 (2020)", SINGLE_CLIP, languages=["zho"])
    make_bdmv(movie_root / "读得慢的原盘 (2020)", SLOW_CLIP, languages=["zho"])

    real_ffmpeg = shutil.which("ffmpeg")
    assert real_ffmpeg
    fake_bin = root / "bin"
    fake_bin.mkdir()
    wrapper = fake_bin / "ffmpeg"
    wrapper.write_text(_SLOW_FFMPEG.format(real=real_ffmpeg))
    wrapper.chmod(0o755)
    delay_file = root / "sup-delay"
    delay_file.touch()
    read_log = root / "sup-reads.log"
    read_log.touch()
    tmdb_log = root / "tmdb-requests.log"
    tmdb_log.touch()

    api_port, web_port = _free_port(), _free_port()
    data = root / "data"
    data.mkdir()
    env = {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
        "PYTHONPATH": f"{REPO / 'src'}{os.pathsep}{os.environ.get('PYTHONPATH', '')}",
        "MC_SUP_DELAY_FILE": str(delay_file),
        "MC_SUP_READ_LOG": str(read_log),
        "MOVIECLAW_PLAYBACK_SUBS_CACHE_DIR": str(data / "subs"),
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(api_port),
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'app.db'}",
        "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "E2E_TMDB_LOG": str(tmdb_log),
    }
    api_log_path = root / "api.log"
    api_log = api_log_path.open("w")
    api = subprocess.Popen(  # noqa: S603
        [sys.executable, str(Path(__file__).with_name("_disc_pgs_api_launcher.py"))],
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
            "movie_root": movie_root,
            "delay_file": delay_file,
            "read_log": read_log,
            "shots": Path(os.environ.get("MC_SHOT_DIR", root / "shots")),
            "api_log": api_log_path,
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


def _session(p, stack):
    base = stack["base"]
    browser = p.chromium.launch(headless=True, **_chromium_kwargs())
    context = browser.new_context(viewport={"width": 1280, "height": 800}, locale="zh-CN")
    api = context.request
    api.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)  # 第二个用例时已建过，忽略结果
    login = api.post(f"{base}/api/v1/auth/login", data=ADMIN)
    assert login.ok, login.text()
    libraries = api.get(f"{base}/api/v1/libraries").json()["data"]
    if isinstance(libraries, dict):
        libraries = libraries.get("items", [])
    library_id = next((lib["id"] for lib in libraries if lib["name"] == "电影"), None)
    if library_id is None:
        created = api.post(
            f"{base}/api/v1/libraries",
            data={"name": "电影", "kind": "movie", "root_paths": [str(stack["movie_root"])]},
        )
        assert created.ok, created.text()
        library_id = created.json()["data"]["id"]
    return browser, context, library_id


def _item_id(context, base: str, library_id: int, title: str) -> int:
    def scanned():
        rows = context.request.get(f"{base}/api/v1/libraries/{library_id}/items").json()["data"]
        if isinstance(rows, dict):
            rows = rows.get("items", [])
        return next((row for row in rows if title in row["title"]), None)

    return _wait_for(scanned, timeout=180, what=f"《{title}》扫描入库")["media_item_id"]


class _Watch:
    """记下这一页的决策与字幕请求（同步版 Playwright 只在调用它的接口时派发事件）。"""

    def __init__(self, page) -> None:
        self.decisions: list[dict] = []
        self.subtitle_status: list[int] = []
        self.subtitle_url: str | None = None
        self.console: list[str] = []
        page.on("response", self._on_response)
        page.on("console", lambda msg: self.console.append(msg.text))

    def _on_response(self, response) -> None:
        if response.request.method == "POST" and response.url.endswith("/api/v1/playback/sessions"):
            self.decisions.append(response.json()["data"])
        elif "/subtitles?" in response.url:
            self.subtitle_status.append(response.status)
            self.subtitle_url = response.url


def _wait_in_page(page, fn, *, timeout_s: float, what: str) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if fn():
            return
        page.wait_for_timeout(250)
    raise AssertionError(f"等待超时（{timeout_s} 秒）：{what}")


def _lit(page, rect: dict[str, int]) -> bool:
    """字幕矩形此刻在不在画面上：截图，看矩形中心一块的亮度（纯黑片子上只有字幕是亮的）。"""
    box = page.evaluate(
        """() => {
          const v = document.querySelector('video');
          const r = v.getBoundingClientRect();
          const scale = Math.min(r.width / v.videoWidth, r.height / v.videoHeight);
          return {
            left: r.left + (r.width - v.videoWidth * scale) / 2,
            top: r.top + (r.height - v.videoHeight * scale) / 2,
            scale,
          };
        }"""
    )
    image = Image.open(io.BytesIO(page.screenshot())).convert("L")
    cx = box["left"] + (rect["x"] + rect["w"] / 2) * box["scale"]
    cy = box["top"] + (rect["y"] + rect["h"] / 2) * box["scale"]
    half = min(rect["w"], rect["h"]) / 4 * box["scale"]
    crop = image.crop((int(cx - half), int(cy - half), int(cx + half), int(cy + half)))
    pixels = list(crop.getdata())
    return sum(pixels) / len(pixels) > 200


def _seek(page, seconds: float) -> None:
    """暂停在这个时间点、等画面到位（播放列表时间：VOD 下 currentTime 就是它）。"""
    page.evaluate(
        """(t) => new Promise((resolve) => {
          const v = document.querySelector('video');
          v.pause();
          v.addEventListener('seeked', resolve, { once: true });
          v.currentTime = t;
        })""",
        seconds,
    )
    # 字幕在下一帧才画上：等一小会儿，别和 canvas 抢
    page.wait_for_timeout(800)


def _shoot(page, stack, name: str) -> None:
    shots: Path = stack["shots"]
    shots.mkdir(parents=True, exist_ok=True)
    page.screenshot(path=str(shots / f"{name}.png"))


def _assert_timeline(page, stack, name: str, checkpoints) -> None:
    for seconds, expect_left, expect_right in checkpoints:
        _seek(page, seconds)
        _shoot(page, stack, f"{name}-{seconds}s")
        left, right = _lit(page, LEFT), _lit(page, RIGHT)
        assert (left, right) == (expect_left, expect_right), (
            f"{name}：播放到 {seconds} 秒时字幕（左、右）应为 "
            f"{(expect_left, expect_right)}，实际 {(left, right)}"
        )


def _assert_sup(context, url: str, expected: list[int]) -> None:
    body = context.request.get(url).body()
    # 时间轴与视频同一份 concat 输入：起点比 IN 早一点的音频包（夹具约 20 毫秒）会让两边一起后移
    assert sup_presentations(body) == pytest.approx(expected, abs=0.05)


def _assert_no_transcode(watch: _Watch) -> None:
    assert watch.decisions, "没有等到开播决策"
    decision = watch.decisions[-1]["decision"]
    assert decision["video"]["action"] == "copy", decision
    assert decision["video"].get("burn_subtitle") is None, decision


def test_multi_clip_disc_renders_pgs_on_the_playlist_timeline(stack) -> None:
    """多剪辑：第二段的字幕接在第一段后面，IN/OUT 之外的字幕不出现，视频不转码。"""
    from playwright.sync_api import sync_playwright

    base = stack["base"]
    with sync_playwright() as p:
        browser, context, library_id = _session(p, stack)
        try:
            item = _item_id(context, base, library_id, "某电影")
            page = context.new_page()
            watch = _Watch(page)
            page.goto(f"{base}/play/{item}")
            _play_current_video(page)
            _wait_in_page(
                page, lambda: 200 in watch.subtitle_status, timeout_s=60, what="字幕 .sup 下发"
            )
            _assert_no_transcode(watch)
            _assert_sup(context, watch.subtitle_url, MULTI_CLIP_SHOWN)
            page.wait_for_timeout(1000)  # libbitsub 解析、建 canvas
            _assert_timeline(
                page,
                stack,
                "multi",
                [
                    (5.5, True, False),  # 第一段的字幕
                    (11, False, False),
                    (22.5, False, False),  # 第二段 IN 之前那条（剪辑 2～3 秒），不属于主片
                    (24, False, False),  # 不看 IN 的话第二段字幕在 32～38，这里也不该有
                    (30, False, True),  # 第二段的字幕：播放列表 27～33
                    (37, False, False),
                ],
            )
        finally:
            browser.close()


def test_single_clip_disc_uses_playlist_time_not_clip_time(stack) -> None:
    """单剪辑也走同一条路：播放列表只用剪辑一截时，字幕按播放列表时间、不按剪辑时间。"""
    from playwright.sync_api import sync_playwright

    base = stack["base"]
    with sync_playwright() as p:
        browser, context, library_id = _session(p, stack)
        try:
            item = _item_id(context, base, library_id, "单剪辑原盘")
            page = context.new_page()
            watch = _Watch(page)
            page.goto(f"{base}/play/{item}")
            _play_current_video(page)
            _wait_in_page(
                page, lambda: 200 in watch.subtitle_status, timeout_s=60, what="字幕 .sup 下发"
            )
            _assert_no_transcode(watch)
            _assert_sup(context, watch.subtitle_url, SINGLE_CLIP_SHOWN)
            page.wait_for_timeout(1000)
            _assert_timeline(
                page,
                stack,
                "single",
                [
                    (3, False, False),
                    (9, True, False),
                    (14, False, False),  # 按剪辑时间算字幕在 10～16，这里就会错
                ],
            )
        finally:
            browser.close()


def test_a_read_longer_than_the_request_can_wait_still_ends_in_subtitles(stack) -> None:
    """真盘要读几分钟，请求等不到头（这里是 next dev 的反代 30 秒掐断，现场还有 Safari、群晖）。

    视频照常放；播放器接着等，服务端还是那一趟读取，读完字幕自己出现，不用用户做任何事。
    """
    from playwright.sync_api import sync_playwright

    base = stack["base"]
    reads: Path = stack["read_log"]
    before = reads.read_text().count("read")
    stack["delay_file"].write_text(str(SLOW_READ_S))
    with sync_playwright() as p:
        browser, context, library_id = _session(p, stack)
        try:
            item = _item_id(context, base, library_id, "读得慢的原盘")
            page = context.new_page()
            watch = _Watch(page)
            page.goto(f"{base}/play/{item}")
            _play_current_video(page)
            assert 200 not in watch.subtitle_status, "夹具没拖慢：这个用例什么也没测到"
            _wait_in_page(
                page,
                lambda: 200 in watch.subtitle_status,
                timeout_s=SLOW_READ_S + 45,
                what="读完之后字幕下发",
            )
            assert reads.read_text().count("read") - before == 1, (
                "请求断了一次就从头再读：真盘上这样永远读不完"
            )
            _assert_no_transcode(watch)
            page.wait_for_timeout(1000)
            # 片长 30 秒，读完时已经放到头了：拖回字幕那一段
            _assert_timeline(page, stack, "slow", [(23, False, True), (28, False, False)])
        finally:
            stack["delay_file"].write_text("")
            browser.close()

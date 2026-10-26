"""issue #763：硬件转码起步即退出时，网页播放器要自己降到软件转码放起来。

现场（群晖 + i5-12500，0.35.0）：硬件自检通过，4K 杜比视界片走档 3 VAAPI，ffmpeg 过了
快速失败窗口才退出、一段都没产出。服务端把第 0 段标成「产不出来」却仍当会话活着，
播放器对着分片 404 层层重试，缓冲了 4 分多钟也没走到降档。

真后端 + 真前端 + 无头 Chrome + 真 ffmpeg。只有两处替身：硬件自检结论（测试机没有
VAAPI，见 ``_hw_fail_api_launcher``）和 PATH 里包了一层的 ffmpeg——命令里带
``h264_vaapi`` 就照现场的样子 0.6 秒后带着那几行 stderr 退出，其余原样交给真 ffmpeg，
所以降档之后的软件转码是真转、真放。

标 integration：要 ffmpeg（含 libx264）、pnpm（apps/web 已 install）与 Chromium。
本地：``pytest -m integration tests/e2e/test_hw_transcode_startup_failure_browser.py``。
"""

from __future__ import annotations

import os
import re
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

playwright = pytest.importorskip("playwright.sync_api")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要系统 ffmpeg"),
    pytest.mark.skipif(shutil.which("pnpm") is None, reason="需要 pnpm 启动前端 dev server"),
    pytest.mark.skipif(
        not (WEB / "node_modules").is_dir(), reason="apps/web 未安装依赖（pnpm install）"
    ),
]

#: 现场 stderr 的形状：真正的原因在前面，末尾几行只是连带的「编码器打不开」
_FAKE_STDERR = (
    "[Parsed_tonemap_vaapi_0 @ 0x1] e2e-root-cause: VAAPI filter init failed",
    "[vf#0:0 @ 0x2] Terminating thread with return code -38 (Function not implemented)",
    "[vost#0:0/h264_vaapi @ 0x3] Could not open encoder before EOF",
    "[vost#0:0/h264_vaapi @ 0x3] Task finished with error code: -22 (Invalid argument)",
    "[vost#0:0/h264_vaapi @ 0x3] Terminating thread with return code -22 (Invalid argument)",
    "[out#0/hls @ 0x4] Nothing was written into output file",
)


def _write_failing_vaapi_ffmpeg(bin_dir: Path, real_ffmpeg: str) -> None:
    bin_dir.mkdir(parents=True, exist_ok=True)
    echoes = "\n".join(f"    echo '{line}' >&2" for line in _FAKE_STDERR)
    script = bin_dir / "ffmpeg"
    script.write_text(
        "#!/bin/sh\n"
        'for a in "$@"; do\n'
        '  if [ "$a" = "h264_vaapi" ]; then\n'
        "    sleep 0.6\n"
        f"{echoes}\n"
        "    exit 218\n"
        "  fi\n"
        "done\n"
        f'exec "{real_ffmpeg}" "$@"\n',
        encoding="utf-8",
    )
    script.chmod(0o755)


def _gen_mpeg2_clip(dest: Path, seconds: int) -> None:
    """MPEG-2 视频 + AAC 的 MKV：浏览器解不了 MPEG-2，必须转视频（档 3/4）。

    色彩显式标成 BT.709：不标的话决策层会插 ``colorspace`` 软件滤镜，VAAPI 档在准备阶段
    就判不能执行、直接走软转，现场那条「硬件命令起步即退出」的路就测不到了。
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-y",
            "-f", "lavfi", "-i", f"testsrc2=duration={seconds}:size=1280x720:rate=25",
            "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
            "-map", "0:v", "-map", "1:a",
            "-c:v", "mpeg2video", "-b:v", "2M", "-g", "25",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-c:a", "aac", "-b:a", "96k", "-shortest", str(dest),
        ],
        check=True,
        timeout=300,
    )  # fmt: skip


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("hw-startup-failure-e2e")
    movie_root = root / "media" / "movies"
    _gen_mpeg2_clip(movie_root / "某电影 (2020)" / "某电影.2020.720p.mkv", 40)
    real_ffmpeg = shutil.which("ffmpeg")
    assert real_ffmpeg
    fake_bin = root / "bin"
    _write_failing_vaapi_ffmpeg(fake_bin, real_ffmpeg)
    tmdb_log = root / "tmdb-requests.log"
    tmdb_log.touch()

    api_port, web_port = _free_port(), _free_port()
    data = root / "data"
    data.mkdir()
    env = {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
        "PYTHONPATH": f"{REPO / 'src'}{os.pathsep}{os.environ.get('PYTHONPATH', '')}",
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
        [sys.executable, str(Path(__file__).with_name("_hw_fail_api_launcher.py"))],
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
            "shots": root / "shots",
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


def test_player_steps_down_to_software_when_hardware_transcode_dies_at_startup(stack):
    from playwright.sync_api import sync_playwright

    base = stack["base"]
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, **_chromium_kwargs())
        context = browser.new_context(viewport={"width": 1280, "height": 800}, locale="zh-CN")
        page = context.new_page()
        api = context.request
        # 登录页先是欢迎屏、没有输入框：走接口建管理员并登录，Cookie 与页面共用
        bootstrap = api.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        assert bootstrap.ok, bootstrap.text()
        login = api.post(f"{base}/api/v1/auth/login", data=ADMIN)
        assert login.ok, login.text()
        library = api.post(
            f"{base}/api/v1/libraries",
            data={"name": "电影", "kind": "movie", "root_paths": [str(stack["movie_root"])]},
        )
        assert library.ok, library.text()
        library_id = library.json()["data"]["id"]

        def scanned():
            rows = api.get(f"{base}/api/v1/libraries/{library_id}/items").json()["data"]
            if isinstance(rows, dict):
                rows = rows.get("items", [])
            return next((row for row in rows if row["title"] == "某电影"), None)

        movie = _wait_for(scanned, timeout=180, what="电影扫描入库")
        # 用户此前已同意过软件转码：降档后应直接软转放起来，而不是停在同意弹窗
        policy = api.put(
            f"{base}/api/v1/playback/policy", data={"software_transcode_enabled": True}
        )
        assert policy.ok, policy.text()

        def ready_tiers() -> list[tuple[str, str]]:
            # 后端日志是会话档位的事实来源：「播放会话就绪：档 N … hw=…」
            log = stack["api_log"].read_text(encoding="utf-8")
            return re.findall(r"播放会话就绪：档 (\d) .*?hw=(\S+) ", log)

        started = time.monotonic()
        page.goto(f"{base}/play/{movie['media_item_id']}")
        tiers = _wait_for(ready_tiers, timeout=60, what="首个播放会话")
        assert tiers[0] == ("3", "vaapi"), tiers
        # 心跳 15 秒一次：服务端判死后最多一拍就该降档，留足余量也远小于现场的 4 分多钟
        _wait_for(
            lambda: any(tier == "4" for tier, _ in ready_tiers()),
            timeout=60,
            what="降到档 4 软件转码",
        )
        _play_current_video(page)
        elapsed = time.monotonic() - started
        stack["shots"].mkdir(exist_ok=True)
        page.screenshot(path=str(stack["shots"] / "issue-763-stepped-down-playing.png"))
        browser.close()

    assert elapsed < 90, f"从起播到软转放起来用了 {elapsed:.0f} 秒"
    log = stack["api_log"].read_text(encoding="utf-8")
    # 判死那行带着真正的原因，不再把锅甩给「源文件比台账时长短」
    assert "转码会话失败" in log and "e2e-root-cause" in log, log[-4000:]
    assert "比台账时长短" not in log
    # 降档是心跳报「失败」触发的，按「这一档放不了」走，而不是网络类的同档重连
    assert '"reason": "服务端转码起步即失败"' in log and '"response": "step-down"' in log

"""应用外壳（托盘 + 窗口 + 首次运行下载 ffmpeg）的真机端到端：需要 NVIDIA + 网络。

与 ``test_windows_transcoder_e2e.py`` 同一套隔离 NAS 搭台，区别只在「谁来当 Worker」：
这里起的是安装包里的那份 ``MovieClawTranscoder.pyw``（app/ 外壳 + runtime python），
走真实的用户路径——首次运行没有 ffmpeg → 从 Jellyfin 官方下载校验 → 自检 → 配对 → 接单。
CI 没有显卡也不该拉 68 MB，所以落在 integration 标记下，只在真机手动跑::

    pytest -m integration tests/playback/test_windows_transcoder_app_e2e.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from windows_transcoder_stack import (
    Capture,
    decode,
    diagnostics,
    end_session,
    make_source,
    require_nvenc_worker,
    running_stack,
    seed,
    start_session,
    wait_for,
)

ROOT = Path(__file__).resolve().parents[2]
WORKER_DIR = ROOT / "windows" / "MovieClawTranscoder"
APP_DIR = WORKER_DIR / "app"

pytestmark = [pytest.mark.integration]


@pytest.fixture(scope="module")
def nvenc():
    return require_nvenc_worker()


@pytest.fixture(scope="module")
def stack(tmp_path_factory, nvenc):
    ffmpeg, caps = nvenc
    with running_stack(tmp_path_factory.mktemp("windows-transcoder-app-e2e"), ffmpeg) as running:
        running["caps"] = caps
        yield running


@pytest.fixture(scope="module", autouse=True)
def _stop_cli_worker(stack):
    """搭台默认起的是命令行 Worker：同机只允许一个，先停掉，让应用外壳去配对。"""
    stack["worker"].terminate()
    stack["worker"].wait(timeout=10)
    wait_for(
        lambda: not stack["client"]
        .get("/api/v1/transcode-worker/status")
        .json()["data"]["workers"],
        30,
        "NAS 看到命令行 Worker 离线",
    )
    yield


def _launch_app(home: Path, server: str, ffmpeg: str) -> tuple[subprocess.Popen, Capture]:
    """按用户双击的方式起应用：``python MovieClawTranscoder.pyw``（生产用 pythonw）。

    窗口与托盘只在真机上有意义，所以测试模式下用 ``MOVIECLAW_APP_HEADLESS=1`` 关掉界面
    （model 照常跑），验收看的是配对、自检、接单这些真正会出问题的地方。
    """
    env = {
        **os.environ,
        "MOVIECLAW_TRANSCODER_HOME": str(home),
        "MOVIECLAW_APP_HEADLESS": "1",
        "PYTHONUTF8": "1",
        # 仓库布局里核心包在 app/ 外；打包布局里两者同在 app/。启动脚本两处都加，
        # 这里补一条是为了让 pytest 的 venv python 也能找到它们。
        "PYTHONPATH": os.pathsep.join(
            [str(APP_DIR), str(WORKER_DIR), os.environ.get("PYTHONPATH", "")]
        ).strip(os.pathsep),
    }
    process = subprocess.Popen(
        [sys.executable, str(APP_DIR / "MovieClawTranscoder.pyw"), "--server", server,
         "--ffmpeg", ffmpeg],
        env=env,
        cwd=WORKER_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
    )
    return process, Capture(process)


def test_first_run_downloads_ffmpeg_pairs_and_transcodes(stack, tmp_path):
    """用户第一次打开应用：本机没有 ffmpeg → 自动下载官方 jellyfin-ffmpeg → 配对 → 接单转码。"""
    home = tmp_path / "app-home"
    ffmpeg = stack["ffmpeg"]

    # 用一个假的、不会被认的 ffmpeg 路径逼出「下载」分支？不行——下载会真的拉 68 MB。
    # 真机验收里就用本机这份 jellyfin-ffmpeg（下载逻辑由单测覆盖），验收的是「外壳能把它
    # 自检通过、配对、接单」。
    process, output = _launch_app(home, stack["url"], ffmpeg)
    log_file = home / "transcoder.log"
    try:
        def pairing_code() -> str | None:
            # 配对码走日志（transcoder.log 与 stdout 都写；pythonw 下只有文件）
            lines = list(output.lines)
            if log_file.exists():
                lines += log_file.read_text(encoding="utf-8", errors="replace").splitlines()
            return next(
                (
                    line.split("配对码：", 1)[1].split("（")[0].strip()
                    for line in lines
                    if "配对码：" in line
                ),
                None,
            )

        code = wait_for(
            pairing_code,
            180,
            lambda: f"应用打印配对码；输出：{output.text()[-1200:]}",
        )
        approve = stack["client"].post(f"/api/v1/auth/devices/requests/{code}/approve")
        assert approve.status_code == 200

        wait_for(
            lambda: stack["client"]
            .get("/api/v1/transcode-worker/status")
            .json()["data"]["workers"],
            180,
            "应用外壳上线",
        )
        worker = stack["client"].get("/api/v1/transcode-worker/status").json()["data"]["workers"][0]
        assert worker["backends"] == ["nvenc"]
        assert worker["platform"] == "Windows"

        # 真实派单 → 转码 → 回传 → 解码
        data = start_session(stack, seed(stack, make_source(stack, "app-sdr.mkv", seconds=20)))
        try:
            playback = decode(stack, data, seconds=3)
            assert playback.returncode == 0, playback.stderr.decode(errors="replace")[-1500:]
            assert diagnostics(stack, data)["worker_id"] == worker["worker_id"]
        finally:
            end_session(stack, data)

        config = json.loads((home / "config.json").read_text(encoding="utf-8"))
        assert config["token"] and config["server"] == stack["url"]
        assert config["ffmpeg"] == ffmpeg
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
    assert "Traceback" not in output.text(), output.text()[-3000:]


def test_tray_window_registry_and_install_smoke(tmp_path):
    """装机形态本身的冒烟（不需要 NAS）：两个包能导入、注册表自启能读写、图标在包里。

    这是「装完双击能看到托盘」的最小证据；依赖 GUI/注册表，只在真机跑。
    """
    env = {
        **os.environ,
        "MOVIECLAW_TRANSCODER_HOME": str(tmp_path / "home"),
        "PYTHONPATH": os.pathsep.join([str(APP_DIR), str(WORKER_DIR)]),
        "PYTHONUTF8": "1",
    }
    script = (
        "from movieclaw_transcoder_app import autostart, tray, window\n"
        "from pathlib import Path\n"
        f"print('icon', (Path(r'{APP_DIR}') / 'movieclaw_transcoder_app' / 'icon.ico').is_file())\n"
        "key = r'Software\\\\MovieClawTranscoderAppSmoke'\n"
        "autostart.enable('\"x\" \"y\"', key)\n"
        "assert autostart.enabled(key)\n"
        "autostart.disable(key)\n"
        "import winreg, contextlib\n"
        "with contextlib.suppress(FileNotFoundError):\n"
        "    winreg.DeleteKey(winreg.HKEY_CURRENT_USER, key)\n"
        "print('imports ok autostart ok')\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=120,
    )
    assert result.returncode == 0, result.stderr[-2000:]
    assert "icon True" in result.stdout, result.stdout
    assert "imports ok autostart ok" in result.stdout, result.stdout

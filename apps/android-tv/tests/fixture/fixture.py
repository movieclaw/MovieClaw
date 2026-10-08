"""Android TV 端到端验收用的隔离测试服务器（docs/design/androidtv-app.md §7）。

全新数据库 + 生成的测试片，不碰本机 data 库、不连 TMDB；后端跑当前工作区的代码。

  .venv/bin/python apps/android-tv/tests/fixture/fixture.py start   # 生成测试片、起服务、建库扫描
  .venv/bin/python apps/android-tv/tests/fixture/fixture.py stop
  .venv/bin/python apps/android-tv/tests/fixture/fixture.py status

默认目录 /tmp/mc-atv-fixture、端口 8810（环境变量 MC_ATV_FIXTURE / MC_ATV_PORT 可改）。
模拟器里访问宿主机用 http://10.0.2.2:<端口>。账号 admin / mclaw-atv-2026。
"""

from __future__ import annotations

import contextlib
import http.cookiejar
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
FIX = Path(os.environ.get("MC_ATV_FIXTURE", "/tmp/mc-atv-fixture"))
PORT = int(os.environ.get("MC_ATV_PORT", "8810"))
BASE = f"http://127.0.0.1:{PORT}/api/v1"
ADMIN = {"username": "admin", "password": "mclaw-atv-2026"}
DATA = FIX / "data"
CLIPS = FIX / "media/clips"
PID = FIX / "server.pid"
LOG = FIX / "server.log"

#: 测试片：文件名 → ffmpeg 参数（输入之后的部分）。各覆盖一种起播路径。
SRT_ZH = (
    "1\n00:00:01,000 --> 00:00:05,000\n第一句中文字幕\n\n"
    "2\n00:00:06,000 --> 00:00:10,000\n第二句中文字幕\n"
)
SRT_EN = (
    "1\n00:00:01,000 --> 00:00:05,000\nFirst English line\n\n"
    "2\n00:00:06,000 --> 00:00:10,000\nSecond English line\n"
)


def _video(size: str, rate: int) -> list[str]:
    return ["-f", "lavfi", "-i", f"testsrc2=size={size}:rate={rate}:duration=60"]


def _tone(layout: str = "stereo", duration: int = 60) -> list[str]:
    return [
        "-f", "lavfi",
        "-i", f"sine=frequency=440:duration={duration},aformat=channel_layouts={layout}",
    ]  # fmt: skip


def make_media() -> None:
    CLIPS.mkdir(parents=True, exist_ok=True)
    (FIX / "zh.srt").write_text(SRT_ZH, encoding="utf-8")
    (FIX / "en.srt").write_text(SRT_EN, encoding="utf-8")
    jobs = {
        "测试片 H264.mp4": [
            *_video("1280x720", 30), *_tone(),
            "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "1500k", "-c:a", "aac", "-shortest",
        ],
        "测试片 HEVC 5.1.mkv": [
            *_video("1920x1080", 24), *_tone("5.1"), *_tone(),
            "-i", str(FIX / "zh.srt"), "-i", str(FIX / "en.srt"),
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3", "-map", "4",
            # 固定 2 秒一个关键帧、闭合 GOP，服务端 HLS 分片切得细，拖动与续播更好验
            "-c:v", "libx265", "-preset", "ultrafast", "-b:v", "2000k", "-tag:v", "hvc1",
            "-x265-params", "keyint=48:min-keyint=48:open-gop=0:scenecut=0",
            "-c:a:0", "ac3", "-c:a:1", "aac", "-c:s", "srt",
            "-metadata:s:a:0", "language=chi", "-metadata:s:a:0", "title=国语 5.1",
            "-metadata:s:a:1", "language=eng", "-metadata:s:a:1", "title=English 2.0",
            "-metadata:s:s:0", "language=chi", "-metadata:s:s:0", "title=简体中文",
            "-metadata:s:s:1", "language=eng", "-metadata:s:s:1", "title=English",
            # 不用 -shortest：字幕流 10 秒就结束，会把整个文件截到 10 秒
            "-disposition:a:0", "default", "-disposition:s:0", "default", "-t", "60",
        ],
        "测试片 MPEG2.ts": [
            *_video("1920x1080", 25), *_tone(),
            "-c:v", "mpeg2video", "-b:v", "4000k", "-c:a", "ac3", "-shortest",
        ],
        # 服务端不给 5 分钟以内的短片记续播点（progress.MIN_RESUME_DURATION_MS），
        # 续播要用长一点的片子
        "测试片 续播 6 分钟.mp4": [
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=360", *_tone(duration=360),
            "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "400k", "-c:a", "aac", "-t", "360",
        ],
        "测试片 VP9.webm": [
            *_video("1280x720", 30), *_tone(),
            "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "1000k",
            "-c:a", "libopus", "-shortest",
        ],
    }  # fmt: skip
    for name, args in jobs.items():
        out = CLIPS / name
        if out.exists():
            continue
        print(f"生成 {name} ……", flush=True)
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args, str(out)], check=True
        )
        # 刚写完的文件会被扫描判成「疑似写入中」暂缓入账，把 mtime 拨回一小时前
        old = time.time() - 3600
        os.utime(out, (old, old))


def server_env() -> dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "PYTHONPATH": str(ROOT / "src"),
            "APP_ENV": "local",
            "SCHEDULER_ENABLED": "false",
            "MOVIECLAW_DATA_DIR": str(DATA),
            "DATABASE_URL": f"sqlite+aiosqlite:///{DATA}/movieclaw.db",
            "SECRET_KEY_FILE": str(DATA / ".secret_key"),
            "METADATA_DIR": str(DATA / "metadata"),
            "MOVIECLAW_TRANSCODE_DIR": str(DATA / "transcodes"),
            "MOVIECLAW_UPDATES_DIR": str(DATA / "updates"),
            "MOVIECLAW_WEB_PORT_FILE": str(DATA / "config/web-port"),
            # 扫描入口无论库类型都要一个 TMDB 客户端；给假 Key、指向本机不存在的端口，保证不连外网
            "TMDB_API_KEY": "0000000000000000000000000000fake",
            "TMDB_API_BASE_URL": "http://127.0.0.1:9/3",
        }
    )
    caches = {
        "MOVIECLAW_PLAYBACK_CUES_CACHE_DIR": "playback_cues",
        "MOVIECLAW_PLAYBACK_SUBS_CACHE_DIR": "playback-subs",
        "MOVIECLAW_TRICKPLAY_CACHE_DIR": "playback-trickplay",
        "MOVIECLAW_REELS_CACHE_DIR": "reels",
        "MOVIECLAW_SUBTITLE_GEN_CACHE_DIR": "subtitle_gen",
        "MOVIECLAW_AUDIO_FINGERPRINT_DIR": "audio-fingerprints",
    }
    env.update({key: str(DATA / "cache" / name) for key, name in caches.items()})
    return env


class Client:
    def __init__(self) -> None:
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def call(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(BASE + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        with self.opener.open(req, timeout=30) as resp:
            payload = json.loads(resp.read() or b"null")
        return payload.get("data") if isinstance(payload, dict) and "data" in payload else payload


def healthy() -> bool:
    try:
        with urllib.request.urlopen(BASE + "/health", timeout=2) as resp:
            return json.loads(resp.read()).get("status") == "ok"
    except (OSError, ValueError):
        return False


def start() -> int:
    if healthy():
        print(f"已在运行：{BASE}")
        return 0
    make_media()
    DATA.mkdir(parents=True, exist_ok=True)
    log = LOG.open("a", encoding="utf-8")
    log.write(f"===== {time.strftime('%F %T')} start =====\n")
    proc = subprocess.Popen(
        [
            sys.executable, "-m", "uvicorn", "movieclaw_api.app:create_app", "--factory",
            "--host", "0.0.0.0", "--port", str(PORT),
        ],
        env=server_env(), stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
    )  # fmt: skip
    PID.write_text(str(proc.pid))
    for _ in range(120):
        if healthy():
            break
        if proc.poll() is not None:
            print(f"后端启动失败，见 {LOG}")
            return 1
        time.sleep(0.5)
    else:
        print(f"后端 60 秒内没起来，见 {LOG}")
        return 1
    seed()
    print(
        f"就绪：{BASE}（模拟器里用 http://10.0.2.2:{PORT}），"
        f"账号 {ADMIN['username']} / {ADMIN['password']}"
    )
    return 0


def seed() -> None:
    client = Client()
    if not client.call("GET", "/auth/bootstrap")["initialized"]:
        client.call("POST", "/auth/bootstrap", ADMIN)
    else:
        client.call("POST", "/auth/login", ADMIN)
    libraries = client.call("GET", "/libraries?scope=all")
    library = next((lib for lib in libraries if lib["name"] == "测试片"), None)
    if library is None:
        library = client.call(
            "POST", "/libraries", {"name": "测试片", "kind": "video", "root_paths": [str(CLIPS)]}
        )
    expected = len(list(CLIPS.iterdir()))
    for _ in range(120):
        items = client.call("GET", f"/libraries/{library['id']}/items")
        if len(items) >= expected:
            print(f"媒体库「测试片」(id={library['id']}) 已入库 {len(items)} 条：")
            for item in items:
                print(f"  media_item_id={item['media_item_id']}  {item['title']}")
            return
        time.sleep(1)
    raise SystemExit("扫描超时：测试片没有全部入库")


def stop() -> int:
    if not PID.exists():
        print("没有在运行")
        return 0
    pid = int(PID.read_text())
    with contextlib.suppress(ProcessLookupError):
        os.killpg(pid, signal.SIGTERM)
    # 等它真正退出：优雅关闭期间 /health 还会应答，紧接着 start 会误以为它还在跑
    for _ in range(60):
        if not healthy():
            break
        time.sleep(0.5)
    PID.unlink()
    print(f"已停止（pid {pid}）")
    return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "start":
        return start()
    if cmd == "stop":
        return stop()
    print(f"{'运行中' if healthy() else '未运行'}：{BASE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

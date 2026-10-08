"""TV 客户端端到端验收用的隔离测试服务器（docs/design/androidtv-app.md §7）。

全新数据库 + 生成的测试片 + 假 TMDB（tmdb_mock.py），不碰本机 data 库、不连外网；
后端跑当前工作区的代码。Android TV 模拟器与 Apple TV 模拟器连同一台，走查对比用。

  .venv/bin/python apps/android-tv/tests/fixture/fixture.py start   # 生成片子、起服务、建库、灌数据
  .venv/bin/python apps/android-tv/tests/fixture/fixture.py stop
  .venv/bin/python apps/android-tv/tests/fixture/fixture.py status

默认目录 /tmp/mc-atv-fixture，后端 8810、假 TMDB 8811（MC_ATV_FIXTURE / MC_ATV_PORT 可改）。
Android 模拟器里访问宿主机用 http://10.0.2.2:8810，Apple TV 模拟器用 http://127.0.0.1:8810。

内容：
- 电影库：编码矩阵（H.264 MP4、HEVC + AC3 5.1 + 双字幕 MKV、MPEG-2 TS、VP9 WebM）+ 一批 6 分钟的片；
- 剧集库：雾港疑云（3 集，带片头片尾标记）、月光侦探社（两季）、长街灯火、隔壁的外星人；
- 其他库：两段本地视频；
- 账号 admin、xiaoyu（成员），密码都是 mclaw-atv-2026；admin 有续播记录、看到一半的剧、收藏。
"""

from __future__ import annotations

import contextlib
import http.cookiejar
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
FIX = Path(os.environ.get("MC_ATV_FIXTURE", "/tmp/mc-atv-fixture"))
PORT = int(os.environ.get("MC_ATV_PORT", "8810"))
TMDB_PORT = PORT + 1
BASE = f"http://127.0.0.1:{PORT}/api/v1"
PASSWORD = "mclaw-atv-2026"
ADMIN = {"username": "admin", "password": PASSWORD}
MEMBER = {"username": "xiaoyu", "password": PASSWORD, "nickname": "小雨"}
DATA = FIX / "data"
MEDIA = FIX / "media"
CLIPS = FIX / "clips"
PIDS = {"server": FIX / "server.pid", "tmdb": FIX / "tmdb.pid"}
CATALOG = json.loads((HERE / "tmdb_catalog.json").read_text(encoding="utf-8"))

SRT_ZH = (
    "1\n00:00:01,000 --> 00:00:05,000\n第一句中文字幕\n\n"
    "2\n00:00:06,000 --> 00:00:10,000\n第二句中文字幕\n"
)
SRT_EN = (
    "1\n00:00:01,000 --> 00:00:05,000\nFirst English line\n\n"
    "2\n00:00:06,000 --> 00:00:10,000\nSecond English line\n"
)


def _video(size: str, rate: int, duration: int) -> list[str]:
    return ["-f", "lavfi", "-i", f"testsrc2=size={size}:rate={rate}:duration={duration}"]


def _tone(duration: int, layout: str = "stereo", freq: int = 440) -> list[str]:
    return [
        "-f", "lavfi",
        "-i", f"sine=frequency={freq}:duration={duration},aformat=channel_layouts={layout}",
    ]  # fmt: skip


#: 母片：文件名 → ffmpeg 参数。各片在媒体库里用硬链接复用，生成一次就够
MASTERS: dict[str, list[str]] = {
    "h264.mp4": [
        *_video("1280x720", 30, 60), *_tone(60),
        "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "1500k", "-c:a", "aac", "-t", "60",
    ],
    "hevc51.mkv": [
        *_video("1920x1080", 24, 60), *_tone(60, "5.1"), *_tone(60, freq=660),
        "-i", "{zh}", "-i", "{en}",
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
    "mpeg2.ts": [
        *_video("1920x1080", 25, 60), *_tone(60),
        "-c:v", "mpeg2video", "-b:v", "4000k", "-c:a", "ac3", "-t", "60",
    ],
    "vp9.webm": [
        *_video("1280x720", 30, 60), *_tone(60),
        "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "1000k",
        "-c:a", "libopus", "-t", "60",
    ],
    # 6 分钟：服务端不给 5 分钟以内的短片记续播点（progress.MIN_RESUME_DURATION_MS）。
    # 双音轨（都是 AAC，模拟器能解）+ 双字幕，验证本机切轨与字幕菜单
    "long.mkv": [
        *_video("640x360", 25, 360), *_tone(360), *_tone(360, freq=660),
        "-i", "{zh}", "-i", "{en}",
        "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3", "-map", "4",
        "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "400k", "-g", "50",
        "-c:a", "aac", "-c:s", "srt",
        "-metadata:s:a:0", "language=chi", "-metadata:s:a:0", "title=国语",
        "-metadata:s:a:1", "language=eng", "-metadata:s:a:1", "title=English",
        "-metadata:s:s:0", "language=chi", "-metadata:s:s:0", "title=简体中文",
        "-metadata:s:s:1", "language=eng", "-metadata:s:s:1", "title=English",
        "-disposition:a:0", "default", "-t", "360",
    ],
}  # fmt: skip

#: 电影：TMDB id → 母片。编码矩阵四部各用一种片源，其余用 6 分钟的片
MOVIES = {
    99000001: "h264.mp4",
    99000002: "hevc51.mkv",
    99000003: "mpeg2.ts",
    99100011: "vp9.webm",
    **{
        mid: "long.mkv"
        for mid in (
            99100001, 99100002, 99100003, 99100005, 99100006, 99100008,
            99100010, 99100013, 99100015, 99100016, 99100021, 99100024,
        )
    },
}  # fmt: skip
#: 剧集：TMDB id → 要放进库的季
SERIES = {99000101: [1], 99200004: [1, 2], 99200001: [1], 99200003: [1]}
#: 「雾港疑云」每集的片头片尾（毫秒）：直接写进识别台账，合成片做不出整季音频指纹
SEGMENTED_SERIES = 99000101
SEGMENTS = [
    {"type": "intro", "start_ms": 0, "end_ms": 30_000, "support": 3, "to_end": False},
    {"type": "outro", "start_ms": 330_000, "end_ms": 360_000, "support": 3, "to_end": True},
]


def make_media() -> None:
    CLIPS.mkdir(parents=True, exist_ok=True)
    subs = {"zh": FIX / "zh.srt", "en": FIX / "en.srt"}
    subs["zh"].write_text(SRT_ZH, encoding="utf-8")
    subs["en"].write_text(SRT_EN, encoding="utf-8")
    for name, args in MASTERS.items():
        out = CLIPS / name
        if out.exists():
            continue
        print(f"生成母片 {name} ……", flush=True)
        args = [a.format(**{k: str(v) for k, v in subs.items()}) for a in args]
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args, str(out)], check=True
        )

    def place(master: str, target: Path) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            os.link(CLIPS / master, target)
        # 刚写的文件会被扫描判成「疑似写入中」暂缓入账，把 mtime 拨回一小时前
        old = time.time() - 3600
        os.utime(target, (old, old))

    for mid, master in MOVIES.items():
        movie = CATALOG[f"movie/{mid}"]
        name = f"{movie['title']} ({movie['release_date'][:4]})"
        ext = master.rsplit(".", 1)[1]
        place(master, MEDIA / "movies" / f"{name} [tmdbid={mid}]" / f"{name}.{ext}")
    for tid, seasons in SERIES.items():
        show = CATALOG[f"tv/{tid}"]
        folder = MEDIA / "tv" / f"{show['name']} ({show['first_air_date'][:4]}) [tmdbid={tid}]"
        for season in seasons:
            for ep in CATALOG[f"tv/{tid}/season/{season}"]["episodes"]:
                n = ep["episode_number"]
                name = f"{show['name']} S{season:02d}E{n:02d}.mkv"
                place("long.mkv", folder / f"Season {season:02d}" / name)
    place("h264.mp4", MEDIA / "docs" / "极地纪行.mp4")
    place("vp9.webm", MEDIA / "docs" / "深海之光.webm")


def server_env() -> dict[str, str]:
    env = dict(os.environ)
    caches = {
        "MOVIECLAW_PLAYBACK_CUES_CACHE_DIR": "playback_cues",
        "MOVIECLAW_PLAYBACK_SUBS_CACHE_DIR": "playback-subs",
        "MOVIECLAW_TRICKPLAY_CACHE_DIR": "playback-trickplay",
        "MOVIECLAW_REELS_CACHE_DIR": "reels",
        "MOVIECLAW_SUBTITLE_GEN_CACHE_DIR": "subtitle_gen",
        "MOVIECLAW_AUDIO_FINGERPRINT_DIR": "audio-fingerprints",
    }
    env.update({key: str(DATA / "cache" / name) for key, name in caches.items()})
    proxy = f"http://127.0.0.1:{TMDB_PORT}"
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
            "TMDB_API_KEY": "0000000000000000000000000000fake",
            "TMDB_API_BASE_URL": f"http://127.0.0.1:{TMDB_PORT}/3",
            "TMDB_IMAGE_BASE_URL": "http://image.tmdb.org/t/p",
            # 一切外网请求都交给假 TMDB：取图落到它那里，其余 404，测试服务器碰不到真网络
            "HTTP_PROXY": proxy,
            "HTTPS_PROXY": proxy,
            "http_proxy": proxy,
            "https_proxy": proxy,
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
    )
    return env


class Client:
    def __init__(self) -> None:
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        )

    def call(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(BASE + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        try:
            with self.opener.open(req, timeout=60) as resp:
                payload = json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as e:
            raise SystemExit(f"{method} {path} → {e.code} {e.read()[:300]!r}") from e
        return payload.get("data") if isinstance(payload, dict) and "data" in payload else payload


def healthy(url: str = BASE + "/health") -> bool:
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=2) as resp:
            return json.loads(resp.read()).get("status") == "ok"
    except (OSError, ValueError):
        return False


def _spawn(name: str, argv: list[str], env: dict[str, str] | None = None) -> subprocess.Popen:
    log = (FIX / f"{name}.log").open("a", encoding="utf-8")
    log.write(f"===== {time.strftime('%F %T')} start =====\n")
    log.flush()
    proc = subprocess.Popen(
        argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
    )
    PIDS[name].write_text(str(proc.pid))
    return proc


def _wait(url: str, proc: subprocess.Popen, name: str) -> None:
    for _ in range(120):
        if healthy(url):
            return
        if proc.poll() is not None:
            raise SystemExit(f"{name} 启动失败，见 {FIX / (name + '.log')}")
        time.sleep(0.5)
    raise SystemExit(f"{name} 60 秒内没起来，见 {FIX / (name + '.log')}")


def start() -> int:
    if healthy():
        print(f"已在运行：{BASE}")
        return 0
    FIX.mkdir(parents=True, exist_ok=True)
    make_media()
    DATA.mkdir(parents=True, exist_ok=True)
    tmdb = _spawn("tmdb", [sys.executable, str(HERE / "tmdb_mock.py"), "--port", str(TMDB_PORT)])
    _wait(f"http://127.0.0.1:{TMDB_PORT}/health", tmdb, "tmdb")
    server = _spawn(
        "server",
        [
            sys.executable, "-m", "uvicorn", "movieclaw_api.app:create_app", "--factory",
            "--host", "0.0.0.0", "--port", str(PORT),
        ],
        env=server_env(),
    )  # fmt: skip
    _wait(BASE + "/health", server, "server")
    seed()
    print(
        f"就绪：{BASE}（Android 模拟器用 http://10.0.2.2:{PORT}，Apple TV 模拟器用 127.0.0.1），"
        f"账号 admin / xiaoyu，密码 {PASSWORD}"
    )
    return 0


def _wait_items(client: Client, library_id: int, expected: int, label: str) -> list[dict]:
    items: list[dict] = []
    for _ in range(240):
        items = client.call("GET", f"/libraries/{library_id}/items")
        if len(items) >= expected:
            return items
        time.sleep(1)
    raise SystemExit(f"扫描超时：{label}只入库 {len(items)} / {expected}")


def seed() -> None:
    admin = Client()
    if admin.call("GET", "/auth/bootstrap")["initialized"]:
        admin.call("POST", "/auth/login", ADMIN)
    else:
        admin.call("POST", "/auth/bootstrap", ADMIN)
    existing = {lib["name"]: lib for lib in admin.call("GET", "/libraries?scope=all")}
    specs = [
        ("电影", "movie", MEDIA / "movies", len(MOVIES)),
        ("剧集", "tv", MEDIA / "tv", len(SERIES)),
        ("纪录片", "video", MEDIA / "docs", 2),
    ]
    items: dict[str, list[dict]] = {}
    for name, kind, root, expected in specs:
        library = existing.get(name) or admin.call(
            "POST", "/libraries", {"name": name, "kind": kind, "root_paths": [str(root)]}
        )
        items[name] = _wait_items(admin, library["id"], expected, f"「{name}」")
        print(f"媒体库「{name}」(id={library['id']}) 入库 {len(items[name])} 条")
    by_tmdb = {i["tmdb_id"]: i for i in items["电影"] + items["剧集"] if i.get("tmdb_id")}

    members = admin.call("GET", "/members")
    if not any(m.get("username") == MEMBER["username"] for m in members):
        admin.call("POST", "/members", MEMBER)

    _write_segments()

    # admin 的观看记录：一部看到一半的电影、一部剧看完第 1 集看到第 2 集中间、两部收藏
    device = "fixture-seed-0001"
    long_movie = by_tmdb[99100001]["media_item_id"]
    fog = by_tmdb[SEGMENTED_SERIES]["media_item_id"]
    moon = by_tmdb[99200004]["media_item_id"]
    for body in (
        {"media_item_id": long_movie, "event": "stop", "position_ms": 151_000},
        {"media_item_id": fog, "season_number": 1, "episode_number": 1, "event": "stop"},
        {"media_item_id": fog, "season_number": 1, "episode_number": 2, "event": "stop",
         "position_ms": 95_000},
        {"media_item_id": moon, "season_number": 1, "episode_number": 3, "event": "stop",
         "position_ms": 200_000},
    ):  # fmt: skip
        admin.call("POST", "/playback/progress", {"device_id": device, **body})
    for tmdb_id in (99100005, 99200001):
        admin.call(
            "POST",
            "/playback/marks",
            {"media_item_id": by_tmdb[tmdb_id]["media_item_id"], "favorite": True},
        )
    print("已灌入观看记录：续播 1 部电影、2 部在追的剧、2 个收藏")


def _write_segments() -> None:
    """片头片尾识别靠整季音频指纹，合成片做不出来：直接写进识别台账（算法版本对齐，不会被重算）。"""
    sys.path.insert(0, str(ROOT / "src"))
    from movieclaw_playback.skip_segments import ALGO_VERSION

    show = CATALOG[f"tv/{SEGMENTED_SERIES}"]["name"]
    now = datetime.now(UTC).replace(tzinfo=None).isoformat(sep=" ")
    db = sqlite3.connect(DATA / "movieclaw.db")
    with db:
        rows = db.execute(
            "SELECT id, size_bytes FROM library_file WHERE file_path LIKE ?", (f"%/{show} S01E%",)
        ).fetchall()
        for file_id, size in rows:
            db.execute(
                "INSERT OR REPLACE INTO media_segment (created_at, updated_at, library_file_id, "
                "fingerprint_status, source_size, fingerprinted_at, algo_version, analyzed_at, "
                "segments) VALUES (?, ?, ?, 'ok', ?, ?, ?, ?, ?)",
                (now, now, file_id, size, now, ALGO_VERSION, now, json.dumps(SEGMENTS)),
            )
    db.close()
    print(f"「{show}」{len(rows)} 集写入片头片尾标记")


def stop() -> int:
    for name in ("server", "tmdb"):
        path = PIDS[name]
        if not path.exists():
            continue
        pid = int(path.read_text())
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pid, signal.SIGTERM)
        path.unlink()
        print(f"已停止 {name}（pid {pid}）")
    # 等它真正退出：优雅关闭期间 /health 还会应答，紧接着 start 会误以为它还在跑
    for _ in range(60):
        if not healthy():
            break
        time.sleep(0.5)
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

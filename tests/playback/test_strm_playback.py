"""网盘（strm）条目的服务端读直链（docs/design/strm-playback.md）。

本地起一个仿网盘的 HTTP 服务：``/d/<名字>`` 302 到带签名的 ``/cdn/<名字>``（alist 一类
的直链形态），``/cdn`` 只认 Range。真 ffmpeg / ffprobe 的用例标 ``integration``。
"""

from __future__ import annotations

import contextlib
import re
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from movieclaw_api.services import media_extract
from movieclaw_api.services.media_probe import probe_media
from movieclaw_api.services.playback import strm_probe
from movieclaw_api.services.playback.session import TranscodeSession, TranscodeSessionManager
from movieclaw_api.services.playback.strm_probe import ensure_strm_spec, strm_container
from movieclaw_db.engine import get_database
from movieclaw_db.models import FileSource, FileState, LibraryFile
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_playback.decide import AudioPlan, PlaybackPlan, PlaybackTier, VideoPlan
from movieclaw_playback.keyframes import read_keyframe_index
from movieclaw_playback.remote_range import RemoteRangeFile
from movieclaw_playback.streaming import STRM_PROTOCOL_WHITELIST, media_input, strm_input_args

needs_ffmpeg = pytest.mark.skipif(
    shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
    reason="需要系统 ffmpeg/ffprobe",
)


class _CloudDrive:
    """仿网盘：记下每个请求的路径与 Range，供断言「只读了索引，没拉整片」。"""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.requests: list[tuple[str, str | None]] = []
        self.served_bytes = 0
        drive = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                drive.requests.append((self.path, self.headers.get("Range")))
                path, _, _ = self.path.partition("?")
                if path.startswith("/d/"):
                    self.send_response(302)
                    self.send_header("Location", f"/cdn/{path[3:]}?sign=fresh")
                    self.end_headers()
                    return
                target = drive.root / path.removeprefix("/cdn/")
                if not path.startswith("/cdn/") or not target.is_file():
                    self.send_error(404)
                    return
                size = target.stat().st_size
                match = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
                if path.endswith(".norange") or match is None:
                    self.send_response(200)
                    self.send_header("Content-Length", str(size))
                    self.end_headers()
                    if path.endswith(".norange"):
                        return
                    body = target.read_bytes()
                else:
                    start = int(match.group(1))
                    end = min(int(match.group(2)) if match.group(2) else size - 1, size - 1)
                    with target.open("rb") as f:
                        f.seek(start)
                        body = f.read(end - start + 1)
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Accept-Ranges", "bytes")
                    self.end_headers()
                drive.served_bytes += len(body)
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def url(self, name: str) -> str:
        return f"http://127.0.0.1:{self.server.server_port}/d/{name}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def drive(tmp_path):
    root = tmp_path / "cloud"
    root.mkdir()
    server = _CloudDrive(root)
    yield server
    server.close()


@pytest.fixture(scope="module")
def sample_mkv(tmp_path_factory) -> Path:
    """30 秒、2 秒一个关键帧的 H.264 + AAC + SRT 字幕 MKV。"""
    root = tmp_path_factory.mktemp("strm-corpus")
    srt = root / "zh.srt"
    srt.write_text("1\n00:00:01,000 --> 00:00:03,000\n你好\n", encoding="utf-8")
    path = root / "sample.mkv"
    proc = subprocess.run(
        [
            "ffmpeg", "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=30",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=30",
            "-i", str(srt),
            "-map", "0", "-map", "1", "-map", "2",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "50", "-keyint_min", "50",
            "-sc_threshold", "0", "-c:a", "aac", "-c:s", "srt", "-y", str(path),
        ],  # fmt: skip
        capture_output=True,
        timeout=120,
    )
    if proc.returncode != 0:
        pytest.skip("ffmpeg 生成样本失败：" + proc.stderr.decode(errors="replace")[-300:])
    return path


@pytest.fixture(scope="module")
def sample_mp4_and_ts(sample_mkv) -> tuple[Path, Path]:
    """同一份码流换成 MP4（moov 在前）与 MPEG-TS。"""
    mp4 = sample_mkv.with_suffix(".mp4")
    ts = sample_mkv.with_suffix(".ts")
    for out, extra in ((mp4, ["-movflags", "+faststart"]), (ts, [])):
        proc = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(sample_mkv), "-map", "0:v", "-map", "0:a",
             "-c", "copy", *extra, "-y", str(out)],  # fmt: skip
            capture_output=True,
            timeout=60,
        )
        if proc.returncode != 0:
            pytest.skip("ffmpeg 转封装失败：" + proc.stderr.decode(errors="replace")[-300:])
    return mp4, ts


def _strm(tmp_path: Path, url: str, name: str = "movie.strm") -> Path:
    path = tmp_path / name
    path.write_text(f"# 网盘直链\n{url}\n", encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# 输入装配（不起 ffmpeg）
# ---------------------------------------------------------------------------


def test_media_input_reads_strm_url_with_network_only_options(tmp_path):
    strm = _strm(tmp_path, "https://pan.example.com/d/a.mkv?sign=1")
    url, options = media_input(str(strm))
    assert url == "https://pan.example.com/d/a.mkv?sign=1"
    assert options[:2] == ["-protocol_whitelist", STRM_PROTOCOL_WHITELIST]
    assert "file" not in STRM_PROTOCOL_WHITELIST.split(",")
    assert "-reconnect" in options
    local = tmp_path / "a.mkv"
    assert media_input(str(local)) == (str(local), [])
    bad = tmp_path / "bad.strm"
    bad.write_text("file:///etc/passwd\n")
    assert media_input(str(bad)) is None


def test_rtsp_strm_gets_no_http_only_options():
    assert strm_input_args("rtsp://cam.local/live") == [
        "-protocol_whitelist",
        STRM_PROTOCOL_WHITELIST,
    ]


def test_local_transcode_command_reads_the_strm_url(tmp_path):
    """会话的源仍是 strm 文件（缓存指纹按它算），喂给 ffmpeg 的是现读出的直链。"""
    strm = _strm(tmp_path, "https://pan.example.com/d/a.mkv?sign=1")
    plan = PlaybackPlan(
        tier=PlaybackTier.REMUX,
        file_id=1,
        container="hls-fmp4",
        video=VideoPlan(action="copy", codec="h264"),
        audio=AudioPlan(action="copy", track_ref="embedded:0"),
    )
    session = TranscodeSession(
        id="s1", file_id=1, member_id=0, tier=PlaybackTier.REMUX,
        directory=tmp_path / "s1", start_ms=0, plan=plan, source_path=str(strm),
    )  # fmt: skip
    argv = TranscodeSessionManager(tmp_path / "cache")._local_command(session, start_number=0).argv
    i = argv.index("-i")
    assert argv[i + 1] == "https://pan.example.com/d/a.mkv?sign=1"
    assert argv[argv.index("-protocol_whitelist") + 1] == STRM_PROTOCOL_WHITELIST
    assert argv.index("-protocol_whitelist") < i
    assert argv.index("-reconnect") < i

    strm.write_text("not a url\n")
    with pytest.raises(Exception, match="网盘直链无效"):
        TranscodeSessionManager(tmp_path / "cache")._local_command(session, start_number=0)


def test_subtitle_extraction_reads_the_strm_url(tmp_path):
    strm = _strm(tmp_path, "https://pan.example.com/d/a.mkv")
    argv = media_extract._ffmpeg_input(strm)
    assert argv[-2:] == ["-i", "https://pan.example.com/d/a.mkv"]
    assert "-protocol_whitelist" in argv
    # 占位文件看不出体积：通读上限直接给封顶值
    assert media_extract._extract_timeout(strm) == media_extract._MAX_EXTRACT_TIMEOUT


@pytest.mark.parametrize(
    ("url", "format_name", "expected"),
    [
        ("https://pan.example.com/d/电影/a.mkv?sign=1", "matroska,webm", "mkv"),
        ("https://pan.example.com/d/a.MP4", "mov,mp4,m4a,3gp,3g2,mj2", "mp4"),
        ("https://pan.example.com/play?id=42", "matroska,webm", "mkv"),
        ("https://pan.example.com/play?id=42", "mov,mp4,m4a,3gp,3g2,mj2", "mp4"),
        ("https://pan.example.com/play?id=42", "mpegts", "ts"),
        ("https://pan.example.com/play?id=42", None, None),
    ],
)
def test_strm_container_prefers_url_suffix_then_format(url, format_name, expected):
    assert strm_container(url, format_name) == expected


def test_remote_range_file_refuses_a_server_without_range(drive):
    (drive.root / "a.norange").write_bytes(b"x" * 1024)
    remote = RemoteRangeFile(drive.url("a.norange"))
    with pytest.raises(OSError, match="不支持按区间读取"):
        remote.read(16)


def test_remote_range_file_follows_redirect_and_reads_windows(drive):
    data = bytes(range(256)) * 1024
    (drive.root / "blob.bin").write_bytes(data)
    with RemoteRangeFile(drive.url("blob.bin"), min_fetch=4096) as f:
        assert f.read(4) == data[:4]
        assert f.read(4) == data[4:8]  # 落在同一块里，不再请求
        f.seek(200_000)
        assert f.read(10) == data[200_000:200_010]
        assert f.size == len(data)
    # 只有第一次绕了 302，之后直接打最终地址；整个过程只取了两块
    assert [p for p, _ in drive.requests if p.startswith("/d/")] == ["/d/blob.bin"]
    assert drive.served_bytes == 2 * 4096


# ---------------------------------------------------------------------------
# 真 ffmpeg / ffprobe：直链上读索引、探规格、落库
# ---------------------------------------------------------------------------


@pytest.mark.integration
@needs_ffmpeg
def test_matroska_cues_over_http_match_the_local_index(drive, sample_mkv, tmp_path):
    shutil.copy(sample_mkv, drive.root / "sample.mkv")
    strm = _strm(tmp_path, drive.url("sample.mkv"))
    remote = read_keyframe_index(strm, allow_ffprobe=False)
    local = read_keyframe_index(sample_mkv, allow_ffprobe=False)
    assert remote is not None and local is not None
    assert remote.times_s == local.times_s
    # 只读了头部与 Cues，远没有把整片拉下来
    assert drive.served_bytes < sample_mkv.stat().st_size / 2


@pytest.mark.integration
@needs_ffmpeg
def test_mp4_index_over_http_matches_local_and_ts_is_remembered_unindexed(
    drive, sample_mp4_and_ts, tmp_path
):
    """MP4 读 moov 样本表（另抽检关键帧样本）与本地结果一致；TS 没有索引可读，
    结论记下来，下次开会话不再白跑请求。"""
    mp4, ts = sample_mp4_and_ts
    shutil.copy(mp4, drive.root / "sample.mp4")
    shutil.copy(ts, drive.root / "sample.ts")
    remote = read_keyframe_index(_strm(tmp_path, drive.url("sample.mp4")), allow_ffprobe=False)
    local = read_keyframe_index(mp4, allow_ffprobe=False)
    assert remote is not None and local is not None
    assert remote.times_s == local.times_s
    assert drive.served_bytes < mp4.stat().st_size / 2

    ts_strm = _strm(tmp_path, drive.url("sample.ts"), name="ts.strm")
    assert read_keyframe_index(ts_strm, allow_ffprobe=False) is None
    requests = len(drive.requests)
    assert read_keyframe_index(ts_strm, allow_ffprobe=False) is None
    assert len(drive.requests) == requests


@pytest.mark.integration
@needs_ffmpeg
def test_probe_media_reads_spec_from_strm_url(drive, sample_mkv):
    shutil.copy(sample_mkv, drive.root / "sample.mkv")
    url = drive.url("sample.mkv")
    spec = probe_media(url, input_args=strm_input_args(url))
    assert spec is not None
    assert spec.video_codec == "h264"
    assert spec.duration_seconds == 30
    assert [s["codec"] for s in spec.audio_streams] == ["aac"]
    assert [s["codec"] for s in spec.subtitle_streams] == ["subrip"]
    assert strm_container(url, spec.format_name) == "mkv"


@pytest.mark.integration
@needs_ffmpeg
async def test_ensure_strm_spec_probes_once_and_persists(drive, sample_mkv, tmp_path, seeded_db):
    shutil.copy(sample_mkv, drive.root / "sample.mkv")
    strm = _strm(tmp_path, drive.url("sample.mkv"))
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name="网盘电影", kind="movie", root_paths=[str(tmp_path)]
        )
        row = LibraryFile(
            library_id=library.id,
            media_item_id=seeded_db["movie"],
            file_path=str(strm),
            size_bytes=strm.stat().st_size,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="strm",
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)

        assert await ensure_strm_spec(row) is True
        assert row.container == "mkv" and row.video_codec == "h264"
        assert not session.dirty  # 写回的是「已提交」状态，调用方会话不会再写一遍
        requests = len(drive.requests)
        assert await ensure_strm_spec(row) is True  # 已有规格：不再探
        assert len(drive.requests) == requests

    async with get_database().session() as session:
        stored = await session.get(LibraryFile, row.id)
        assert stored.container == "mkv"
        assert stored.duration_seconds == 30
        assert [s["codec"] for s in stored.subtitle_streams] == ["subrip"]


async def test_ensure_strm_spec_failure_is_remembered_briefly(tmp_path, seeded_db, monkeypatch):
    """探测失败不落库（决策退回乐观直连），一分钟内不再白等一轮超时。"""
    calls = []
    monkeypatch.setattr(strm_probe, "probe_media", lambda *a, **k: calls.append(a) or None)
    strm = _strm(tmp_path, "https://pan.example.com/d/gone.mkv")
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name="网盘电影", kind="movie", root_paths=[str(tmp_path)]
        )
        row = LibraryFile(
            library_id=library.id,
            media_item_id=seeded_db["movie"],
            file_path=str(strm),
            size_bytes=1,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="strm",
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        assert await ensure_strm_spec(row) is False
        assert await ensure_strm_spec(row) is False
    assert len(calls) == 1
    assert row.video_codec is None

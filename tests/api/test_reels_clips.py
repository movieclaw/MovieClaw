"""预切片段（docs/design/reels.md §8）。

覆盖开关、刷片只出切好的、预告、取流、统计与删除、队列档位、规格。

接口层沿用 test_reels_api 的夹具（假容器索引、假抓帧）；「切」这一步用 ``clips.install`` 直接放一个
假文件进去。最后两个用例用真 ffmpeg：一个直接切一段、核对输出规格，一个走完整链路——打开开关、
预告请求落空排进档 0、后台真切、再请求拿到小文件。
"""

from __future__ import annotations

import asyncio
import json
import re
import shutil
import subprocess
import time
from pathlib import Path

import pytest
from sqlmodel import select
from tests.api.test_reels_api import client, feed, preview, seed  # noqa: F401 —— client 是夹具

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library import skip_segments
from movieclaw_api.services.reels import clips, segments
from movieclaw_api.services.reels import feed as reels_feed
from movieclaw_api.services.reels.segments import ReelSegment
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile, PlaybackState
from movieclaw_playback.container_index import read_container_index

FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
#: 夹具把后台工作协程换成空操作，真切的用例要换回来
_REAL_START_WORKER = clips._start_worker
needs_ffmpeg = pytest.mark.skipif(not FFMPEG, reason="需要系统 ffmpeg / ffprobe")


@pytest.fixture
def clip_client(client, tmp_path, monkeypatch):  # noqa: F811
    monkeypatch.setenv("MOVIECLAW_REELS_CLIPS_DIR", str(tmp_path / "clips"))
    get_settings.cache_clear()
    monkeypatch.setattr(clips, "_registry", clips._Registry())
    clips._queues.clear()
    # 后台工作协程默认不跑：接口用例只看「排进了哪一档」；真切的用例自己放开
    monkeypatch.setattr(clips, "_start_worker", lambda _queue: None)
    yield client
    clips._queues.clear()


def enable(tc, on: bool = True) -> dict:
    resp = tc.put("/api/v1/playback/policy", json={"reel_clips_enabled": on})
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def queue_of(tc) -> clips.ClipQueue:
    async def get() -> clips.ClipQueue:
        return clips.get_queue()

    return tc.portal.call(get)


def settle(tc) -> None:
    """等整库排队这类后台小任务跑完。"""

    async def wait() -> None:
        for _ in range(50):
            if not clips._tasks:
                return
            await asyncio.sleep(0.02)

    tc.portal.call(wait)


async def _chosen(item_id: int) -> tuple[LibraryFile, str]:
    async with get_database().session() as session:
        files = list(
            (
                await session.execute(
                    select(LibraryFile).where(LibraryFile.media_item_id == item_id)
                )
            ).scalars()
        )
    kind = "episode" if files[0].season_number else "movie"
    return reels_feed.choose_file(files, kind), kind


def make_clip(tc, item_id: int, payload: bytes = b"MP4CLIP!" * 16) -> clips.ClipInfo:
    """假装切好了：算出挑点、放一个假 MP4 进去登记。"""

    async def run() -> clips.ClipInfo:
        file, kind = await _chosen(item_id)
        segment = await segments.get_segment(reels_feed._file_ref(file, kind))
        part = clips.clips_root() / str(file.id) / ".tmp.part"
        part.parent.mkdir(parents=True, exist_ok=True)
        part.write_bytes(payload)
        return await clips.install(file, segment, part)

    return tc.portal.call(run)


# --- 开关 ------------------------------------------------------------------------


def test_switch_is_off_by_default_and_clip_capable_apps_get_originals(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=2, episodes=0, extras=False)
    policy = clip_client.get("/api/v1/playback/policy").json()["data"]
    assert policy["reel_clips_enabled"] is False
    assert policy["reel_clips_progress"] is None
    data = feed(clip_client, modes="seek,clip")
    assert {i["title"]["media_item_id"] for i in data["items"]} == set(ids["movies"])
    assert all(i["play"]["mode"] == "seek" for i in data["items"])
    assert data["clips"] is None
    # 关着时预告照旧（不排队）
    assert preview(clip_client, ids["movies"][0], modes="seek,clip")["play"]["mode"] == "seek"
    assert queue_of(clip_client).pending == 0


def test_enabling_plans_the_whole_library_and_reports_progress(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=3, episodes=2, extras=False)
    data = enable(clip_client)
    settle(clip_client)
    assert data["reel_clips_enabled"] is True
    queue = queue_of(clip_client)
    assert set(queue.queued) == {*ids["movies"], ids["show"]}
    progress = clip_client.get("/api/v1/playback/policy").json()["data"]["reel_clips_progress"]
    assert progress == {"ready": 0, "total": 4, "state": "running"}
    # 关掉：队列清空
    enable(clip_client, False)
    assert queue_of(clip_client).pending == 0


def test_recently_watched_titles_are_cut_first(clip_client, tmp_path, monkeypatch):
    monkeypatch.setattr(clips, "HOME_RECENT_ADDED", 0)
    ids = seed(clip_client, tmp_path, movies=4, episodes=0, extras=False)
    watched = ids["movies"][2]

    async def watch() -> None:
        async with get_database().session() as session:
            session.add(PlaybackState(member_id=0, media_item_id=watched, position_ms=60_000))
            await session.commit()

    clip_client.portal.call(watch)
    enable(clip_client)
    settle(clip_client)
    queue = queue_of(clip_client)
    assert list(queue.tiers[clips.TIER_HOME]) == [watched]
    assert set(queue.tiers[clips.TIER_LIBRARY]) == set(ids["movies"]) - {watched}


# --- 刷片 ------------------------------------------------------------------------


def test_clip_mode_feed_only_has_cut_titles(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=3, episodes=0, extras=False)
    enable(clip_client)
    info = make_clip(clip_client, ids["movies"][1])
    data = feed(clip_client, modes="seek,clip")
    assert [i["title"]["media_item_id"] for i in data["items"]] == [ids["movies"][1]]
    assert data["has_more"] is False
    assert data["clips"]["ready"] == 1 and data["clips"]["total"] == 3
    play = data["items"][0]["play"]
    assert play["mode"] == "clip"
    assert play["clip_url"].startswith(
        f"/api/v1/reels/clips/{info.file_id}/{info.start_ms}.mp4?token="
    )
    assert play["clip_size_bytes"] == info.size_bytes
    assert play["prefetch"] == []
    # 「接着看」还要原片地址；segment 仍是原片时间轴
    assert play["stream_url"].startswith(f"/api/v1/playback/files/{info.file_id}/stream?token=")
    assert data["items"][0]["segment"]["start_ms"] == info.start_ms
    # 小文件按 Range 出；系统播放器带不了登录凭据，只凭地址里的签名令牌就能取
    clip_client.cookies.clear()
    resp = clip_client.get(play["clip_url"], headers={"Range": "bytes=0-7"})
    assert resp.status_code == 206
    assert resp.content == b"MP4CLIP!"
    assert resp.headers["content-type"] == "video/mp4"


def test_old_apps_keep_getting_originals_while_clips_are_on(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=3, episodes=0, extras=False)
    enable(clip_client)
    make_clip(clip_client, ids["movies"][0])
    data = feed(clip_client, modes="seek")
    assert {i["title"]["media_item_id"] for i in data["items"]} == set(ids["movies"])
    assert all(i["play"]["mode"] == "seek" and i["play"]["clip_url"] is None for i in data["items"])
    assert data["clips"] is None


def test_clip_pages_follow_the_draw_order_without_repeats(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=7, episodes=0, extras=False)
    enable(clip_client)
    cut = ids["movies"][:5]
    for item_id in cut:
        make_clip(clip_client, item_id)
    first = feed(clip_client, modes="seek,clip", limit=2)
    seen = [i["title"]["media_item_id"] for i in first["items"]]
    page, offset = first, first["next_offset"]
    while page["has_more"]:
        page = feed(clip_client, modes="seek,clip", limit=2, seed=first["seed"], offset=offset)
        seen += [i["title"]["media_item_id"] for i in page["items"]]
        offset = page["next_offset"]
    assert sorted(seen) == sorted(cut)
    # 同一个种子的 seek 顺序里，切好的这几部按同样的先后出现
    order = [
        i["title"]["media_item_id"]
        for i in feed(clip_client, modes="seek", limit=20, seed=first["seed"])["items"]
    ]
    assert seen == [i for i in order if i in cut]


def test_nothing_cut_yet_gives_an_empty_page_with_progress(clip_client, tmp_path):
    seed(clip_client, tmp_path, movies=2, episodes=1, extras=False)
    enable(clip_client)
    data = feed(clip_client, modes="seek,clip")
    assert data["items"] == []
    assert data["has_more"] is False
    assert data["clips"] == {"ready": 0, "total": 3, "state": "running"}


def test_replaced_source_file_is_not_served_and_gets_recut(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=2, episodes=0, extras=False)
    enable(clip_client)
    settle(clip_client)
    info = make_clip(clip_client, ids["movies"][0])

    async def replace_file() -> None:
        async with get_database().session() as session:
            file = await session.get(LibraryFile, info.file_id)
            file.size_bytes = (file.size_bytes or 0) + 1  # 洗版换了文件
            await session.commit()

    clip_client.portal.call(replace_file)
    data = feed(clip_client, modes="seek,clip")
    assert data["items"] == []
    assert queue_of(clip_client).queued.get(ids["movies"][0]) == clips.TIER_HOME


# --- 预告 ------------------------------------------------------------------------


def test_preview_serves_the_clip_or_queues_it_first(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=2, episodes=0, extras=False)
    enable(clip_client)
    settle(clip_client)
    ready, missing = ids["movies"]
    info = make_clip(clip_client, ready)
    # 切好的：放小文件；预告不开字幕；续播回忆不再做，source=resume 也放精彩片段
    item = preview(clip_client, ready, modes="seek,clip", source="resume")
    assert item["play"]["mode"] == "clip"
    assert item["play"]["clip_url"].startswith(f"/api/v1/reels/clips/{info.file_id}/")
    assert item["play"]["subtitle"] is None
    assert item["segment"]["method"] == "bitrate"
    # 没切好的：null（App 保持剧照），排进档 0 的最前面
    assert preview(clip_client, missing, modes="seek,clip") is None
    queue = queue_of(clip_client)
    assert queue.tiers[clips.TIER_NOW][0] == missing
    # 老 App 照旧放原片
    assert preview(clip_client, missing, modes="seek")["play"]["mode"] == "seek"


def test_clip_route_checks_the_token_and_the_clip(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=2, episodes=0, extras=False)
    enable(clip_client)
    info = make_clip(clip_client, ids["movies"][0])
    url = feed(clip_client, modes="seek,clip")["items"][0]["play"]["clip_url"]
    token = url.split("token=")[1]
    assert clip_client.get(f"{info.url_path}?token=bogus").status_code == 404
    wrong_start = f"/api/v1/reels/clips/{info.file_id}/1.mp4?token={token}"
    assert clip_client.get(wrong_start).status_code == 404
    # 令牌按文件签发：拿这个文件的令牌取别的文件不行
    other = f"/api/v1/reels/clips/{info.file_id + 1}/{info.start_ms}.mp4?token={token}"
    assert clip_client.get(other).status_code == 404


def test_stats_disable_keeps_files_and_delete_clears_them(clip_client, tmp_path):
    ids = seed(clip_client, tmp_path, movies=2, episodes=0, extras=False)
    enable(clip_client)
    info = make_clip(clip_client, ids["movies"][0], payload=b"x" * 1000)
    stats = clip_client.get("/api/v1/reels/clips/stats").json()["data"]
    assert stats == {"count": 1, "bytes": 1000}
    enable(clip_client, False)
    assert info.path.is_file()  # 关掉不删，设置页另问
    make_clip(clip_client, ids["movies"][1], payload=b"y" * 10)
    # 重新打开：留着的立即可用；全切好了就是完成，不因整库排队还在跑报「还在切」
    assert enable(clip_client)["reel_clips_progress"] == {"ready": 2, "total": 2, "state": "done"}
    resp = clip_client.delete("/api/v1/reels/clips")
    assert resp.json()["data"] == {"count": 2, "bytes": 1010}
    assert not info.path.exists()
    assert clip_client.get("/api/v1/reels/clips/stats").json()["data"] == {"count": 0, "bytes": 0}


def test_registry_is_rebuilt_from_disk_after_a_restart(clip_client, tmp_path, monkeypatch):
    ids = seed(clip_client, tmp_path, movies=2, episodes=0, extras=False)
    enable(clip_client)
    info = make_clip(clip_client, ids["movies"][0])
    monkeypatch.setattr(clips, "_registry", clips._Registry())  # 进程重启
    assert clips.ready_item_ids() == {ids["movies"][0]}
    assert clips.clip_for_file(info.file_id, info.start_ms) == info
    # 存储页清空了缓存目录：登记表跟着认，刷片不再出它
    info.path.unlink()
    assert clips.ready_item_ids() == set()


# --- 队列与规格（纯逻辑） -----------------------------------------------------------


def test_now_tier_is_last_in_first_out_capped_and_preempts_lower_tiers():
    queue = clips.ClipQueue()
    for item in (1, 2, 3):
        queue.put(item, clips.TIER_LIBRARY)
    queue.put(2, clips.TIER_HOME)  # 升档
    assert list(queue.tiers[clips.TIER_HOME]) == [2]
    queue.put(2, clips.TIER_LIBRARY)  # 不降档
    assert queue.queued[2] == clips.TIER_HOME
    queue.current = (9, clips.TIER_LIBRARY)
    for item in (10, 11, 12, 13):
        queue.put(item, clips.TIER_NOW)
    assert list(queue.tiers[clips.TIER_NOW]) == [13, 12, 11]
    assert list(queue.tiers[clips.TIER_HOME]) == [10, 2]  # 挤出去的排到档 1 最前
    assert queue.preempt is True
    queue.put(11, clips.TIER_NOW)  # 又停到这张卡上：提到最前
    assert list(queue.tiers[clips.TIER_NOW]) == [11, 13, 12]
    assert queue.pop(clips.TIER_NOW) == (11, clips.TIER_NOW)
    queue.tiers[clips.TIER_NOW].clear()
    for item in (13, 12):
        del queue.queued[item]
    assert queue.pop(clips.TIER_NOW) is None  # 有人在看时只切档 0
    assert queue.pop(clips.TIER_OTHER) == (10, clips.TIER_HOME)
    queue.requeue_front(10, clips.TIER_HOME)
    assert queue.tiers[clips.TIER_HOME][0] == 10


def test_playback_load_decides_how_far_down_the_queue_to_go():
    assert clips.allowed_tier(skip_segments.TRANSCODING) == -1
    assert clips.allowed_tier(skip_segments.PLAYING) == clips.TIER_NOW
    assert clips.allowed_tier(skip_segments.IDLE) == clips.TIER_OTHER


@pytest.mark.parametrize(
    ("source", "expected"),
    [(60, 30), (59.94, 29.97), (50, 25), (30, None), (29.97, None), (24, None), (None, None)],
)
def test_high_frame_rates_are_halved(source, expected):
    assert clips.output_fps(source) == expected


def test_command_follows_the_spec(tmp_path):
    cmd = clips.build_command(
        input_args=["-ss", "12.000", "-i", "/media/a.mkv"],
        duration_s=45,
        chain=["bwdif", "null", clips.scale_filter(), "format=yuv420p"],
        fps=30.0,
        source_fps=60.0,
        audio_map="0:a:1?",
        dest=tmp_path / "out.mp4",
    )
    joined = " ".join(cmd)
    assert "-ss 12.000 -i /media/a.mkv -t 45.000" in joined
    assert "bwdif,scale='min(1920,iw)':-2:flags=lanczos,format=yuv420p,fps=30" in joined
    assert "-c:v libx264 -preset faster -crf 23 -maxrate 5000k -bufsize 10000k" in joined
    assert "-g 60 -keyint_min 60" in joined
    assert "-map 0:a:1? " in joined and "-c:a aac -b:a 128k -ac 2 -ar 48000" in joined
    # 响度统一到 -23 LUFS，首尾淡入淡出（结尾 0.5 秒）
    assert "-af loudnorm=I=-23:TP=-2:LRA=9,afade=t=in:d=0.15,afade=t=out:st=44.500:d=0.5" in joined
    assert "-movflags +faststart" in joined and cmd[-1].endswith("out.mp4")
    silent = clips.build_command(
        input_args=["-i", "x"], duration_s=30, chain=["null"], fps=None, source_fps=24.0,
        audio_map=None, dest=tmp_path / "o.mp4",
    )
    assert "-c:a" not in silent and "-g 48" in " ".join(silent)


# --- 真 ffmpeg ---------------------------------------------------------------------


def _make_source(path: Path, *, size: str = "2560x1440", rate: int = 50, seconds: int = 90) -> None:
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-y",
            "-f", "lavfi", "-i", f"testsrc2=size={size}:rate={rate}",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-ac", "6", "-t", str(seconds),
            "-c:v", "libx264", "-preset", "ultrafast", "-g", str(rate * 2),
            "-c:a", "aac", str(path),
        ],
        check=True,
    )  # fmt: skip


def _probe(path: Path) -> dict:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]
    )
    return json.loads(out)


@needs_ffmpeg
@pytest.mark.parametrize("hdr", [None, "HDR10"])
async def test_real_clip_matches_the_spec(tmp_path, monkeypatch, hdr):
    """真切一段：2560x1440 50 帧 5.1 声道 → 1920x1080 25 帧 H.264 + 立体声 AAC，索引在文件头。
    标了 HDR 的走映射链（没有 tonemapx 的 ffmpeg 退回不映射），一样产出。"""
    monkeypatch.setenv("MOVIECLAW_REELS_CLIPS_DIR", str(tmp_path / "clips"))
    get_settings.cache_clear()
    monkeypatch.setattr(clips, "_registry", clips._Registry())
    source = tmp_path / "source.mkv"
    _make_source(source)
    file = LibraryFile(
        id=7,
        media_item_id=70,
        library_id=1,
        file_path=str(source),
        size_bytes=source.stat().st_size,
        file_mtime_ns=source.stat().st_mtime_ns,
        container="mkv",
        frame_rate=50.0,
        hdr=hdr,
        audio_streams=[{"codec": "aac", "language": "eng", "default": True}],
    )
    segment = ReelSegment(7, 20_000, 50_000, "bitrate", 1.0, (), None)
    monkeypatch.setattr(clips, "video_color_for", lambda *_a, **_k: clips.VideoColor(hdr=hdr))
    info = await clips.generate(file, segment)
    assert info.path.is_file()
    probe = _probe(info.path)
    video = next(s for s in probe["streams"] if s["codec_type"] == "video")
    audio = next(s for s in probe["streams"] if s["codec_type"] == "audio")
    assert (video["codec_name"], video["width"], video["height"]) == ("h264", 1920, 1080)
    assert video["profile"] == "High" and video["pix_fmt"] == "yuv420p"
    assert video["r_frame_rate"] == "25/1"
    assert (audio["codec_name"], audio["channels"], audio["sample_rate"]) == ("aac", 2, "48000")
    # 响度统一：整段积分响度落在 -23 LUFS 附近（源是正弦波测试音）
    loud = subprocess.run(
        ["ffmpeg", "-nostdin", "-i", str(info.path), "-af", "ebur128", "-f", "null", "-"],
        capture_output=True,
        text=True,
    ).stderr
    integrated = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", loud)[-1])
    assert -24.2 <= integrated <= -21.8, integrated  # 第二遍补偿后落在目标 ±1 LU 内
    assert abs(float(probe["format"]["duration"]) - 30.0) < 0.5
    data = info.path.read_bytes()
    assert data.index(b"moov") < data.index(b"mdat")  # faststart
    # 记录落盘、登记表认它；同一文件换了起点再切，旧的删掉
    assert clips.ready_clip(file, segment) == info
    moved = ReelSegment(7, 30_000, 40_000, "bitrate", 1.0, (), None)
    again = await clips.generate(file, moved)
    assert not info.path.exists() and again.path.is_file()
    assert sorted(p.name for p in again.path.parent.iterdir()) == [
        f"30000-v{clips.CLIP_VERSION}.mp4",
        f"30000-v{clips.CLIP_VERSION}.mp4.json",
    ]


@needs_ffmpeg
def test_end_to_end_preview_queues_cuts_then_serves_the_clip(clip_client, tmp_path, monkeypatch):
    """完整链路：开开关 → 预告落空、排进档 0 → 后台真读索引、挑点、切 →
    再要就是小文件，按 Range 取得到。"""
    ids = seed(clip_client, tmp_path, movies=1, episodes=0, extras=False)
    item_id = ids["movies"][0]

    async def real_source() -> None:
        async with get_database().session() as session:
            query = select(LibraryFile).where(LibraryFile.media_item_id == item_id)
            file = (await session.execute(query)).scalar_one()
            source = Path(file.file_path)
            _make_source(source, size="1280x720", rate=25, seconds=120)
            file.size_bytes = source.stat().st_size
            file.file_mtime_ns = source.stat().st_mtime_ns
            file.duration_seconds = 120
            file.frame_rate = 25.0
            file.subtitle_streams = []
            file.audio_streams = [{"codec": "aac", "language": "eng", "default": True}]
            await session.commit()

    clip_client.portal.call(real_source)
    monkeypatch.setattr(segments, "read_container_index", read_container_index)
    monkeypatch.setattr(clips, "_start_worker", _REAL_START_WORKER)
    enable(clip_client)
    assert preview(clip_client, item_id, modes="seek,clip") is None
    deadline = time.monotonic() + 120
    item = None
    while time.monotonic() < deadline:
        item = preview(clip_client, item_id, modes="seek,clip")
        if item is not None:
            break
        time.sleep(0.5)
    assert item is not None, "后台没切出来"
    assert item["play"]["mode"] == "clip"
    seconds = (item["segment"]["end_ms"] - item["segment"]["start_ms"]) / 1000
    assert 30 <= seconds <= 60
    resp = clip_client.get(item["play"]["clip_url"], headers={"Range": "bytes=0-1023"})
    assert resp.status_code == 206 and len(resp.content) == 1024
    # 刷片也有它了
    data = feed(clip_client, modes="seek,clip")
    assert [i["title"]["media_item_id"] for i in data["items"]] == [item_id]
    assert data["clips"]["ready"] == 1


# --- 「开启片段预切」建议（docs/design/tips.md 服务端代记的事件）-------------------


@pytest.fixture
def tip_client(clip_client, monkeypatch):
    from movieclaw_api.services.push import events as push_events
    from movieclaw_api.services.reels import clip_tip

    clip_tip.reset_state()
    pushed: list[int] = []
    monkeypatch.setattr(push_events, "reel_clips_suggested", lambda: pushed.append(1))
    clip_client.pushed = pushed
    yield clip_client
    clip_tip.reset_state()


def settle_tip(tc) -> None:
    from movieclaw_api.services.push import dispatcher

    async def wait() -> None:
        for _ in range(100):
            if not dispatcher._tasks:
                return
            await asyncio.sleep(0.02)

    tc.portal.call(wait)


def tip_state(tc) -> tuple[dict, dict]:
    data = tc.get("/api/v1/tips/state").json()["data"]
    events = {e["event_id"]: e for e in data["events"]}
    records = {t["tip_id"]: t for t in data["tips"]}
    return events.get("reels.played-without-clips", {}), records.get("playback.reel-clips", {})


def test_reels_without_clips_suggest_the_switch_once(tip_client, tmp_path):
    from movieclaw_api.services.reels import clip_tip

    ids = seed(tip_client, tmp_path, movies=2, episodes=0, extras=False)
    assert tip_state(tip_client) == ({}, {})
    feed(tip_client)  # 手机刷片放了原片
    settle_tip(tip_client)
    event, _ = tip_state(tip_client)
    assert event["count"] == 1
    assert tip_client.pushed == [1]

    # 同一进程里之后的刷片、预告不再写库
    feed(tip_client)
    preview(tip_client, ids["movies"][0])
    settle_tip(tip_client)
    assert tip_state(tip_client)[0]["count"] == 1

    # 重启后再记一次，但只推第一次
    clip_tip.reset_state()
    preview(tip_client, ids["movies"][0])  # 电视大图预告
    settle_tip(tip_client)
    assert tip_state(tip_client)[0]["count"] == 2
    assert tip_client.pushed == [1]


def test_enabling_the_switch_retires_the_suggestion(tip_client, tmp_path):
    from movieclaw_api.services.reels import clip_tip

    ids = seed(tip_client, tmp_path, movies=1, episodes=0, extras=False)
    preview(tip_client, ids["movies"][0])
    settle_tip(tip_client)
    enable(tip_client)
    settle(tip_client)
    _, record = tip_state(tip_client)
    assert record["invalidated_reason"] == "action_performed"

    # 关掉之后再有人放原片：已作废，不再记、不再推
    enable(tip_client, False)
    clip_tip.reset_state()
    preview(tip_client, ids["movies"][0])
    settle_tip(tip_client)
    assert tip_state(tip_client)[0]["count"] == 1
    assert tip_client.pushed == [1]


def test_old_apps_with_the_switch_on_retire_the_suggestion(tip_client, tmp_path):
    """本功能上线前就开着开关：老 App 放原片时直接作废，不提示也不推。"""
    from movieclaw_api.settings.playback import PlaybackPolicySetting
    from movieclaw_api.settings.store import get_setting_store

    ids = seed(tip_client, tmp_path, movies=1, episodes=0, extras=False)

    async def turn_on() -> None:
        store = get_setting_store()
        stored = await store.get(PlaybackPolicySetting)
        await store.set(stored.model_copy(update={"reel_clips_enabled": True}))

    tip_client.portal.call(turn_on)
    assert preview(tip_client, ids["movies"][0], modes="seek")["play"]["mode"] == "seek"
    settle_tip(tip_client)
    event, record = tip_state(tip_client)
    assert event == {} and record["invalidated_reason"] == "action_performed"
    assert tip_client.pushed == []

"""跳过片头 / 片尾的服务端链路（docs/design/skip-intro.md）。

ffmpeg 的 chromaprint 用替身（按文件路径生成可复现的合成指纹：每集片头位置不同、
片尾放到结尾），其余全是真的：整季识别在独立子进程里跑、结果落 ``media_segment``、
播放会话下发、Jellyfin ``/MediaSegments`` 输出、库开关收放、后台作业走真执行器。
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
from functools import partial
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from sqlmodel import select

from jellyfin.helpers import AUTH_HEADER
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.library import skip_segments
from movieclaw_api.services.playback.session import get_session_manager, reset_session_manager
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import FileSource, FileState, LibraryFile, MediaItem, MediaSegmentState
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_jellyfin.ids import episode_guid
from movieclaw_playback import activity
from movieclaw_playback.events import ClientInfo
from movieclaw_playback.skip_segments import HASH_SECONDS

_PB = "/api/v1/playback"


def test_real_truncated_first_audio_selects_complete_track() -> None:
    """NAS《开端》E03：第一轨 2422.368 秒，第二轨才覆盖完整的 2671.701 秒。"""
    fixture = Path(__file__).parents[1] / "playback/fixtures/skip_segments/nas-reset-audio.json"
    data = json.loads(fixture.read_text())
    assert skip_segments._complete_audio_index(data["streams"], data["duration"]) == 1
    # 正常的第一轨仍有优先权，不因多一条音轨就任意换轨。
    data["streams"][0]["tags"]["DURATION"] = "00:44:31.701000000"
    assert skip_segments._complete_audio_index(data["streams"], data["duration"]) == 0


@pytest.mark.parametrize("reason", ["commentary", "different_language", "unknown_length"])
def test_incomplete_audio_does_not_switch_without_suitable_alternative(reason: str) -> None:
    streams = [
        {"duration": "2400", "tags": {"language": "chi"}},
        {"duration": "2700", "tags": {"language": "chi"}},
    ]
    if reason == "commentary":
        streams[1]["disposition"] = {"comment": 1}
    elif reason == "different_language":
        streams[1]["tags"]["language"] = "eng"
    else:
        streams[0]["duration"] = "N/A"
    assert skip_segments._complete_audio_index(streams, 2700) == 0


_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}
CAPABILITY = {
    "video": [{"codec": "h264"}],
    "audio": [{"codec": "aac"}],
    "containers": ["mp4", "hls-fmp4", "matroska"],
}
DURATION = 2700
INTRO_S = 60.0
OUTRO_S = 120.0


def intro_at(episode: int) -> float:
    """第 n 集片头的起点：冷开场长短不一。"""
    return 20.0 + 15.0 * episode


_COMMON = np.random.default_rng(2026)
_INTRO = _COMMON.integers(0, 2**32, size=int(INTRO_S / HASH_SECONDS), dtype=np.uint64).astype(
    np.uint32
)
_OUTRO = _COMMON.integers(0, 2**32, size=int(OUTRO_S / HASH_SECONDS), dtype=np.uint64).astype(
    np.uint32
)


async def fake_window(path: str, start: float, length: float) -> bytes:
    """合成指纹：随机底噪 + 片头窗贴片头、片尾窗在末尾贴片尾。"""
    if "bad" in path:
        raise skip_segments.FingerprintError("文件没有音轨")
    match = re.search(r"E(\d+)", Path(path).name)
    episode = int(match.group(1)) if match else 0
    rng = np.random.default_rng(abs(hash((path, round(start)))) % (2**32))
    out = rng.integers(0, 2**32, size=int(length / HASH_SECONDS), dtype=np.uint64).astype(np.uint32)
    if start == 0:
        i = int(intro_at(episode) / HASH_SECONDS)
        out[i : i + len(_INTRO)] = _INTRO
    else:
        out[len(out) - len(_OUTRO) :] = _OUTRO
    return out.astype("<u4").tobytes()


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MOVIECLAW_TRANSCODE_DIR", str(tmp_path / "transcodes"))
    monkeypatch.setenv("MOVIECLAW_AUDIO_FINGERPRINT_DIR", str(tmp_path / "fp"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    reset_session_manager()
    monkeypatch.setattr(skip_segments, "_chromaprint_window", fake_window)
    monkeypatch.setattr(skip_segments, "_chromaprint", True)
    monkeypatch.setattr(skip_segments, "_BUMP_DELAY_S", 0.0)
    monkeypatch.setattr("movieclaw_api.api.routes.playback.available_backends", lambda: ())
    monkeypatch.setattr(
        "movieclaw_api.services.playback.plan.probe_keyframe_interval",
        lambda path, duration: 4.0,
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield c

    asyncio.get_event_loop_policy().new_event_loop().run_until_complete(
        get_session_manager().shutdown()
    )
    reset_session_manager()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


async def _seed(tmp_path: Path, episodes: int = 5, *, bad: int | None = None) -> dict:
    """剧集库（1 部剧第 1 季 n 集 + 第 0 季特别篇 + 一个 strm）+ 电影库（1 部片）。"""
    root = tmp_path / "tv"
    movies = tmp_path / "movies"
    root.mkdir(exist_ok=True)
    movies.mkdir(exist_ok=True)
    async with get_database().session() as session:
        repo = LibraryRepository(session)
        tv = await repo.create(name="剧集", kind="tv", root_paths=[str(root)])
        movie_lib = await repo.create(name="电影", kind="movie", root_paths=[str(movies)])
        show = MediaItem(kind="tv", tmdb_id=1, title="示例剧", original_title="Show")
        film = MediaItem(kind="movie", tmdb_id=2, title="示例片", original_title="Film")
        session.add_all([show, film])
        await session.flush()

        def row(library_id, item_id, path: Path, season, episode, container="mp4"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"FAKE-MEDIA" * 64)
            return LibraryFile(
                library_id=library_id,
                media_item_id=item_id,
                season_number=season,
                episode_number=episode,
                file_path=str(path),
                size_bytes=path.stat().st_size,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                container=container,
                video_codec="h264",
                resolution="1080p",
                duration_seconds=DURATION,
                audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
            )

        files = []
        for n in range(1, episodes + 1):
            name = f"Show S01E{n:02d}{'.bad' if n == bad else ''}.mp4"
            files.append(row(tv.id, show.id, root / "Season 01" / name, 1, n))
        special = row(tv.id, show.id, root / "Specials" / "Show S00E01.mp4", 0, 1)
        film_row = row(movie_lib.id, film.id, movies / "Film.mp4", 0, 0)
        session.add_all([*files, special, film_row])
        await session.commit()
        return {
            "tv": tv.id,
            "movie_lib": movie_lib.id,
            "show": show.id,
            "files": [f.id for f in files],
            "special": special.id,
            "film": film_row.id,
        }


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


async def _states() -> dict[int, MediaSegmentState]:
    async with get_database().session() as session:
        rows = (await session.execute(select(MediaSegmentState))).scalars().all()
        return {r.library_file_id: r for r in rows}


async def _needing(**kwargs) -> list[tuple[int, int]]:
    async with get_database().session() as session:
        return await skip_segments.seasons_needing_work(session, **kwargs)


def start_session(client: TestClient, file_id: int) -> dict:
    resp = client.post(f"{_PB}/sessions", json={"file_id": file_id, "capability": CAPABILITY})
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def jf_token(client: TestClient) -> str:
    resp = client.post(
        "/Users/AuthenticateByName",
        json={"Username": _ADMIN["username"], "Pw": _ADMIN["password"]},
        headers={"Authorization": AUTH_HEADER},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["AccessToken"]


def test_only_eligible_episodes_need_work(client: TestClient, tmp_path: Path) -> None:
    """电影、第 0 季不参与；开关关掉的库不参与。"""
    ids = call(client, _seed, tmp_path)
    assert call(client, _needing) == [(ids["show"], 1)]
    assert call(client, _needing, library_id=ids["movie_lib"]) == []


def test_season_analysis_feeds_session_and_jellyfin(client: TestClient, tmp_path: Path) -> None:
    ids = call(client, _seed, tmp_path)
    outcome = call(client, skip_segments.analyze_season, ids["show"], 1)
    assert outcome.fingerprinted == 5 and outcome.analyzed
    assert outcome.with_intro == 5 and outcome.with_outro == 5
    for file_id in ids["files"]:
        assert (Path(tmp_path / "fp") / f"{file_id}.fp").is_file()
    # 做完的季不再有活
    assert call(client, _needing) == []

    # 播放会话随响应下发片段
    third = ids["files"][2]
    session = start_session(client, third)
    segments = {s["type"]: s for s in session["segments"]}
    assert set(segments) == {"intro", "outro"}
    assert abs(segments["intro"]["start_ms"] - intro_at(3) * 1000) < 1500
    assert abs(segments["intro"]["end_ms"] - (intro_at(3) + INTRO_S) * 1000) < 1500
    assert segments["outro"]["to_end"] is True
    assert abs(segments["outro"]["end_ms"] - DURATION * 1000) < 1500
    # 电影没有片段
    assert start_session(client, ids["film"])["segments"] == []

    # Jellyfin：按集给，Ticks = 毫秒 × 10000，可按类型过滤
    token = jf_token(client)
    guid = episode_guid(ids["show"], 1, 3)
    body = client.get(f"/MediaSegments/{guid}", params={"ApiKey": token}).json()
    assert [i["Type"] for i in body["Items"]] == ["Intro", "Outro"]
    assert body["TotalRecordCount"] == 2
    assert body["Items"][0]["StartTicks"] == segments["intro"]["start_ms"] * 10_000
    assert all(i["ItemId"] == guid for i in body["Items"])
    only_outro = client.get(
        f"/MediaSegments/{guid}", params={"ApiKey": token, "includeSegmentTypes": "Outro"}
    ).json()
    assert [i["Type"] for i in only_outro["Items"]] == ["Outro"]
    # 查询键任意大小写（ASP.NET 的 query 不区分大小写），多个类型逗号分隔
    for key in ("includesegmenttypes", "IncludeSegmentTypes"):
        both = client.get(
            f"/MediaSegments/{guid}", params={"ApiKey": token, key: "Intro,Outro"}
        ).json()
        assert [i["Type"] for i in both["Items"]] == ["Intro", "Outro"], key
        only_intro = client.get(
            f"/MediaSegments/{guid}", params={"ApiKey": token, key: "Intro"}
        ).json()
        assert [i["Type"] for i in only_intro["Items"]] == ["Intro"], key
    # 特别篇没识别：空 QueryResult
    special = episode_guid(ids["show"], 0, 1)
    assert client.get(f"/MediaSegments/{special}", params={"ApiKey": token}).json()["Items"] == []


def test_switch_off_hides_segments_and_cancels_job(client: TestClient, tmp_path: Path) -> None:
    ids = call(client, _seed, tmp_path)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    lib = client.get(f"/api/v1/libraries/{ids['tv']}").json()["data"]
    assert lib["detect_media_segments"] is True

    async def _queue_library_job() -> str:
        async with get_database().session() as session:
            created = await skip_segments.enqueue_library_job(session, ids["tv"], "剧集")
            return created.job.id

    payload = {"name": "剧集", "kind": "tv", "root_paths": lib["root_paths"]}
    job_id = call(client, _queue_library_job)
    resp = client.put(
        f"/api/v1/libraries/{ids['tv']}", json={**payload, "detect_media_segments": False}
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["detect_media_segments"] is False

    async def _job_status() -> str:
        async with get_database().session() as session:
            job = await jobs.get_job(session, job_id)
            return str(job.status)

    assert call(client, _job_status) in {"cancelled", "cancelling", "succeeded"}
    assert start_session(client, ids["files"][0])["segments"] == []
    token = jf_token(client)
    guid = episode_guid(ids["show"], 1, 1)
    assert client.get(f"/MediaSegments/{guid}", params={"ApiKey": token}).json()["Items"] == []
    # 不传字段不改动（老客户端）；重新打开立即恢复（结果保留着）
    assert (
        client.put(f"/api/v1/libraries/{ids['tv']}", json=payload).json()["data"][
            "detect_media_segments"
        ]
        is False
    )
    client.put(f"/api/v1/libraries/{ids['tv']}", json={**payload, "detect_media_segments": True})
    assert len(start_session(client, ids["files"][0])["segments"]) == 2


def test_failed_fingerprint_is_recorded_and_retried_after_source_change(
    client: TestClient, tmp_path: Path
) -> None:
    ids = call(client, _seed, tmp_path, 5, bad=2)
    outcome = call(client, skip_segments.analyze_season, ids["show"], 1)
    assert outcome.failed == 1 and outcome.fingerprinted == 4 and outcome.with_intro == 4
    states = call(client, _states)
    bad = states[ids["files"][1]]
    assert bad.fingerprint_status == "failed" and bad.error == "文件没有音轨"
    # 失败是终态：不会每轮重试
    assert call(client, _needing) == []

    async def _replace_source() -> None:
        async with get_database().session() as session:
            row = await session.get(LibraryFile, ids["files"][1])
            row.size_bytes = (row.size_bytes or 0) + 1
            session.add(row)
            await session.commit()

    call(client, _replace_source)
    assert call(client, _needing) == [(ids["show"], 1)]


def test_playback_bump_runs_item_job_through_executor(client: TestClient, tmp_path: Path) -> None:
    """开播时这一季还没算过 → 后台排一份条目作业，真执行器跑完后下一次开播就有片段。"""
    ids = call(client, _seed, tmp_path)
    assert start_session(client, ids["files"][0])["segments"] == []
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        states = call(client, _states)
        if len(states) == 5 and all(s.analyzed_at is not None for s in states.values()):
            break
        time.sleep(0.3)
    else:
        pytest.fail("开播后 60 秒内没有跑完片头片尾识别")
    assert {s["type"] for s in start_session(client, ids["files"][0])["segments"]} == {
        "intro",
        "outro",
    }


def test_clearing_fingerprint_cache_recomputes_on_next_analysis(
    client: TestClient, tmp_path: Path
) -> None:
    """缓存管理里清空指纹：识别结果不丢；之后这一季要重算时会把缺的指纹补回来。"""
    ids = call(client, _seed, tmp_path)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    for f in (tmp_path / "fp").iterdir():
        f.unlink()
    assert len(start_session(client, ids["files"][0])["segments"]) == 2

    async def _expire() -> None:
        async with get_database().session() as session:
            row = await session.get(MediaSegmentState, ids["files"][0])
            row.analyzed_at = None
            session.add(row)
            await session.commit()

    call(client, _expire)
    outcome = call(client, skip_segments.analyze_season, ids["show"], 1)
    assert outcome.fingerprinted == 5 and outcome.with_intro == 5


class _Ctx:
    """最小的作业上下文替身：只实现 analyze_season 在作业里会用到的两个方法。"""

    def __init__(self) -> None:
        self.messages: list[str] = []

    async def raise_if_cancelled(self) -> None:
        return None

    async def update_progress(self, **kwargs) -> None:
        self.messages.append(str(kwargs.get("message")))

    def progress_due(self, **_kwargs) -> bool:
        return True


def test_library_backfill_pauses_while_someone_is_watching(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """整库回填读的是和播放同一份磁盘：有人在看片（未暂停的会话）就先等，暂停 / 放完后继续。"""
    ids = call(client, _seed, tmp_path)
    monkeypatch.setattr(skip_segments, "_QUIET_POLL_S", 0.05)
    device = ClientInfo(name="测试播放器", device_id="dev-1")
    unit = (ids["show"], 1, 1)
    ctx = _Ctx()

    async def scenario():
        activity.reset()
        activity.report_progress(
            "dev-1", member_id=0, client=device, unit=unit, position_ms=1000, paused=False
        )
        assert skip_segments.playback_active()
        task = asyncio.create_task(
            skip_segments.analyze_season(ids["show"], 1, context=ctx, polite=True)
        )
        await asyncio.sleep(0.8)
        paused_all_along = not task.done() and not list((tmp_path / "fp").glob("*.fp"))
        # 用户按了暂停：不再算「在看」，回填放行
        activity.report_progress(
            "dev-1", member_id=0, client=device, unit=unit, position_ms=1000, paused=True
        )
        outcome = await asyncio.wait_for(task, 60)
        activity.reset()
        return paused_all_along, outcome

    paused_all_along, outcome = call(client, scenario)
    assert paused_all_along, "有人在看片时不该读盘算指纹"
    assert outcome.fingerprinted == 5 and outcome.analyzed
    assert any("有人正在看片" in m for m in ctx.messages)
    # 恢复读盘时要把「暂停」字样换掉，否则任务中心要等这一季做完才更新
    paused_at = next(i for i, m in enumerate(ctx.messages) if "有人正在看片" in m)
    assert any("继续识别" in m for m in ctx.messages[paused_at + 1 :])


def test_item_job_and_ingest_never_wait_for_playback(client: TestClient, tmp_path: Path) -> None:
    """入库与开播提队的条目作业不让路：只读一集刚下载好的文件 / 本来就因为开播才排。"""
    ids = call(client, _seed, tmp_path)
    device = ClientInfo(name="测试播放器", device_id="dev-2")

    async def scenario():
        activity.reset()
        activity.report_progress(
            "dev-2",
            member_id=0,
            client=device,
            unit=(ids["show"], 1, 1),
            position_ms=0,
            paused=False,
        )
        try:
            return await asyncio.wait_for(skip_segments.analyze_season(ids["show"], 1), 60)
        finally:
            activity.reset()

    outcome = call(client, scenario)
    assert outcome.fingerprinted == 5 and outcome.analyzed


async def _add_episode(tmp_path: Path, ids: dict, number: int) -> int:
    """作业运行期间又落位了一集：往已有的剧集库里补一行台账（文件是真实存在的假字节）。"""
    path = tmp_path / "tv" / "Season 01" / f"Show S01E{number:02d}.mp4"
    path.write_bytes(b"FAKE-MEDIA" * 64)
    async with get_database().session() as session:
        row = LibraryFile(
            library_id=ids["tv"],
            media_item_id=ids["show"],
            season_number=1,
            episode_number=number,
            file_path=str(path),
            size_bytes=path.stat().st_size,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="mp4",
            video_codec="h264",
            resolution="1080p",
            duration_seconds=DURATION,
            audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        return row.id


def test_running_job_picks_up_episode_that_lands_mid_run(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """同库已有作业在跑时，后来的排队请求会被并进它——它做完一轮要再查一次还有没有新活，
    否则运行期间新落位的集要漏到下一次触发。"""
    ids = call(client, _seed, tmp_path, 4)
    real = skip_segments.compute_fingerprint
    landed: dict[str, int] = {}

    async def compute_then_land_new_episode(file) -> None:
        await real(file)
        if "id" not in landed:
            landed["id"] = await _add_episode(tmp_path, ids, 5)

    monkeypatch.setattr(skip_segments, "compute_fingerprint", compute_then_land_new_episode)
    ctx = _Ctx()
    result = call(client, skip_segments._run_library_job, ctx, {"library_id": ids["tv"]})
    assert landed, "测试前提：运行期间应当落位了一集"
    states = call(client, _states)
    assert landed["id"] in states and states[landed["id"]].fingerprint_status == "ok"
    assert all(states[i].analyzed_at is not None for i in [*ids["files"], landed["id"]])
    assert result["fingerprinted"] == 5
    # 新落位的那一集已经带上片段，不用等下一次触发
    assert {s["type"] for s in states[landed["id"]].segments} == {"intro", "outro"}


def test_enqueue_after_library_change_respects_switch_and_kind(
    client: TestClient, tmp_path: Path
) -> None:
    """扫描作业收尾与监听触发的增量扫描共用这个入口：只有开着开关的剧集库才排。"""
    ids = call(client, _seed, tmp_path)

    async def _active_jobs() -> list[str]:
        async with get_database().session() as session:
            rows = await jobs.list_jobs(
                session, active_only=True, job_type=skip_segments.LIBRARY_JOB_TYPE
            )
            return [str(r.status) for r in rows]

    assert call(client, skip_segments.enqueue_after_library_change, ids["movie_lib"]) is False
    assert call(client, skip_segments.enqueue_after_library_change, 999_999) is False
    assert call(client, skip_segments.enqueue_after_library_change, ids["tv"]) is True
    # 同库重复触发并进同一个作业，不排第二份
    assert call(client, skip_segments.enqueue_after_library_change, ids["tv"]) is True
    assert len(call(client, _active_jobs)) <= 1


def test_cache_panel_cleans_orphan_fingerprints_against_real_database(
    client: TestClient, tmp_path: Path
) -> None:
    """缓存管理面板的「清理孤儿」在真数据库上走通：只删没有对应文件的指纹，正常的原样保留。

    这条路径以前在真数据库上一律 500（孤儿判定查主键时用了 AsyncSession 没有的 .exec），
    单测又把判定整个替身了，所以一直没人发现。
    """
    ids = call(client, _seed, tmp_path)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    fp_dir = tmp_path / "fp"
    (fp_dir / "99999.fp").write_bytes(b"orphan")
    before = sorted(p.name for p in fp_dir.glob("*.fp"))
    assert "99999.fp" in before and len(before) == 6
    resp = client.post(
        "/api/v1/app/storage/cache.audio_fingerprints/clean", json={"mode": "orphans"}
    )
    assert resp.status_code == 200, resp.text
    after = sorted(p.name for p in fp_dir.glob("*.fp"))
    assert after == [n for n in before if n != "99999.fp"]
    # 用量快照是后台统计的：先触发一次，再轮询到统计结果出来
    client.get("/api/v1/app/storage?refresh=1")
    usage = None
    for _ in range(50):
        usage = client.get("/api/v1/app/storage").json()["data"]["usage"]
        if usage is not None:
            break
        time.sleep(0.2)
    assert usage is not None, "用量统计一直没出结果"
    mine = next(d for d in usage["dirs"] if d["key"] == "cache.audio_fingerprints")
    assert mine["clearable"] is True and mine["rebuild_cost"] == "expensive"
    assert mine["orphan_aware"] is True and mine["entries"] == 5
    unregistered = [u["path"] for u in usage["unregistered"]]
    assert not any("audio-fingerprints" in path for path in unregistered), unregistered
    # 全部清空：识别结果仍在（会话照常下发），只是缓存没了
    resp = client.post("/api/v1/app/storage/cache.audio_fingerprints/clean", json={"mode": "all"})
    assert resp.status_code == 200, resp.text
    assert list(fp_dir.glob("*.fp")) == []
    assert len(start_session(client, ids["files"][0])["segments"]) == 2


def test_priority_job_is_bounded_and_hands_backlog_to_polite_backfill(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """入库 / 开播提队的条目作业不让路，所以一次最多读 PRIORITY_BATCH 个文件，先读离在看那一集近的；
    整季积压的旧集留给整库回填（它会为在看片的人让路），而不是为一集新片把整个积压读一遍。"""
    ids = call(client, _seed, tmp_path, 8)
    monkeypatch.setattr(skip_segments, "PRIORITY_BATCH", 4)
    ctx = _Ctx()
    # 在看第 8 集：先算离它最近的 4 集（5、6、7、8）
    result = call(
        client,
        skip_segments._run_item_job,
        ctx,
        {"media_item_id": ids["show"], "season_number": 1, "episode_number": 8},
    )
    assert result["fingerprinted"] == 4
    states = call(client, _states)
    done = sorted(n for n, file_id in enumerate(ids["files"], start=1) if file_id in states)
    assert done == [5, 6, 7, 8], done
    # 有了 4 集的指纹就能识别：最近的这几集已经带上片段，积压的旧集还没有
    assert {s["type"] for s in states[ids["files"][7]].segments} == {"intro", "outro"}
    assert ids["files"][0] not in states

    async def _library_jobs() -> list[str]:
        async with get_database().session() as session:
            rows = await jobs.list_jobs(
                session, active_only=True, job_type=skip_segments.LIBRARY_JOB_TYPE
            )
            return [str(r.status) for r in rows]

    assert call(client, _library_jobs), "积压要交给整库回填（排出一份会让路的整库作业）"
    # 整库回填把剩下的补完
    call(client, skip_segments._run_library_job, ctx, {"library_id": ids["tv"]})
    states = call(client, _states)
    assert len(states) == 8 and all(s.analyzed_at is not None for s in states.values())


def test_ingest_style_priority_job_takes_newest_first(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    ids = call(client, _seed, tmp_path, 6)
    monkeypatch.setattr(skip_segments, "PRIORITY_BATCH", 3)

    # 没有「在看哪一集」时先读最新入库的（入库触发）：给第 2、4、6 集一个更新的入库时间
    async def _touch_created() -> None:
        from datetime import timedelta

        async with get_database().session() as session:
            for rank, n in enumerate((2, 4, 6), start=1):
                row = await session.get(LibraryFile, ids["files"][n - 1])
                row.created_at = row.created_at + timedelta(hours=rank)
                session.add(row)
            await session.commit()

    call(client, _touch_created)
    call(
        client,
        skip_segments._run_item_job,
        _Ctx(),
        {"media_item_id": ids["show"], "season_number": None, "episode_number": None},
    )
    done = sorted(n for n, fid in enumerate(ids["files"], start=1) if fid in call(client, _states))
    assert done == [2, 4, 6], done


def test_stale_clients_do_not_count_as_watching(client: TestClient, tmp_path: Path) -> None:
    """浏览器被直接杀掉 / App 崩了不会发「停止」：会话超过新鲜窗口没有动静就不再算在看，
    回填不用白等好几分钟。暂停中的、从没动静的都不算。"""
    ids = call(client, _seed, tmp_path)
    device = ClientInfo(name="测试播放器", device_id="dev-fresh")
    unit = (ids["show"], 1, 1)

    async def scenario():
        import time as _time

        activity.reset()
        assert not skip_segments.playback_active()
        activity.report_progress(
            "dev-fresh", member_id=0, client=device, unit=unit, position_ms=1000, paused=False
        )
        assert skip_segments.playback_active(), "刚上报过进度的未暂停会话算在看"
        activity.report_progress(
            "dev-fresh", member_id=0, client=device, unit=unit, position_ms=1000, paused=True
        )
        assert not skip_segments.playback_active(), "暂停了不算"
        activity.report_progress(
            "dev-fresh", member_id=0, client=device, unit=unit, position_ms=2000, paused=False
        )
        assert skip_segments.playback_active()
        # 上报停了 60 秒：浏览器没了
        activity.current("dev-fresh").last_activity_mono = _time.monotonic() - 60
        assert not skip_segments.playback_active(), "超过新鲜窗口没动静就不算在看"
        activity.reset()

    call(client, scenario)


def test_detection_subprocess_inherits_parents_module_search_path(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """应用内更新的 overlay 是父进程启动后才加进 sys.path 的：识别子进程必须显式继承，
    否则在 overlay 布局里它只看得到镜像里那份旧代码（甚至找不到本模块）。"""
    overlay = str(tmp_path / "overlay-src")
    monkeypatch.syspath_prepend(overlay)
    captured: dict = {}
    real = asyncio.create_subprocess_exec

    async def spy(*args, **kwargs):
        captured["env"] = kwargs.get("env")
        return await real(*args, **kwargs)

    monkeypatch.setattr(asyncio, "create_subprocess_exec", spy)
    response = call(client, skip_segments._run_detection, [])
    assert response["results"] == {} and response["unreadable"] == []
    assert captured["env"] is not None
    assert overlay in captured["env"]["PYTHONPATH"].split(os.pathsep)


def test_concurrent_analyses_never_fingerprint_the_same_file_twice(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """同一季有两个作业并行（入库的条目作业 + 整库回填）：排到 ffmpeg 槽之后要复查还需不需要算，
    不然前一个刚算完的文件后一个手里过时的清单会让它再读一遍盘。"""
    ids = call(client, _seed, tmp_path, 4)
    reads: list[tuple[str, float]] = []
    real = skip_segments._chromaprint_window

    async def counting(path: str, start: float, length: float) -> bytes:
        reads.append((path, start))
        await asyncio.sleep(0.05)
        return await real(path, start, length)

    monkeypatch.setattr(skip_segments, "_chromaprint_window", counting)

    async def both():
        return await asyncio.gather(
            skip_segments.analyze_season(ids["show"], 1),
            skip_segments.analyze_season(ids["show"], 1),
        )

    first, second = call(client, both)
    assert len(reads) == 8, f"4 个文件 × 片头 / 片尾两个窗口，每个只读一次：{len(reads)}"
    assert first.fingerprinted + second.fingerprinted == 4
    assert all(s.analyzed_at is not None for s in call(client, _states).values())


def test_unreadable_fingerprint_is_requeued_without_losing_stored_result(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """指纹在比对时读不了：保留存储结果，暂不下发，并排队重建而不是永久忽略。"""
    ids = call(client, _seed, tmp_path)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    victim = ids["files"][1]
    before = start_session(client, victim)["segments"]
    assert len(before) == 2
    stored_before = call(client, _states)[victim].segments
    monkeypatch.setattr(skip_segments, "schedule_playback_bump", lambda _: None)
    real = skip_segments._run_detection

    async def detection_that_cannot_read_one(episodes):
        response = await real(episodes)
        response["unreadable"] = [victim]
        response["results"].pop(str(victim), None)
        return response

    monkeypatch.setattr(skip_segments, "_run_detection", detection_that_cannot_read_one)

    async def force_reanalysis() -> None:
        async with get_database().session() as session:
            for file_id in ids["files"]:
                row = await session.get(MediaSegmentState, file_id)
                row.analyzed_at = None
                session.add(row)
            await session.commit()

    call(client, force_reanalysis)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    state = call(client, _states)[victim]
    assert state.fingerprint_status == "pending" and state.segments == stored_before
    assert start_session(client, victim)["segments"] == []
    assert len(start_session(client, ids["files"][0])["segments"]) == 2
    monkeypatch.setattr(skip_segments, "_run_detection", real)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    assert start_session(client, victim)["segments"] == before


def test_enqueue_after_scan_only_acts_when_files_were_imported(
    client: TestClient, tmp_path: Path
) -> None:
    """监听触发的增量扫描 / 暂缓补扫直接调 scan_library：只有这一轮真有新文件入账才去看有没有待办。
    没入账任何东西（事件抖动）、结果不是扫描摘要（测试替身返回 None）都不碰数据库、不排作业。"""
    ids = call(client, _seed, tmp_path)

    class Summary:
        scanned = 0
        retried = 0

    assert call(client, skip_segments.enqueue_after_scan, ids["tv"], None) is False
    assert call(client, skip_segments.enqueue_after_scan, ids["tv"], Summary()) is False
    Summary.scanned = 2
    assert call(client, skip_segments.enqueue_after_scan, ids["tv"], Summary()) is True
    Summary.scanned, Summary.retried = 0, 1
    assert call(client, skip_segments.enqueue_after_scan, ids["tv"], Summary()) is True


async def _seed_backfill_order(tmp_path: Path) -> dict[str, int]:
    """五部剧，覆盖整库回填排序的每一档（见 seasons_needing_work）。"""
    from datetime import date, timedelta

    from movieclaw_db.models import MediaMetadata, MediaSeason, PlaybackState, utcnow

    root = tmp_path / "tv"
    async with get_database().session() as session:
        tv = await LibraryRepository(session).create(name="剧集", kind="tv", root_paths=[str(root)])
        shows = {
            # 名字: (首播日期, 库里有的季)
            "追剧中": (date(2023, 1, 1), [1, 2, 3]),
            "新剧": (date(2024, 1, 1), [1, 2]),
            "老剧": (date(2020, 1, 1), [1]),
            "已看完": (date(2022, 1, 1), [1]),
            "弃剧": (date(2021, 1, 1), [1]),
        }
        ids: dict[str, int] = {}
        for n, (title, (aired, seasons)) in enumerate(shows.items(), start=10):
            item = MediaItem(kind="tv", tmdb_id=n, title=title, original_title=title)
            session.add(item)
            await session.flush()
            ids[title] = int(item.id)
            session.add(MediaMetadata(media_item_id=item.id, release_date=aired))
            for season in seasons:
                for episode in (1, 2):
                    path = root / title / f"S{season:02d}E{episode:02d}.mp4"
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"FAKE-MEDIA")
                    session.add(
                        LibraryFile(
                            library_id=tv.id,
                            media_item_id=item.id,
                            season_number=season,
                            episode_number=episode,
                            file_path=str(path),
                            size_bytes=path.stat().st_size,
                            source=FileSource.SCANNED,
                            state=FileState.IN_PLACE,
                            container="mp4",
                            video_codec="h264",
                            resolution="1080p",
                            duration_seconds=DURATION,
                            audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
                        )
                    )
        # 「新剧」第 2 季是今年新出的一季：季首播日期压过剧的首播日期
        session.add(
            MediaSeason(media_item_id=ids["新剧"], season_number=2, air_date=date(2026, 5, 1))
        )
        now = utcnow()
        watched = [
            ("追剧中", 1, 1, True, now - timedelta(days=1)),  # 第 1 季看了一半
            ("已看完", 1, 1, True, now - timedelta(days=2)),
            ("已看完", 1, 2, True, now - timedelta(days=2)),
            ("弃剧", 1, 1, False, now - timedelta(days=90)),
        ]
        for title, season, episode, played, at in watched:
            session.add(
                PlaybackState(
                    media_item_id=ids[title],
                    season_number=season,
                    episode_number=episode,
                    played=played,
                    last_played_at=at,
                )
            )
        await session.commit()
        ids["tv"] = int(tv.id)
        return ids


def test_backfill_order_puts_what_the_user_will_watch_first(
    client: TestClient, tmp_path: Path
) -> None:
    """在追的季 → 下一季 → 没看过的剧的第一季（新上映在前）→ 其余 → 看完 / 弃了的剧。"""
    ids = call(client, _seed_backfill_order, tmp_path)
    order = call(client, _needing, library_id=ids["tv"])
    assert order == [
        (ids["追剧中"], 1),  # 正在追
        (ids["追剧中"], 2),  # 追剧的下一季
        (ids["新剧"], 1),  # 没看过的剧的第一季，2024 年的在前
        (ids["老剧"], 1),
        (ids["新剧"], 2),  # 其余季按季首播：2026 年的新一季
        (ids["追剧中"], 3),  # 2023
        (ids["已看完"], 1),  # 看完了（2022）
        (ids["弃剧"], 1),  # 90 天没碰（2021）
    ]


def test_backfill_resorts_after_every_season(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """作业中途开始追的剧，下一季就被提到最前，不用等整轮做完。"""
    from movieclaw_db.models import PlaybackState, utcnow

    ids = call(client, _seed_backfill_order, tmp_path)
    done: list[tuple[int, int]] = []

    async def fake_analyze(item_id, season, **_kwargs):
        done.append((item_id, season))
        if len(done) == 1:
            # 第一季做完时有人开始看「老剧」
            async with get_database().session() as session:
                session.add(
                    PlaybackState(
                        media_item_id=ids["老剧"],
                        season_number=1,
                        episode_number=1,
                        last_played_at=utcnow(),
                    )
                )
                await session.commit()
        async with get_database().session() as session:
            for f in (
                await session.execute(
                    select(LibraryFile).where(
                        LibraryFile.media_item_id == item_id, LibraryFile.season_number == season
                    )
                )
            ).scalars():
                session.add(
                    MediaSegmentState(
                        library_file_id=f.id,
                        fingerprint_status="ok",
                        source_size=f.size_bytes,
                        algo_version=skip_segments.ALGO_VERSION,
                        analyzed_at=utcnow(),
                    )
                )
            await session.commit()
        return skip_segments.SeasonOutcome()

    monkeypatch.setattr(skip_segments, "analyze_season", fake_analyze)

    async def find(session):
        return await skip_segments.seasons_needing_work(session, library_id=ids["tv"])

    call(client, skip_segments._run_seasons, _Ctx(), find, subject="测试")
    assert done[:2] == [(ids["追剧中"], 1), (ids["老剧"], 1)]
    assert len(done) == 8


def test_first_segment_near_file_start_is_served_from_zero(
    client: TestClient, tmp_path: Path
) -> None:
    """片头前只有几秒台标时，下发的第一段从 0 开始：开播就给「跳过」。库里存的原值不变。"""
    ids = call(client, _seed, tmp_path)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    first, second = ids["files"][0], ids["files"][1]

    async def set_segments(file_id: int, start_ms: int) -> None:
        async with get_database().session() as session:
            state = await session.get(MediaSegmentState, file_id)
            state.segments = [
                {"type": "other", "start_ms": start_ms, "end_ms": 33_000, "to_end": False},
                {"type": "intro", "start_ms": 270_000, "end_ms": 370_000, "to_end": False},
            ]
            await session.commit()

    call(client, set_segments, first, 7_678)
    call(client, set_segments, second, 20_000)
    near = start_session(client, first)["segments"]
    assert [s["start_ms"] for s in near] == [0, 270_000]
    assert near[0]["end_ms"] == 33_000
    # 离开头超过 15 秒的不动
    assert start_session(client, second)["segments"][0]["start_ms"] == 20_000
    assert call(client, _states)[first].segments[0]["start_ms"] == 7_678


def test_replaced_source_hides_old_segments_until_reanalysis(client, tmp_path) -> None:
    """洗版已被扫描入账：重算前、新指纹写完但还没比对时，都不能沿用旧时间点。"""
    ids = call(client, _seed, tmp_path, 3)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    victim = ids["files"][0]

    async def replace_source():
        async with get_database().session() as session:
            file = await session.get(LibraryFile, victim)
            with Path(file.file_path).open("ab") as out:
                out.write(b"REPLACED-SOURCE")
            file.size_bytes = Path(file.file_path).stat().st_size
            await session.commit()

    async def served():
        async with get_database().session() as session:
            file = await session.get(LibraryFile, victim)
            return await skip_segments.segments_for_file(session, file)

    async def fingerprint():
        async with get_database().session() as session:
            file = await session.get(LibraryFile, victim)
        return await skip_segments._fingerprint_one(file)

    assert call(client, served)
    call(client, replace_source)
    assert call(client, served) == [], "新片源不能使用旧时间点"
    assert call(client, fingerprint) == "ok"
    assert call(client, served) == [], "只更新指纹不代表旧时间点已经适用于新片源"
    call(client, skip_segments.analyze_season, ids["show"], 1)
    assert call(client, served), "重算完成后恢复下发"


def test_limited_analysis_excludes_fingerprints_from_replaced_sources(
    client, tmp_path, monkeypatch
) -> None:
    """有读取预算时，尚未轮到重算的旧片源指纹不能混进本轮整季比对。"""
    ids = call(client, _seed, tmp_path, 4)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    victim = ids["files"][0]

    async def expire():
        async with get_database().session() as session:
            file = await session.get(LibraryFile, victim)
            file.size_bytes += 1
            for file_id in ids["files"]:
                state = await session.get(MediaSegmentState, file_id)
                state.algo_version = skip_segments.ALGO_VERSION - 1
            await session.commit()

    call(client, expire)
    included = []
    real = skip_segments._run_detection

    async def capture(episodes):
        included.extend(e["file_id"] for e in episodes)
        return await real(episodes)

    monkeypatch.setattr(skip_segments, "_run_detection", capture)
    call(client, skip_segments.analyze_season, ids["show"], 1, max_new=0)
    assert included == ids["files"][1:]
    assert call(client, _states)[victim].algo_version == skip_segments.ALGO_VERSION - 1


def test_algorithm_upgrade_reuses_existing_fingerprints(client, tmp_path, monkeypatch) -> None:
    """算法升级只重做比对，不为这次修复重新读取整库媒体。"""
    ids = call(client, _seed, tmp_path, 3)
    call(client, skip_segments.analyze_season, ids["show"], 1)

    async def expire():
        async with get_database().session() as session:
            for file_id in ids["files"]:
                state = await session.get(MediaSegmentState, file_id)
                state.algo_version = skip_segments.ALGO_VERSION - 1
            await session.commit()

    async def unexpected_read(*_args):
        pytest.fail("算法升级不应重新提取已有指纹")

    call(client, expire)
    assert call(client, _needing) == [(ids["show"], 1)]
    bumped = []
    monkeypatch.setattr(
        skip_segments, "schedule_playback_bump", lambda file: bumped.append(file.id)
    )
    assert start_session(client, ids["files"][0])["segments"] == [], "重算前不下发旧算法区间"
    assert bumped == [ids["files"][0]], "旧结果撤下后开播应触发优先重算"
    monkeypatch.setattr(skip_segments, "_chromaprint_window", unexpected_read)
    result = call(client, skip_segments.analyze_season, ids["show"], 1)
    assert result.analyzed and result.fingerprinted == 0
    assert call(client, _needing) == []
    assert all(s.algo_version == skip_segments.ALGO_VERSION for s in call(client, _states).values())


def test_old_detection_cannot_overwrite_new_fingerprint(client, tmp_path, monkeypatch) -> None:
    """整季比对在子进程里跑；返回前别的作业已重算洗版文件，旧结果不能覆盖新状态。"""
    ids = call(client, _seed, tmp_path, 3)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    victim = ids["files"][0]
    real = skip_segments._run_detection

    async def expire():
        async with get_database().session() as session:
            state = await session.get(MediaSegmentState, victim)
            state.analyzed_at = None
            await session.commit()

    async def delayed(episodes):
        result = await real(episodes)
        async with get_database().session() as session:
            file = await session.get(LibraryFile, victim)
            file.size_bytes += 1
            await session.commit()
        await skip_segments._fingerprint_one(file)
        return result

    call(client, expire)
    monkeypatch.setattr(skip_segments, "_run_detection", delayed)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    state = call(client, _states)[victim]
    assert state.segments is None and state.analyzed_at is None
    assert call(client, _needing) == [(ids["show"], 1)]
    monkeypatch.setattr(skip_segments, "_run_detection", real)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    assert call(client, _states)[victim].segments
    assert call(client, _needing) == []


def test_audio_reselection_rebuilds_cache_and_withdraws_old_segments(
    client: TestClient, tmp_path: Path, monkeypatch
) -> None:
    """相同文件换用完整音轨也会改变时间点，不能继续下发旧轨识别的区间。"""
    ids = call(client, _seed, tmp_path)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    file_id = ids["files"][0]

    async def load_file():
        async with get_database().session() as session:
            file = await session.get(LibraryFile, file_id)
            file.audio_streams = [{"codec": "eac3"}, {"codec": "aac"}]
            session.add(file)
            await session.commit()
            return file

    file = call(client, load_file)
    path = skip_segments.fingerprint_path(file_id)
    head, _, body = path.read_bytes().partition(b"\n")
    meta = json.loads(head)
    meta.pop("audio_selection_version")
    path.write_bytes(json.dumps(meta).encode() + b"\n" + body)
    state = call(client, _states)[file_id]
    assert state.segments and skip_segments._fingerprint_due(file, state)

    async def select_audio(_file):
        return 1

    calls = []

    async def alternate_window(path, start, length, audio_index=0):
        calls.append(audio_index)
        return await fake_window(path, start, length)

    monkeypatch.setattr(skip_segments, "_fingerprint_audio_index", select_audio)
    monkeypatch.setattr(skip_segments, "_chromaprint_window", alternate_window)
    assert call(client, skip_segments._fingerprint_one, file) == "ok"
    assert calls == [1, 1]
    state = call(client, _states)[file_id]
    assert state.segments is None and state.analyzed_at is None
    assert not skip_segments._fingerprint_due(file, state)
    refreshed = json.loads(path.read_bytes().split(b"\n", 1)[0])
    assert refreshed["audio_index"] == 1


@pytest.mark.parametrize("kind", ["ad", "preview", "other"])
def test_playback_session_preserves_explicit_segment_types(client, tmp_path, kind) -> None:
    """类型由服务端下发，客户端不可将广告/预告/未知段重新猜成片头。"""
    ids = call(client, _seed, tmp_path, 3)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    file_id = ids["files"][0]
    segment = {"type": kind, "start_ms": 30_000, "end_ms": 50_000, "to_end": False}

    async def save():
        async with get_database().session() as session:
            state = await session.get(MediaSegmentState, file_id)
            state.segments = [segment]
            await session.commit()

    call(client, save)
    assert start_session(client, file_id)["segments"] == [segment]


@pytest.fixture
def startup_recovery_probe(monkeypatch):
    calls = []

    async def recover():
        calls.append(True)

    monkeypatch.setattr(skip_segments, "enqueue_pending_libraries", recover, raising=False)
    return calls


@pytest.fixture
def startup_client(startup_recovery_probe, client):
    return client, startup_recovery_probe


def test_application_start_enqueues_segment_recovery(startup_client) -> None:
    """真正进入应用 lifespan；无须库扫描或开播就检查存量识别任务。"""
    client, calls = startup_client
    # 在应用自己的事件循环让出一轮，允许非阻塞启动任务完成。
    call(client, asyncio.sleep, 0)
    assert calls == [True]


def test_limited_upgrade_does_not_mark_old_audio_cache_current(client, tmp_path, monkeypatch):
    """读盘预算不足时旧多音轨缓存不能参与比对并被盖上新版已完成的标记。"""
    ids = call(client, _seed, tmp_path, 4)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    victim = ids["files"][0]

    async def expire():
        async with get_database().session() as session:
            file = await session.get(LibraryFile, victim)
            file.audio_streams = [{"codec": "eac3"}, {"codec": "aac"}]
            for file_id in ids["files"]:
                state = await session.get(MediaSegmentState, file_id)
                state.algo_version = skip_segments.ALGO_VERSION - 1
            await session.commit()

    call(client, expire)
    path = skip_segments.fingerprint_path(victim)
    head, _, body = path.read_bytes().partition(b"\n")
    meta = json.loads(head)
    meta.pop("audio_selection_version")
    path.write_bytes(json.dumps(meta).encode() + b"\n" + body)
    included = []
    real = skip_segments._run_detection

    async def capture(episodes):
        included.extend(e["file_id"] for e in episodes)
        return await real(episodes)

    monkeypatch.setattr(skip_segments, "_run_detection", capture)
    call(client, skip_segments.analyze_season, ids["show"], 1, max_new=0)
    assert victim not in included
    assert call(client, _states)[victim].algo_version != skip_segments.ALGO_VERSION
    assert call(client, _needing) == [(ids["show"], 1)], "必须留在待重算清单中"


def test_startup_recovery_only_queues_stale_enabled_library_once(client, tmp_path, monkeypatch):
    """真实数据库 + 持久化任务：当前版本/关闭的库不排队，旧版本同库只排一份。"""
    # 先停自动派发，精确检查启动恢复产生的持久化队列，再调用真实库处理器验证完成。
    call(client, jobs.close_job_dispatcher)
    ids = call(client, _seed, tmp_path, 3)
    call(client, skip_segments.analyze_season, ids["show"], 1)

    async def queued():
        async with get_database().session() as session:
            return await jobs.list_jobs(session, job_type=skip_segments.LIBRARY_JOB_TYPE)

    async def set_version_and_switch(version, enabled):
        async with get_database().session() as session:
            repo = LibraryRepository(session)
            library = await repo.get(ids["tv"])
            library.detect_media_segments = enabled
            for file_id in ids["files"]:
                state = await session.get(MediaSegmentState, file_id)
                state.algo_version = version
            await session.commit()

    call(client, skip_segments.enqueue_pending_libraries)
    assert call(client, queued) == []
    call(client, set_version_and_switch, skip_segments.ALGO_VERSION - 1, False)
    call(client, skip_segments.enqueue_pending_libraries)
    assert call(client, queued) == []
    call(client, set_version_and_switch, skip_segments.ALGO_VERSION - 1, True)
    call(client, skip_segments.enqueue_pending_libraries)
    call(client, skip_segments.enqueue_pending_libraries)
    queued_jobs = call(client, queued)
    assert len(queued_jobs) == 1
    assert queued_jobs[0].priority == -10
    assert queued_jobs[0].input_data == {"library_id": ids["tv"]}

    async def unexpected_read(*_args):
        pytest.fail("单音轨算法升级只比较已有指纹，不应读原片")

    monkeypatch.setattr(skip_segments, "_chromaprint_window", unexpected_read)
    outcome = call(client, skip_segments._run_library_job, _Ctx(), {"library_id": ids["tv"]})
    assert outcome["fingerprinted"] == 0
    assert call(client, _needing) == []
    assert start_session(client, ids["files"][0])["segments"], "新算法完成后恢复跳过提示"


@pytest.mark.parametrize("newer_finishes_first", [True, False])
def test_older_season_result_cannot_overwrite_newer_consensus(
    client, tmp_path, monkeypatch, newer_finishes_first
):
    """旧任务返回前另一集换音轨并完成重算：其他集的旧共识也不能覆盖新共识。"""
    ids = call(client, _seed, tmp_path, 3)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    victim = ids["files"][0]
    real = skip_segments._run_detection
    nested = False
    newer_input_ready = asyncio.Event()
    release_newer = asyncio.Event()
    newer_task = None

    async def expire():
        async with get_database().session() as session:
            state = await session.get(MediaSegmentState, victim)
            state.analyzed_at = None
            await session.commit()

    async def unique_audio(path, start, length):
        rng = np.random.default_rng(314159 + int(start))
        return rng.integers(0, 2**32, int(length / HASH_SECONDS), dtype=np.uint32).tobytes()

    async def delayed(episodes):
        nonlocal nested, newer_task
        response = await real(episodes)
        if nested:
            newer_input_ready.set()
            if not newer_finishes_first:
                await release_newer.wait()
        else:
            nested = True
            async with get_database().session() as session:
                file = await session.get(LibraryFile, victim)
                with Path(file.file_path).open("ab") as stream:
                    stream.write(b"replacement")
                file.size_bytes = Path(file.file_path).stat().st_size
                await session.commit()
            monkeypatch.setattr(skip_segments, "_chromaprint_window", unique_audio)
            await skip_segments._fingerprint_one(file)
            if newer_finishes_first:
                await skip_segments.analyze_season(ids["show"], 1)
            else:
                newer_task = asyncio.create_task(skip_segments.analyze_season(ids["show"], 1))
                await newer_input_ready.wait()
        return response

    call(client, expire)
    monkeypatch.setattr(skip_segments, "_run_detection", delayed)
    call(client, skip_segments.analyze_season, ids["show"], 1)

    async def finish_newer():
        if newer_task is not None:
            release_newer.set()
            await newer_task

    call(client, finish_newer)
    assert all(s.segments == [] for s in call(client, _states).values()), (
        "三集中一集换成独有音轨，不再有两票支持；无论完成顺序如何，都应保留新共识"
    )
    assert call(client, _needing) == []


def test_truncated_fingerprint_is_rebuilt_in_library_job(client, tmp_path, monkeypatch):
    """实际截断 .fp，保留正确 JSON 头：不能把缺失的音频数据当成“本集没有片头”。"""
    ids = call(client, _seed, tmp_path, 4)
    call(client, skip_segments.analyze_season, ids["show"], 1)
    victim = ids["files"][0]
    path = skip_segments.fingerprint_path(victim)
    good = path.read_bytes()
    path.write_bytes(good.split(b"\n", 1)[0] + b"\n")

    async def expire():
        async with get_database().session() as session:
            state = await session.get(MediaSegmentState, victim)
            state.algo_version = skip_segments.ALGO_VERSION - 1
            await session.commit()

    call(client, expire)
    outcome = call(client, skip_segments._run_library_job, _Ctx(), {"library_id": ids["tv"]})
    assert outcome["fingerprinted"] == 1
    assert path.read_bytes() == good
    assert call(client, _states)[victim].segments
    assert call(client, _needing) == []

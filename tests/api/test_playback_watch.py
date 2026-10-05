"""网页播放器的观看状态与策略端点测试（docs/design/web-player.md §6.5 / §3.6）。

阈值三分支本身由 ``tests/`` 里的进度单测覆盖，这里测 HTTP 边界上真正会出事的
四件事：**续播点往返**、**片长由服务端算**（客户端报什么都不影响已看判定）、
**不可见库的单元一律 404**、**策略增量保存不覆盖别的字段**。
"""

from __future__ import annotations

import itertools
from functools import partial
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import FileSource, FileState, LibraryFile, MediaItem
from movieclaw_db.repositories.library_repo import LibraryRepository

_PB = "/api/v1/playback"
_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}
_MEMBER = {"username": "family", "password": "family-pass-1"}

#: 播放单元的片长：10 分钟。已看阈值 90% → 540 秒是分界线。
_DURATION_S = 600


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'watch.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    # 硬件探测不能在测试里真去摸 /dev/dri
    monkeypatch.setattr(
        "movieclaw_api.api.routes.playback.available_backends", lambda: ()
    )
    # 关键帧探测：假媒体读不出关键帧会返回 None，换了非默认音轨（要重封装）的用例
    # 就被保守降到转码档、要求同意——测不到记忆轨。给它一个正常 GOP 的值
    # （同 test_playback_stream）。
    monkeypatch.setattr(
        "movieclaw_api.services.playback.plan.probe_keyframe_interval",
        lambda path, duration: 4.0,
    )

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


_seed_counter = itertools.count(1)


async def _seed(tmp_path: Path) -> tuple[int, int]:
    """建库 + 建条目 + 落一个在位文件，返回 (library_id, media_item_id)。"""
    n = next(_seed_counter)
    media_root = tmp_path / f"movies{n}"
    media_root.mkdir(exist_ok=True)
    path = media_root / f"movie{n}.mp4"
    path.write_bytes(b"FAKE-MEDIA-BYTES" * 64)
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name=f"电影库{n}", kind="movie", root_paths=[str(media_root)]
        )
        item = MediaItem(
            kind="movie", tmdb_id=n, title=f"示例{n}", original_title=f"Example{n}"
        )
        session.add(item)
        await session.flush()
        session.add(
            LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(path),
                size_bytes=path.stat().st_size,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                container="mp4",
                video_codec="h264",
                resolution="1080p",
                duration_seconds=_DURATION_S,
                audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
            )
        )
        await session.commit()
        return library.id, item.id


def seed(client: TestClient, tmp_path: Path) -> tuple[int, int]:
    return client.portal.call(partial(_seed, tmp_path))  # type: ignore[attr-defined]


def report(client: TestClient, item_id: int, **body) -> dict:
    resp = client.post(f"{_PB}/progress", json={"media_item_id": item_id, **body})
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def resume(client: TestClient, item_id: int) -> dict:
    resp = client.get(f"{_PB}/resume", params={"media_item_id": item_id})
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


# ---------------------------------------------------------------------------
# 续播点
# ---------------------------------------------------------------------------


def test_never_played_unit_resumes_from_zero(client, tmp_path):
    """从未播过不是错误——给全零状态，播放器从头放。"""
    _, item_id = seed(client, tmp_path)
    assert resume(client, item_id) == {
        "position_ms": 0,
        "played": False,
        "play_count": 0,
        "duration_ms": _DURATION_S * 1000,
        "audio_track": None,
        "subtitle_track": None,
        "ended_by_admin": False,
    }


def test_start_then_progress_round_trips_resume_point(client, tmp_path):
    """开播计数、心跳记位置、续播读回来——播放器最核心的一条往返。"""
    _, item_id = seed(client, tmp_path)
    started = report(client, item_id, event="start")
    assert started["play_count"] == 1

    report(client, item_id, event="progress", position_ms=300_000)  # 50%
    state = resume(client, item_id)
    assert state["position_ms"] == 300_000
    assert state["played"] is False
    assert state["play_count"] == 1


def test_watching_past_threshold_marks_played_and_clears_resume(client, tmp_path):
    """播过 90% 即已看，续播点清零——下次点开是重看而不是跳到片尾。"""
    _, item_id = seed(client, tmp_path)
    report(client, item_id, event="start")
    stopped = report(client, item_id, event="stop", position_ms=570_000)  # 95%
    assert stopped["played"] is True
    assert stopped["position_ms"] == 0


def test_runtime_comes_from_server_not_client(client, tmp_path):
    """已看判定的分母是服务端算的片长。

    客户端只报位置、报不了片长——同一部片在网页端和 Jellyfin 客户端才会给出
    一致的已看结论。这里用「按客户端谎报的短片长算就该已看、按真片长算不该」
    的位置来验：300 秒是真片长的 50%，不能被判成已看。
    """
    _, item_id = seed(client, tmp_path)
    state = report(client, item_id, event="progress", position_ms=300_000)
    assert state["played"] is False
    assert state["duration_ms"] == _DURATION_S * 1000


def test_track_selection_is_remembered_and_partial_reports_keep_it(client, tmp_path):
    """轨记忆：报了就改，没报的项保持原值（心跳可能只报进度不报轨）。"""
    _, item_id = seed(client, tmp_path)
    report(
        client,
        item_id,
        event="start",
        audio_track="embedded:1",
        subtitle_track="external:zh.srt",
    )
    report(client, item_id, event="progress", position_ms=120_000)
    state = resume(client, item_id)
    assert state["audio_track"] == "embedded:1"
    assert state["subtitle_track"] == "external:zh.srt"

    report(client, item_id, event="progress", position_ms=180_000, subtitle_track="off")
    state = resume(client, item_id)
    assert state["subtitle_track"] == "off"
    assert state["audio_track"] == "embedded:1"  # 没报的音轨没被清掉


async def _set_tracks(item_id: int, **fields) -> int:
    """改种子文件的轨（音轨 / 内封字幕 / 外挂字幕），返回文件 id。"""
    async with get_database().session() as session:
        file = (
            await session.execute(select(LibraryFile).where(LibraryFile.media_item_id == item_id))
        ).scalar_one()
        for key, value in fields.items():
            setattr(file, key, value)
        await session.commit()
        assert file.id is not None
        return file.id


_EN_ZH_AUDIO = [
    {"codec": "aac", "channels": 2, "language": "eng", "default": True},
    {"codec": "aac", "channels": 2, "language": "chi", "default": False},
]
_EN_ZH_SUBS = [
    {"codec": "subrip", "language": "eng", "default": False, "forced": False},
    {"codec": "subrip", "language": "chi", "default": True, "forced": False},
]


def test_only_choices_that_differ_from_the_default_are_remembered(client, tmp_path):
    """播放器报上来的是默认挑选（英语音轨、标了默认的中文字幕）：不记，交回默认策略；
    换过的照记；选回默认就清空。"""
    _, item_id = seed(client, tmp_path)
    client.portal.call(  # type: ignore[attr-defined]
        partial(_set_tracks, item_id, audio_streams=_EN_ZH_AUDIO,
                subtitle_streams=_EN_ZH_SUBS, external_subtitles=[])
    )
    report(client, item_id, event="start", audio_track="embedded:0", subtitle_track="embedded:1")
    state = resume(client, item_id)
    assert (state["audio_track"], state["subtitle_track"]) == (None, None)

    report(client, item_id, event="progress", position_ms=60_000,
           audio_track="embedded:1", subtitle_track="off")
    state = resume(client, item_id)
    assert (state["audio_track"], state["subtitle_track"]) == ("embedded:1", "off")

    report(client, item_id, event="stop", position_ms=90_000,
           audio_track="embedded:0", subtitle_track="embedded:1")
    state = resume(client, item_id)
    assert (state["audio_track"], state["subtitle_track"]) == (None, None)


async def _add_version(item_id: int, audio_streams: list[dict]) -> int:
    """给同一部片再落一个在位版本（多版本），返回它的文件 id。"""
    async with get_database().session() as session:
        first = (
            await session.execute(select(LibraryFile).where(LibraryFile.media_item_id == item_id))
        ).scalar_one()
        version = LibraryFile(
            library_id=first.library_id,
            media_item_id=item_id,
            file_path=first.file_path + ".v2.mkv",
            size_bytes=1,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="mkv",
            duration_seconds=_DURATION_S,
            audio_streams=audio_streams,
        )
        session.add(version)
        await session.commit()
        assert version.id is not None
        return version.id


def test_the_version_being_played_decides_what_the_default_is(client, tmp_path):
    """两个版本默认音轨不同：同一条 embedded:1，在「默认是第 0 条」的版本上是用户换的，
    在「默认就是第 1 条」的版本上只是默认挑选——按上报的 file_id 对准正在放的版本。"""
    _, item_id = seed(client, tmp_path)
    first_id = client.portal.call(  # type: ignore[attr-defined]
        partial(_set_tracks, item_id, audio_streams=_EN_ZH_AUDIO)
    )
    zh_default = [
        {"codec": "aac", "channels": 2, "language": "eng", "default": False},
        {"codec": "aac", "channels": 2, "language": "chi", "default": True},
    ]
    second_id = client.portal.call(partial(_add_version, item_id, zh_default))  # type: ignore[attr-defined]

    report(client, item_id, event="start", audio_track="embedded:1", file_id=second_id)
    assert resume(client, item_id)["audio_track"] is None
    report(client, item_id, event="progress", position_ms=60_000,
           audio_track="embedded:1", file_id=first_id)
    assert resume(client, item_id)["audio_track"] == "embedded:1"


def test_judging_reported_tracks_adds_no_queries(client, tmp_path):
    """心跳很频繁：判断「是不是默认挑选」复用片长那次取文件，每次进度上报的 SQL 条数
    不因带不带轨、报的是不是默认轨而变。"""
    from sqlalchemy import event

    from movieclaw_api.services.library.search_index import close_search_index

    # 只统计播放心跳；名称索引的独立后台读写不能混进这三次请求的 SQL 条数。
    client.portal.call(close_search_index)
    _, item_id = seed(client, tmp_path)
    client.portal.call(  # type: ignore[attr-defined]
        partial(_set_tracks, item_id, audio_streams=_EN_ZH_AUDIO,
                subtitle_streams=_EN_ZH_SUBS, external_subtitles=[])
    )
    report(client, item_id, event="start")
    # 开始后的第一次心跳会多发一次事件（按单元节流），先走掉它，后面几次口径一致
    report(client, item_id, event="progress", position_ms=30_000)
    engine = get_database().engine.sync_engine

    def statements_for(**tracks) -> list[str]:
        captured: list[str] = []

        def capture(_conn, _cursor, statement, _parameters, _context, _executemany) -> None:
            captured.append(statement.split()[0].upper())

        event.listen(engine, "before_cursor_execute", capture)
        try:
            report(client, item_id, event="progress", position_ms=60_000 + len(captured), **tracks)
        finally:
            event.remove(engine, "before_cursor_execute", capture)
        return captured

    plain = statements_for()
    default_tracks = statements_for(audio_track="embedded:0", subtitle_track="embedded:1")
    changed_tracks = statements_for(audio_track="embedded:1", subtitle_track="off")
    assert len(default_tracks) == len(plain), (plain, default_tracks)
    assert len(changed_tracks) == len(plain), (plain, changed_tracks)


# ---------------------------------------------------------------------------
# 可见性
# ---------------------------------------------------------------------------


def _make_member(client: TestClient, *, library_ids: list[int]) -> None:
    """建一个成员并把可见库收成白名单（新建接口只收账号，白名单走编辑）。"""
    resp = client.post("/api/v1/members", json={**_MEMBER, "nickname": "家人"})
    assert resp.status_code == 200, resp.text
    member_id = resp.json()["data"]["id"]
    updated = client.put(
        f"/api/v1/members/{member_id}",
        json={"all_libraries": False, "library_ids": library_ids},
    )
    assert updated.status_code == 200, updated.text


def test_unit_outside_visible_libraries_is_not_found(client, tmp_path):
    """不可见库的播放单元：报进度和读续播点都 404，与「不存在」不可区分。"""
    _hidden_library_id, hidden_item_id = seed(client, tmp_path)
    visible_library_id, visible_item_id = seed(client, tmp_path)
    _make_member(client, library_ids=[visible_library_id])
    client.post("/api/v1/auth/logout")
    assert client.post("/api/v1/auth/login", json=_MEMBER).status_code == 200

    assert (
        client.get(f"{_PB}/resume", params={"media_item_id": hidden_item_id}).status_code
        == 404
    )
    assert (
        client.post(
            f"{_PB}/progress", json={"media_item_id": hidden_item_id, "event": "start"}
        ).status_code
        == 404
    )
    # 可见库里的同类单元照常可用——证明 404 来自可见性而不是别的原因
    assert resume(client, visible_item_id)["position_ms"] == 0


def test_progress_is_isolated_per_member(client, tmp_path):
    """各人看各的：成员的进度不会写进管理员的续播点。"""
    library_id, item_id = seed(client, tmp_path)
    _make_member(client, library_ids=[library_id])
    report(client, item_id, event="progress", position_ms=300_000)

    client.post("/api/v1/auth/logout")
    assert client.post("/api/v1/auth/login", json=_MEMBER).status_code == 200
    assert resume(client, item_id)["position_ms"] == 0

    report(client, item_id, event="progress", position_ms=120_000)
    assert resume(client, item_id)["position_ms"] == 120_000

    client.post("/api/v1/auth/logout")
    assert client.post("/api/v1/auth/login", json=_ADMIN).status_code == 200
    assert resume(client, item_id)["position_ms"] == 300_000


# ---------------------------------------------------------------------------
# 策略配置
# ---------------------------------------------------------------------------


def test_policy_defaults_and_hardware_is_probed_not_configured(client):
    data = client.get(f"{_PB}/policy").json()["data"]
    assert data["software_transcode_enabled"] is False  # 默认关闭（§3.6）
    assert data["hardware_available"] is False  # 实测结果，不是配置项
    assert data["hw_backends"] == []


def test_policy_saves_software_transcode_toggle(client):
    """同意弹窗翻开软转开关后要持久生效。"""
    data = client.put(
        f"{_PB}/policy", json={"software_transcode_enabled": True}
    ).json()["data"]
    assert data["software_transcode_enabled"] is True
    assert (
        client.get(f"{_PB}/policy").json()["data"]["software_transcode_enabled"] is True
    )


def test_policy_ignores_retired_limit_fields(client):
    """数字上限已撤为自动推导（limits.py）。旧版网页可能还带着这些字段来
    保存——忽略而不是 422，别把只想翻软转开关的老客户端挡在门外。"""
    resp = client.put(
        f"{_PB}/policy",
        json={"software_transcode_enabled": True, "max_transcode_concurrency": 4},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["software_transcode_enabled"] is True
    assert "max_transcode_concurrency" not in data


def test_policy_is_admin_only(client, tmp_path):
    library_id, _ = seed(client, tmp_path)
    _make_member(client, library_ids=[library_id])
    client.post("/api/v1/auth/logout")
    assert client.post("/api/v1/auth/login", json=_MEMBER).status_code == 200
    assert client.get(f"{_PB}/policy").status_code == 403
    assert client.put(f"{_PB}/policy", json={}).status_code == 403


# ---------------------------------------------------------------------------
# 续播并入开会话（§6.10：省掉起播链路里「先问 /resume 再开会话」的串行往返）
# ---------------------------------------------------------------------------

#: 与种子文件（h264/aac/mp4）匹配的能力：判成档 0 直出，不需要 ffmpeg
_CAPABILITY = {
    "video": [{"codec": "h264"}],
    "audio": [{"codec": "aac"}],
    "containers": ["mp4", "hls-fmp4"],
}


def start_session(client: TestClient, item_id: int, **extra) -> dict:
    resp = client.post(
        f"{_PB}/sessions",
        json={"media_item_id": item_id, "capability": _CAPABILITY, **extra},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def test_session_without_start_ms_resumes_from_stored_position(client, tmp_path):
    """start_ms 缺省 = 服务端接续播点，整份观看状态随响应带回。"""
    _, item_id = seed(client, tmp_path)
    report(client, item_id, event="progress", position_ms=120_000)

    data = start_session(client, item_id)
    assert data["start_ms"] == 120_000
    assert data["watch"]["position_ms"] == 120_000
    assert data["watch"]["duration_ms"] == _DURATION_S * 1000
    assert data["decision"]["tier"] == 0


def test_session_explicit_start_ms_wins_over_resume(client, tmp_path):
    """显式给值（含 0）原样照办：seek 重开与「从头播」都不受续播点干扰。"""
    _, item_id = seed(client, tmp_path)
    report(client, item_id, event="progress", position_ms=120_000)

    assert start_session(client, item_id, start_ms=0)["start_ms"] == 0
    assert start_session(client, item_id, start_ms=90_000)["start_ms"] == 90_000


def test_session_replays_finished_unit_from_zero(client, tmp_path):
    """看完的重播从头开始——续播到最后三十秒等于点开就是片尾。"""
    _, item_id = seed(client, tmp_path)
    report(client, item_id, event="stop", position_ms=570_000)  # 95% → 已看

    data = start_session(client, item_id)
    assert data["start_ms"] == 0
    assert data["watch"]["played"] is True


def test_rewatching_finished_unit_resumes_where_the_rewatch_stopped(client, tmp_path):
    """看完后重看到一半就强退（只发过心跳、没发停止），再点开要接着这次重看的位置。

    已看标记保留（不因重看被悄悄改成未看），但续播点不能因为「已看」被丢掉。
    """
    _, item_id = seed(client, tmp_path)
    report(client, item_id, event="start")
    report(client, item_id, event="stop", position_ms=570_000)  # 95% → 已看

    data = start_session(client, item_id)
    assert data["start_ms"] == 0  # 重看从头开始
    report(client, item_id, event="start")
    report(client, item_id, event="progress", position_ms=240_000)  # 40%，随后强退

    state = resume(client, item_id)
    assert state["played"] is True
    assert state["position_ms"] == 240_000
    data = start_session(client, item_id)
    assert data["start_ms"] == 240_000
    assert data["watch"]["played"] is True


def test_session_carries_remembered_tracks(client, tmp_path):
    """开会话把观看记忆整份带回（前端据此恢复字幕选择，省掉一次 /resume 往返）。

    记忆只记用户换过的轨。音轨换到非默认会让会话重封装（要起 ffmpeg），记忆音轨并入
    决策由 decide 的用例覆盖；这里用字幕：文件带默认中文字幕、用户关掉了——文本字幕
    不改变视频策略，会话仍是直出。
    """
    _, item_id = seed(client, tmp_path)
    client.portal.call(  # type: ignore[attr-defined]
        partial(_set_tracks, item_id, subtitle_streams=_EN_ZH_SUBS, external_subtitles=[])
    )
    report(client, item_id, event="start", subtitle_track="off")

    data = start_session(client, item_id)
    assert data["watch"]["subtitle_track"] == "off"
    assert data["watch"]["audio_track"] is None
    assert data["decision"]["audio"]["track_ref"] == "embedded:0"


async def _give_second_audio_track(item_id: int) -> None:
    """给种子文件补一条非默认音轨（同为 AAC，免得牵出转码），用来区分「记住的轨」与「默认轨」。"""
    async with get_database().session() as session:
        file = (
            await session.execute(select(LibraryFile).where(LibraryFile.media_item_id == item_id))
        ).scalar_one()
        file.audio_streams = [
            {"codec": "aac", "channels": 2, "default": True},
            {"codec": "aac", "channels": 2, "default": False},
        ]
        await session.commit()


def test_decide_applies_remembered_tracks_like_session_start(client, tmp_path):
    """decide 与开会话同一口径套用观看记忆（上次的音轨 / 字幕），显式指定的照旧优先。

    否则探测和真开会话判出两种计划：App 的自动选引擎按探测结果先开系统播放器
    会话，真开出来却是转码档（记住的 PGS 字幕要整片压制），再改走 MPV，白白
    拉起又掐掉一路转码（2026-09-27 NAS 实测）。
    """
    _, item_id = seed(client, tmp_path)
    client.portal.call(partial(_give_second_audio_track, item_id))  # type: ignore[attr-defined]
    report(client, item_id, event="start", audio_track="embedded:1")

    def decide(**extra) -> dict:
        resp = client.post(
            f"{_PB}/decide",
            json={"media_item_id": item_id, "capability": _CAPABILITY, **extra},
        )
        assert resp.status_code == 200, resp.text
        return resp.json()["data"]

    assert decide()["audio"]["track_ref"] == "embedded:1"
    assert decide(audio_track="embedded:0")["audio"]["track_ref"] == "embedded:0"


async def _seed_show(tmp_path: Path) -> int:
    """两集的剧：第 1 集英语在前、国语第 2 条，第 2 集国语挪到第 1 条；
    外挂字幕（中文、英文）文件名每集不同。

    第 2 集的国语恰是默认轨——换算后直出，开会话不牵出重封装（测试里没有 ffmpeg）。
    外挂字幕按文件名排序，中文在前，是默认字幕。
    """
    n = next(_seed_counter)
    root = tmp_path / f"show{n}"
    root.mkdir(exist_ok=True)
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name=f"剧集库{n}", kind="tv", root_paths=[str(root)]
        )
        show = MediaItem(kind="tv", tmdb_id=900 + n, title=f"追剧{n}", original_title="S")
        session.add(show)
        await session.flush()
        eng = {"codec": "aac", "channels": 2, "language": "eng", "default": True}
        chi = {"codec": "aac", "channels": 2, "language": "chi", "default": False}
        second = [{**chi, "default": True}, {**eng, "default": False}]
        for episode, audio in ((1, [eng, chi]), (2, second)):
            path = root / f"Show.S01E0{episode}.mp4"
            path.write_bytes(b"FAKE-MEDIA-BYTES" * 64)
            externals = []
            for tag, language in (("chs", "chi"), ("en", "eng")):
                name = f"Show.S01E0{episode}.{tag}.srt"
                (root / name).write_text("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
                externals.append({"filename": name, "format": "srt", "language": language,
                                  "title": None, "forced": False})
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=show.id,
                    season_number=1,
                    episode_number=episode,
                    file_path=str(path),
                    size_bytes=path.stat().st_size,
                    source=FileSource.SCANNED,
                    state=FileState.IN_PLACE,
                    container="mp4",
                    video_codec="h264",
                    resolution="1080p",
                    duration_seconds=_DURATION_S,
                    audio_streams=audio,
                    external_subtitles=externals,
                )
            )
        await session.commit()
        return show.id


def test_new_episode_inherits_the_series_track_choice(client, tmp_path):
    """第 1 集换成国语 + 英文字幕，第 2 集没看过：开会话按语言沿用（轨序、文件名都换算），
    并随观看状态带回，App 据此提示「已沿用上次的选择」。"""
    show_id = client.portal.call(partial(_seed_show, tmp_path))  # type: ignore[attr-defined]
    episode = {"season_number": 1, "episode_number": 1}
    report(client, show_id, event="start", audio_track="embedded:1",
           subtitle_track="external:Show.S01E01.en.srt", **episode)

    data = start_session(client, show_id, season_number=1, episode_number=2)
    assert data["decision"]["audio"]["track_ref"] == "embedded:0"
    assert data["watch"]["audio_track"] == "embedded:0"
    assert data["watch"]["subtitle_track"] == "external:Show.S01E02.en.srt"
    # 这次明确点了别的轨：照点的来
    resp = client.post(
        f"{_PB}/decide",
        json={"media_item_id": show_id, "season_number": 1, "episode_number": 2,
              "capability": _CAPABILITY, "audio_track": "embedded:1"},
    )
    assert resp.json()["data"]["audio"]["track_ref"] == "embedded:1"


# ---------------------------------------------------------------------------
# 播放页条目信息（§6.10 路由只带 media_item_id，库归属服务端解析）
# ---------------------------------------------------------------------------


def test_playback_item_info_resolves_library(client, tmp_path):
    library_id, item_id = seed(client, tmp_path)
    resp = client.get(f"{_PB}/items/{item_id}")
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["media_item_id"] == item_id
    assert data["library_id"] == library_id
    assert data["kind"] == "movie"
    assert data["title"].startswith("示例")


def test_playback_item_outside_visible_libraries_is_not_found(client, tmp_path):
    """不可见与不存在同样 404——与决策接口同一判据。"""
    _hidden_library_id, hidden_item_id = seed(client, tmp_path)
    visible_library_id, visible_item_id = seed(client, tmp_path)
    _make_member(client, library_ids=[visible_library_id])
    client.post("/api/v1/auth/logout")
    assert client.post("/api/v1/auth/login", json=_MEMBER).status_code == 200

    assert client.get(f"{_PB}/items/{hidden_item_id}").status_code == 404
    assert client.get(f"{_PB}/items/{visible_item_id}").status_code == 200
    assert client.get(f"{_PB}/items/99999").status_code == 404

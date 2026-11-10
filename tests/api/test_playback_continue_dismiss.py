"""真实 HTTP + SQLite：「接下来继续」隐藏（``dismiss_continue`` / ``continue_dismissed``）。

真实播放走 ``/playback/progress``（落 playback_state + playback_log），隐藏走
``/playback/sync/state``，结果从 ``/playback/up-next``（含 ``this_device``）、
``/playback/resume`` 与 sync catalog 读回——不直接摆状态行。
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from movieclaw_api.api.deps import require_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import DeviceRef, Principal, reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    Member,
    PlaybackLog,
    PlaybackState,
)
from movieclaw_db.repositories.library_repo import LibraryRepository

SYNC = "/api/v1/playback/sync"
ADMIN = Principal(kind="admin", name="admin")


@pytest.fixture
def env(tmp_path, monkeypatch):
    for key, value in {
        "DATABASE_URL": f"sqlite+aiosqlite:///{tmp_path / 'dismiss.db'}",
        "SECRET_KEY_FILE": str(tmp_path / ".secret_key"),
        "MOVIECLAW_DATA_DIR": str(tmp_path),
        "SITE_CONFIGS_DIR": str(tmp_path / "sites"),
        "SCHEDULER_ENABLED": "false",
    }.items():
        monkeypatch.setenv(key, value)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    from movieclaw_api.app import create_app

    app = create_app()
    who = {"p": ADMIN}
    app.dependency_overrides[require_login] = lambda: who["p"]
    with TestClient(app) as c:

        async def seed():
            async with get_database().session() as s:
                library = await LibraryRepository(s).create(
                    name="库", kind="movie", root_paths=[str(tmp_path)]
                )
                members = [
                    Member(id=1, username="one", password_hash="unused"),
                    Member(id=2, username="two", password_hash="unused"),
                ]
                s.add_all(members)
                movie = MediaItem(kind="movie", title="电影", original_title="M", tmdb_id=100)
                show = MediaItem(kind="tv", title="剧", original_title="T", tmdb_id=200)
                video = MediaItem(
                    source="local",
                    kind="video",
                    external_id="local-video-1",
                    tmdb_id=None,
                    imdb_id=None,
                    title="视频",
                    original_title="V",
                )
                s.add_all([movie, show, video])
                await s.flush()
                units = [(movie.id, 0, 0), (video.id, 0, 0)] + [(show.id, 1, e) for e in (1, 2, 3)]
                for item, season, episode in units:
                    s.add(
                        LibraryFile(
                            library_id=library.id,
                            media_item_id=item,
                            season_number=season,
                            episode_number=episode,
                            file_path=str(tmp_path / f"{item}-{season}-{episode}.mkv"),
                            size_bytes=1,
                            source=FileSource.SCANNED,
                            state=FileState.IN_PLACE,
                            duration_seconds=600,
                        )
                    )
                await s.commit()
                return {"movie": movie.id, "tv": show.id, "video": video.id}, {
                    m.id: m for m in members
                }

        ids, members = c.portal.call(seed)

        def as_member(member_id: int, device: int | None = None) -> Principal:
            ref = (
                DeviceRef(id=device, kind="ios", scope="full", name=f"d{device}")
                if device is not None
                else None
            )
            if member_id == 0:
                return Principal(kind="admin", name="admin", device=ref)
            return Principal(
                kind="member",
                name=members[member_id].username,
                member_id=member_id,
                is_admin=False,
                member=members[member_id],
                device=ref,
            )

        def call(principal, method, path, **kw):
            who["p"] = principal
            try:
                return getattr(c, method)(path, **kw)
            finally:
                who["p"] = ADMIN

        yield SimpleNamespace(c=c, ids=ids, as_member=as_member, call=call)
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


UNITS = {"movie": (0, 0), "video": (0, 0), "tv": (1, 2)}


def play(env, member, item, season, episode, position, *, device=5):
    p = env.as_member(member, device)
    body = {"media_item_id": item, "season_number": season, "episode_number": episode}
    r = env.call(p, "post", "/api/v1/playback/progress", json={**body, "event": "start"})
    assert r.status_code == 200, r.text
    r = env.call(
        p,
        "post",
        "/api/v1/playback/progress",
        json={**body, "event": "stop", "position_ms": position},
    )
    assert r.status_code == 200, r.text
    return r.json()["data"]


def up_next(env, member, *, device=None):
    params = {"this_device": "true"} if device is not None else {}
    r = env.call(env.as_member(member, device), "get", "/api/v1/playback/up-next", params=params)
    assert r.status_code == 200, r.text
    return [
        (i["media_item_id"], i["season_number"], i["episode_number"])
        for i in r.json()["data"]["items"]
    ]


def resume(env, member, item, season, episode):
    r = env.call(
        env.as_member(member),
        "get",
        "/api/v1/playback/resume",
        params={"media_item_id": item, "season_number": season, "episode_number": episode},
    )
    assert r.status_code == 200, r.text
    return r.json()["data"]


def catalog_unit(env, member, item, season, episode):
    r = env.c.get(
        SYNC + "/catalog", params={"member_id": member, "kinds": ["movie", "tv", "video"]}
    )
    assert r.status_code == 200, r.text
    items = r.json()["data"]["items"]
    assert all("continue_dismissed" in u for u in items)
    return next(
        u for u in items if (u["media"]["id"], u["season"], u["episode"]) == (item, season, episode)
    )


def write(env, member, unit, **fields):
    r = env.c.post(SYNC + "/state", json={"member_id": member, "changes": [change(unit, **fields)]})
    assert r.status_code == 200, r.text
    return r.json()["data"]["outcomes"][0]


def write_batch(env, member, changes):
    r = env.c.post(SYNC + "/state", json={"member_id": member, "changes": changes})
    assert r.status_code == 200, r.text
    return [o["status"] for o in r.json()["data"]["outcomes"]]


def change(unit, **fields):
    media = unit["media"]
    body = {
        "media_item_id": media["id"],
        "kind": media["kind"],
        "expected_updated_at": unit["updated_at"],
        **fields,
    }
    if media["tmdb_id"] is None and media["imdb_id"] is None:
        body["identity"] = media["identity"]
    else:
        body["tmdb_id"] = media["tmdb_id"]
    if media["kind"] == "tv":
        body.update(season=unit["season"], episode=unit["episode"])
    return body


def facts(env, member, item):
    async def run():
        async with get_database().session() as s:
            states = (
                await s.execute(
                    select(PlaybackState)
                    .where(PlaybackState.member_id == member, PlaybackState.media_item_id == item)
                    .order_by(PlaybackState.id)
                )
            ).scalars()
            logs = (
                await s.execute(
                    select(PlaybackLog)
                    .where(PlaybackLog.member_id == member, PlaybackLog.media_item_id == item)
                    .order_by(PlaybackLog.id)
                )
            ).scalars()
            return (
                [
                    (
                        r.season_number,
                        r.episode_number,
                        r.played,
                        r.play_count,
                        r.is_favorite,
                        r.favorited_at,
                        r.last_played_at,
                    )
                    for r in states
                ],
                [
                    (
                        r.id,
                        r.device_id,
                        r.last_seen_at,
                        r.end_position_ms,
                        r.watched_ms,
                        r.completed,
                    )
                    for r in logs
                ],
            )

    return env.c.portal.call(run)


@pytest.mark.parametrize("kind", ["movie", "tv", "video"])
def test_dismiss_hides_whole_title_keeps_facts_and_replay_brings_it_back(env, kind, monkeypatch):
    item = env.ids[kind]
    season, episode = UNITS[kind]
    if kind == "tv":
        play(env, 1, item, 1, 1, None)  # E1 看完
    play(env, 1, item, season, episode, 120_000)
    play(env, 2, item, season, episode, 60_000, device=9)  # 另一成员同一单元
    key = (item, season, episode)
    assert key in up_next(env, 1) and key in up_next(env, 1, device=5)
    unit = catalog_unit(env, 1, item, season, episode)
    assert unit["continue_dismissed"] is False and unit["position_ms"] == 120_000
    # 收藏一下，证明隐藏不碰收藏
    assert write(env, 1, unit, is_favorite=True)["status"] == "applied"
    unit = catalog_unit(env, 1, item, season, episode)
    before = facts(env, 1, item)
    before_resume = resume(env, 1, item, season, episode)

    from movieclaw_api import events

    published = []

    async def spy(*args, **kwargs):
        published.append(args)

    monkeypatch.setattr(events, "publish", spy)
    out = write(env, 1, unit, position_ms=0, dismiss_continue=True)
    assert out["status"] == "applied"
    assert published == []

    after = resume(env, 1, item, season, episode)
    assert after["position_ms"] == 0
    assert (after["played"], after["play_count"]) == (
        before_resume["played"],
        before_resume["play_count"],
    )
    # 整部作品不出卡：剧集不跳到 E3，本设备也一样
    assert [k for k in up_next(env, 1) if k[0] == item] == []
    assert [k for k in up_next(env, 1, device=5) if k[0] == item] == []
    # played / play_count / 收藏 / 收藏时间 / last_played_at / 播放日志都没动
    assert facts(env, 1, item) == before
    dismissed = catalog_unit(env, 1, item, season, episode)
    assert dismissed["continue_dismissed"] is True
    assert dismissed["updated_at"] == out["state_version"]
    assert dismissed["last_played_at"] == unit["last_played_at"]
    # 成员隔离：另一成员照旧
    assert key in up_next(env, 2) and key in up_next(env, 2, device=9)
    assert catalog_unit(env, 2, item, season, episode)["continue_dismissed"] is False
    monkeypatch.undo()

    # 真正再播放：标记清掉，卡片回来；之后还能再隐藏
    play(env, 1, item, season, episode, 200_000)
    again = catalog_unit(env, 1, item, season, episode)
    assert again["continue_dismissed"] is False
    assert key in up_next(env, 1) and key in up_next(env, 1, device=5)
    assert write(env, 1, again, position_ms=0, dismiss_continue=True)["status"] == "applied"
    assert [k for k in up_next(env, 1) if k[0] == item] == []


def test_dismiss_works_when_position_is_already_zero_and_can_be_undone(env):
    item = env.ids["movie"]
    play(env, 1, item, 0, 0, 0)  # 拖回开头停：position 0、未看完，卡片仍在
    unit = catalog_unit(env, 1, item, 0, 0)
    assert (unit["position_ms"], unit["played"]) == (0, False)
    assert (item, 0, 0) in up_next(env, 1)

    out = write(env, 1, unit, dismiss_continue=True)  # 只隐藏，不给 position
    assert out["status"] == "applied"
    assert (item, 0, 0) not in up_next(env, 1)
    dismissed = catalog_unit(env, 1, item, 0, 0)
    # 重复隐藏：unchanged，不动版本
    assert write(env, 1, dismissed, dismiss_continue=True) == {
        "status": "unchanged",
        "state_version": dismissed["updated_at"],
    }
    # 撤销（显式 false）回来
    assert write(env, 1, dismissed, dismiss_continue=False)["status"] == "applied"
    assert (item, 0, 0) in up_next(env, 1)
    assert catalog_unit(env, 1, item, 0, 0)["continue_dismissed"] is False


def test_dismiss_respects_cas_identity_and_shape(env):
    item = env.ids["video"]
    play(env, 1, item, 0, 0, 90_000)
    unit = catalog_unit(env, 1, item, 0, 0)
    # 过期版本：conflict，不写
    stale = {**unit, "updated_at": "2020-01-01T00:00:00Z"}
    assert write(env, 1, stale, position_ms=0, dismiss_continue=True)["status"] == "conflict"
    # 令牌不对：mismatch，不写
    forged = {**unit, "media": {**unit["media"], "identity": "local-video-other"}}
    assert write(env, 1, forged, dismiss_continue=True)["status"] == "mismatch"
    assert catalog_unit(env, 1, item, 0, 0)["continue_dismissed"] is False
    assert (item, 0, 0) in up_next(env, 1)
    # 播放把版本推走后，旧预览的隐藏被 CAS 拦下
    play(env, 1, item, 0, 0, 100_000)
    assert write(env, 1, unit, dismiss_continue=True)["status"] == "conflict"

    show = env.ids["tv"]

    def status(change):
        return env.c.post(SYNC + "/state", json={"member_id": 1, "changes": [change]}).status_code

    base = {"media_item_id": show, "kind": "tv", "tmdb_id": 200, "expected_updated_at": None}
    assert status({**base, "season": 1, "dismiss_continue": True}) == 422  # 整季不收
    assert status({**base, "dismiss_continue": True}) == 422  # 整剧不收
    assert status({**base, "season": 1, "episode": 1, "dismiss_continue": "x"}) == 422


def test_this_device_respects_title_level_dismiss(env):
    """本设备锚点（E1）与跨设备最近一行（E2）不同：隐藏按人、作品级，本设备条也拿掉。"""
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000, device=5)
    play(env, 1, show, 1, 2, 100_000, device=6)
    assert (show, 1, 1) in up_next(env, 1, device=5)
    unit = catalog_unit(env, 1, show, 1, 2)
    assert write(env, 1, unit, position_ms=0, dismiss_continue=True)["status"] == "applied"
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    assert [k for k in up_next(env, 1, device=5) if k[0] == show] == []
    # 本设备再播 E1：E1 成了最近一行且未隐藏，卡片回来
    play(env, 1, show, 1, 1, 150_000, device=5)
    assert (show, 1, 1) in up_next(env, 1, device=5)
    assert (show, 1, 1) in up_next(env, 1)


def test_dismissing_an_older_episode_conflicts_and_keeps_the_current_card(env):
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000)
    play(env, 1, show, 1, 2, 100_000)
    older = catalog_unit(env, 1, show, 1, 1)
    # 作品级意图：E1 不是锚点，写了也藏不住卡片 → 冲突，不写
    assert write(env, 1, older, position_ms=0, dismiss_continue=True)["status"] == "conflict"
    assert (show, 1, 2) in up_next(env, 1)
    assert catalog_unit(env, 1, show, 1, 1) == older


def test_dismiss_conflicts_when_another_device_played_the_next_episode(env):
    """预览时锚点是 E1，之后另一台设备播了 E2：按旧预览隐藏 E1 必须冲突，卡片照旧。"""
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000, device=5)
    preview = catalog_unit(env, 1, show, 1, 1)
    assert (show, 1, 1) in up_next(env, 1)
    play(env, 1, show, 1, 2, 100_000, device=6)  # 预览之后，别的设备播了下一集
    # E1 这一行的版本没变（CAS 本身能过），但它已不是作品锚点
    assert catalog_unit(env, 1, show, 1, 1)["updated_at"] == preview["updated_at"]
    assert write(env, 1, preview, position_ms=0, dismiss_continue=True)["status"] == "conflict"
    assert (show, 1, 2) in up_next(env, 1)
    # this_device：本设备条显示的是 E1，同样冲突、同样还在
    assert (show, 1, 1) in up_next(env, 1, device=5)
    assert write(env, 1, preview, dismiss_continue=True)["status"] == "conflict"
    assert (show, 1, 1) in up_next(env, 1, device=5)
    assert (show, 1, 2) in up_next(env, 1, device=6)
    for episode in (1, 2):
        assert catalog_unit(env, 1, show, 1, episode)["continue_dismissed"] is False
    assert resume(env, 1, show, 1, 1)["position_ms"] == 100_000  # position_ms=0 也没写进去

    # 重新读、对锚点 E2 隐藏：成功，跨设备与两台设备的条都拿掉
    current = catalog_unit(env, 1, show, 1, 2)
    assert write(env, 1, current, dismiss_continue=True)["status"] == "applied"
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    assert [k for k in up_next(env, 1, device=5) if k[0] == show] == []
    assert [k for k in up_next(env, 1, device=6) if k[0] == show] == []
    # 隐藏之后真的再播（哪一集都行）：整部作品的标记清掉
    play(env, 1, show, 1, 1, 150_000, device=5)
    assert (show, 1, 1) in up_next(env, 1)
    for episode in (1, 2):
        assert catalog_unit(env, 1, show, 1, episode)["continue_dismissed"] is False


def iso(moment):
    return moment.isoformat().replace("+00:00", "Z")


def upload(env, member, item, season, episode, position, at, *, viewing, device=7):
    record = {
        "viewing_id": viewing,
        "media_item_id": item,
        "season_number": season,
        "episode_number": episode,
        "started_at": iso(at - timedelta(minutes=5)),
        "updated_at": iso(at),
        "position_ms": position,
        "watched_ms": 60_000,
    }
    r = env.call(
        env.as_member(member, device),
        "post",
        "/api/v1/playback/viewings",
        json={"sent_at": iso(datetime.now(UTC)), "records": [record]},
    )
    assert r.status_code == 200, r.text
    return r.json()["data"]["results"][0]["status"]


def test_late_offline_upload_older_than_dismiss_keeps_title_hidden(env):
    item = env.ids["movie"]
    now = datetime.now(UTC)
    # 服务器上已有一场较早的播放（t0）
    assert upload(
        env, 1, item, 0, 0, 60_000, now - timedelta(minutes=30), viewing="v-movie-t0"
    ) == ("applied")
    # 手机离线时在 t1 又看了一段，但还没传上来；另一台设备此刻（t2 > t1）隐藏
    unit = catalog_unit(env, 1, item, 0, 0)
    assert write(env, 1, unit, dismiss_continue=True)["status"] == "applied"
    assert (item, 0, 0) not in up_next(env, 1)
    # 旧离线记录上传：比 last_played_at 新（续播点照常合并），但比隐藏早 → 仍隐藏
    t1 = now - timedelta(minutes=10)
    assert upload(env, 1, item, 0, 0, 200_000, t1, viewing="v-movie-t1") == "applied"
    late = catalog_unit(env, 1, item, 0, 0)
    assert late["position_ms"] == 200_000
    assert late["continue_dismissed"] is True
    assert (item, 0, 0) not in up_next(env, 1)
    assert (item, 0, 0) not in up_next(env, 1, device=7)
    # 对照：隐藏之后才发生的离线播放 → 回来
    assert upload(env, 1, item, 0, 0, 250_000, datetime.now(UTC), viewing="v-movie-t3") == "applied"
    assert catalog_unit(env, 1, item, 0, 0)["continue_dismissed"] is False
    assert (item, 0, 0) in up_next(env, 1)


def test_late_offline_upload_of_another_episode_does_not_resurface_title(env):
    """旧离线记录把较早那一集顶成锚点时，隐藏仍是作品级的。"""
    show = env.ids["tv"]
    now = datetime.now(UTC)
    upload(env, 1, show, 1, 2, 60_000, now - timedelta(minutes=30), viewing="v-show-e2")
    e2 = catalog_unit(env, 1, show, 1, 2)
    assert write(env, 1, e2, dismiss_continue=True)["status"] == "applied"
    # E1 在 t1（E2 之后、隐藏之前）离线播过，现在才传：它成了最近播放的一行
    upload(env, 1, show, 1, 1, 60_000, now - timedelta(minutes=10), viewing="v-show-e1")
    assert catalog_unit(env, 1, show, 1, 2)["continue_dismissed"] is True
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    assert [k for k in up_next(env, 1, device=7) if k[0] == show] == []


def history(env, member, unit, watched_at, source_id):
    media = unit["media"]
    record = {
        "media_item_id": media["id"],
        "kind": media["kind"],
        "tmdb_id": media["tmdb_id"],
        "season": unit["season"],
        "episode": unit["episode"],
        "source_id": source_id,
        "watched_at": iso(watched_at),
        "expected_updated_at": unit["updated_at"],
    }
    r = env.c.post(SYNC + "/import", json={"member_id": member, "records": [record]})
    assert r.status_code == 200, r.text
    return r.json()["data"]["outcomes"][0]["status"]


def test_watch_history_import_restores_only_when_newer_than_dismiss(env):
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000)
    e1 = catalog_unit(env, 1, show, 1, 1)
    assert write(env, 1, e1, dismiss_continue=True)["status"] == "applied"
    # 外部（Trakt / Plex 历史）导入一条比隐藏早的观看：不恢复
    old = datetime.now(UTC) - timedelta(days=1)
    assert history(env, 1, catalog_unit(env, 1, show, 1, 1), old, "old") == "applied"
    assert catalog_unit(env, 1, show, 1, 1)["continue_dismissed"] is True
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    # 隐藏之后的观看（插件无需发 dismiss_continue=false）：恢复，接着看 E2
    assert history(env, 1, catalog_unit(env, 1, show, 1, 1), datetime.now(UTC), "new") == (
        "applied"
    )
    restored = catalog_unit(env, 1, show, 1, 1)
    assert restored["continue_dismissed"] is False and restored["played"] is True
    assert (show, 1, 2) in up_next(env, 1)


def test_progress_sync_restores_unless_same_request_dismisses(env):
    item = env.ids["video"]
    play(env, 1, item, 0, 0, 90_000)
    unit = catalog_unit(env, 1, item, 0, 0)
    assert write(env, 1, unit, dismiss_continue=True)["status"] == "applied"
    # 带着比隐藏早的 last_played_at：旧事实，不恢复（进度照写）
    hidden = catalog_unit(env, 1, item, 0, 0)
    stale = iso(datetime.now(UTC) - timedelta(hours=1))
    assert write(env, 1, hidden, position_ms=95_000, last_played_at=stale)["status"] == "applied"
    assert catalog_unit(env, 1, item, 0, 0)["continue_dismissed"] is True
    assert (item, 0, 0) not in up_next(env, 1)
    # 同一请求里显式 dismiss_continue=true 优先：进度往前走也保持隐藏
    hidden = catalog_unit(env, 1, item, 0, 0)
    assert write(env, 1, hidden, position_ms=100_000, dismiss_continue=True)["status"] == "applied"
    assert catalog_unit(env, 1, item, 0, 0)["continue_dismissed"] is True
    assert (item, 0, 0) not in up_next(env, 1)
    # 普通进度同步（旧插件，不带 dismiss_continue、也不带时间）：自动恢复
    hidden = catalog_unit(env, 1, item, 0, 0)
    assert write(env, 1, hidden, position_ms=120_000)["status"] == "applied"
    back = catalog_unit(env, 1, item, 0, 0)
    assert (back["continue_dismissed"], back["position_ms"]) == (False, 120_000)
    assert (item, 0, 0) in up_next(env, 1)


@pytest.mark.parametrize("dismiss_first", [True, False])
@pytest.mark.parametrize("failure", ["not_anchor", "stale_version", "mismatch", "not_found"])
def test_failed_dismiss_in_batch_does_not_block_progress_restore(env, failure, dismiss_first):
    """同一批：合法较新进度 + 没落下的 dismiss_continue=true——进度照常让作品回来。"""
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000)
    play(env, 1, show, 1, 2, 100_000)
    assert write(env, 1, catalog_unit(env, 1, show, 1, 2), dismiss_continue=True)["status"] == (
        "applied"
    )
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    e1, e2 = catalog_unit(env, 1, show, 1, 1), catalog_unit(env, 1, show, 1, 2)
    dismiss = {
        "not_anchor": change(e1, dismiss_continue=True),
        "stale_version": change(e2, dismiss_continue=True)
        | {"expected_updated_at": iso(datetime.now(UTC) - timedelta(days=3))},
        "mismatch": change(e1, dismiss_continue=True) | {"tmdb_id": 999},
        "not_found": change(e1, dismiss_continue=True)
        | {"episode": 9, "expected_updated_at": None},
    }[failure]
    progress = change(e2, position_ms=150_000, last_played_at=iso(datetime.now(UTC)))
    expected = {"mismatch": "mismatch", "not_found": "not_found"}.get(failure, "conflict")
    if dismiss_first:
        assert write_batch(env, 1, [dismiss, progress]) == [expected, "applied"]
    else:
        assert write_batch(env, 1, [progress, dismiss]) == ["applied", expected]
    for episode in (1, 2):
        assert catalog_unit(env, 1, show, 1, episode)["continue_dismissed"] is False
    assert catalog_unit(env, 1, show, 1, 2)["position_ms"] == 150_000
    assert (show, 1, 2) in up_next(env, 1)


def test_successful_dismiss_in_batch_still_wins_over_progress(env):
    """对照：同批隐藏真的落下（applied / unchanged）时，显式意图照旧优先。"""
    show = env.ids["tv"]
    play(env, 1, show, 1, 1, 100_000)
    play(env, 1, show, 1, 2, 100_000)
    e1, e2 = catalog_unit(env, 1, show, 1, 1), catalog_unit(env, 1, show, 1, 2)
    batch = [change(e2, dismiss_continue=True), change(e1, position_ms=120_000)]
    assert write_batch(env, 1, batch) == ["applied", "applied"]
    assert catalog_unit(env, 1, show, 1, 2)["continue_dismissed"] is True
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    # 重发同一隐藏（unchanged）+ 进度：仍隐藏
    e1, e2 = catalog_unit(env, 1, show, 1, 1), catalog_unit(env, 1, show, 1, 2)
    batch = [change(e1, position_ms=130_000), change(e2, dismiss_continue=True)]
    assert write_batch(env, 1, batch) == ["applied", "unchanged"]
    assert catalog_unit(env, 1, show, 1, 2)["continue_dismissed"] is True
    assert [k for k in up_next(env, 1) if k[0] == show] == []


def test_explicit_restore_clears_every_flag_of_the_title(env):
    """dismiss_continue=false 是作品级：目标行没标记、别的行带着也清，清完卡片回来。"""
    show = env.ids["tv"]
    now = datetime.now(UTC)
    upload(env, 1, show, 1, 2, 60_000, now - timedelta(minutes=30), viewing="v-show-e2")
    assert write(env, 1, catalog_unit(env, 1, show, 1, 2), dismiss_continue=True)["status"] == (
        "applied"
    )
    # 较早的离线记录晚到，E1 顶成锚点；标记留在 E2，作品照旧隐藏
    upload(env, 1, show, 1, 1, 60_000, now - timedelta(minutes=10), viewing="v-show-e1")
    assert [k for k in up_next(env, 1) if k[0] == show] == []
    # 对看得见的锚点 E1 取消隐藏：E1 自己没标记，但作品是藏着的 → applied、整部回来
    e1 = catalog_unit(env, 1, show, 1, 1)
    assert e1["continue_dismissed"] is False
    assert write(env, 1, e1, dismiss_continue=False)["status"] == "applied"
    assert catalog_unit(env, 1, show, 1, 2)["continue_dismissed"] is False
    assert (show, 1, 1) in up_next(env, 1)
    # 再隐藏锚点 E1，然后 E1 被重新识别成 E3：观看状态（连同标记）带到 E3，两行都有标记
    assert write(env, 1, catalog_unit(env, 1, show, 1, 1), dismiss_continue=True)["status"] == (
        "applied"
    )

    async def reanchor():
        from movieclaw_api.services.library.reanchor import migrate_watch_state

        async with get_database().session() as s:
            await migrate_watch_state(s, (show, 1, 1), (show, 1, 3))
            await s.commit()

    env.c.portal.call(reanchor)
    assert [catalog_unit(env, 1, show, 1, e)["continue_dismissed"] for e in (1, 3)] == [True, True]
    # 对 E1 取消隐藏：作品所有标记都清，卡片回来（以前只清 E1，E3 的标记让整部继续藏着）
    assert write(env, 1, catalog_unit(env, 1, show, 1, 1), dismiss_continue=False)["status"] == (
        "applied"
    )
    for episode in (1, 2, 3):
        assert catalog_unit(env, 1, show, 1, episode)["continue_dismissed"] is False
    assert [k for k in up_next(env, 1) if k[0] == show] != []
    # 作品没有任何标记时取消隐藏：unchanged，不动版本
    e1 = catalog_unit(env, 1, show, 1, 1)
    assert write(env, 1, e1, dismiss_continue=False)["status"] == "unchanged"
    assert catalog_unit(env, 1, show, 1, 1)["updated_at"] == e1["updated_at"]


def test_continue_dismissed_migration_upgrade_downgrade_keeps_rows(tmp_path, monkeypatch):
    import sqlite3

    from alembic import command

    from movieclaw_db.migrations import _build_config

    path = tmp_path / "migration.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    try:
        config = _build_config()
        command.upgrade(config, "c5f1a8e3b724")
        with sqlite3.connect(path) as db:
            # 旧库的一行条目：NOT NULL 且无默认值的列一律填占位值
            required = [
                (r[1], r[2])
                for r in db.execute("pragma table_info(media_item)")
                if r[3] and r[4] is None and not r[5]
            ]
            values = {
                name: (1 if "INT" in type_.upper() or "BOOL" in type_.upper() else "x")
                for name, type_ in required
            }
            values.update(id=1, kind="movie", source="local", external_id="x")
            values.update(created_at="2026-01-01", updated_at="2026-01-01")
            if "aliases" in values:
                values["aliases"] = "[]"
            db.execute(
                f"insert into media_item ({', '.join(values)})"
                f" values ({', '.join('?' * len(values))})",
                list(values.values()),
            )
            db.execute(
                "insert into playback_state (member_id, media_item_id, season_number,"
                " episode_number, position_ms, played, play_count, is_favorite,"
                " last_played_at, created_at, updated_at)"
                " values (0, 1, 0, 0, 5000, 0, 2, 1, '2026-01-02', '2026-01-01', '2026-01-02')"
            )
        command.upgrade(config, "head")
        with sqlite3.connect(path) as db:
            row = db.execute(
                "select position_ms, played, play_count, is_favorite, last_played_at,"
                " continue_dismissed, continue_dismissed_at from playback_state"
            ).fetchone()
            assert row == (5000, 0, 2, 1, "2026-01-02", 0, None)
        command.downgrade(config, "c5f1a8e3b724")
        with sqlite3.connect(path) as db:
            cols = {r[1] for r in db.execute("pragma table_info(playback_state)")}
            assert not {"continue_dismissed", "continue_dismissed_at"} & cols
            assert db.execute("select play_count from playback_state").fetchone() == (2,)
        command.upgrade(config, "head")
    finally:
        get_settings.cache_clear()

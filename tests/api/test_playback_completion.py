"""设置 → 保存 → 真实播放上报 → 续播回读；不依赖客户端的完成阈值。"""
# ruff: noqa: F811 -- 复用 HTTP client fixture，测试参数按 pytest 约定同名。

from functools import partial

import pytest
from sqlalchemy import select
from tests.api.test_playback_watch import client, report, resume, seed  # noqa: F401

from movieclaw_api.services.library.skip_segments import ALGO_VERSION
from movieclaw_db.engine import get_database
from movieclaw_db.models import Library, LibraryFile, MediaItem
from movieclaw_db.models.media_segment import MediaSegmentState

PB = "/api/v1/playback"


@pytest.mark.parametrize("value", [80, 83, 90, 97.5, 100])
def test_custom_percentage_round_trips_and_keeps_other_settings(client, value):
    response = client.put(f"{PB}/policy", json={"played_threshold_percent": value})
    assert response.status_code == 200, response.text
    assert response.json()["data"]["played_threshold_percent"] == value
    client.put(f"{PB}/policy", json={"trickplay_enabled": False})
    assert client.get(f"{PB}/policy").json()["data"]["played_threshold_percent"] == value


@pytest.mark.parametrize("value", [0, 79.99, 100.01, 200])
def test_invalid_percentage_is_not_saved(client, value):
    response = client.put(f"{PB}/policy", json={"played_threshold_percent": value})
    assert response.status_code == 422
    assert client.get(f"{PB}/policy").json()["data"]["played_threshold_percent"] == 90


def test_live_policy_changes_apply_without_client_changes(client, tmp_path):
    _, item = seed(client, tmp_path)
    assert client.put(f"{PB}/policy", json={"played_threshold_percent": 97}).status_code == 200
    report(client, item, event="stop", position_ms=560_000)
    assert resume(client, item)["position_ms"] == 560_000
    assert resume(client, item)["played"] is False
    client.put(f"{PB}/policy", json={"played_threshold_percent": 85})
    report(client, item, event="progress", position_ms=560_000)
    assert resume(client, item)["played"] is True
    assert resume(client, item)["position_ms"] == 0


def test_one_hundred_percent_keeps_progress_until_the_end_tolerance(client, tmp_path):
    _, item = seed(client, tmp_path)
    client.put(f"{PB}/policy", json={"played_threshold_percent": 100})
    report(client, item, event="stop", position_ms=598_500)
    assert resume(client, item)["position_ms"] == 598_500
    assert resume(client, item)["played"] is False
    report(client, item, event="stop", position_ms=600_000)
    assert resume(client, item)["played"] is True
    assert resume(client, item)["position_ms"] == 0


def test_custom_percentage_also_applies_to_short_videos(client, tmp_path):
    _, item = seed(client, tmp_path)

    async def shorten():
        async with get_database().session() as session:
            file = (
                await session.execute(select(LibraryFile).where(LibraryFile.media_item_id == item))
            ).scalar_one()
            file.duration_seconds = 120
            await session.commit()

    client.portal.call(shorten)
    client.put(f"{PB}/policy", json={"played_threshold_percent": 100})
    report(client, item, event="stop", position_ms=118_500)
    assert resume(client, item)["played"] is False
    assert resume(client, item)["position_ms"] == 118_500
    report(client, item, event="stop", position_ms=120_000)
    assert resume(client, item)["played"] is True


def test_one_hundred_percent_accepts_actual_end_with_rounded_runtime(client, tmp_path):
    _, item = seed(client, tmp_path)

    async def round_duration():
        async with get_database().session() as session:
            file = (
                await session.execute(select(LibraryFile).where(LibraryFile.media_item_id == item))
            ).scalar_one()
            file.duration_seconds = 601
            await session.commit()

    client.portal.call(round_duration)
    client.put(f"{PB}/policy", json={"played_threshold_percent": 100})
    state = report(client, item, event="stop", position_ms=600_600)
    assert state["played"] is True and state["position_ms"] == 0


async def _segments(library_id, item_id, *, case, start):
    async with get_database().session() as session:
        library = await session.get(Library, library_id)
        item = await session.get(MediaItem, item_id)
        if case != "movie":
            library.kind = "tv"
            item.kind = "tv"
        library.detect_media_segments = case != "disabled"
        file = (
            await session.execute(select(LibraryFile).where(LibraryFile.media_item_id == item_id))
        ).scalar_one()
        if case != "movie":
            file.season_number, file.episode_number = 1, 1
        session.add(
            MediaSegmentState(
                library_file_id=file.id,
                source_size=file.size_bytes + (1 if case == "replaced" else 0),
                algo_version=ALGO_VERSION - (1 if case == "stale" else 0),
                fingerprint_status="ok",
                segments=[]
                if case == "missing"
                else [
                    dict(
                        type="outro",
                        start_ms=start,
                        end_ms=600_000,
                        to_end=case != "postcredits",
                    )
                ],
            )
        )
        await session.commit()


@pytest.mark.parametrize(
    "case", ["valid", "movie", "disabled", "stale", "replaced", "missing", "postcredits"]
)
def test_outro_uses_only_current_enabled_tv_markers(client, tmp_path, case):
    lib, item = seed(client, tmp_path)
    client.portal.call(partial(_segments, lib, item, case=case, start=480_000))
    client.put(f"{PB}/policy", json={"played_threshold_percent": 97, "played_use_outro": True})
    unit = {} if case == "movie" else {"season_number": 1, "episode_number": 1}
    state = report(client, item, event="stop", position_ms=500_000, **unit)
    assert state["played"] is (case == "valid")
    assert state["position_ms"] == (0 if case == "valid" else 500_000)
    # 不可用的片尾不妨碍正常按所选百分比完成。
    state = report(client, item, event="stop", position_ms=590_000, **unit)
    assert state["played"] is True and state["position_ms"] == 0


def test_valid_later_outro_takes_precedence_over_percentage(client, tmp_path):
    lib, item = seed(client, tmp_path)
    client.portal.call(partial(_segments, lib, item, case="valid", start=580_000))
    client.put(f"{PB}/policy", json={"played_threshold_percent": 80, "played_use_outro": True})
    state = report(
        client, item, event="progress", position_ms=550_000, season_number=1, episode_number=1
    )
    assert state["played"] is False
    assert state["position_ms"] == 550_000
    state = report(
        client, item, event="stop", position_ms=580_000, season_number=1, episode_number=1
    )
    assert state["played"] is True and state["position_ms"] == 0


@pytest.mark.parametrize("offline", [False, True])
def test_replaced_file_does_not_borrow_current_versions_outro(client, tmp_path, offline):
    lib, item = seed(client, tmp_path)
    client.portal.call(partial(_segments, lib, item, case="valid", start=480_000))
    client.put(f"{PB}/policy", json={"played_threshold_percent": 97, "played_use_outro": True})
    if offline:
        from tests.api.test_offline_download import _send_viewings, _viewing

        record = _viewing(
            item,
            file_id=999999,
            season_number=1,
            episode_number=1,
            position_ms=500_000,
            completed=False,
            ended=True,
        )
        assert _send_viewings(client, [record]) == {"v-0000-0001": "applied"}
        state = client.get(
            f"{PB}/resume", params={"media_item_id": item, "season_number": 1, "episode_number": 1}
        ).json()["data"]
    else:
        state = report(
            client,
            item,
            event="stop",
            file_id=999999,
            position_ms=500_000,
            season_number=1,
            episode_number=1,
        )
    assert state["played"] is False and state["position_ms"] == 500_000


@pytest.mark.parametrize("offline", [False, True])
@pytest.mark.parametrize("historical", [False, True])
@pytest.mark.parametrize("old_duration,new_duration,position,played", [
    (7200, 5400, 5100, False),  # 旧版更长：不能按新版 94% 误判完成。
    (5400, 7200, 5100, True),   # 旧版更短：不能按新版 71% 漏掉完成。
])
def test_replaced_version_uses_its_own_duration(
    client, tmp_path, offline, historical, old_duration, new_duration, position, played
):
    from tests.api.test_offline_download import _send_viewings, _viewing

    from movieclaw_db.models import FileState

    _, item = seed(client, tmp_path)

    async def replace():
        async with get_database().session() as session:
            current = (await session.execute(
                select(LibraryFile).where(LibraryFile.media_item_id == item)
            )).scalar_one()
            current.duration_seconds = new_duration
            old = LibraryFile(
                library_id=current.library_id, media_item_id=item,
                file_path=current.file_path + ".old", size_bytes=current.size_bytes,
                source=current.source, state=FileState.MISSING,
                duration_seconds=old_duration,
            )
            session.add(old)
            await session.flush()
            old_id = old.id
            if not historical:
                await session.delete(old)
            await session.commit()
            return old_id

    file_id = client.portal.call(replace)
    if offline:
        record = _viewing(item, file_id=file_id, duration_ms=old_duration * 1000,
                          position_ms=position * 1000, completed=not played, ended=True)
        assert _send_viewings(client, [record]) == {"v-0000-0001": "applied"}
        state = resume(client, item)
    else:
        state = report(client, item, event="stop", file_id=file_id, position_ms=position * 1000)
    expected_played = played and (offline or historical)
    assert state["played"] is expected_played
    assert state["position_ms"] == (0 if expected_played else position * 1000)


def test_unknown_version_without_duration_preserves_online_and_offline_progress(client, tmp_path):
    from tests.api.test_offline_download import _send_viewings, _viewing

    _, item = seed(client, tmp_path)
    state = report(client, item, event="progress", file_id=999999, position_ms=599_999)
    assert state["played"] is False and state["position_ms"] == 599_999
    state = report(client, item, event="stop", file_id=999999)
    assert state["played"] is False and state["position_ms"] == 599_999
    record = _viewing(item, file_id=999999, position_ms=590_000, completed=True, ended=True)
    assert _send_viewings(client, [record]) == {"v-0000-0001": "applied"}
    state = resume(client, item)
    assert state["played"] is False and state["position_ms"] == 590_000


def test_offline_record_duration_takes_precedence_over_server_duration(client, tmp_path):
    from tests.api.test_offline_download import _send_viewings, _viewing

    _, item = seed(client, tmp_path)
    record = _viewing(item, duration_ms=1_200_000, position_ms=590_000, completed=True, ended=True)
    assert _send_viewings(client, [record]) == {"v-0000-0001": "applied"}
    state = resume(client, item)
    assert state["played"] is False and state["position_ms"] == 590_000


@pytest.mark.parametrize("first,second", [
    ({"played_threshold_percent": 97.5}, {"trickplay_enabled": False}),
    ({"trickplay_enabled": False}, {"played_threshold_percent": 97.5}),
])
def test_concurrent_partial_policy_saves_preserve_both_db_and_cache(
    client, monkeypatch, first, second
):
    import asyncio

    import httpx

    from movieclaw_api.settings import get_setting_store
    from movieclaw_db.repositories.setting_repo import SettingRepository

    original = SettingRepository.upsert

    async def exercise():
        writing, release, second_started = asyncio.Event(), asyncio.Event(), asyncio.Event()
        calls = 0

        async def pause_first_write(repo, namespace, value_json):
            nonlocal calls
            if namespace == "playback.policy":
                calls += 1
                if calls == 1:
                    writing.set()
                    await release.wait()
            return await original(repo, namespace, value_json)

        monkeypatch.setattr(SettingRepository, "upsert", pause_first_write)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=client.app),
            base_url="http://testserver", cookies=dict(client.cookies),
        ) as http:
            a = asyncio.create_task(http.put(f"{PB}/policy", json=first))
            await asyncio.wait_for(writing.wait(), 5)

            async def save_second():
                second_started.set()
                return await http.put(f"{PB}/policy", json=second)

            b = asyncio.create_task(save_second())
            await second_started.wait()
            # 第一份已读取旧值、但尚未写库，第二份请求此时进入保存流程。
            await asyncio.sleep(0.05)
            release.set()
            responses = await asyncio.gather(a, b)
            assert all(r.status_code == 200 for r in responses)
            cached = (await http.get(f"{PB}/policy")).json()["data"]
            get_setting_store().invalidate()
            persisted = (await http.get(f"{PB}/policy")).json()["data"]
            for result in (cached, persisted):
                assert result["played_threshold_percent"] == 97.5
                assert result["trickplay_enabled"] is False

    client.portal.call(exercise)


def test_offline_database_writer_does_not_wait_for_policy_save_lock(client, tmp_path, monkeypatch):
    import asyncio

    from movieclaw_api.settings import PlaybackPolicySetting, get_setting_store
    from movieclaw_db.repositories.setting_repo import SettingRepository
    from movieclaw_playback.state import lock_titles

    _, item = seed(client, tmp_path)
    original = SettingRepository.upsert

    async def exercise():
        writing = asyncio.Event()

        async def signal_write(repo, namespace, value_json):
            if namespace == "playback.policy":
                writing.set()
            return await original(repo, namespace, value_json)

        monkeypatch.setattr(SettingRepository, "upsert", signal_write)
        store = get_setting_store()
        # 冷缓存也覆盖：保存者先读配置，离线读取仍不能等待保存者的写锁。
        store.invalidate()
        async with get_database().session() as offline:
            await lock_titles(offline, 0, [item])
            save = asyncio.create_task(
                store.update(PlaybackPolicySetting, {"played_threshold_percent": 97})
            )
            try:
                await asyncio.wait_for(writing.wait(), 2)
                policy = await asyncio.wait_for(store.get(PlaybackPolicySetting), 1)
                assert policy.played_threshold_percent == 90
            finally:
                await offline.rollback()
                await save
        assert (await store.get(PlaybackPolicySetting)).played_threshold_percent == 97

    client.portal.call(exercise)

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

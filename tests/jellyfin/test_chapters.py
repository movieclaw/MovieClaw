"""Jellyfin 兼容层的章节输出（docs/design/video-chapters.md §4.7）。

- ``Chapters`` 受 fields 门控：不传不出，传了出；单条目接口全字段语义带出；
- 内嵌章节按起点输出，合成章节输出图上那一帧的真实时间；无标题补「第 N 章」；
- 有图才给 ImageTag，ImageDateModified 恒输出（无图是 DateTime.MinValue），
  ``ImagePath`` 省略（偏离⑫）；
- 章节图路由 ``/Items/{id}/Images/Chapter/{index}``：有图 200、无图/越界 404；
- 库没开「生成章节」（默认关）：只出内嵌章节、不给 ImageTag，合成章节不出，
  章节图 404——图还在盘上，只是不展示；
- VirtualFolders 的 EnableChapterImageExtraction 如实反映库开关。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from jellyfin.helpers import ADMIN, jf_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    FileSource,
    Library,
    LibraryFile,
    MediaEpisode,
    MediaItem,
    MediaMetadata,
    MediaSeason,
)
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_jellyfin.ids import episode_guid, item_guid, library_guid

_EMBEDDED = [
    {"start_ms": 0, "end_ms": 600_000, "title": "Opening"},
    {"start_ms": 600_000, "end_ms": 3_000_000, "title": None},
    {"start_ms": 3_000_000, "end_ms": None, "title": "Finale"},
]


@pytest.fixture
def seeded_chapters(tmp_path: Path, monkeypatch) -> dict:
    """电影：三段内嵌章节，第 2/3 章有图；剧集一集：无内嵌章节（47 分钟 → 合成 8 段），
    首段有图。这两个库都开了「生成章节」；第三个库保持默认（关），里面一部内嵌章节、
    一部合成章节，各自都有一张以前生成的图。"""
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'jf-ch.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()

    media = tmp_path / "media"
    movie_file = media / "Inception (2010)" / "Inception.2010.mkv"
    movie_file.parent.mkdir(parents=True)
    movie_file.write_bytes(b"A" * 1024)
    ep_file = media / "Breaking (2008)" / "Season 01" / "S01E01.mkv"
    ep_file.parent.mkdir(parents=True)
    ep_file.write_bytes(b"B" * 1024)
    off_real_file = media / "The Matrix (1999)" / "The.Matrix.1999.mkv"
    off_real_file.parent.mkdir(parents=True)
    off_real_file.write_bytes(b"C" * 1024)
    off_synth_file = media / "Fight Club (1999)" / "Fight.Club.1999.mkv"
    off_synth_file.parent.mkdir(parents=True)
    off_synth_file.write_bytes(b"D" * 1024)

    from PIL import Image

    ids: dict = {}

    async def _seed() -> None:
        init_db(get_settings().database_url, echo=False)
        await run_migrations()
        async with get_database().session() as session:
            movie_lib = Library(
                name="电影", kind="movie", root_paths=[str(media)], extract_chapter_images=True
            )
            tv_lib = Library(
                name="剧集", kind="tv", root_paths=[str(media)], extract_chapter_images=True
            )
            off_lib = Library(name="关章节", kind="movie", root_paths=[str(media)])
            session.add_all([movie_lib, tv_lib, off_lib])
            await session.flush()
            movie = MediaItem(
                kind="movie", tmdb_id=27205, title="盗梦空间", original_title="Inception", year=2010
            )
            show = MediaItem(
                kind="tv", tmdb_id=1396, title="绝命毒师", original_title="Breaking Bad", year=2008
            )
            off_real = MediaItem(
                kind="movie", tmdb_id=603, title="黑客帝国", original_title="The Matrix", year=1999
            )
            off_synth = MediaItem(
                kind="movie",
                tmdb_id=550,
                title="搏击俱乐部",
                original_title="Fight Club",
                year=1999,
            )
            session.add_all([movie, show, off_real, off_synth])
            await session.flush()
            session.add_all(
                [
                    MediaMetadata(media_item_id=movie.id, runtime_minutes=148),
                    MediaMetadata(media_item_id=off_real.id, runtime_minutes=136),
                    MediaMetadata(media_item_id=off_synth.id, runtime_minutes=139),
                    MediaMetadata(media_item_id=show.id),
                    MediaSeason(media_item_id=show.id, season_number=1, name="第 1 季"),
                    MediaEpisode(
                        media_item_id=show.id, season_number=1, episode_number=1, name="Pilot"
                    ),
                ]
            )
            movie_row = LibraryFile(
                library_id=movie_lib.id,
                media_item_id=movie.id,
                file_path=str(movie_file),
                size_bytes=1024,
                container="mkv",
                duration_seconds=148 * 60,
                chapters=_EMBEDDED,
                source=FileSource.SCANNED,
            )
            ep_row = LibraryFile(
                library_id=tv_lib.id,
                media_item_id=show.id,
                season_number=1,
                episode_number=1,
                file_path=str(ep_file),
                size_bytes=1024,
                container="mkv",
                duration_seconds=47 * 60,
                chapters=[],
                source=FileSource.SCANNED,
            )
            off_real_row = LibraryFile(
                library_id=off_lib.id,
                media_item_id=off_real.id,
                file_path=str(off_real_file),
                size_bytes=1024,
                container="mkv",
                duration_seconds=136 * 60,
                chapters=_EMBEDDED,
                source=FileSource.SCANNED,
            )
            off_synth_row = LibraryFile(
                library_id=off_lib.id,
                media_item_id=off_synth.id,
                file_path=str(off_synth_file),
                size_bytes=1024,
                container="mkv",
                duration_seconds=139 * 60,
                chapters=[],
                source=FileSource.SCANNED,
            )
            session.add_all([movie_row, ep_row, off_real_row, off_synth_row])
            await session.flush()
            assets = tmp_path / "metadata" / "images"
            movie_row.chapter_images = []
            for start in (600_000, 3_000_000):
                rel = f"{movie.id}/chapters/{movie_row.id}/{start:010d}.jpg"
                (assets / rel).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (960, 540), "#335577").save(assets / rel, "JPEG")
                movie_row.chapter_images.append(
                    {"start_ms": start, "frame_ms": start + 2000, "image": rel}
                )
            # 合成首段起点 = 47*60*1000*0.06 = 169200ms；图上那一帧在 171000ms
            rel = f"{show.id}/chapters/{ep_row.id}/{169_200:010d}.jpg"
            (assets / rel).parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (960, 540), "#553377").save(assets / rel, "JPEG")
            ep_row.chapter_images = [{"start_ms": 169_200, "frame_ms": 171_000, "image": rel}]
            # 关着开关的库里也留着以前生成的图（开关一次不删产物）：内嵌章节第 2 章
            # 一张；合成章节首段（139 分钟 → 10 段，起点 8340s×0.06=500.4s）一张
            for row, start in ((off_real_row, 600_000), (off_synth_row, 500_400)):
                rel = f"{row.media_item_id}/chapters/{row.id}/{start:010d}.jpg"
                (assets / rel).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (960, 540), "#775533").save(assets / rel, "JPEG")
                row.chapter_images = [{"start_ms": start, "frame_ms": start + 2000, "image": rel}]
            await session.commit()
            await LibraryRepository(session).refresh_stats([movie_lib.id, tv_lib.id, off_lib.id])
            ids.update(
                {
                    "movie_lib": movie_lib.id,
                    "tv_lib": tv_lib.id,
                    "off_lib": off_lib.id,
                    "movie": movie.id,
                    "show": show.id,
                    "off_real": off_real.id,
                    "off_synth": off_synth.id,
                }
            )
        await dispose_db()

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    asyncio.run(_seed())
    return ids


@pytest.fixture
def client(seeded_chapters, monkeypatch):
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as c:
        resp = c.post("/api/v1/auth/bootstrap", json=ADMIN)
        assert resp.status_code == 200, resp.text
        yield c
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def test_chapters_are_field_gated_and_full_on_single_item(
    client: TestClient, seeded_chapters: dict
) -> None:
    auth = {"ApiKey": jf_login(client)}
    parent = library_guid(seeded_chapters["movie_lib"])
    plain = client.get("/Items", params={**auth, "parentId": parent}).json()["Items"][0]
    assert "Chapters" not in plain

    with_fields = client.get(
        "/Items", params={**auth, "parentId": parent, "fields": "Chapters"}
    ).json()["Items"][0]
    chapters = with_fields["Chapters"]
    assert [c["StartPositionTicks"] for c in chapters] == [0, 600_000 * 10_000, 3_000_000 * 10_000]
    assert [c["Name"] for c in chapters] == ["Opening", "第 2 章", "Finale"]
    # 有图才给 ImageTag；ImagePath 永远不出（偏离⑫）
    assert "ImageTag" not in chapters[0]
    assert chapters[0]["ImageDateModified"] == "0001-01-01T00:00:00.0000000Z"
    assert chapters[1]["ImageTag"] and chapters[1]["ImageDateModified"].endswith("Z")
    assert chapters[1]["ImageDateModified"] != chapters[0]["ImageDateModified"]
    assert all("ImagePath" not in c for c in chapters)

    single = client.get(f"/Items/{item_guid(seeded_chapters['movie'])}", params=auth).json()
    assert [c["Name"] for c in single["Chapters"]] == ["Opening", "第 2 章", "Finale"]


def test_synthetic_chapters_use_frame_time_and_are_output(
    client: TestClient, seeded_chapters: dict
) -> None:
    auth = {"ApiKey": jf_login(client)}
    guid = episode_guid(seeded_chapters["show"], 1, 1)
    episode = client.get(f"/Items/{guid}", params=auth).json()
    chapters = episode["Chapters"]
    assert len(chapters) == 8 and chapters[0]["Name"] == "第 1 章"
    # 首段有图：起点用图上那一帧（171s）；其余没图：名义起点
    assert chapters[0]["StartPositionTicks"] == 171_000 * 10_000
    assert chapters[0]["ImageTag"]
    assert chapters[1]["StartPositionTicks"] == int(47 * 60 * 1000 * (0.06 + 0.88 / 7)) * 10_000
    assert "ImageTag" not in chapters[1]


def test_chapter_image_route(client: TestClient, seeded_chapters: dict) -> None:
    token = jf_login(client)
    guid = item_guid(seeded_chapters["movie"])
    no_image = client.get(f"/Items/{guid}/Images/Chapter/0", params={"ApiKey": token})
    assert no_image.status_code == 404
    ok = client.get(f"/Items/{guid}/Images/Chapter/1", params={"ApiKey": token, "tag": "t1"})
    assert ok.status_code == 200 and ok.headers["content-type"].startswith("image/jpeg")
    assert ok.headers["ETag"] == '"t1"'
    scaled = client.get(
        f"/Items/{guid}/Images/Chapter/2", params={"ApiKey": token, "maxWidth": 320}
    )
    assert scaled.status_code == 200
    assert (
        client.head(f"/Items/{guid}/Images/Chapter/2", params={"ApiKey": token}).status_code == 200
    )
    out_of_range = client.get(f"/Items/{guid}/Images/Chapter/9", params={"ApiKey": token})
    assert out_of_range.status_code == 404
    # 剧集单元也走同一路由：首段有图
    ep = episode_guid(seeded_chapters["show"], 1, 1)
    assert client.get(f"/Items/{ep}/Images/Chapter/0", params={"ApiKey": token}).status_code == 200
    assert client.get(f"/Items/{ep}/Images/Chapter/1", params={"ApiKey": token}).status_code == 404


def test_switch_off_library_keeps_only_real_chapters_without_images(
    client: TestClient, seeded_chapters: dict
) -> None:
    """库没开「生成章节」：内嵌章节照样输出（播放器靠它跳章，零成本），但不给
    ImageTag；合成章节是这个功能的产物，整体不出；以前生成的图还在盘上，路由一律 404。
    单条目（整行装载）与列表（最小列集装载）两条路径同一口径。"""
    auth = {"ApiKey": jf_login(client)}
    real_guid = item_guid(seeded_chapters["off_real"])
    synth_guid = item_guid(seeded_chapters["off_synth"])

    real = client.get(f"/Items/{real_guid}", params=auth).json()["Chapters"]
    assert [c["Name"] for c in real] == ["Opening", "第 2 章", "Finale"]
    assert [c["StartPositionTicks"] for c in real] == [0, 600_000 * 10_000, 3_000_000 * 10_000]
    assert all("ImageTag" not in c for c in real)
    assert client.get(f"/Items/{synth_guid}", params=auth).json()["Chapters"] == []

    listed = client.get(
        "/Items",
        params={
            **auth,
            "parentId": library_guid(seeded_chapters["off_lib"]),
            "fields": "Chapters",
        },
    ).json()["Items"]
    by_name = {i["Name"]: i["Chapters"] for i in listed}
    assert [c["Name"] for c in by_name["黑客帝国"]] == ["Opening", "第 2 章", "Finale"]
    assert all("ImageTag" not in c for c in by_name["黑客帝国"])
    assert by_name["搏击俱乐部"] == []

    assert client.get(f"/Items/{real_guid}/Images/Chapter/1", params=auth).status_code == 404
    assert client.get(f"/Items/{synth_guid}/Images/Chapter/0", params=auth).status_code == 404


def test_virtual_folders_reflect_chapter_switch(client: TestClient, seeded_chapters: dict) -> None:
    auth = {"ApiKey": jf_login(client)}
    folders = {f["Name"]: f for f in client.get("/Library/VirtualFolders", params=auth).json()}
    assert folders["电影"]["LibraryOptions"]["EnableChapterImageExtraction"] is True
    assert folders["关章节"]["LibraryOptions"]["EnableChapterImageExtraction"] is False

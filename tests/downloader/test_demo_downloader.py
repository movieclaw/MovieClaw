"""演示下载器（docs/design/demo-site.md §10）：按时间推进、完成时从种子目录落盘、刷流种只做种。"""

from __future__ import annotations

import json

import pytest

from movieclaw_downloader.clients import demo as demo_client
from movieclaw_downloader.factory import create_downloader
from movieclaw_downloader.models import DownloaderConfig, DownloadRequest
from movieclaw_tracker.sites.custom import demo as demo_site

RELEASE = "Spring.2019.1080p.WEB-DL.AAC.H.264-BLENDER"


@pytest.fixture
def env(tmp_path, monkeypatch):
    seeds = tmp_path / "seeds"
    folder = seeds / RELEASE
    folder.mkdir(parents=True)
    (folder / f"{RELEASE}.mp4").write_bytes(b"v" * (5 * 1024 * 1024 + 7))
    (folder / f"{RELEASE}.nfo").write_text("CC BY 4.0", encoding="utf-8")
    (folder / "release.json").write_text(
        json.dumps({"title": "Spring", "title_zh": "春", "year": 2019}), encoding="utf-8"
    )
    monkeypatch.setenv("MOVIECLAW_DEMO_SEED_DIR", str(seeds))
    monkeypatch.setenv("MOVIECLAW_DEMO_SITE_DIR", str(tmp_path / "site"))
    monkeypatch.setenv("MOVIECLAW_DEMO_DOWNLOADER_STATE", str(tmp_path / "state.json"))
    clock = {"now": 1_000_000.0}
    monkeypatch.setattr(demo_client.time, "time", lambda: clock["now"])
    catalog = demo_site.build_catalog()
    downloader = create_downloader(DownloaderConfig(type="demo", url="http://demo.local"))
    return {"tmp": tmp_path, "clock": clock, "catalog": catalog, "dl": downloader}


def _torrent(env) -> bytes:
    return (env["tmp"] / "site" / "torrents" / "1001.torrent").read_bytes()


async def test_download_progresses_then_lands_the_seed_folder(env) -> None:
    dl, clock = env["dl"], env["clock"]
    save = env["tmp"] / "downloads"
    result = await dl.submit(
        DownloadRequest(torrent_bytes=_torrent(env), save_path=str(save), tags=["owner-1"])
    )
    assert result.info_hash == env["catalog"][0]["info_hash"]
    assert result.name == RELEASE
    again = await dl.submit(DownloadRequest(torrent_bytes=_torrent(env), save_path=str(save)))
    assert again.already_exists

    status = await dl.get_torrent(result.info_hash)
    assert status is not None and status.state == "downloading" and not status.completed
    assert status.tags == ["owner-1"]
    # 文件路径带种子名作根目录（与 qBittorrent 一致，落盘核对按它找）
    assert {f.path for f in status.files} == {
        f"{RELEASE}/{RELEASE}.mp4",
        f"{RELEASE}/{RELEASE}.nfo",
    }

    clock["now"] += 10
    halfway = await dl.get_torrent(result.info_hash)
    assert 0 < halfway.progress < 1
    assert not (save / RELEASE).exists(), "没下完不能落盘"

    clock["now"] += demo_client.MAX_SECONDS
    done = await dl.get_torrent(result.info_hash)
    assert done.completed and done.state == "completed"
    assert (save / RELEASE / f"{RELEASE}.mp4").stat().st_size == 5 * 1024 * 1024 + 7
    assert not (save / RELEASE / "release.json").exists()

    briefs = await dl.list_torrents()
    assert [b.name for b in briefs] == [RELEASE] and briefs[0].completed


async def test_paused_add_waits_for_resume(env) -> None:
    dl, clock = env["dl"], env["clock"]
    result = await dl.submit(
        DownloadRequest(torrent_bytes=_torrent(env), save_path=str(env["tmp"] / "d"), paused=True)
    )
    clock["now"] += 500
    status = await dl.get_torrent(result.info_hash)
    assert status.state == "paused" and status.progress == 0
    await dl.set_file_selection(result.info_hash, [0])
    await dl.resume(result.info_hash)
    clock["now"] += demo_client.MAX_SECONDS
    assert (await dl.get_torrent(result.info_hash)).completed


async def test_boost_release_only_seeds(env) -> None:
    dl, clock = env["dl"], env["clock"]
    site = demo_site.DemoSite(
        site_id="demo", base_url="https://x.invalid", client=None, auth_manager=None
    )
    page = await site.list_torrents()
    boost = next(item for item in page.items if item.free)
    torrent = await site.download_torrent(boost.download_url)
    save = env["tmp"] / "boost"
    result = await dl.submit(
        DownloadRequest(torrent_bytes=torrent, save_path=str(save), category="movieclaw-boost")
    )
    clock["now"] += 60
    brief = next(b for b in await dl.list_torrents() if b.info_hash == result.info_hash)
    assert brief.completed and brief.uploaded_bytes and brief.uploaded_bytes > 0
    assert brief.swarm_leechers and brief.swarm_leechers > 0
    assert not save.exists(), "刷流种没有实体数据，不落盘"
    up, _down = await dl.transfer_speeds()
    assert up > 0


async def test_delete_and_move(env) -> None:
    dl, clock = env["dl"], env["clock"]
    save = env["tmp"] / "downloads"
    result = await dl.submit(DownloadRequest(torrent_bytes=_torrent(env), save_path=str(save)))
    clock["now"] += demo_client.MAX_SECONDS
    assert (await dl.get_torrent(result.info_hash)).completed
    moved = env["tmp"] / "moved"
    await dl.set_location(result.info_hash, str(moved))
    assert (moved / RELEASE).is_dir() and not (save / RELEASE).exists()
    await dl.delete_torrent(result.info_hash, delete_files=True)
    assert await dl.get_torrent(result.info_hash) is None
    assert not (moved / RELEASE).exists()
    await dl.delete_torrent(result.info_hash)  # 幂等
    info = await dl.test_connection()
    assert info.type == "demo"

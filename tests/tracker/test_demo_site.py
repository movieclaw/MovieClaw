"""演示资源站（docs/design/demo-site.md §10）：只读本地目录，种子是真实可解析的 v1 种子。"""

from __future__ import annotations

import json
import os

import pytest

from movieclaw_downloader.torrent import compute_info_hash
from movieclaw_tracker import get_site_config, load_all_sites
from movieclaw_tracker.models import SearchQuery
from movieclaw_tracker.sites.custom import demo


@pytest.fixture
def site(tmp_path, monkeypatch):
    seeds = tmp_path / "seeds"
    for name, meta in [
        (
            "Spring.2019.1080p.WEB-DL.AAC.H.264-BLENDER",
            {"title": "Spring", "title_zh": "春", "year": 2019, "imdb_id": "tt9249278"},
        ),
        (
            "Charge.2022.1080p.WEB-DL.AAC.H.264-BLENDER",
            {"title": "Charge", "title_zh": "冲锋", "year": 2022},
        ),
    ]:
        folder = seeds / name
        folder.mkdir(parents=True)
        (folder / f"{name}.mp4").write_bytes(os.urandom(demo.PIECE_LENGTH + 99))
        (folder / "release.json").write_text(json.dumps({**meta, "license": "CC BY 4.0"}))
    monkeypatch.setenv("MOVIECLAW_DEMO_SEED_DIR", str(seeds))
    monkeypatch.setenv("MOVIECLAW_DEMO_SITE_DIR", str(tmp_path / "site"))
    demo.build_catalog()
    return demo.DemoSite(
        site_id="demo", base_url="https://x.invalid", client=None, auth_manager=None
    )


def test_demo_site_is_registered_as_builtin(tmp_path) -> None:
    load_all_sites(str(tmp_path / "user-sites"))
    config = get_site_config("demo")
    assert config.site_class is demo.DemoSite
    assert "apikey" in config.supported_auth_types


async def test_search_matches_english_chinese_and_year(site) -> None:
    for keyword, expected in [("spring", 1), ("冲锋", 1), ("2022", 1), ("", 2), ("sintel", 0)]:
        result = await site.search(SearchQuery(keyword=keyword))
        assert len(result.items) == expected, keyword
    hit = (await site.search(SearchQuery(keyword="spring"))).items[0]
    assert "CC BY 4.0" in hit.subtitle and hit.size_bytes > demo.PIECE_LENGTH
    assert hit.download_url and not hit.download_url.startswith("http")


async def test_torrents_are_real_and_stable(site, tmp_path) -> None:
    catalog = demo.load_catalog()
    torrent = await site.download_torrent(f"download.php?id={catalog[0]['torrent_id']}")
    assert compute_info_hash(torrent) == catalog[0]["info_hash"]
    # 重建目录：文件没变就不重算，info_hash 不变
    assert demo.build_catalog()[0]["info_hash"] == catalog[0]["info_hash"]
    detail = await site.get_torrent_detail(f"download.php?id={catalog[0]['torrent_id']}")
    assert detail.file_list == [f["path"] for f in catalog[0]["files"]]
    # 资源站给出影片编号：订阅靠它区分同名同年的片
    spring = next(e for e in catalog if e["title"] == "Spring")
    assert (await site.get_torrent_detail(f"id={spring['torrent_id']}")).imdb_id == "tt9249278"


async def test_list_rotates_free_boost_releases(site) -> None:
    page = await site.list_torrents()
    boosts = [item for item in page.items if item.free]
    assert len(boosts) == demo.BOOST_PER_WINDOW
    assert all(item.leechers >= 1 and item.download_volume_factor == 0 for item in boosts)
    # 刷流准入的供需门槛（ratio_boost._MIN_ADMIT_SCORE）：每条都得够格，否则审核员看不到刷流
    assert all(item.leechers / (item.seeders + 1) >= 3 for item in boosts)
    torrent = await site.download_torrent(boosts[0].download_url)
    assert len(compute_info_hash(torrent)) == 40
    assert (await site.list_torrents(page=2)).items == []
    # 只有一页：明确说没有下一页，客户端据此不显示「加载更多」
    assert page.has_more is False
    first = await site.search(SearchQuery(keyword="spring"))
    assert first.has_more is False and first.items
    assert (await site.search(SearchQuery(keyword="spring", page=2))).items == []
    profile = await site.get_user_profile()
    assert profile.username


async def test_boost_release_ids_survive_catalog_changes(site, tmp_path, monkeypatch) -> None:
    """刷流种的 ID 里带着底片：目录增减后，按旧 ID 取到的仍是同一条种子。"""
    listed = next(item for item in (await site.list_torrents()).items if item.free)
    before = await site.download_torrent(listed.download_url)
    extra = tmp_path / "seeds" / "Wing.It.2023.1080p.WEB-DL.AAC.H.264-BLENDER"
    extra.mkdir()
    (extra / "w.mp4").write_bytes(b"w" * 10)
    (extra / "release.json").write_text(json.dumps({"title": "Wing It!", "year": 2023}))
    demo.build_catalog()
    assert await site.download_torrent(listed.download_url) == before
    detail = await site.get_torrent_detail(listed.download_url)
    assert detail.title == listed.title


async def test_boost_releases_never_match_a_film_search(site) -> None:
    """刷流种会进本地种子索引：名字和副标题都不能带片名，免得被按片名搜到或被订阅抓走。"""
    boosts = [item for item in (await site.list_torrents()).items if item.free]
    for item in boosts:
        text = f"{item.title} {item.subtitle}".lower()
        assert not any(word in text for word in ("spring", "charge", "春", "冲锋")), text

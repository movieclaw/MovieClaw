"""HDWing 合成页面回归：注册 → Cookie 认证 → 搜索/优惠/详情/资料。

所有账号、Cookie、下载 hash、种子内容均为测试数据，不访问真实站点。
"""

from __future__ import annotations

import json
from datetime import datetime
from urllib.parse import parse_qs

import httpx
import pytest

from movieclaw_tracker import CookieAuthProvider, create_site, load_all_sites
from movieclaw_tracker.exceptions import TrackerAuthError, TrackerParseError
from movieclaw_tracker.models import SearchQuery, TorrentCategory
from movieclaw_tracker.registry import get_site_config, list_sites
from movieclaw_tracker.sites.custom.hdwing import HDWingSite

BASE = "https://hdwing.org"
COOKIE = "synthetic-hdwing-cookie"
HOME = """
<html><body><div id="site_header"><div class="userinfo">
  <a href="userdetails.php?id=12345"><b>fixture_user</b></a>
</div></div><div id="comments"><a href="userdetails.php?id=999">other_user</a></div>
</body></html>
"""
ROW = """
<tr><td class="t_cat"><a href="?cat=410"><img class="catchs type_410"></a></td>
<td class="t_name"><table class="tbname"><tr><td class="t_pin"></td><td>
  <h3><a href="details.php?id={id}&amp;hit=1" title="Fixture Movie 2026 2160p">
    Fixture Movie…</a></h3><h4>测试副标题</h4></td>
  <td class="discount"><span class="sp_state_placeholder" id="{id}"></span></td>
  <td class="share_rule"><img src="/pic/share_rule_3.gif" title="禁止转载"></td>
  <td class="act"><a href="download.php?hash=synthetic-{id}">下载</a></td>
</tr></table></td>
<td class="t_comment"><a href="details.php?id={id}&amp;cmtpage=1">8</a></td>
<td class="t_time"><span title="2026-11-07 12:00:00">刚刚</span></td>
<td class="t_size">12.5 GB</td><td class="t_torrents"><b>42</b></td>
<td class="t_leech"><a>3</a></td><td class="t_completed"><a>999</a></td>
<td class="t_uploader"><span class="nowrap"><a>fixture_uploader</a></span></td></tr>
"""


def listing(torrent_id: str = "101", *, csrf: bool = True) -> str:
    meta = '<meta name="x-csrf" content="synthetic-csrf">' if csrf else ""
    return (
        f"<html><head>{meta}</head><body><table class='torrent_list'>"
        f"<tr><th>表头</th></tr>{ROW.format(id=torrent_id)}</table>"
        "<a href='?page=0'>1</a><a href='?page=7'>8</a></body></html>"
    )


PROFILE = """
<html><body><div id="site_header"><div class="userinfo">
<a href="userdetails.php?id=999">wrong_header_user</a></div></div>
<div class="noraml_box"><h2><span class="nowrap"><b>fixture_user</b></span></h2>
<table><tr><td class="rowhead">等级</td><td><img alt="金牌经纪(Insane User)"></td></tr>
<tr><td class="rowhead">传输</td><td><table>
  <tr><td><strong>分享率</strong>: <font>3.125</font></td></tr>
  <tr><td><strong>上传量</strong>: 25.0 TB(本月1.0 GB)</td>
      <td><strong>下载量</strong>: 8.0 TB(本月2.0 GB)</td></tr>
</table></td></tr><tr><td class="rowhead">魔力值</td><td>123,456.5</td></tr>
<tr><td class="rowhead">当前做种</td><td><a><u>[显示/隐藏]</u></a>
  (12个种子，共计12.5 GB)<div hidden>999</div></td></tr>
<tr><td class="rowhead">当前下载</td><td><a><u>[显示/隐藏]</u></a>
  (2个种子，共计3.0 GB)</td></tr></table></div>
</body></html>
"""
DETAIL = """
<html><body><div class="details_box"><table class="movie_details"><tr><td>
<h2 id="top">Fixture Movie 2026 2160p<span class="sp_state_placeholder" id="101"></span></h2>
<h3>测试副标题</h3></td><td class="info_box">
<a href="download.php?hash=synthetic-101">下载种子</a>
<ul><li class="right bspace"><i><b>大小：</b>12.5 GB</i></li></ul></td></tr></table>
<table class="table_details"><tr><td class="rowhead">简介</td><td>
<div id="kdescr">合成简介</div></td></tr><tr><td class="rowhead">种子文件</td><td>
<div class="file_structure"><a href="javascript:void(0)">展开文件列表</a></div>
</td></tr></table><a href="https://www.imdb.com/title/tt1234567/">IMDb</a>
<a href="https://movie.douban.com/subject/1234567/">豆瓣</a></div></body></html>
"""


@pytest.fixture
async def site(monkeypatch):
    load_all_sites()
    requests: list[httpx.Request] = []
    control = {"listing": None, "promotion": None, "profile": PROFILE}

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.url.host == "hdwing.org"
        assert COOKIE in request.headers.get("cookie", "")
        path = request.url.path
        if path == "/torrents.php":
            torrent_id = "102" if request.url.params.get("page") == "1" else "101"
            return httpx.Response(200, text=control["listing"] or listing(torrent_id))
        if path == "/ajax_promotion.php":
            assert request.method == "POST"
            data = parse_qs(request.content.decode())
            assert data["csrf"] == ["synthetic-csrf"]
            assert request.headers["referer"].startswith(BASE + "/torrents.php?")
            payload = control["promotion"]
            if payload is None:
                payload = {
                    "status": 200,
                    "message": {
                        tid: {
                            "sp_state": '<img class="pro_free2up" alt="Free 2x">',
                            "timeout": '<span title="2026-11-08 12:00:00">限时</span>',
                        }
                        for tid in data["ids[]"]
                    },
                }
            return httpx.Response(200, text=json.dumps(payload))
        if path == "/index.php":
            return httpx.Response(200, text=HOME)
        if path == "/userdetails.php":
            assert request.url.params["id"] == "12345"
            return httpx.Response(200, text=control["profile"])
        if path == "/details.php":
            return httpx.Response(200, text=DETAIL)
        if path == "/download.php":
            assert request.url.params["hash"] == "synthetic-101"
            return httpx.Response(200, content=b"synthetic-torrent-bytes")
        raise AssertionError(f"Unexpected endpoint: {path}")

    monkeypatch.setattr(
        "movieclaw_tracker.http.egress_transport", lambda *a, **kw: httpx.MockTransport(handler)
    )
    # 本地 MockTransport 不需要站点限流；生产配置仍然为 5 秒。
    monkeypatch.setattr("movieclaw_tracker.http.get_site_limiter", lambda *a, **kw: None)
    instance = await create_site("hdwing", auth_provider=CookieAuthProvider({"fixture": COOKIE}))
    assert (await instance.authenticate()).success
    try:
        yield instance, requests, control
    finally:
        await instance.client.close()


def test_builtin_config_is_registered_with_supported_auth_and_categories():
    load_all_sites()
    config = get_site_config("hdwing")
    assert config.display_name == "瓷器" and config.base_url == BASE
    assert config.site_class is HDWingSite
    assert config.supported_auth_types == ("cookie",)
    assert config.min_request_interval == 5.0
    assert config.selectors.page_offset == -1
    assert config.selectors.torrent_hr_css == "" and config.hr_seed_hours is None
    assert len({cat for ids in config.category_map.values() for cat in ids}) == 26
    assert sum(item.site_id == "hdwing" for item in list_sites()) == 1


async def test_factory_search_promotion_detail_download_profile_flow(site):
    instance, requests, _ = site
    result = await instance.search(
        SearchQuery(keyword="Fixture", categories=[TorrentCategory.MOVIE])
    )
    assert result.page == 1 and result.total_pages == 8
    first = result.items[0]
    assert first.torrent_id == "101" and first.title == "Fixture Movie 2026 2160p"
    assert first.subtitle == "测试副标题" and first.category is TorrentCategory.MOVIE
    assert first.size_bytes == int(12.5 * 1024**3)
    assert (first.seeders, first.leechers, first.snatched) == (42, 3, 999)
    assert first.uploader == "fixture_uploader" and first.hit_and_run is None
    assert first.upload_time == datetime(2026, 11, 7, 4)
    assert first.free and first.download_volume_factor == 0 and first.upload_volume_factor == 2
    assert first.free_deadline == datetime(2026, 11, 8, 4)
    assert requests[0].url.params["page"] == "0"
    assert requests[0].url.params["search"] == "Fixture"
    assert requests[0].url.params["cat410"] == "1"

    detail = await instance.get_torrent_detail(first.detail_url)
    assert detail.title == first.title and detail.subtitle == first.subtitle
    assert detail.size == "12.5 GB" and "合成简介" in detail.description
    assert detail.imdb_id == "tt1234567" and detail.douban_id == "1234567"
    assert detail.file_list == [] and detail.download_url == first.download_url
    assert await instance.download_torrent(detail.download_url) == b"synthetic-torrent-bytes"

    profile = await instance.get_user_profile()
    assert profile.user_id == "12345" and profile.username == "fixture_user"
    assert profile.user_class == "金牌经纪(Insane User)"
    assert profile.ratio == 3.125 and profile.bonus == 123456.5
    assert profile.uploaded_bytes == 25 * 1024**4 and profile.downloaded_bytes == 8 * 1024**4
    assert profile.uploaded == "25.0 TB" and profile.downloaded == "8.0 TB"
    assert (profile.seeding_count, profile.leeching_count) == (12, 2)
    assert not profile.vip_group
    assert [request.url.path for request in requests] == [
        "/torrents.php",
        "/ajax_promotion.php",
        "/details.php",
        "/download.php",
        "/index.php",
        "/userdetails.php",
    ]


async def test_list_second_page_preserves_zero_index_and_tv_filter(site):
    instance, requests, _ = site
    result = await instance.list_torrents(page=2, categories=[TorrentCategory.TV])
    assert result.items[0].torrent_id == "102" and result.page == 2
    assert requests[0].url.params["page"] == "1" and requests[0].url.params["cat401"] == "1"
    assert "search" not in requests[0].url.params


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"status": 403, "message": {}},
        {"status": 200, "message": {}},
        {"status": 200, "message": {"101": {"sp_state": None, "timeout": ""}}},
        {"status": 200, "message": {"101": {"sp_state": "", "timeout": None}}},
        {"status": 200, "message": []},
        ["unexpected"],
    ],
)
async def test_unconfirmed_promotion_is_not_silently_treated_as_normal(site, payload):
    instance, requests, control = site
    control["promotion"] = payload
    with pytest.raises(TrackerParseError, match="promotion response is invalid") as error:
        await instance.list_torrents()
    assert "synthetic-csrf" not in str(error.value) and COOKIE not in str(error.value)
    assert len(requests) == 2


async def test_empty_successful_promotion_means_no_discount(site):
    instance, _, control = site
    control["promotion"] = {"status": 200, "message": {"101": {"sp_state": "", "timeout": ""}}}
    item = (await instance.list_torrents()).items[0]
    assert not item.free and item.download_volume_factor == item.upload_volume_factor == 1


# 2026-11-07 站点真实返回：``onmouseover`` 的引号没闭合就被截断的半截 HTML
TRUNCATED_FREE = (
    '<p style="display: none"> <img class="pro_free" src="pic/trans.gif" alt="Free" '
    "onmouseover=\"domTT_activate(this, event, 'content', "
    "'<b><font class=&quot;free&quot;>免费</font></b>"
)


async def test_truncated_promotion_fragment_is_not_silently_dropped(site):
    """半截 HTML 也要能认出免费，否则全站免费时每个种子都会被当成普通种。"""
    instance, _, control = site
    control["promotion"] = {
        "status": 200,
        "message": {"101": {"sp_state": TRUNCATED_FREE, "timeout": ""}},
    }

    item = (await instance.list_torrents()).items[0]

    assert item.free and item.download_volume_factor == 0.0


async def test_truncated_promotion_fragment_keeps_deadline(site):
    instance, _, control = site
    control["promotion"] = {
        "status": 200,
        "message": {
            "101": {
                "sp_state": TRUNCATED_FREE,
                "timeout": '<span title="2026-11-08 12:00:00">限时</span>',
            }
        },
    }

    item = (await instance.list_torrents()).items[0]

    assert item.download_volume_factor == 0.0
    assert item.free_deadline == datetime(2026, 11, 8, 4)


async def test_missing_csrf_prevents_promotion_post(site):
    instance, requests, control = site
    control["listing"] = listing(csrf=False)
    with pytest.raises(TrackerParseError, match="query context is missing"):
        await instance.list_torrents()
    assert len(requests) == 1


async def test_login_page_never_triggers_promotion_or_login_post(site):
    instance, requests, control = site
    control["listing"] = '<form action="takelogin.php"><input type="password"></form>'
    with pytest.raises(TrackerAuthError):
        await instance.list_torrents()
    assert len(requests) == 1


async def test_empty_listing_does_not_need_promotion_request(site):
    instance, requests, control = site
    control["listing"] = (
        '<html><body><table class="torrent_list"><tr><th>表头</th></tr></table></body></html>'
    )
    page = await instance.list_torrents()
    assert page.items == [] and page.total_pages is None
    assert len(requests) == 1


async def test_explicit_user_id_skips_index_discovery(site):
    instance, requests, _ = site
    assert (await instance.get_user_profile("12345")).username == "fixture_user"
    assert [request.url.path for request in requests] == ["/userdetails.php"]


async def test_profile_login_redirect_does_not_return_header_username(site):
    instance, _, control = site
    control["profile"] = HOME + '<form action="takelogin.php"><input type="password"></form>'
    with pytest.raises(TrackerParseError, match="user profile"):
        await instance.get_user_profile("12345")

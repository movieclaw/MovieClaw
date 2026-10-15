"""网盘挂载直链钩子（docs/design/strm-playback.md §10）。

strm 指向服务器挂载目录里的文件时，插件经 ``playback.strm.direct-link`` 给出网盘直链，播放器被
302 过去；插件没认领、出错、给的地址播放器连不上，一律照旧由服务器出挂载里的字节。

钩子层用内核测试工具挂真插件；端点层（``TestClient`` 跑在另一个事件循环里）替换钩子入口。
"""

# ruff: noqa: F811 — 复用其他测试文件的夹具，用例参数与导入同名

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from urllib.parse import quote

import pytest
from tests.api.test_playback_stream import (  # noqa: F401
    _install_remote_session,
    client,
    seed,
    start_session,
)
from tests.api.test_strm_compat import BODY, PLAYER_UA, eco, mount  # noqa: F401

from movieclaw_api import events, hooks
from movieclaw_api.services.playback import strm_direct
from movieclaw_kernel import plugin
from movieclaw_kernel.testing import KernelHarness

CDN = "https://cdn.example.com/115/a.mkv?t=1&k=abc"


@pytest.fixture(autouse=True)
def _fresh_cache():
    strm_direct._cache.clear()
    yield
    strm_direct._cache.clear()


@asynccontextmanager
async def direct_link_plugin(handler):
    @plugin("test.direct-link", title="直链测试")
    async def apply(ctx) -> None:
        ctx.on(hooks.STRM_DIRECT_LINK, handler)

    async with KernelHarness() as h:
        events.bind_bus(h.kernel.bus)
        try:
            fiber = await h.mount(apply)
            assert fiber.state.value == "active", fiber.error
            yield h
        finally:
            events.unbind_bus(h.kernel.bus)


# ---------------------------------------------------------------------------
# 钩子层
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_without_plugins_nothing_is_asked(mount):
    assert await strm_direct.mounted_redirect(1, mount, PLAYER_UA) is None


@pytest.mark.asyncio
async def test_claimed_file_gets_the_plugin_link_and_it_is_reused(mount):
    seen = []

    async def handler(payload: hooks.MountedFile):
        seen.append(payload)
        return hooks.DirectLink(url=CDN, ttl_s=600)

    async with direct_link_plugin(handler):
        assert await strm_direct.mounted_redirect(7, mount, PLAYER_UA) == CDN
        assert await strm_direct.mounted_redirect(7, mount, PLAYER_UA) == CDN  # 拖进度：用缓存
        assert len(seen) == 1
        assert seen[0] == hooks.MountedFile(file_id=7, path=str(mount), user_agent=PLAYER_UA)
        # 直链与 UA 绑定：换个播放器要重新问
        await strm_direct.mounted_redirect(7, mount, "VLC/3")
        assert [p.user_agent for p in seen] == [PLAYER_UA, "VLC/3"]


@pytest.mark.asyncio
async def test_unclaimed_file_is_served_locally_and_not_asked_per_range_request(mount):
    calls = []

    async def handler(payload):
        calls.append(payload)
        return None

    async with direct_link_plugin(handler):
        for _ in range(5):
            assert await strm_direct.mounted_redirect(1, mount, PLAYER_UA) is None
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_broken_or_unusable_answers_fall_back_to_serving_bytes(mount):
    async def broken(_payload):
        raise RuntimeError("网盘登录失效")

    async with direct_link_plugin(broken):
        assert await strm_direct.mounted_redirect(1, mount, PLAYER_UA) is None

    strm_direct._cache.clear()

    async def not_http(_payload):
        return hooks.DirectLink(url="file:///etc/passwd")

    async with direct_link_plugin(not_http):
        assert await strm_direct.mounted_redirect(1, mount, PLAYER_UA) is None


@pytest.mark.asyncio
async def test_lan_302_service_link_is_followed_with_the_player_ua(mount, eco):
    """插件给内网 alist 的 /d/ 地址：服务端带播放器的 UA 跟跳转，把播放器送到网盘 CDN。"""
    eco.add("a.mkv", BODY)

    async def handler(_payload):
        return hooks.DirectLink(url=f"{eco.base}/alist/d/115/{quote('a.mkv')}?sign=x")

    async with direct_link_plugin(handler):
        url = await strm_direct.mounted_redirect(1, mount, PLAYER_UA)
    assert url == eco.cdn_url("a.mkv", PLAYER_UA)
    assert [r.ua for r in eco.log] == [PLAYER_UA]


@pytest.mark.asyncio
async def test_lan_link_that_serves_bytes_itself_is_ignored(mount, eco):
    """跟跳转也落不到外网（内网服务自己出字节）：与其让服务器转发，不如照旧读挂载。"""
    eco.add("a.mkv", BODY)

    async def handler(_payload):
        return hooks.DirectLink(url=f"{eco.base}/alist/d/local/a.mkv?sign=x")

    async with direct_link_plugin(handler):
        assert await strm_direct.mounted_redirect(1, mount, PLAYER_UA) is None


@pytest.mark.asyncio
async def test_concurrent_requests_ask_the_plugin_once(mount):
    calls = []

    async def handler(payload):
        calls.append(payload)
        await asyncio.sleep(0.05)
        return hooks.DirectLink(url=CDN)

    async with direct_link_plugin(handler):
        urls = await asyncio.gather(
            *(strm_direct.mounted_redirect(1, mount, PLAYER_UA) for _ in range(4))
        )
    assert urls == [CDN] * 4 and len(calls) == 1


@pytest.mark.asyncio
async def test_disabling_the_plugin_stops_redirecting_at_once(mount):
    async def handler(_payload):
        return hooks.DirectLink(url=CDN, ttl_s=3600)

    async with direct_link_plugin(handler):
        assert await strm_direct.mounted_redirect(1, mount, PLAYER_UA) == CDN
    assert await strm_direct.mounted_redirect(1, mount, PLAYER_UA) is None


# ---------------------------------------------------------------------------
# 端点层
# ---------------------------------------------------------------------------


@pytest.fixture
def fake_plugin(monkeypatch):
    """替换钩子入口：认领 ``claimed`` 里的路径，记下问过的载荷。"""
    state = {"claimed": set(), "asked": []}

    async def bail(event, payload):
        assert event is hooks.STRM_DIRECT_LINK
        state["asked"].append(payload)
        return hooks.DirectLink(url=CDN) if payload.path in state["claimed"] else None

    monkeypatch.setattr(hooks, "active", lambda event: event is hooks.STRM_DIRECT_LINK)
    monkeypatch.setattr(hooks, "bail", bail)
    return state


def test_web_stream_redirects_claimed_mount_files(client, tmp_path, mount, fake_plugin):
    fake_plugin["claimed"].add(str(mount.resolve()))
    file_id = seed(client, tmp_path, container="mkv", strm=True, strm_url=str(mount))
    url = start_session(client, file_id, capability={"universal": True})["stream_url"]
    resp = client.get(url, headers={"User-Agent": PLAYER_UA}, follow_redirects=False)
    assert resp.status_code == 302 and resp.headers["location"] == CDN
    assert fake_plugin["asked"][0].file_id == file_id
    assert fake_plugin["asked"][0].user_agent == PLAYER_UA


def test_web_stream_serves_unclaimed_mount_files_as_before(client, tmp_path, mount, fake_plugin):
    file_id = seed(client, tmp_path, container="mp4", strm=True, strm_url=str(mount))
    url = start_session(client, file_id)["stream_url"]
    resp = client.get(url, headers={"Range": "bytes=0-99"})
    assert resp.status_code == 206 and resp.content == BODY[:100]
    assert len(fake_plugin["asked"]) == 1


def test_remote_worker_takes_claimed_mount_files_from_the_cloud(
    client, tmp_path, mount, fake_plugin
):
    fake_plugin["claimed"].add(str(mount.resolve()))
    file_id = seed(client, tmp_path, container="mkv", strm=True, strm_url=str(mount))
    grants = _install_remote_session(client, tmp_path, file_id)
    resp = client.get(
        f"/api/v1/transcode-worker/sessions/{grants['session_id']}/source?token={grants['source']}",
        follow_redirects=False,
    )
    assert resp.status_code == 302 and resp.headers["location"] == CDN


def test_plain_local_files_never_ask_the_plugin(client, tmp_path, fake_plugin):
    file_id = seed(client, tmp_path, container="mp4")
    resp = client.get(start_session(client, file_id)["stream_url"], headers={"Range": "bytes=0-9"})
    assert resp.status_code == 206 and fake_plugin["asked"] == []

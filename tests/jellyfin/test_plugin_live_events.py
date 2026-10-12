"""Jellyfin 客户端的动作也产生系统事件（docs/design/domain-events.md §8）。

客户端取单个条目 / 集 → ``library.item.viewed``（client=jellyfin）；开始播放、收藏走与网页
共用的 watch / marks 服务，同样发 ``playback.started`` / ``library.item.favorited``。
"""

from __future__ import annotations

import time

from jellyfin.helpers import jf_login
from movieclaw_jellyfin.ids import episode_guid, item_guid
from movieclaw_kernel import Entry, plugin
from movieclaw_sdk.events import LIBRARY_ITEM_FAVORITED, LIBRARY_ITEM_VIEWED, PLAYBACK_STARTED


def wait_for(predicate, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("等待超时")


def test_jellyfin_clients_emit_view_play_and_favorite(client, seeded) -> None:
    heard: list[tuple[str, object]] = []

    @plugin("test.jf-listener", title="听事件")
    async def listener(ctx) -> None:
        for event in (LIBRARY_ITEM_VIEWED, PLAYBACK_STARTED, LIBRARY_ITEM_FAVORITED):
            ctx.on(event, lambda p, name=event.name: heard.append((name, p)), id=event.name)

    kernel = client.app.state.kernel
    client.portal.call(kernel.mount, Entry("test.jf-listener", listener))
    auth = {"ApiKey": jf_login(client)}

    def got(name):
        return [p for n, p in heard if n == name]

    ep = episode_guid(seeded["show"], 1, 2)
    assert client.get(f"/Items/{ep}", params=auth).status_code == 200
    wait_for(lambda: got("library.item.viewed"))
    viewed = got("library.item.viewed")[0]
    assert (viewed.media.id, viewed.season, viewed.episode) == (seeded["show"], 1, 2)
    assert viewed.client.name == "jellyfin"

    assert client.get(f"/Items/{item_guid(seeded['show'])}", params=auth).status_code == 200
    wait_for(lambda: len(got("library.item.viewed")) == 2)
    assert got("library.item.viewed")[1].season is None

    assert client.post("/Sessions/Playing", params=auth, json={"ItemId": ep}).status_code == 204
    wait_for(lambda: got("playback.started"))
    assert got("playback.started")[0].unit.episode == 2

    url = f"/UserFavoriteItems/{item_guid(seeded['show'])}"
    assert client.post(url, params=auth).status_code == 200
    wait_for(lambda: got("library.item.favorited"))
    assert got("library.item.favorited")[0].level == "series"

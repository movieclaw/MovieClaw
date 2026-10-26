"""局域网自动发现（movieclaw_api.services.lan_discovery）。

重点场景：Docker 桥接部署下探测到的是容器内网 IP，此时应改用浏览器访问时
学到的局域网地址或「外部访问地址」，而不是把 172.x 回给客户端。
"""

from __future__ import annotations

import asyncio
import json
import logging

import pytest

from movieclaw_api.services import lan_discovery
from movieclaw_api.settings import AppServerSetting
from movieclaw_api.settings.schemas import JellyfinCompatSetting


class _FakeStore:
    def __init__(self, external_url: str, origins: list[str] | None = None) -> None:
        self.values = {
            AppServerSetting: AppServerSetting(external_url=external_url),
            lan_discovery.LanOriginsSetting: lan_discovery.LanOriginsSetting(origins=origins or []),
        }
        self.writes = 0

    async def get(self, schema):
        return self.values[schema]

    async def set(self, instance):
        self.writes += 1
        self.values[type(instance)] = instance


@pytest.fixture
def env(monkeypatch):
    """probe=探测出的本机 IP；external=外部访问地址；origins=库里记着的局域网访问地址。"""

    def configure(
        *,
        probe: str | None,
        external: str = "",
        origins: list[str] | None = None,
        compat: JellyfinCompatSetting | None = None,
    ) -> _FakeStore:
        store = _FakeStore(external, origins)
        monkeypatch.setattr(lan_discovery, "_probe_outbound_ip", lambda _client_ip: probe)
        monkeypatch.setattr(lan_discovery, "get_setting_store", lambda: store)
        monkeypatch.setattr(lan_discovery, "lan_origins", lan_discovery._LanOrigins())
        setting = compat or JellyfinCompatSetting(server_id="abc", server_name="客厅 NAS")

        async def get_compat():
            return setting

        monkeypatch.setattr(lan_discovery, "get_jellyfin_compat", get_compat)
        return store

    return configure


# ---------------------------------------------------------------------------
# Jellyfin 应答（只有一个地址）
# ---------------------------------------------------------------------------


async def test_published_server_url_wins(env):
    env(probe="172.17.0.3", external="http://192.168.1.10:3000")
    address = await lan_discovery._resolve_address("192.168.1.50", 3000, "http://nas.lan:3000/")
    assert address == "http://nas.lan:3000"


async def test_lan_probe_used_directly_even_with_external_url(env):
    """host 网络/裸机：探测到的局域网 IP 优先，不被（可能是公网域名的）外部访问地址覆盖。"""
    env(probe="192.168.1.10", external="https://movie.example.com")
    address = await lan_discovery._resolve_address("192.168.1.50", 3000, "")
    assert address == "http://192.168.1.10:3000"


async def test_docker_bridge_prefers_learned_lan_origin(env):
    """桥接 + 宿主端口映射成 3300：浏览器访问时学到的地址排在外部访问地址前面。"""
    env(
        probe="172.17.0.3",
        external="https://movie.example.com",
        origins=["http://192.168.1.10:3300"],
    )
    address = await lan_discovery._resolve_address("192.168.1.50", 3000, "")
    assert address == "http://192.168.1.10:3300"


async def test_docker_bridge_falls_back_to_external_url(env, caplog):
    env(probe="172.17.0.3", external="http://192.168.1.10:3000/")
    with caplog.at_level(logging.WARNING, logger="movieclaw_api.lan_discovery"):
        address = await lan_discovery._resolve_address("192.168.1.50", 3000, "")
    assert address == "http://192.168.1.10:3000"
    assert not caplog.records


async def test_docker_bridge_without_config_still_answers_with_warning(env, caplog):
    env(probe="172.17.0.3")
    with caplog.at_level(logging.WARNING, logger="movieclaw_api.lan_discovery"):
        address = await lan_discovery._resolve_address("192.168.1.50", 3000, "")
    assert address == "http://172.17.0.3:3000"
    assert "外部访问地址" in caplog.text


async def test_probe_failure_skips_reply(env):
    env(probe=None, external="http://192.168.1.10:3000")
    assert await lan_discovery._resolve_address("192.168.1.50", 3000, "") is None


async def test_jellyfin_reply_respects_compat_switch(env):
    env(probe="192.168.1.10", compat=JellyfinCompatSetting(enabled=False, server_id="abc"))
    assert await lan_discovery.jellyfin_reply("192.168.1.50", 3000) is None
    env(probe="192.168.1.10")
    assert await lan_discovery.jellyfin_reply("192.168.1.50", 3000) == {
        "Address": "http://192.168.1.10:3000",
        "Id": "abc",
        "Name": "客厅 NAS",
        "EndpointAddress": None,
    }


# ---------------------------------------------------------------------------
# 自家应答（一组地址，不受 Jellyfin 兼容开关影响）
# ---------------------------------------------------------------------------


async def test_movieclaw_reply_lists_all_candidates(env):
    env(
        probe="192.168.1.10",
        external="https://movie.example.com/",
        origins=["http://192.168.1.10:3000", "http://10.0.0.2:3300"],
        compat=JellyfinCompatSetting(enabled=False, server_id="abc", server_name="客厅 NAS"),
    )
    reply = await lan_discovery.movieclaw_reply("192.168.1.50", 3000)
    assert reply == {
        "type": "movieclaw.discovery",
        "version": 1,
        "instance_id": "abc",
        "name": "客厅 NAS",
        "server_version": lan_discovery.__version__,
        "addresses": [
            "http://192.168.1.10:3000",
            "http://10.0.0.2:3300",
            "https://movie.example.com",
        ],
        # 同一组地址标上内网 / 外网（server-addresses.md §3.2）
        "endpoints": [
            {"url": "http://192.168.1.10:3000", "kind": "lan"},
            {"url": "http://10.0.0.2:3300", "kind": "lan"},
            {"url": "https://movie.example.com", "kind": "wan"},
        ],
    }


async def test_movieclaw_reply_leaves_out_container_address(env, caplog):
    """桥接、什么都没学到：地址列表为空（App 用来源 IP 自己拼），但仍应答并告警。"""
    env(probe="172.17.0.3")
    with caplog.at_level(logging.WARNING, logger="movieclaw_api.lan_discovery"):
        reply = await lan_discovery.movieclaw_reply("192.168.1.50", 3000)
    assert reply is not None and reply["addresses"] == []
    assert "外部访问地址" in caplog.text


async def test_movieclaw_reply_skipped_when_unroutable(env):
    env(probe=None)
    assert await lan_discovery.movieclaw_reply("192.168.1.50", 3000) is None


# ---------------------------------------------------------------------------
# 从 Host 头学局域网访问地址
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("host", "fwd_host", "fwd_proto", "expected"),
    [
        ("192.168.1.10:3300", "192.168.1.10:3300", "http", "http://192.168.1.10:3300"),
        ("10.0.0.5", None, None, "http://10.0.0.5"),
        ("172.20.1.2:80", None, None, "http://172.20.1.2"),
        # 外层 HTTPS 反代没改 Host：沿用它给的协议
        ("192.168.1.10:8443", "192.168.1.10:8443", "https", "https://192.168.1.10:8443"),
        # 外层反代把 Host 改成了上游地址：对外是域名 + https，上游这一跳是 http
        ("192.168.1.10:3300", "movie.example.com", "https", "http://192.168.1.10:3300"),
        ("movie.example.com", None, None, None),
        ("127.0.0.1:3000", None, None, None),
        ("8.8.8.8", None, None, None),
        ("198.18.0.5:3000", None, None, None),  # 代理 fake-ip 段，不是 RFC 1918
        ("[fd00::1]:3000", None, None, None),
        ("192.168.1.10:abc", None, None, None),
        ("192.168.1.10:0", None, None, None),
    ],
)
def test_origin_from_host(host, fwd_host, fwd_proto, expected):
    assert lan_discovery.origin_from_host(host, fwd_host, fwd_proto) == expected


async def test_observed_origins_are_remembered_and_persisted_on_change(env):
    store = env(probe="172.17.0.3", origins=["http://192.168.1.10:3000"])
    origins = lan_discovery.lan_origins
    origins.observe(b"192.168.1.10:3300", None, None)
    origins.observe(b"192.168.1.10:3300", None, None)
    origins.observe(b"movie.example.com", b"movie.example.com", b"https")
    await asyncio.sleep(0)
    await asyncio.gather(*origins._tasks)
    # 新学到的在前，库里原有的保留在后
    assert await origins.get() == ["http://192.168.1.10:3300", "http://192.168.1.10:3000"]
    assert store.values[lan_discovery.LanOriginsSetting].origins == [
        "http://192.168.1.10:3300",
        "http://192.168.1.10:3000",
    ]
    writes = store.writes
    # 两个已知地址来回切换：只调内存里的先后，不写库
    origins.observe(b"192.168.1.10:3000", None, None)
    origins.observe(b"192.168.1.10:3300", None, None)
    await asyncio.sleep(0)
    assert store.writes == writes


# ---------------------------------------------------------------------------
# 端到端：真起 UDP 监听，两种询问各发一次
# ---------------------------------------------------------------------------


async def test_udp_listener_answers_both_queries(env):
    env(probe="192.168.1.10")
    loop = asyncio.get_running_loop()
    server, _ = await loop.create_datagram_endpoint(
        lambda: lan_discovery._DiscoveryProtocol(3000), local_addr=("127.0.0.1", 0)
    )
    port = server.get_extra_info("sockname")[1]
    received: asyncio.Queue[bytes] = asyncio.Queue()

    class _Client(asyncio.DatagramProtocol):
        def datagram_received(self, data, addr):
            received.put_nowait(data)

    client, _ = await loop.create_datagram_endpoint(_Client, remote_addr=("127.0.0.1", port))
    try:
        client.sendto(b"who is MovieClawServer?")
        mine = json.loads(await asyncio.wait_for(received.get(), 2))
        assert mine["type"] == "movieclaw.discovery"
        assert mine["addresses"] == ["http://192.168.1.10:3000"]
        client.sendto(b"Who is JellyfinServer?")
        theirs = json.loads(await asyncio.wait_for(received.get(), 2))
        assert theirs["Address"] == "http://192.168.1.10:3000"
        client.sendto(b"hello")
        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(received.get(), 0.3)
    finally:
        client.close()
        server.close()

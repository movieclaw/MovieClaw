"""Keep AI settings services real; route external search HTTP to a loopback provider."""

import os
from urllib.parse import urlsplit

import httpx
from tests.api.test_llm import _FakeProtocol
from tests.e2e._smart_api_launcher import app

from movieclaw_api.services import llm_config, web_search_config
from movieclaw_api.settings import LlmDefaultsSetting, get_setting_store
from movieclaw_llm.protocols import PROTOCOLS

upstream = os.environ["E2E_SEARCH_UPSTREAM"]
assert urlsplit(upstream).hostname == "127.0.0.1"


class SearchTransport(httpx.AsyncBaseTransport):
    def __init__(self):
        self.transport = httpx.AsyncHTTPTransport()

    async def handle_async_request(self, request):
        assert request.url.host in {"api.tavily.com", "api.exa.ai", "api.search.brave.com"}
        redirected = httpx.Request(
            request.method,
            upstream + request.url.raw_path.decode(),
            headers=request.headers,
            content=await request.aread(),
            extensions=request.extensions,
        )
        return await self.transport.handle_async_request(redirected)

    async def aclose(self):
        await self.transport.aclose()


web_search_config.search_transport = lambda **kwargs: SearchTransport()


@app.post("/api/v1/__lab/ai/stale-defaults")
async def stale_defaults():
    await get_setting_store().set(
        LlmDefaultsSetting(
            agent_model="retired-agent-model", subtitle_model="retired-subtitle-model"
        )
    )
    return {"ok": True}


# Dummy ChatGPT grants stay inside this fixture; the protocol is the external-service seam.
PROTOCOLS["openai_chatgpt"] = _FakeProtocol
revocation_confirmed = True


async def revoke_fixture_credentials(credentials):
    return revocation_confirmed


llm_config.revoke_credentials = revoke_fixture_credentials


@app.post("/api/v1/__lab/ai/revocation/{confirmed}")
async def set_revocation(confirmed: bool):
    global revocation_confirmed
    revocation_confirmed = confirmed
    return {"ok": True}


@app.post("/api/v1/__lab/sites/upstream")
async def site_http_fixture(payload: dict[str, str]):
    """Route official site adapters to the isolated loopback HTTP fixture."""
    from dataclasses import replace

    from movieclaw_tracker.registry import get_site_config, register_site

    for site_id in ("mteam", "ttg"):
        url = payload[site_id]
        assert urlsplit(url).hostname in {"127.0.0.1", "localhost"}
        register_site(
            replace(
                get_site_config(site_id),
                base_url=url,
                web_base_url=url,
                min_request_interval=0,
                max_retries=1,
                timeout=3,
            )
        )
    return {"ok": True}


@app.post("/api/v1/__lab/sites/sync/{site_id}")
async def synchronize_site_fixture(site_id: str):
    from movieclaw_api.services.torrent_sync import _sync_one_site
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.credential_repo import CredentialRepository

    assert site_id in {"mteam", "ttg"}
    async with get_database().session() as session:
        row = await CredentialRepository(session).get_by_site(site_id)
    assert row is not None
    await _sync_one_site(row)
    return {"ok": True}


@app.post("/api/v1/__lab/import-watch/tick")
async def poll_import_watch_fixture():
    """Keep real probes and jobs; remove only the five-minute quiet wait in this fixture."""
    from movieclaw_api.services import media_discover
    from movieclaw_api.services.library import ingest, scan

    ingest.get_tmdb_client = media_discover.get_tmdb_client
    scan.get_tmdb_client = media_discover.get_tmdb_client
    ingest.QUIET_SECONDS = 0
    await ingest.ingest_tick()
    return {"ok": True}


# Marketplace fixture keeps signature/hash/package validation real and substitutes only HTTP.
if os.environ.get("E2E_MARKET_UPSTREAM"):
    import json
    from urllib.parse import quote

    from movieclaw_api.services import plugin_market

    market_upstream = os.environ["E2E_MARKET_UPSTREAM"]
    assert urlsplit(market_upstream).hostname == "127.0.0.1"
    plugin_market.CATALOG_KEYS = json.loads(os.environ["E2E_MARKET_KEYS"])

    class MarketTransport(httpx.AsyncBaseTransport):
        def __init__(self):
            self.transport = httpx.AsyncHTTPTransport()

        async def handle_async_request(self, request):
            assert request.url.host in {"github.com", "raw.githubusercontent.com"}
            redirected = httpx.Request(
                request.method,
                market_upstream + "/" + quote(str(request.url), safe=""),
                content=await request.aread(),
                extensions=request.extensions,
            )
            return await self.transport.handle_async_request(redirected)

        async def aclose(self):
            await self.transport.aclose()

    plugin_market.transport_factory = MarketTransport


@app.post("/api/v1/__lab/im/upstream")
async def im_http_fixture(payload: dict[str, str]):
    """Use the owned drivers and real HTTP; replace only their external destination."""
    from movieclaw_plugins.weixin.weixin_channel import binding as weixin_binding
    from movieclaw_sdk import net

    upstream = payload["url"].rstrip("/")
    assert urlsplit(upstream).hostname == "127.0.0.1"
    weixin_binding.DEFAULT_BASE_URL = upstream + "/weixin"
    original_poll = getattr(
        weixin_binding.poll_qr_status, "_fixture_original", weixin_binding.poll_qr_status
    )

    async def poll(base_url, qrcode, verify_code=None):
        return await original_poll(upstream + "/weixin", qrcode, verify_code)

    poll._fixture_original = original_poll
    weixin_binding.poll_qr_status = poll
    original = getattr(net.http_transport, "_fixture_original", net.http_transport)

    class ImTransport(httpx.AsyncBaseTransport):
        def __init__(self, service):
            self.service = service
            self.transport = httpx.AsyncHTTPTransport()

        async def handle_async_request(self, request):
            assert request.url.host in {"api.telegram.org", "open.feishu.cn"}
            return await self.transport.handle_async_request(
                httpx.Request(
                    request.method,
                    upstream + "/" + self.service + request.url.raw_path.decode(),
                    headers=request.headers,
                    content=await request.aread(),
                    extensions=request.extensions,
                )
            )

        async def aclose(self):
            await self.transport.aclose()

    def transport(service=None, **kwargs):
        return (
            ImTransport(service)
            if service in {"telegram", "feishu"}
            else original(service, **kwargs)
        )

    transport._fixture_original = original
    net.http_transport = transport
    return {"ok": True}
